from TestSim import TestSim

def main():
    print("=== PARTITION TEST: remove and restore link 2--3 on a line ===")
    print("Topology: topo/line4.topo")
    print("Noise: noise/no_noise.txt")

    sim = TestSim()
    sim.loadTopo("line4.topo")
    sim.loadNoise("no_noise.txt")
    sim.bootAll()
    # sim.addChannel(sim.COMMAND_CHANNEL)
    # sim.addChannel(sim.GENERAL_CHANNEL)
    # sim.addChannel(sim.NEIGHBOR_CHANNEL)
    sim.addChannel(sim.ROUTING_CHANNEL)
    # sim.addChannel(sim.FLOODING_CHANNEL)

    ticksPerSecond = sim.t.ticksPerSecond()
    print("--- t=15 s: initial route snapshot ---")
    while sim.t.time() < 15 * ticksPerSecond:
        sim.t.runNextEvent()
    while sim.t.time() < 20 * ticksPerSecond:
        sim.t.runNextEvent()

    print("--- t=20 s: remove both directions of 2--3 ---")
    sim.r.remove(2, 3)
    sim.r.remove(3, 2)
    while sim.t.time() < 35 * ticksPerSecond:
        sim.t.runNextEvent()
    print("--- t=35 s: after withdrawal convergence, attempt ping (expect a drop) ---")
    sim.ping(1, 4, "partition-drop")
    while sim.t.time() < 40 * ticksPerSecond:
        sim.t.runNextEvent()

    print("--- t=40 s: restore both directions of 2--3 ---")
    sim.r.add(2, 3, -54.0)
    sim.r.add(3, 2, -54.0)
    while sim.t.time() < 55 * ticksPerSecond:
        sim.t.runNextEvent()
    print("--- t=55 s: after recovery convergence, ping again ---")
    sim.ping(1, 4, "partition-recovered")
    while sim.t.time() < 60 * ticksPerSecond:
        sim.t.runNextEvent()

if __name__ == '__main__':
    main()
