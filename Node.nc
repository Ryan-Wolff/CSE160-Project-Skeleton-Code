/*
 * ANDES Lab - University of California, Merced
 * This class provides the basic functions of a network node.
 *
 * @author UCM ANDES Lab
 * @date   2013/09/03
 *
 */
#include <Timer.h>
#include "includes/command.h"
#include "includes/packet.h"
#include "includes/CommandMsg.h"
#include "includes/sendInfo.h"
#include "includes/channels.h"

module Node {
   uses interface Boot;

   uses interface SplitControl as AMControl;
   uses interface Receive;

   uses interface SimpleSend as Sender;

   uses interface CommandHandler;

   uses interface NDiscovery;
}

implementation {
   pack sendPackage;
   const uint16_t FLOOD_CACHE_SIZE = 40;
   const uint16_t DISCOVERY_MAGIC = 0xD1; // MUST be same value as in NDiscoveryP.nc, do NOT change this without changing there too. TODO: better implemtation of this, but it works for now as long as we dont touch it.
   uint16_t nextSequence = 0;
   uint16_t seenSources[FLOOD_CACHE_SIZE];
   uint16_t seenSequences[FLOOD_CACHE_SIZE];
   uint8_t nextCacheSlot = 0;

   // Prototypes
   void makePack(pack *Package, uint16_t src, uint16_t dest, uint16_t TTL, uint16_t Protocol, uint16_t seq, uint8_t *payload, uint8_t length);
   bool wasSeen(pack *Package);
   void remember(pack *Package);
   bool isDiscoveryBeacon(pack *Package);

   event void Boot.booted() {
      call AMControl.start();

      dbg(GENERAL_CHANNEL, "Booted\n");
   }

   event void AMControl.startDone(error_t err) {
      if(err == SUCCESS) {
         dbg(GENERAL_CHANNEL, "Radio On\n");
         call NDiscovery.start();
      } else {
         //Retry until successful
         call AMControl.start();
      }
   }

   event void AMControl.stopDone(error_t err){}

   event message_t* Receive.receive(message_t* msg, void* payload, uint8_t len) {
      dbg(GENERAL_CHANNEL, "Packet Received\n");
      if(len == sizeof(pack)) {
         pack* myMsg=(pack*) payload;
         dbg(GENERAL_CHANNEL, "Package Payload: %s\n", myMsg->payload);

         if (isDiscoveryBeacon(myMsg)) {
            // "The beacons of Minas Tirith! The beacons are lit! Gondor [announces itself]!"
            // "And Rohan will [record it]. Muster the [neighbors list]"
            call NDiscovery.receive(myMsg);
            return msg;
         }

         if (wasSeen(myMsg)) {
            dbg(FLOODING_CHANNEL, "Node %hu dropped duplicate %hu:%hu\n", TOS_NODE_ID, myMsg->src, myMsg->seq);
            return msg;
         }

         remember(myMsg);
         dbg(FLOODING_CHANNEL, "Node %hu received %hu:%hu for %hu\n", TOS_NODE_ID, myMsg->src, myMsg->seq, myMsg->dest);

         if (myMsg->dest == TOS_NODE_ID) {
            if (myMsg->protocol == PROTOCOL_PING) {
               pack reply;
               reply = *myMsg;
               reply.dest = myMsg->src;
               reply.src = TOS_NODE_ID;
               reply.seq = nextSequence++;
               reply.TTL = MAX_TTL;
               reply.protocol = PROTOCOL_PINGREPLY;
               call Sender.send(reply, AM_BROADCAST_ADDR);
               dbg(FLOODING_CHANNEL, "Node %hu sent ping reply to %hu\n", TOS_NODE_ID, reply.dest);
            } else if (myMsg->protocol == PROTOCOL_PINGREPLY)
               dbg(GENERAL_CHANNEL, "Node %hu received ping reply: %s\n", TOS_NODE_ID, myMsg->payload);
            return msg;
         }

         if (myMsg->TTL > 1) {
            // More time to live left, so we are passing this packet on. In the wise words of Gandalf: "Fly, you packets!"
            pack forward;
            forward = *myMsg;
            forward.TTL--;
            call Sender.send(forward, AM_BROADCAST_ADDR);
            dbg(FLOODING_CHANNEL, "Node %hu forwarded %hu:%hu (TTL %hhu)\n", TOS_NODE_ID, forward.src, forward.seq, forward.TTL);
         } else
            dbg(FLOODING_CHANNEL, "Node %hu dropped expired %hu:%hu\n", TOS_NODE_ID, myMsg->src, myMsg->seq);

         return msg;
      }
      dbg(GENERAL_CHANNEL, "Unknown Packet Type %d\n", len);
      return msg;
   }


   event void CommandHandler.ping(uint16_t destination, uint8_t *payload) {
      makePack(&sendPackage, TOS_NODE_ID, destination, MAX_TTL, PROTOCOL_PING, nextSequence++, payload, PACKET_MAX_PAYLOAD_SIZE);
      remember(&sendPackage); // If packet returns to sender, we want to ignore it
      call Sender.send(sendPackage, AM_BROADCAST_ADDR);
      dbg(GENERAL_CHANNEL, "Node %hu sent ping to %hu\n", TOS_NODE_ID, destination);
   }

   event void CommandHandler.printNeighbors(){
      call NDiscovery.printNeighbors();
   }

   event void CommandHandler.printRouteTable(){}

   event void CommandHandler.printLinkState(){}

   event void CommandHandler.printDistanceVector(){}

   event void CommandHandler.setTestServer(){}

   event void CommandHandler.setTestClient(){}

   event void CommandHandler.setAppServer(){}

   event void CommandHandler.setAppClient(){}

   void makePack(pack *Package, uint16_t src, uint16_t dest, uint16_t TTL, uint16_t protocol, uint16_t seq, uint8_t* payload, uint8_t length) {
      Package->src = src;
      Package->dest = dest;
      Package->TTL = TTL;
      Package->seq = seq;
      Package->protocol = protocol;
      memcpy(Package->payload, payload, length);
   }

   bool wasSeen(pack *Package) {
      for (uint8_t i = 0; i < FLOOD_CACHE_SIZE; i++) {
         if (seenSources[i] == Package->src && seenSequences[i] == Package->seq)
            return TRUE;
      }
      return FALSE;
   }

   void remember(pack *Package) {
      seenSources[nextCacheSlot] = Package->src;
      seenSequences[nextCacheSlot] = Package->seq;
      nextCacheSlot = (nextCacheSlot + 1) % FLOOD_CACHE_SIZE;
   }

   bool isDiscoveryBeacon(pack *Package) {
      return Package->protocol == PROTOCOL_PING && Package->TTL == 1 && Package->payload[0] == DISCOVERY_MAGIC;
   }

}
