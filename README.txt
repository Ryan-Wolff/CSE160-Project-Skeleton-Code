To run demos, use one of the following:

    python run.py midpoint             # 132-byte stop-and-wait connection and close
    python run.py baseline             # 1,201-byte sliding-window baseline
    python run.py data-loss            # drop data sequence 2 at node 2
    python run.py ack-loss             # drop cumulative ACK 14 at node 2
    python run.py flow                 # fill 128-byte receive buffer; drop reopening update
    python run.py syn-loss             # drop one SYN
    python run.py synack-loss          # drop one SYN+ACK
    python run.py handshake-ack-loss   # drop final handshake ACK
    python run.py close-ack-loss       # drop final close ACK
    python run.py failure              # connect to node 4 without a listener on port 29
    python run.py overlap              # two client tuples to the same listener
    python run.py noisy                # 1,201-byte transfer with moderate noise
    
For easier log reading, grep can be used, such as:
    python run.py midpoint > midpoint.log
    grep -E 'route-check|TEST_SERVER|TEST_OPEN|SYN_TX|SYN_ACK_TX|STATE |ALLOC|DATA_TX|DATA_RX|RETX|FIN_TX|FIN_RX|TIME_WAIT|TEST_RESULT|TEST_RECEIVER_RESULT|CLEANUP' midpoint.log

To run everything:
    python validate.py
    
test driver helper signatures from TestSim.py:
    cmdTestServer(serverAddress, listenPort)
    cmdTestClient(clientAddress, serverAddress, srcPort, destPort, transferBytes, stopWait=False, flowControl=False)
    cmdClientClose(clientAddress, serverAddress, srcPort, destPort)
    cmdTestPause(serverAddress, clientAddress, srcPort, destPort)
    cmdTestResume(serverAddress, clientAddress, srcPort, destPort)
    cmdTestDrop(intermediate, source, destination, srcPort, dstPort, flags, sequence=None, acknowledgment=None, occurrence=1)

The client command is delivered to clientAddress; the server command is delivered to serverAddress. Pause/resume are delivered to serverAddress and name the client/server tuple. Drop flags are 0=data, 1=SYN, 2=ACK, 3=SYN+ACK, and 4=FIN.

Constants + timers:
An 8 byte IP header and 9 byte transport header leave up to 12 data bytes for the payload (since forced to use TinyOS’s 29 byte budget), so window of 48 bytes allows 4.
Each connection has a 128-byte circular send buffer and a 128-byte circular receive buffer. There are a max of 6 connections per node. The normal fixed sender window is 48 bytes, midpoint stop and wait uses a 12 bytes, the flow scenario permits a 128 bytes to exercise flow control. The receiver cumulative ACK advertises 128 minus unread buffered bytes (so how many it has read).
One Timer<TMilli> ticks every quarter second and scans connection records. RTO is 5 seconds with 8 retries before culling connection. TIME_WAIT_MS is 15 seconds, WINDOW_PROBE_MS is half a second.

Results summary:
Midpoint: completed a 132-byte transfer with accepted=132, acknowledged=132, consumed=132
baseline: completed with no mismatches, multiple outstanding segments, and a short 9 byte final segment (maximum segment data is 12 bytes).
data-loss: node 2 drops data seq=2; receiver repeats ACK=2 at the gap; timeout retransmits seq=2
ack-loss: selected ACK=14 is dropped; later cumulative ACK=26 advances the sender
flow: receiver advertises ACK=130 window=0, and consumption opens window
syn-loss: selected SYN is dropped, SYN is retried, one connection is allocated, and transfer completes.
synack-loss: selected SYN+ACK is dropped/retried; one connection is allocated and transfer completes.
handshake-ack-loss: final handshake ACK is dropped; duplicate handshake completes with one connection allocation.
close-ack-loss: final close ACK is dropped; FIN is retried and TIME_WAIT cleanup completes.
failure: unavailable listener ends after 8 retries with a failure report and connection cleanup; no allocation.
overlap: allocated exactly two connection records while retaining the listener
noisy: 1,201 byte transfer on the moderate-noise input

For the full event traces (very messy), they are logged as validation/observed-results.md and validation/logs/<scenario>.log after running 'python validate.py'.
