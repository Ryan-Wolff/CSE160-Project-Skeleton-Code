#include <Timer.h>
#include "../../includes/packet.h"
#include "../../includes/protocol.h"
#include "../../includes/channels.h"

module LinkStateP {
    provides interface LinkState;
    uses interface NDiscovery;
    uses interface SimpleSend as Sender;
    uses interface Timer<TMilli> as updateTimer;
    uses interface Random;
}

implementation {
    enum {
        ROUTE_INFINITY = 16,
        MAX_NODES = 255,
        MAX_NEIGHBORS = 64,
        ROUTE_PERIOD = 250,
        DV_MAGIC = 0xD7,
        DV_ENTRIES = (PACKET_MAX_PAYLOAD_SIZE - 2) / 2
    };
    
    uint8_t distance[256], nextHopTable[256], knownDestination[256];
    uint8_t neighborDistance[MAX_NEIGHBORS][256];
    uint8_t hasNeighborVector[MAX_NEIGHBORS];
    uint8_t neighborIds[MAX_NEIGHBORS];
    uint16_t lastAdvertisementSequence[MAX_NEIGHBORS];
    uint8_t hasAdvertisementSequence[MAX_NEIGHBORS];
    uint16_t advertisementSequence;
    uint8_t neighborSendIndex, destinationScanStart;

    bool sequenceIsNewer(uint16_t candidateSequence, uint16_t savedSequence) {
        return (int16_t)(candidateSequence - savedSequence) > 0;
    }

    void recompute() {
        uint16_t destinationId;
        uint8_t neighborIndex, neighborCost, bestCost, bestNextHop, activeNeighborCount, neighborId, vectorIndex;

        activeNeighborCount = call NDiscovery.neighborCount();
        for (destinationId = 1; destinationId <= MAX_NODES; destinationId++) {
            if (destinationId == TOS_NODE_ID) {
                // this node is dest
                distance[destinationId] = 0;
                nextHopTable[destinationId] = 0;
                knownDestination[destinationId] = TRUE;
                continue;
            }
            
            bestNextHop = 0;
            bestCost = ROUTE_INFINITY;
            
            for (neighborIndex = 0; neighborIndex < activeNeighborCount && neighborIndex < MAX_NEIGHBORS; neighborIndex++) {
                neighborId = call NDiscovery.neighborAt(neighborIndex);
                neighborCost = ROUTE_INFINITY;

                if (neighborId == 0)
                    continue;
                if (destinationId == neighborId)
                    neighborCost = 1;
                else {
                    for (vectorIndex = 0; vectorIndex < MAX_NEIGHBORS && neighborIds[vectorIndex] != neighborId; vectorIndex++) {}

                    if (vectorIndex < MAX_NEIGHBORS && hasNeighborVector[vectorIndex])
                        neighborCost = neighborDistance[vectorIndex][destinationId];
                    else
                        continue; // dest is unreachable through this path as far as we know
                }

                if (neighborCost < ROUTE_INFINITY && (uint8_t)(neighborCost + 1) < bestCost) {
                    // found new best route to dest node
                    bestCost = neighborCost + 1;
                    bestNextHop = neighborId;
                }
            }

            // If unreachable dest, these will be 0 and INFIINITY respectively 
            nextHopTable[destinationId] = bestNextHop;
            distance[destinationId] = bestCost;

            if (bestCost < ROUTE_INFINITY)
                knownDestination[destinationId] = TRUE;
        }
    }

    // Set nextHopAddress to the selected first hop if available and return TRUE
    // If node is unreachable, return FALSE and dont change nextHopAddress
    command bool LinkState.nextHop(uint8_t destination, uint8_t *nextHopAddress) {
        if (destination == TOS_NODE_ID) {
            *nextHopAddress = (uint8_t) TOS_NODE_ID;
            return TRUE;
        }

        if (destination == 0 || distance[destination] >= ROUTE_INFINITY)
            return FALSE;

        *nextHopAddress = nextHopTable[destination];
        return *nextHopAddress != 0;
    }

    // Set nextHopAddress to the selected first hop if available and dist to its cost and return TRUE
    // If node is unreachable, return FALSE and dont change nextHopAddress
    command bool LinkState.nextHopWithDist(uint8_t destination, uint8_t *nextHopAddress, uint8_t* dist) {
        if (destination == TOS_NODE_ID) {
            *nextHopAddress = (uint8_t) TOS_NODE_ID;
            return TRUE;
        }

        if (destination == 0 || distance[destination] >= ROUTE_INFINITY)
            return FALSE;

        *nextHopAddress = nextHopTable[destination];
        *dist = distance[destination];
        return *nextHopAddress != 0;
    }

    // Initialize self and routes, then begin randomized periodic advertisements
    command void LinkState.start() {
        uint16_t destinationId;
        for (destinationId = 0; destinationId < 256; destinationId++) {
            distance[destinationId] = ROUTE_INFINITY;
            nextHopTable[destinationId] = 0;
            knownDestination[destinationId] = FALSE;
        }
        distance[TOS_NODE_ID] = 0;
        knownDestination[TOS_NODE_ID] = TRUE;
        neighborSendIndex = 0;
        destinationScanStart = 0;
        call updateTimer.startPeriodic(ROUTE_PERIOD + (call Random.rand16() % ROUTE_PERIOD));
    }

    // Remove vectors for neighbors that have expired, then recalculate routes
    // immediately so traffic can use remaining backup routes.
    event void NDiscovery.neighborsChanged() {
        uint8_t vectorIndex, neighborIndex, activeNeighborCount = call NDiscovery.neighborCount();
        bool isPresent;
        for (vectorIndex = 0; vectorIndex < MAX_NEIGHBORS; vectorIndex++) {
            if (neighborIds[vectorIndex] != 0) {
                isPresent = FALSE;
                for (neighborIndex = 0; neighborIndex < activeNeighborCount; neighborIndex++)
                    if (call NDiscovery.neighborAt(neighborIndex) == neighborIds[vectorIndex])
                        isPresent = TRUE;
                
                if (!isPresent) {
                    neighborIds[vectorIndex] = 0;
                    hasNeighborVector[vectorIndex] = FALSE;
                    hasAdvertisementSequence[vectorIndex] = FALSE;
                    memset(neighborDistance[vectorIndex], ROUTE_INFINITY, sizeof neighborDistance[vectorIndex]);
                }
            }
        }
        recompute();
    }

    // Validate a one-hop DV fragment and copy its entries into owned routing
    // state. Other fragments from this neighbor fill or update the same vector.
    command void LinkState.receive(pack *dvPacket) {
        uint8_t vectorIndex, entryCount, entryIndex, destinationId, advertisedCost;
        bool isNeighbor = FALSE;
        dv_header *dvHeader;

        if (dvPacket->protocol != PROTOCOL_DV || dvPacket->TTL != 1 || dvPacket->src == 0 || dvPacket->src > MAX_NODES)
            return;

        dvHeader = (dv_header *) dvPacket->payload;
        if (dvHeader->magic != DV_MAGIC)
            return;

        entryCount = dvHeader->count;
        if (entryCount > DV_ENTRIES || (uint16_t)(2 + entryCount * 2) > PACKET_MAX_PAYLOAD_SIZE)
            return;

        for (entryIndex = 0; entryIndex < entryCount; entryIndex++)
            if (dvHeader->entries[entryIndex * 2] == 0)
                return;

        for (entryIndex = 0; entryIndex < call NDiscovery.neighborCount(); entryIndex++)
            if (call NDiscovery.neighborAt(entryIndex) == dvPacket->src)
                isNeighbor = TRUE;
        
        if (!isNeighbor)
            return;

        for (vectorIndex = 0; vectorIndex < MAX_NEIGHBORS && neighborIds[vectorIndex] != dvPacket->src; vectorIndex++) { }

        if (vectorIndex >= MAX_NEIGHBORS) {
            for (vectorIndex = 0; vectorIndex < MAX_NEIGHBORS && neighborIds[vectorIndex] != 0; vectorIndex++) { }
            if (vectorIndex >= MAX_NEIGHBORS)
                return;
            neighborIds[vectorIndex] = dvPacket->src;
            memset(neighborDistance[vectorIndex], ROUTE_INFINITY, sizeof neighborDistance[vectorIndex]);
        }

        // Reject duplicates and older fragments from this neighbor. Updates
        // are periodic, so a skipped out-of-order fragment is retransmitted in
        // the next advertisement round.
        if (hasAdvertisementSequence[vectorIndex] &&
            !sequenceIsNewer(dvPacket->seq, lastAdvertisementSequence[vectorIndex]))
            return;
        lastAdvertisementSequence[vectorIndex] = dvPacket->seq;
        hasAdvertisementSequence[vectorIndex] = TRUE;
        //dbg(ROUTING_CHANNEL, "DV receive node %hu from %hu seq %hu entries %hhu\n", TOS_NODE_ID, dvPacket->src, dvPacket->seq, entryCount);

        neighborDistance[vectorIndex][dvPacket->src] = 0;
        for (entryIndex = 0; entryIndex < entryCount; entryIndex++) {
            destinationId = dvHeader->entries[entryIndex * 2];
            advertisedCost = dvHeader->entries[entryIndex * 2 + 1];
            neighborDistance[vectorIndex][destinationId] = advertisedCost >= ROUTE_INFINITY ? ROUTE_INFINITY : advertisedCost;
            knownDestination[destinationId] = TRUE;
            // dbg(ROUTING_CHANNEL, "DV entry node %hu from %hu dest %hhu cost %hhu seq %hu\n", TOS_NODE_ID, dvPacket->src, destinationId, neighborDistance[vectorIndex][destinationId], dvPacket->seq);
        }
        hasNeighborVector[vectorIndex] = TRUE;
        recompute();
    }

    // Send at most one bounded fragment per timer event. Each neighbor receives
    // its own split-horizon/poison-reverse view via one-hop unicast.
    event void updateTimer.fired() {
        uint8_t neighborCount = call NDiscovery.neighborCount();
        uint8_t entryCount = 0, neighborId;
        uint16_t destinationId = destinationScanStart;
        pack advertisement;
        dv_header *dvHeader;
        if (neighborCount == 0)
            return;

        if (neighborSendIndex >= neighborCount || neighborSendIndex >= MAX_NEIGHBORS) {
            neighborSendIndex = 0;
            destinationScanStart = 0;
        }

        neighborId = call NDiscovery.neighborAt(neighborSendIndex);
        if (neighborId == 0) {
            neighborSendIndex++;
            destinationScanStart = 0;
            return;
        }

        advertisement.src = TOS_NODE_ID;
        advertisement.dest = neighborId;
        advertisement.seq = advertisementSequence++;
        advertisement.TTL = 1;
        advertisement.protocol = PROTOCOL_DV;
        memset(advertisement.payload, 0, PACKET_MAX_PAYLOAD_SIZE);
        dvHeader = (dv_header *) advertisement.payload;
        dvHeader->magic = DV_MAGIC;
        for (; destinationId <= MAX_NODES && entryCount < DV_ENTRIES; destinationId++) {
            uint8_t advertisedCost;
            if (!knownDestination[destinationId] && distance[destinationId] >= ROUTE_INFINITY)
                continue;
            advertisedCost = distance[destinationId];
            // Poison a route when using this neighbor as its next hop.
            if (nextHopTable[destinationId] == neighborId)
                advertisedCost = ROUTE_INFINITY;
            // dbg(ROUTING_CHANNEL, "DV advertise node %hu to %hhu dest %hu cost %hhu seq %hu\n", TOS_NODE_ID, neighborId, destinationId, advertisedCost, advertisement.seq);
            dvHeader->entries[entryCount * 2] = destinationId;
            dvHeader->entries[entryCount * 2 + 1] = advertisedCost;
            entryCount++;
        }
        
        dvHeader->count = entryCount;
        // Advance the staged vector only after SimpleSend accepts the packet
        // otherwise the next timer event retries this same fragment.
        if (call Sender.send(advertisement, neighborId) == SUCCESS) {
            if (destinationId > MAX_NODES) {
                neighborSendIndex++;
                destinationScanStart = 0;
            } else
                destinationScanStart = destinationId;
        }
    }

    // Print every known or currently reachable destination
    command void LinkState.printRoutes() {
        uint16_t destinationId = 1;
        for (; destinationId <= MAX_NODES; destinationId++) {
            if (knownDestination[destinationId] || distance[destinationId] < ROUTE_INFINITY)
                dbg(ROUTING_CHANNEL, "Node %hu route to %hu cost %hhu next %hhu\n", TOS_NODE_ID, destinationId, distance[destinationId], nextHopTable[destinationId]);
        }
    }
}
