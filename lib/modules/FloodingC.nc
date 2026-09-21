configuration FloodingC {
    provides interface Flooding;
    uses interface SimpleSend as Sender;
}

implementation {
    components FloodingP;
    Flooding = FloodingP;
    FloodingP.Sender = Sender;
}
