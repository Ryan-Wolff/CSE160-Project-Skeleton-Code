configuration IPC {
    provides interface IP;
    uses interface LinkState;
    uses interface SimpleSend as Sender;
}

implementation {
    // Connect IP forwarding to routing decisions and the common radio queue.
    components IPP;
    IP = IPP;
    IPP.LinkState = LinkState;
    IPP.Sender = Sender;
}
