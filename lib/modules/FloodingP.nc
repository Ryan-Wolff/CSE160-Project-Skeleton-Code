#include "../../includes/packet.h"
#include "../../includes/protocol.h"
#include "../../includes/channels.h"

module FloodingP {
    provides interface Flooding;
    uses interface SimpleSend as Sender;
}

implementation {
    enum {
        FLOOD_CACHE_SIZE = 40
    };

    uint16_t nextSequence = 0;
    uint16_t seenSources[FLOOD_CACHE_SIZE];
    uint16_t seenSequences[FLOOD_CACHE_SIZE];
    uint8_t nextCacheSlot = 0;

    bool wasSeen(pack *message);
    void remember(pack *message);

    command void Flooding.send(uint16_t destination, uint8_t *payload) {
        pack message;
        message.src = TOS_NODE_ID;
        message.dest = destination;
        message.seq = nextSequence++;
        message.TTL = MAX_TTL;
        message.protocol = PROTOCOL_PING;
        memcpy(message.payload, payload, PACKET_MAX_PAYLOAD_SIZE);
        remember(&message);
        call Sender.send(message, AM_BROADCAST_ADDR);
        dbg(FLOODING_CHANNEL, "Node %hu sent ping to %hu\n", TOS_NODE_ID, destination);
    }

    command void Flooding.receive(pack *message) {
        pack reply;
        pack forward;

        if (wasSeen(message)) {
            dbg(FLOODING_CHANNEL, "Node %hu dropped duplicate %hu:%hu\n", TOS_NODE_ID, message->src, message->seq);
            return;
        }

        remember(message);
        dbg(FLOODING_CHANNEL, "Node %hu received %hu:%hu for %hu\n", TOS_NODE_ID, message->src, message->seq, message->dest);

        if (message->dest == TOS_NODE_ID) {
            if (message->protocol == PROTOCOL_PING) {
                reply = *message;
                reply.dest = message->src;
                reply.src = TOS_NODE_ID;
                reply.seq = nextSequence++;
                reply.TTL = MAX_TTL;
                reply.protocol = PROTOCOL_PINGREPLY;
                remember(&reply);
                call Sender.send(reply, AM_BROADCAST_ADDR);
                dbg(FLOODING_CHANNEL, "Node %hu sent ping reply to %hu\n", TOS_NODE_ID, reply.dest);
            } else if (message->protocol == PROTOCOL_PINGREPLY)
                signal Flooding.pingReply(message->src, message->payload);
            return;
        }

        if (message->TTL > 1) {
            // More time to live left, so we are passing this packet on. In the wise words of Gandalf: "Fly, you packets!"
            forward = *message;
            forward.TTL--;
            call Sender.send(forward, AM_BROADCAST_ADDR);
            dbg(FLOODING_CHANNEL, "Node %hu forwarded %hu:%hu (TTL %hhu)\n", TOS_NODE_ID, forward.src, forward.seq, forward.TTL);
        } else
            dbg(FLOODING_CHANNEL, "Node %hu dropped expired %hu:%hu\n", TOS_NODE_ID, message->src, message->seq);
    }

    // We've seen this packet within the last FLOOD_CACHE_SIZE packets
    bool wasSeen(pack *message) {
        uint8_t i;

        for (i = 0; i < FLOOD_CACHE_SIZE; i++) {
            if (seenSources[i] == message->src &&
                seenSequences[i] == message->seq) {
                return TRUE;
            }
        }
        return FALSE;
    }

    // Remember this packet for FLOOD_CACHE_SIZE packets worth of time, so
    // we know it is a duplicate (with wasSeen) if we are passed it again
    void remember(pack *message) {
        seenSources[nextCacheSlot] = message->src;
        seenSequences[nextCacheSlot] = message->seq;
        nextCacheSlot = (nextCacheSlot + 1) % FLOOD_CACHE_SIZE;
    }
}
