from struct import pack
from TestSim import TestSim

def main():
    print("=== ROUTED PACKET TTL TEST ===")
    print("Topology: topo/line4.topo")
    print("Noise: noise/no_noise.txt")

    sim = TestSim()
    sim.loadTopo("line4.topo")
    sim.loadNoise("no_noise.txt")
    sim.bootAll()
    #sim.addChannel(sim.COMMAND_CHANNEL)
    #sim.addChannel(sim.GENERAL_CHANNEL)
    sim.addChannel(sim.ROUTING_CHANNEL)

    ticksPerSecond = sim.t.ticksPerSecond()
    while sim.t.time() < 15 * ticksPerSecond:
        sim.t.runNextEvent()
    payload = "short-ttl" + ("\x00" * 11)
    packetBytes = pack("!HHHBB20s", 4, 1, 4242, 2, 0, payload[:20])
    packet = sim.t.newPacket()
    packet.setType(6)  # AM_PACK
    packet.setData(packetBytes)
    packet.setDestination(1)
    packet.deliver(1, sim.t.time() + 5)
    print("--- t=15 s: injected 1->4 ping with TTL=2; wait through t=20 s ---")
    while sim.t.time() < 20 * ticksPerSecond:
        sim.t.runNextEvent()

if __name__ == '__main__':
    main()
