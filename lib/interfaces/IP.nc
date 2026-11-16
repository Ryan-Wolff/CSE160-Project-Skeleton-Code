#include "../../includes/packet.h"

interface IP {
    command void send(uint16_t destination, uint8_t *payload);
    command error_t sendTransport(uint16_t destination, uint8_t *payload);
    command void configureTransportDrop(uint16_t source, uint16_t destination, uint8_t sourcePort, uint8_t destinationPort, uint8_t flags, bool matchSeq, uint16_t sequence, bool matchAck, uint16_t acknowledgment, uint8_t occurrence);
    command void receive(pack *message);
    event void pingReply(uint16_t source, uint8_t *payload);
}
