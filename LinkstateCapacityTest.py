from TestSim import TestSim

def main():
    print("=== PACKET CAPACITY TEST: 11-node line ===")
    print("Topology: topo/capacity_line11.topo")
    print("Noise: noise/no_noise.txt")

    sim = TestSim()
    sim.loadTopo("capacity_line11.topo")
    sim.loadNoise("no_noise.txt")
    sim.bootAll()
    # sim.addChannel(sim.COMMAND_CHANNEL)
    # sim.addChannel(sim.GENERAL_CHANNEL)
    sim.addChannel(sim.ROUTING_CHANNEL)

    ticksPerSecond = sim.t.ticksPerSecond()
    while sim.t.time() < 40 * ticksPerSecond:
        sim.t.runNextEvent()
    print("--- t=40 s: end-to-end ping to node 11 ---")
    sim.ping(1, 11, "capacity-later-fragment")
    while sim.t.time() < 43 * ticksPerSecond:
        sim.t.runNextEvent()
    print("--- t=43 s: route snapshot at node 1; check later and earlier fragments together ---")
    sim.routeDMP(1)
    while sim.t.time() < 45 * ticksPerSecond:
        sim.t.runNextEvent()

if __name__ == '__main__':
    main()
