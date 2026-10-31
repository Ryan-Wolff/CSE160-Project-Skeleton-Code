#include "../../includes/packet.h"

interface LinkState {
    command void start();
    command bool nextHop(uint8_t destination, uint8_t *hop);
    command bool nextHopWithDist(uint8_t destination, uint8_t *hop, uint8_t* dist);
    command void receive(pack *message);
    command void printRoutes();
}
