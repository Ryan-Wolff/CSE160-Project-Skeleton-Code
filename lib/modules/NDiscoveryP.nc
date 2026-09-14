module NDiscoveryP {
    provides interface NDiscovery;
    uses interface Timer<TMilli> as neighborTimer;
    uses interface Random;
}

implementation {
    command void NDiscovery.start() {
        //call neighborTimer.startOneShot(500 + (uint16_t) call Random.rand16() % 500);
        call neighborTimer.startPeriodic(500 + (uint16_t) call Random.rand16() % 500);
    }

    event void neighborTimer.fired() {
        dbg(NEIGHBOR_CHANNEL, "neighbor discovery has started! \n");
    }

    command void NDiscovery.printNeighbors() {

    }
}