#include "../../includes/packet.h"
#include "../../includes/protocol.h"
#include "../../includes/channels.h"

module NDiscoveryP {
    provides interface NDiscovery;
    uses interface Timer<TMilli> as neighborTimer;
    uses interface Random;
    uses interface SimpleSend as Sender;
    uses interface Hashmap<uint8_t> as Neighbors;
}

implementation {

    enum {
        DISCOVERY_MAGIC = 0xD1,
        DISCOVERY_PERIOD = 500,
        NEIGHBOR_TIMEOUT = 5
    };

    uint16_t nextSequence = 0;

    command void NDiscovery.start() {
        //call neighborTimer.startOneShot(DISCOVERY_PERIOD + (uint16_t) call Random.rand16() % DISCOVERY_PERIOD);
        call neighborTimer.startPeriodic(DISCOVERY_PERIOD + (uint16_t) call Random.rand16() % DISCOVERY_PERIOD);
    }

    // > "I exist! I'm a real boy~ I mean node!"
    // Regularly use this to send out a packet just to let other nodes know it exists and is still online
    void sendBeacon() {
        pack beacon;
        uint8_t i;

        beacon.dest = AM_BROADCAST_ADDR; // all neighbors hear
        beacon.src = TOS_NODE_ID; // neighbors know which node sent
        beacon.seq = nextSequence++;
        beacon.TTL = 1; // 1 hop (immediately adjacent)
        beacon.protocol = PROTOCOL_PING;

        for (i = 0; i < PACKET_MAX_PAYLOAD_SIZE; i++)
            beacon.payload[i] = 0;

        beacon.payload[0] = DISCOVERY_MAGIC;
        call Sender.send(beacon, AM_BROADCAST_ADDR);
        dbg(NEIGHBOR_CHANNEL, "Node %hu sent neighbor beacon\n", TOS_NODE_ID);
    }

    // > "POV: You forgot to log out so someone else kindly does it for you"
    // If we haven't heard from a neighbor in NEIGHBOR_TIMEOUT time, assume they
    // are dead... I mean unreachable, and remove them from the array of neighbor nodes
    // Otherwise, if we cant reach but less than NEIGHBOR_TIMEOUT has elapsed, just
    // add 1 to the amount of check-ins they missed.
    void expireNeighbors() {
        uint8_t i;
        uint8_t missedPeriods;
        uint16_t neighborCount;
        uint32_t *neighborIds;

        neighborIds = call Neighbors.getKeys();
        neighborCount = call Neighbors.size();
        i = 0;
        while (i < neighborCount) {
            missedPeriods = call Neighbors.get(neighborIds[i]);
            if (missedPeriods >= NEIGHBOR_TIMEOUT) {
                dbg(NEIGHBOR_CHANNEL, "Node %hu lost neighbor %hu\n", TOS_NODE_ID, (uint16_t) neighborIds[i]);
                call Neighbors.remove(neighborIds[i]);
                neighborCount--;
                // dont do i++, since remove shifted down later stuff
            } else {
                call Neighbors.insert(neighborIds[i], missedPeriods + 1);
                i++;
            }
        }
    }

    event void neighborTimer.fired() {
        dbg(NEIGHBOR_CHANNEL, "Neighbor discovery has started!\n");
        expireNeighbors();
        sendBeacon();
    }

    // > Yellowpages
    // Prints every node directly adjacent to this one
    command void NDiscovery.printNeighbors() {
        uint8_t i;
        uint16_t neighborCount;
        uint32_t *neighborIds;

        neighborIds = call Neighbors.getKeys();
        neighborCount = call Neighbors.size();
        for (i = 0; i < neighborCount; i++)
            dbg(NEIGHBOR_CHANNEL, "Node %hu neighbor: %hu\n", TOS_NODE_ID, (uint16_t) neighborIds[i]);

        if (neighborCount == 0)
            dbg(NEIGHBOR_CHANNEL, "Node %hu has no neighbors\n", TOS_NODE_ID);
    }
    
    // > Just out here playing a nice game of catch with my fellow nodes.
    // Fired when this node catches a beacon packet (Node.nc should handle this
    // correctly (hopefully)) so as to update the list of neighboring nodes.
    command void NDiscovery.receive(pack *message) {
        uint32_t neighborId;

        // ignore self + invalid nodes (0 or less)
        if (message->src == TOS_NODE_ID || message->src <= 0)
            return;

        neighborId = (uint32_t) message->src;
        if (call Neighbors.contains(neighborId)) {
            call Neighbors.insert(neighborId, 0);
            return;
        }

        call Neighbors.insert(neighborId, 0);
        dbg(NEIGHBOR_CHANNEL, "Node %hu discovered neighbor %hu\n", TOS_NODE_ID, message->src);
    }

    command bool NDiscovery.isBeacon(pack *message) {
        return message->protocol == PROTOCOL_PING && message->TTL == 1 && message->payload[0] == DISCOVERY_MAGIC;
    }
}
