from TestSim import TestSim

def main():
    print("=== LOSSY ADVERTISEMENT RECOVERY TEST ===")
    print("Topology: topo/lossy_line4.topo")
    print("Noise: noise/interference_bursts.txt")

    sim = TestSim()
    sim.loadTopo("lossy_line4.topo")
    sim.loadNoise("interference_bursts.txt")
    sim.bootAll()
    # sim.addChannel(sim.GENERAL_CHANNEL)
    # sim.addChannel(sim.COMMAND_CHANNEL)
    sim.addChannel(sim.ROUTING_CHANNEL)

    ticksPerSecond = sim.t.ticksPerSecond()
    while sim.t.time() < 60 * ticksPerSecond:
        sim.t.runNextEvent()
    print("--- t=60 s: route snapshot and routed ping after repeated noisy exchanges ---")
    sim.ping(1, 4, "loss-recovery")
    while sim.t.time() < 65 * ticksPerSecond:
        sim.t.runNextEvent()

if __name__ == '__main__':
    main()
