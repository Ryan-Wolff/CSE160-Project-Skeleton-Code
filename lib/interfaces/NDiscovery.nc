#include "../../includes/packet.h"

interface NDiscovery {
    command void start();
    command void printNeighbors();
    command bool isBeacon(pack *message);
    command void receive(pack *message);
    command uint8_t neighborCount();
    command uint8_t neighborAt(uint8_t neighborIndex);
    event void neighborsChanged();
}
