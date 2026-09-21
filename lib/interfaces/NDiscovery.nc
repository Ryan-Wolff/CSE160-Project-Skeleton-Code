#include "../../includes/packet.h"

interface NDiscovery {
    command void start();
    command void printNeighbors();
    command void receive(pack *message);
}
