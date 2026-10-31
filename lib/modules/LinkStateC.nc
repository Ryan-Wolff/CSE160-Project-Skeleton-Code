configuration LinkStateC {
    provides interface LinkState;
    uses interface NDiscovery;
    uses interface SimpleSend as Sender;
}

implementation {
    // Provide the DV engine with neighbor discovery, a randomized timer, and
    // the shared one-hop packet sender.
    components LinkStateP, new TimerMilliC() as updateTimer, RandomC;

    LinkState = LinkStateP;
    LinkStateP.NDiscovery = NDiscovery;
    LinkStateP.Sender = Sender;

    LinkStateP.updateTimer->updateTimer;
    LinkStateP.Random->RandomC;
}
