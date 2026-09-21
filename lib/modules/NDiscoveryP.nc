#include "../../includes/packet.h"
#include "../../includes/protocol.h"
#include "../../includes/channels.h"

module NDiscoveryP {
    provides interface NDiscovery;
    uses interface Timer<TMilli> as neighborTimer;
    uses interface Random;
    uses interface SimpleSend as Sender;
}

implementation {

    const uint16_t MAX_NEIGHBORS = 20;
    uint16_t neighbors[MAX_NEIGHBORS];
    uint8_t missedPeriods[MAX_NEIGHBORS];

    const uint16_t DISCOVERY_MAGIC = 0xD1; // Special identification that packet is a beacon instead of a normal packet
    const uint16_t DISCOVERY_PERIOD = 500; // How often to send out beacons
    const uint16_t NEIGHBOR_TIMEOUT = 5; // How many failed beacon report ins before we remove as a neighbor.
    uint16_t nextSequence = 0;

    command void NDiscovery.start() {
        //call neighborTimer.startOneShot(DISCOVERY_PERIOD + (uint16_t) call Random.rand16() % DISCOVERY_PERIOD);
        call neighborTimer.startPeriodic(DISCOVERY_PERIOD + (uint16_t) call Random.rand16() % DISCOVERY_PERIOD);
    }

    // > "I exist! I'm a real boy~ I mean node!"
    // Regularly use this to send out a packet just to let other nodes know it exists and is still online
    void sendBeacon() {
        pack beacon;
        beacon.dest = AM_BROADCAST_ADDR; // all neighbors hear
        beacon.src = TOS_NODE_ID; // neighbors know which node sent
        beacon.seq = nextSequence++;
        beacon.TTL = 1; // 1 hop (immediately adjacent)
        beacon.protocol = PROTOCOL_PING;

        for (uint8_t i = 0; i < PACKET_MAX_PAYLOAD_SIZE; i++)
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
        for (uint8_t i = 0; i < MAX_NEIGHBORS; i++) {
            if (neighbors[i] != 0) {
                if (missedPeriods[i] >= NEIGHBOR_TIMEOUT) {
                    dbg(NEIGHBOR_CHANNEL, "Node %hu lost neighbor %hu\n",
                        TOS_NODE_ID, neighbors[i]);
                    neighbors[i] = 0;
                    missedPeriods[i] = 0;
                } else
                    missedPeriods[i]++;
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
        bool found = FALSE;
        for (uint8_t i = 0; i < MAX_NEIGHBORS; i++) {
            if (neighbors[i] != 0) {
                dbg(NEIGHBOR_CHANNEL, "Node %hu neighbor: %hu\n", TOS_NODE_ID, neighbors[i]);
                found = TRUE;
            }
        }

        if (!found)
            dbg(NEIGHBOR_CHANNEL, "Node %hu has no neighbors\n", TOS_NODE_ID);
    }
    
    // > Just out here playing a nice game of catch with my fellow nodes.
    // Fired when this node catches a beacon packet (Node.nc should handle this
    // correctly (hopefully)) so as to update the list of neighboring nodes.
    command void NDiscovery.receive(pack *message) {

        if (message->src == TOS_NODE_ID || message->src <= 0)
            return; // ignote self + invalid nodes (0 or less)

        uint8_t empty = MAX_NEIGHBORS;
        for (uint8_t i = 0; i < MAX_NEIGHBORS; i++) {
            if (neighbors[i] == message->src) {
                missedPeriods[i] = 0;
                return;
            }
            
            if (!neighbors[i] && empty == MAX_NEIGHBORS)
                empty = i;
        }

        if (empty != MAX_NEIGHBORS) {
            neighbors[empty] = message->src;
            missedPeriods[empty] = 0;
            dbg(NEIGHBOR_CHANNEL, "Node %hu discovered neighbor %hu\n",
                TOS_NODE_ID, message->src);
        }
    }
}