configuration NDiscoveryC  {
    provides interface NDiscovery;
    uses interface SimpleSend as Sender;
}

implementation {
    components NDiscoveryP;
    NDiscovery = NDiscoveryP;

    components new TimerMilliC() as neighborTimer;
    NDiscoveryP.neighborTimer -> neighborTimer;

    components RandomC as Random;
    NDiscoveryP.Random -> Random;

    NDiscoveryP.Sender = Sender;
}
