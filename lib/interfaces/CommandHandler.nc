interface CommandHandler{
   // Events
   event void ping(uint16_t destination, uint8_t *payload);
   event void printNeighbors();
   event void printRouteTable();
   event void printLinkState();
   event void printDistanceVector();
   event void setTestServer(uint16_t address, uint8_t port);
   event void setTestClient(uint16_t client, uint16_t server, uint8_t srcPort, uint8_t dstPort, uint16_t length, bool stopWait);
   event void testClose(uint16_t client, uint16_t server, uint8_t srcPort, uint8_t dstPort);
   event void testPause(uint16_t client, uint16_t server, uint8_t srcPort, uint8_t dstPort, bool pause);
   event void testDrop(uint16_t source, uint16_t destination, uint8_t srcPort, uint8_t dstPort, uint8_t flags, bool matchSeq, uint16_t sequence, bool matchAck, uint16_t acknowledgment, uint8_t occurrence);
   event void setAppServer();
   event void setAppClient();
}
