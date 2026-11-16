#include <Timer.h>

configuration TransportC {
    provides interface Transport;
    uses interface IP;
}

implementation {
    components TransportP;
    Transport = TransportP;
    TransportP.IP = IP;
    components new TimerMilliC() as RetryTimer;
    TransportP.RetryTimer -> RetryTimer;
}
