#include <Timer.h>
#include "../../includes/packet.h"
#include "../../includes/protocol.h"
#include "../../includes/channels.h"

module IPP {
    provides interface IP;
    uses interface LinkState;
    uses interface SimpleSend as Sender;
    uses interface Timer<TMilli> as Clock;
}

implementation {
    enum {
        IP_DUPLICATE_CACHE_SIZE = 40
    };

    // IP sequence numbers identify locally originated ping and reply packets.
    uint16_t packetSequence;
    uint16_t seenSource[IP_DUPLICATE_CACHE_SIZE];
    uint16_t seenSequence[IP_DUPLICATE_CACHE_SIZE];
    uint8_t seenProtocol[IP_DUPLICATE_CACHE_SIZE];
    bool seenValid[IP_DUPLICATE_CACHE_SIZE];
    uint8_t nextSeenSlot;

    event void Clock.fired() { }

    bool dropRuleArmed, dropMatchSeq, dropMatchAck;
    uint16_t dropSource, dropDestination, dropSequence, dropAcknowledgment;
    uint8_t dropSourcePort, dropDestinationPort, dropFlags;
    uint8_t dropSkip;

    bool shouldDropForTest(pack *packet) {
        uint8_t *payload, flags, length;
        if (!dropRuleArmed || packet->protocol != PROTOCOL_TCP)
            return FALSE;
        payload = (uint8_t *)packet->payload;
        if (PACKET_MAX_PAYLOAD_SIZE < 9)
            return FALSE;
        flags = payload[2];
        length = payload[8];
        if (length > PACKET_MAX_PAYLOAD_SIZE-9 || 9+length > PACKET_MAX_PAYLOAD_SIZE)
            return FALSE;
        if (packet->src != dropSource || packet->dest != dropDestination
            || payload[0] != dropSourcePort || payload[1] != dropDestinationPort || flags != dropFlags
            || (dropMatchSeq && (((uint16_t)payload[3] << 8) | payload[4]) != dropSequence)
            || (dropMatchAck && (((uint16_t)payload[5] << 8) | payload[6]) != dropAcknowledgment))
            return FALSE;
        if (dropSkip>0) {
            dropSkip--;
            return FALSE;
        }
        dropRuleArmed = FALSE;
        dbg(TRANSPORT_CHANNEL,"t=%lu node=%hu TEST_DROP src=%hu:%hhu dst=%hu:%hhu flags=%hhu seq=%hu ack=%hu len=%hhu\n", (uint32_t)call Clock.getNow(), TOS_NODE_ID, packet->src,payload[0], packet->dest,payload[1], flags, ((uint16_t)payload[3] << 8) | payload[4], ((uint16_t)payload[5] << 8) | payload[6], length);
        return TRUE;
    }

    command void IP.configureTransportDrop(uint16_t source, uint16_t destination, uint8_t sourcePort,uint8_t destinationPort, uint8_t flags, bool matchSeq, uint16_t sequence, bool matchAck, uint16_t acknowledgment, uint8_t occurrence) {
        dropSource = source;
        dropDestination = destination;
        dropSourcePort = sourcePort;
        dropDestinationPort = destinationPort;
        dropFlags = flags;
        dropMatchSeq = matchSeq;
        dropSequence = sequence;
        dropMatchAck = matchAck;
        dropAcknowledgment = acknowledgment;
        dropSkip = (occurrence > 0) ? (occurrence - 1) : 0;
        dropRuleArmed = TRUE;
        dbg(TRANSPORT_CHANNEL,"t=%lu node=%hu TEST_DROP_ARM src=%hu:%hhu dst=%hu:%hhu flags=%hhu\n", (uint32_t)call Clock.getNow(),TOS_NODE_ID,source,sourcePort,destination,destinationPort,flags);
    }

    // Check and record the sender/sequence/protocol key, matching the bounded
    // duplicate suppression used by flooding while keeping ping and reply keys
    // distinct.
    bool packetWasSeen(pack *packet) {
        uint8_t cacheIndex;
        for (cacheIndex = 0; cacheIndex < IP_DUPLICATE_CACHE_SIZE; cacheIndex++)
            if (seenValid[cacheIndex] && seenSource[cacheIndex] == packet->src
                && seenSequence[cacheIndex] == packet->seq && seenProtocol[cacheIndex] == packet->protocol)
                return TRUE;
        return FALSE;
    }

    void rememberPacket(pack *packet) {
        seenSource[nextSeenSlot] = packet->src;
        seenSequence[nextSeenSlot] = packet->seq;
        seenProtocol[nextSeenSlot] = packet->protocol;
        seenValid[nextSeenSlot] = TRUE;
        nextSeenSlot = (nextSeenSlot + 1) % IP_DUPLICATE_CACHE_SIZE;
    }

    // Send to next node as designated by LinkState module
    command void IP.send(uint16_t destination, uint8_t *payload) {
        pack outgoingPacket;
        uint8_t nextHopAddress, dist;

        if (destination == 0 || destination > 255 || !call LinkState.nextHopWithDist((uint8_t) destination, &nextHopAddress, &dist)) {
            dbg(ROUTING_CHANNEL, "Node %hu has no route to %hu, dropping packet!\n", TOS_NODE_ID, destination);
            return;
        }
        
        outgoingPacket.src = TOS_NODE_ID;
        outgoingPacket.dest = destination;
        outgoingPacket.seq = packetSequence++;
        if (dist > MAX_TTL)
            outgoingPacket.TTL = MAX_TTL; // should never hit here since nextHopWithDist will return false, but just in case since that uses a custom INFINITY insted of MAX_TTL
        else
            outgoingPacket.TTL = dist;
        outgoingPacket.protocol = PROTOCOL_PING;
        memcpy(outgoingPacket.payload, payload, PACKET_MAX_PAYLOAD_SIZE);
        if (call Sender.send(outgoingPacket, nextHopAddress) == SUCCESS) {
            rememberPacket(&outgoingPacket);
            dbg(ROUTING_CHANNEL, "Routing Packet - src: %hu, dest: %hu, seq: %hu, next hop: %hhu, cost: %hhu\n", outgoingPacket.src, outgoingPacket.dest, outgoingPacket.seq, nextHopAddress, dist);
        }
    }

    command error_t IP.sendTransport(uint16_t destination, uint8_t *payload) {
        pack outgoingPacket;
        uint8_t nextHopAddress, dist;
        error_t sent;
        if (destination == 0 || destination > 255 || !call LinkState.nextHopWithDist((uint8_t)destination, &nextHopAddress, &dist)) {
            dbg(ROUTING_CHANNEL,"t=%lu node=%hu TCP_NO_ROUTE dst=%hu\n",(uint32_t)call Clock.getNow(),TOS_NODE_ID,destination);
            return FAIL;
        }

        outgoingPacket.src = TOS_NODE_ID;
        outgoingPacket.dest = destination;
        outgoingPacket.seq = packetSequence++;
        outgoingPacket.TTL = dist > MAX_TTL ? MAX_TTL : dist;
        outgoingPacket.protocol = PROTOCOL_TCP;
        memcpy(outgoingPacket.payload, payload, PACKET_MAX_PAYLOAD_SIZE);
        sent = call Sender.send(outgoingPacket, nextHopAddress);
        
        if (sent != SUCCESS)
            dbg(ROUTING_CHANNEL, "t=%lu node=%hu TCP_SEND_QUEUE_BUSY dst=%hu packet=%hu\n", (uint32_t)call Clock.getNow(), TOS_NODE_ID,destination, outgoingPacket.seq);
        return sent;
    }

    // Check if packets are meant for here, need to be forwarded, or need to be removed
    command void IP.receive(pack *message) {
        pack replyPacket, forwardedPacket;
        uint8_t nextHopAddress, dist;

        if (message->protocol == PROTOCOL_TCP) {
            if (message->dest == TOS_NODE_ID)
                return;
        } else if (message->protocol != PROTOCOL_PING && message->protocol != PROTOCOL_PINGREPLY)
            return;

        // Send the pingreply even if we have already seen this packet before
        // in case the reply was lost in transit when we saw it before
        if (message->dest == TOS_NODE_ID) {
            if (message->protocol == PROTOCOL_PING) {
                replyPacket = *message;
                replyPacket.src = TOS_NODE_ID;
                replyPacket.dest = message->src;
                replyPacket.seq = packetSequence++;
                replyPacket.TTL = MAX_TTL;
                replyPacket.protocol = PROTOCOL_PINGREPLY;
                if (call LinkState.nextHopWithDist((uint8_t) replyPacket.dest, &nextHopAddress, &dist)) {
                    if (call Sender.send(replyPacket, nextHopAddress) == SUCCESS) {
                        rememberPacket(&replyPacket);
                        dbg(ROUTING_CHANNEL, "Ping Reply - src: %hu, dest: %hu, seq: %hu, next hop: %hhu, cost: %hhu\n", replyPacket.src, replyPacket.dest, replyPacket.seq, nextHopAddress, dist);
                    }
                } else {
                    dbg(ROUTING_CHANNEL, "Node %hu has no route to %hhu, cannot send a ping reply!\n", TOS_NODE_ID, nextHopAddress);
                    return;
                }
            } else {
                if (message->protocol == PROTOCOL_PINGREPLY)
                    dbg(ROUTING_CHANNEL, "Recieved ping reply from node %hu\n", message->src);
                signal IP.pingReply(message->src, (uint8_t *) message->payload);
            }
                
            return;
        }

        if (shouldDropForTest(message))
            return;

        if (packetWasSeen(message))
            return;
        
        rememberPacket(message);

        // The clock is ticking, and you are out of time. Drop packets with no recieved TTL left
        if (message->TTL <= 1) {
            dbg(ROUTING_CHANNEL, "IP TTL expired at node %hu for %hu->%hu seq %hu\n", TOS_NODE_ID, message->src, message->dest, message->seq);
            return;
        }

        if (!call LinkState.nextHopWithDist((uint8_t) message->dest, &nextHopAddress, &dist)) {
            dbg(ROUTING_CHANNEL, "Node %hu has no route to %hu, dropping packet!\n", TOS_NODE_ID, message->dest);
            return;
        }
        
        forwardedPacket = *message;
        forwardedPacket.TTL--;
        if (call Sender.send(forwardedPacket, nextHopAddress) == SUCCESS) {
            rememberPacket(message);
            dbg(ROUTING_CHANNEL, "Routing Packet - src: %hu, dest: %hu, seq: %hu, next hop: %hhu, cost: %hhu\n", forwardedPacket.src, forwardedPacket.dest, forwardedPacket.seq, nextHopAddress, dist);
        }
    }
}
