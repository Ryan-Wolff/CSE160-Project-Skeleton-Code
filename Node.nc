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

   uses interface CommandHandler;

   uses interface NDiscovery;
   uses interface Flooding;
}

implementation {
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

         if (call NDiscovery.isBeacon(myMsg)) {
            // "The beacons of Minas Tirith! The beacons are lit! Gondor [announces itself]!"
            // "And Rohan will [record it]. Muster the [neighbors list]"
            call NDiscovery.receive(myMsg);
         } else
            call Flooding.receive(myMsg);

         return msg;
      }
      dbg(GENERAL_CHANNEL, "Unknown Packet Type %d\n", len);
      return msg;
   }


   event void CommandHandler.ping(uint16_t destination, uint8_t *payload) {
      call Flooding.send(destination, payload);
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

   event void Flooding.pingReply(uint16_t source, uint8_t *payload) {
      dbg(GENERAL_CHANNEL, "Node %hu received ping reply from %hu: %s\n", TOS_NODE_ID, source, payload);
   }

}
