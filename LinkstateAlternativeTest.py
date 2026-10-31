from TestSim import TestSim

def main():
    print("=== ALTERNATIVE PATH TEST: remove and restore link 2--4 ===")
    print("Topology: topo/alternative5.topo")
    print("Noise: noise/no_noise.txt.")

    sim = TestSim()
    sim.loadTopo("alternative5.topo")
    sim.loadNoise("no_noise.txt")
    sim.bootAll()
    # sim.addChannel(sim.COMMAND_CHANNEL)
    # sim.addChannel(sim.GENERAL_CHANNEL)
    # sim.addChannel(sim.NEIGHBOR_CHANNEL)
    sim.addChannel(sim.ROUTING_CHANNEL)

    ticksPerSecond = sim.t.ticksPerSecond()
    print("--- t=15 s: one ping; routing logs show selected next hop and cost ---")
    while sim.t.time() < 15 * ticksPerSecond:
        sim.t.runNextEvent()
    sim.ping(1, 4, "initial-path")
    while sim.t.time() < 20 * ticksPerSecond:
        sim.t.runNextEvent()

    print("--- t=20 s: remove the two directed 2--4 links but keep node 2 on ---")
    sim.r.remove(2, 4)
    sim.r.remove(4, 2)
    while sim.t.time() < 35 * ticksPerSecond:
        sim.t.runNextEvent()
    print("--- t=35 s: after withdrawal/reconvergence, ping over the alternate path ---")
    sim.ping(1, 4, "alternate-path")
    while sim.t.time() < 45 * ticksPerSecond:
        sim.t.runNextEvent()

    print("--- t=45 s: restore links 2->4 and 4->2 ---")
    sim.r.add(2, 4, -54.0)
    sim.r.add(4, 2, -54.0)
    while sim.t.time() < 60 * ticksPerSecond:
        sim.t.runNextEvent()
    print("--- t=60 s: after reconvergence, ping over the restored path ---")
    sim.ping(1, 4, "restored-path")
    while sim.t.time() < 65 * ticksPerSecond:
        sim.t.runNextEvent()

if __name__ == '__main__':
    main()
