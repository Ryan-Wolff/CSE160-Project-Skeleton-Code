#include "../../includes/packet.h"

interface NDiscovery {
    command void start();
    command void printNeighbors();
    command bool isBeacon(pack *message);
    command void receive(pack *message);
}
