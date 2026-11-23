/**
 * @author UCM ANDES Lab
 * $Author: abeltran2 $
 * $LastChangedDate: 2014-08-31 16:06:26 -0700 (Sun, 31 Aug 2014) $
 *
 */


#include "../../includes/CommandMsg.h"
#include "../../includes/command.h"
#include "../../includes/channels.h"

module CommandHandlerP{
   provides interface CommandHandler;
   uses interface Receive;
   uses interface Pool<message_t>;
   uses interface Queue<message_t*>;
   uses interface Packet;
}

implementation{
    task void processCommand(){
        if(! call Queue.empty()){
            CommandMsg *msg;
            uint8_t commandID;
            uint8_t* buff;
            uint16_t srcAddr, dstAddr, length;
            message_t *raw_msg;
            void *payload;

            // Pop message out of queue.
            raw_msg = call Queue.dequeue();
            payload = call Packet.getPayload(raw_msg, sizeof(CommandMsg));

            // Check to see if the packet is valid.
            if(!payload){
                call Pool.put(raw_msg);
                post processCommand();
                return;
            }
            // Change it to our type.
            msg = (CommandMsg*) payload;

            dbg(COMMAND_CHANNEL, "A Command has been Issued.\n");
            buff = (uint8_t*) msg->payload;
            commandID = msg->id;

            // Multi-byte command arguments are big-endian. The command
            // packet's own dest field identifies the mote receiving it.
            srcAddr = ((uint16_t)buff[0] << 8) | buff[1];
            dstAddr = ((uint16_t)buff[2] << 8) | buff[3];
            length = ((uint16_t)buff[6] << 8) | buff[7];

            //Find out which command was called and call related command
            switch(commandID){
            // A ping will have the destination of the packet as the first
            // value and the string in the remainder of the payload
            case CMD_PING:
                dbg(COMMAND_CHANNEL, "Command Type: Ping\n");
                signal CommandHandler.ping(buff[0], &buff[1]);
                break;

            case CMD_NEIGHBOR_DUMP:
                dbg(COMMAND_CHANNEL, "Command Type: Neighbor Dump\n");
                signal CommandHandler.printNeighbors();
                break;

            case CMD_LINKSTATE_DUMP:
                dbg(COMMAND_CHANNEL, "Command Type: Link State Dump\n");
                signal CommandHandler.printLinkState();
                break;

            case CMD_ROUTETABLE_DUMP:
                dbg(COMMAND_CHANNEL, "Command Type: Route Table Dump\n");
                signal CommandHandler.printRouteTable();
                break;

            case CMD_TEST_SERVER:
                signal CommandHandler.setTestServer(srcAddr, buff[2]);
                break;

            case CMD_TEST_CLIENT:
                signal CommandHandler.setTestClient(srcAddr, dstAddr, buff[4], buff[5], length, buff[8]);
                break;

            case CMD_TEST_CLOSE:
                signal CommandHandler.testClose(srcAddr, dstAddr, buff[4], buff[5]);
                break;

            case CMD_TEST_PAUSE:
            case CMD_TEST_RESUME:
                signal CommandHandler.testPause(srcAddr, dstAddr, buff[4], buff[5], commandID == CMD_TEST_PAUSE);
                break;

            case CMD_TEST_DROP:
                signal CommandHandler.testDrop(srcAddr, dstAddr, buff[4], buff[5], buff[6], buff[7] != 0, ((uint16_t)buff[8] << 8) | buff[9], buff[10] != 0, ((uint16_t)buff[11] << 8) | buff[12], buff[13]);
                break;

            default:
                dbg(COMMAND_CHANNEL, "CMD_ERROR: \"%d\" does not match any known commands.\n", msg->id);
                break;
            }
            call Pool.put(raw_msg);
        }

        if(! call Queue.empty()){
            post processCommand();
        }
    }
    event message_t* Receive.receive(message_t* raw_msg, void* payload, uint8_t len){
        if (! call Pool.empty()){
            call Queue.enqueue(raw_msg);
            post processCommand();
            return call Pool.get();
        }
        return raw_msg;
    }
}
