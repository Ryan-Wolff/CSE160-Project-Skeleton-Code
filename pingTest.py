from TestSim import TestSim

def main():
    # Get simulation ready to run.
    s = TestSim();

    # Before we do anything, lets simulate the network off.
    s.runTime(1);

    # Load the the layout of the network.
    s.loadTopo("long_line.topo");

    # Add a noise model to all of the motes.
    s.loadNoise("no_noise.txt");

    # Turn on all of the sensors.
    s.bootAll();

    # Add the main channels. These channels are declared in includes/channels.h
    # s.addChannel(s.COMMAND_CHANNEL);
    # s.addChannel(s.GENERAL_CHANNEL);
    s.addChannel(s.NEIGHBOR_CHANNEL);
    s.addChannel(s.FLOODING_CHANNEL);

    # Allow the randomized neighbor beacons time to populate the tables
    s.runTime(20);

    print("------ NDiscovery: Node 2 neighbors ------")
    s.neighborDMP(2);
    # s.neighborDMP(1);
    # s.neighborDMP(3);
    s.runTime(100);

    print("------ Flooding: Node 1 pings to Node 10, Node 10 replies ------")
    s.ping(1, 10, "Hi!");
    s.runTime(100);

    # print("------ Flooding: Node 2 pings to Node 3, Node 3 replies ------") # playing hopscotch with 1 square, so very boring
    # s.ping(2, 3, "Hello, World");
    # s.runTime(100);

    print("------ NDiscovery: turning off node 3------")
    s.moteOff(3);
    s.runTime(100); # Give it enough time to expire on neighbors
    s.neighborDMP(2);
    s.runTime(100);

    print("------ Flooding: Node 1 pings to Node 10, but never reaches 10 ------")
    s.ping(1, 10, "Hi again!");
    s.runTime(100);

if __name__ == '__main__':
    main()
