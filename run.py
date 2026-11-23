#!/usr/bin/env python
"""Project 3 repeatable TOSSIM scenarios. Run with the course Python 2/TOSSIM environment."""
import sys
from TestSim import TestSim

def setup(topology, noise):
    s = TestSim()
    s.loadTopo(topology)
    s.loadNoise(noise)
    s.bootAll()
    s.addChannel(s.GENERAL_CHANNEL)
    s.addChannel(s.TRANSPORT_CHANNEL)
    s.runForSeconds(30)
    for attempt in range(3):
        s.ping(1, 4, 'route-check')
        s.runForSeconds(2)
    return s

def baseline(s, noisy=False):
    s.cmdTestServer(4, 20)
    s.runForSeconds(1)
    s.cmdTestClient(1, 4, 10, 20, 1201)
    s.runForSeconds(900)

def midpoint(s):
    # Stop-and-wait keeps only one 12-byte segment outstanding at a time.
    s.cmdTestServer(4, 20)
    s.runForSeconds(1)
    s.cmdTestClient(1, 4, 10, 20, 132, stopWait=True)
    s.runForSeconds(400)

def flow(s):
    s.cmdTestServer(4, 20)
    s.runForSeconds(1)
    # Arm pause before the handshake so the new connected record inherits it.
    s.cmdTestPause(4, 1, 10, 20)
    s.runForSeconds(2)
    # The first ACK=130 acknowledges the 128-byte receive buffer filling;
    # discard the next one, which advertises the reopening after consumption.
    s.cmdTestDrop(2, 4, 1, 20, 10, 2, acknowledgment=130, occurrence=2)
    s.runForSeconds(1)
    s.cmdTestClient(1, 4, 10, 20, 300, flowControl=True)
    s.runForSeconds(12)
    s.cmdTestResume(4, 1, 10, 20)
    s.runForSeconds(600)

def data_loss(s):
    s.cmdTestServer(4, 20)
    s.runForSeconds(1)
    # The first data byte follows SYN at sequence 2. Drop that segment once
    # at intermediate node 2; retransmission gets a fresh IP packet ID.
    s.cmdTestDrop(2, 1, 4, 10, 20, 0, sequence=2)
    s.runForSeconds(1)
    s.cmdTestClient(1, 4, 10, 20, 1201)
    s.runForSeconds(900)

def ack_loss(s):
    s.cmdTestServer(4, 20)
    s.runForSeconds(1)
    s.cmdTestDrop(2, 4, 1, 20, 10, 2, acknowledgment=14)
    s.runForSeconds(1)
    s.cmdTestClient(1, 4, 10, 20, 1201)
    s.runForSeconds(900)

def control_loss(s, kind):
    s.cmdTestServer(4, 20)
    s.runForSeconds(1)
    if kind == 'syn-loss':
        s.cmdTestDrop(2, 1, 4, 10, 20, 1, sequence=1)
    elif kind == 'synack-loss':
        s.cmdTestDrop(2, 4, 1, 20, 10, 3, sequence=1, acknowledgment=2)
    elif kind == 'handshake-ack-loss':
        s.cmdTestDrop(2, 1, 4, 10, 20, 2, sequence=2, acknowledgment=2)
    elif kind == 'close-ack-loss':
        s.cmdTestDrop(2, 1, 4, 10, 20, 2, acknowledgment=3)
    s.runForSeconds(1)
    s.cmdTestClient(1, 4, 10, 20, 1201)
    s.runForSeconds(1000)

def failed_open(s):
    # No listener is installed at node 4. This must end with bounded failure.
    s.cmdTestClient(1, 4, 10, 29, 100)
    s.runForSeconds(60)

def overlapping(s):
    s.cmdTestServer(4, 20)
    s.runForSeconds(1)
    s.cmdTestClient(1, 4, 10, 20, 701)
    s.runForSeconds(1)
    s.cmdTestClient(1, 4, 11, 20, 907)
    s.runForSeconds(1000)

def main():
    scenario = sys.argv[1] if len(sys.argv) > 1 else 'baseline'
    topo = 'line4.topo'
    noise = 'moderate_noise.txt' if scenario == 'noisy' else 'no_noise.txt'
    s = setup(topo, noise)
    if scenario == 'midpoint':
        midpoint(s)
    elif scenario in ('baseline', 'noisy'):
        baseline(s, scenario == 'noisy')
    elif scenario == 'flow':
        flow(s)
    elif scenario == 'data-loss':
        data_loss(s)
    elif scenario == 'ack-loss':
        ack_loss(s)
    elif scenario in ('syn-loss', 'synack-loss', 'handshake-ack-loss', 'close-ack-loss'):
        control_loss(s, scenario)
    elif scenario == 'failure':
        failed_open(s)
    elif scenario == 'overlap':
        overlapping(s)
    else:
        raise SystemExit('scenario: midpoint, baseline, data-loss, ack-loss, flow, syn-loss, synack-loss, handshake-ack-loss, close-ack-loss, failure, overlap, noisy')

if __name__ == '__main__':
    main()
