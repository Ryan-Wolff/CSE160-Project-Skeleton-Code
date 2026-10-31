from TestSim import TestSim

def main():
    print("=== LINK-STATE LINE TEST: 1--2--3--4 ===")
    print("Topology: topo/line4.topo")
    print("Noise: noise/no_noise.txt")

    sim = TestSim()
    sim.loadTopo("line4.topo")
    sim.loadNoise("no_noise.txt")
    sim.bootAll()
    # sim.addChannel(sim.COMMAND_CHANNEL)
    # sim.addChannel(sim.GENERAL_CHANNEL)
    # sim.addChannel(sim.FLOODING_CHANNEL)
    sim.addChannel(sim.ROUTING_CHANNEL)

    ticksPerSecond = sim.t.ticksPerSecond()
    print("--- t=15 s: route snapshot after convergence ---")
    while sim.t.time() < 15 * ticksPerSecond:
        sim.t.runNextEvent()
    while sim.t.time() < 15 * ticksPerSecond + ticksPerSecond / 4:
        sim.t.runNextEvent()

    print("--- t>15 s: ping 1->4 ---")
    sim.ping(1, 4, "line-forward")
    while sim.t.time() < 18 * ticksPerSecond + ticksPerSecond / 4:
        sim.t.runNextEvent()

    print("--- t>18 s: ping 4->1 ---")
    sim.ping(4, 1, "line-reverse")
    while sim.t.time() < 21 * ticksPerSecond + ticksPerSecond / 4:
        sim.t.runNextEvent()

if __name__ == '__main__':
    main()
