from TestSim import TestSim

def main():
    print("=== POISON REVERSE TEST ===")
    print("Topology: topo/poison4.topo")
    print("Noise: noise/no_noise.txt")

    sim = TestSim()
    sim.loadTopo("poison4.topo")
    sim.loadNoise("no_noise.txt")
    sim.bootAll()
    # sim.addChannel(sim.COMMAND_CHANNEL)
    # sim.addChannel(sim.NEIGHBOR_CHANNEL)
    sim.addChannel(sim.ROUTING_CHANNEL)

    ticksPerSecond = sim.t.ticksPerSecond()
    while sim.t.time() < 15 * ticksPerSecond:
        sim.t.runNextEvent()
    print("--- t=15 s: route tables and per-neighbor DV advertisement logs ---")
    while sim.t.time() < 16 * ticksPerSecond:
        sim.t.runNextEvent()

if __name__ == '__main__':
    main()
