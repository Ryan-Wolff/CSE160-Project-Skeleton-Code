#include "../../includes/packet.h"

interface Flooding {
    command void send(uint16_t destination, uint8_t *payload);
    command void receive(pack *message);
    event void pingReply(uint16_t source, uint8_t *payload);
}
