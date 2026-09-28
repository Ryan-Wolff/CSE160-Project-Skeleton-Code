configuration NDiscoveryC  {
    provides interface NDiscovery;
    uses interface SimpleSend as Sender;
}

implementation {
    enum {
        NEIGHBOR_MAP_CAPACITY = 64
    };

    components NDiscoveryP;
    NDiscovery = NDiscoveryP;

    components new TimerMilliC() as neighborTimer;
    NDiscoveryP.neighborTimer -> neighborTimer;

    components RandomC as Random;
    NDiscoveryP.Random -> Random;

    NDiscoveryP.Sender = Sender;

    components new HashmapC(uint8_t, NEIGHBOR_MAP_CAPACITY) as Neighbors;
    NDiscoveryP.Neighbors -> Neighbors;
}
