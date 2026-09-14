configuration NDiscoveryC  {
    provides interface NDiscovery;
}

implementation {
    components NDiscoveryP;
    NDiscovery = NDiscoveryP;

    components new TimerMilliC() as neighborTimer;
    NDiscoveryP.neighborTimer -> neighborTimer;

    components RandomC as Random;
    NDiscoveryP.Random -> Random;
}