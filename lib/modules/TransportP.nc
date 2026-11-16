#include <Timer.h>
#include "../../includes/packet.h"
#include "../../includes/socket.h"
#include "../../includes/channels.h"

module TransportP {
    provides interface Transport;
    uses interface IP;
    uses interface Timer<TMilli> as RetryTimer;
}

implementation {
    // Byte-stream transport over IP. Each datagram carries a 9-byte header plus
    // optional data. Sequence numbers count bytes (and one extra for SYN/FIN)
    //
    // Header layout in the IP payload:
    //   [0] srcPort  [1] dstPort  [2] flags  [3..4] seq  [5..6] ack
    //   [7] advertised receive window  [8] data length  [9..] data
    //
    // Flags are mutually exclusive with data: a packet is SYN, SYN-ACK, ACK,
    // FIN, or a pure data segment. Sliding-window send is capped by the
    // smaller of the peer's advertised window and sendWindow
    enum {
        NCONN = 6,                 // sockets this node can hold at once
        CAP = 128,                 // circular send/recv buffer size
        FIXED_WND = 44,            // default local send window (sliding mode)
        DATA_MAX = PACKET_MAX_PAYLOAD_SIZE-9, // max bytes after the header
        RTO = 1500,                // retransmission timeout in ms
        MAX_RETRIES = 8,           // give up after this many timeouts
        TIME_WAIT_MS = 15000,      // hold the 4-tuple after both FINs
        WINDOW_PROBE_MS = 500,     // how often to re-advertise a non-zero window
        ST_CLOSED = 0,
        ST_LISTEN = 1,
        ST_SYN_SENT = 2,
        ST_SYN_RCVD = 3,
        ST_OPEN = 4,
        ST_FIN_WAIT = 5,
        ST_TIME_WAIT = 6,
        F_SYN = 1,
        F_ACK = 2,
        F_FIN = 4,
        HDR = 9
    };

    typedef struct conn {
        bool used, isListener, serverSide, testClient, producerStopped, paused, closeRequested, finSent, finAcked, peerFin, failed, windowProbe;
        uint8_t state, retries, localPort, remotePort, sendWindow;
        uint16_t sndISS; // initial send seq (SYN uses this)
        uint16_t sndUna; // sndUna: oldest unacked seq
        uint16_t sndNxt; // next seq to send
        uint16_t rcvNxt; // next seq we expect to receive
        uint16_t peerWnd; // last window the peer advertised
        uint16_t peerWndAck; // ack that carried it
        uint16_t local, remote, finSeq;
        uint32_t deadline, lastProbe;

        uint8_t tx[CAP], rx[CAP]; // Circular buffers
        uint16_t txBase, rxBase; // circular buffer head
        uint16_t txUsed; // all queued send bytes
        uint16_t txFlight; // unacked prefix of txUsed.
        uint16_t txLen; // not-yet-sent bytes (txUsed - txFlight)
        uint16_t rxLen; // unread recv bytes

        // Test-client/server accounting: produced bytes, queued (accepted),
        // ACKed, consumed, and content mismatches against 0, 1, 2,...
        uint16_t testLength, produced, accepted, acknowledged, consumed, mismatches, dataAccepted;
    } conn_t;

    // Pause rules that arrive before the server-side connection is allocated
    typedef struct pause_rule {
        bool used, paused;
        uint16_t client, server;
        uint8_t srcPort, dstPort;
    } pause_rule_t;

    conn_t conns[NCONN];
    pause_rule_t pauseRules[4];

    // Sequence and ack fields are big-endian 16-bit values
    uint16_t get16(uint8_t *bytes, uint8_t offset) {
        return ((uint16_t)bytes[offset] << 8) | bytes[offset+1];
    }

    void put16(uint8_t *bytes, uint8_t offset, uint16_t value) {
        bytes[offset] = (uint8_t)(value>>8); bytes[offset+1] = (uint8_t)value;
    }

    uint32_t now() {
        return call RetryTimer.getNow();
    }

    // One 250ms tick drives test I/O, window probes, and retransmission
    void ensureTimer() {
        if (!call RetryTimer.isRunning())
            call RetryTimer.startPeriodic(250);
    }

    // Bytes of rx[] still free; advertised to the peer as the receive window
    uint8_t recvWindow(conn_t *conn) {
        return conn->rxLen >= CAP ? 0 : CAP-conn->rxLen;
    }

    // Find an established (non-listener) socket by 4-tuple
    int8_t lookup(uint16_t localAddr, uint8_t localPort, uint16_t remoteAddr, uint8_t remotePort) {
        uint8_t i;
        for (i = 0; i < NCONN; i++) {
            if (conns[i].used && !conns[i].isListener && conns[i].local == localAddr && conns[i].localPort == localPort && conns[i].remote == remoteAddr && conns[i].remotePort == remotePort)
                return i;
        }
        return -1;
    }

    // Take a free slot and give it the default sliding send window
    int8_t allocate() {
        uint8_t i;
        for (i = 0; i < NCONN; i++) {
            if (!conns[i].used) {
                memset(&conns[i], 0, sizeof(conn_t));
                conns[i].used = TRUE;
                conns[i].sendWindow = FIXED_WND;
                return i;
            }
        }
        return -1;
    }

    // testPause can arrive before the server accepts; stash it on the new conn
    void applyPauseRule(conn_t *conn) {
        uint8_t i;
        for (i = 0; i < 4; i++) {
            if (pauseRules[i].used && pauseRules[i].client == conn->remote
                && pauseRules[i].server == conn->local && pauseRules[i].srcPort == conn->remotePort
                && pauseRules[i].dstPort == conn->localPort) {
                conn->paused = pauseRules[i].paused;
                pauseRules[i].used = FALSE;
                dbg(TRANSPORT_CHANNEL, "t=%lu node=%hu conn=%hu:%hhu<-%hu:%hhu CONSUMER_PAUSE inherited\n",now(), TOS_NODE_ID, conn->local, conn->localPort, conn->remote, conn->remotePort);
            }
        }
    }

    // Build a transport datagram and hand it to IP for routing
    error_t emit(conn_t *conn, uint8_t flags, uint16_t seq, uint16_t ackNum, uint8_t *data, uint8_t len) {
        uint8_t payload[PACKET_MAX_PAYLOAD_SIZE], i;

        if (len>DATA_MAX || HDR+len>PACKET_MAX_PAYLOAD_SIZE)
            return FAIL;

        memset(payload, 0, sizeof(payload));
        payload[0] = conn->localPort; payload[1] = conn->remotePort;
        payload[2] = flags;
        put16(payload, 3, seq);
        put16(payload, 5, ackNum);
        payload[7] = recvWindow(conn);
        payload[8] = len;
        for (i = 0; i < len; i++)
            payload[HDR+i] = data[i];

        return call IP.sendTransport(conn->remote, payload);
    }

    // Cumulative ACK of rcvNxt, also carrying the current receive window
    void sendAck(conn_t *conn) {
        if (emit(conn,F_ACK,conn->sndNxt,conn->rcvNxt,NULL,0) == SUCCESS)
            dbg(TRANSPORT_CHANNEL, "t=%lu node=%hu %hu:%hhu<-%hu:%hhu ACK_TX ack=%hu wnd=%hhu\n",(uint32_t)now(), TOS_NODE_ID, conn->local, conn->localPort, conn->remote, conn->remotePort, conn->rcvNxt, recvWindow(conn));
    }

    // Server reply to SYN: seq is ISS, ack is the client's SYN + 1
    void sendSynAck(conn_t *conn) {
        if (emit(conn,F_SYN|F_ACK,conn->sndISS,conn->rcvNxt,NULL,0) == SUCCESS) {
            conn->deadline = (uint32_t)now() + RTO;
            dbg(TRANSPORT_CHANNEL, "t=%lu node=%hu %hu:%hhu<-%hu:%hhu SYN_ACK_TX seq=%hu ack=%hu\n",(uint32_t)now(), TOS_NODE_ID, conn->local, conn->localPort, conn->remote, conn->remotePort, conn->sndISS, conn->rcvNxt);
        }
    }

    // Both sides have finished; keep the 4-tuple until TIME_WAIT expires so a
    // delayed FIN/ACK does not spawn a new connection
    void finishTimeWait(conn_t *conn) {
        conn->state = ST_TIME_WAIT;
        conn->deadline = (uint32_t)now() + TIME_WAIT_MS;
        conn->retries = 0;
        dbg(TRANSPORT_CHANNEL, "t=%lu node=%hu %hu:%hhu<-%hu:%hhu STATE TIME_WAIT retain=%u\n",(uint32_t)now(), TOS_NODE_ID, conn->local, conn->localPort, conn->remote, conn->remotePort, TIME_WAIT_MS);
    }

    // Send as many new data segments as the min of peer window and local send
    // window allows, then emit FIN once queued data has left the send buffer
    void pump(conn_t *conn) {
        uint16_t outstanding, allowed, chunkLen, i;
        uint8_t tmp[DATA_MAX];

        if (conn->state != ST_OPEN && conn->state != ST_FIN_WAIT)
            return;

        outstanding = conn->sndNxt-conn->sndUna;
        allowed = conn->peerWnd;
        if (allowed>conn->sendWindow)
            allowed = conn->sendWindow;

        // New data starts after the in-flight prefix (txBase + txFlight)
        while (conn -> txLen && outstanding < allowed) {
            chunkLen = conn->txLen;
            if (chunkLen > DATA_MAX)
                chunkLen = DATA_MAX;
            if (chunkLen > allowed-outstanding)
                chunkLen = allowed-outstanding;
            if (!chunkLen)
                break;

            for (i = 0;i<chunkLen;i++)
                tmp[i] = conn->tx[(conn->txBase + conn->txFlight + i) % CAP];

            if (emit(conn,0,conn->sndNxt,0,tmp,(uint8_t)chunkLen) != SUCCESS)
                break;

            dbg(TRANSPORT_CHANNEL, "t=%lu node=%hu %hu:%hhu->%hu:%hhu DATA_TX seq=%hu len=%hu outstanding=%hu peerWnd=%hu\n",(uint32_t)now(), TOS_NODE_ID, conn->local, conn->localPort, conn->remote, conn->remotePort, conn->sndNxt, chunkLen, outstanding + chunkLen, allowed);
            conn->sndNxt += chunkLen;
            conn->txFlight += chunkLen;
            conn->txLen -= chunkLen;
            outstanding += chunkLen;
            conn->deadline = (uint32_t)now() + RTO;
        }

        // FIN consumes one sequence number after every data byte is ACKed
        if (conn->closeRequested && !conn->txLen && !conn->txFlight && !conn->finSent && !conn->finAcked) {
            conn->finSeq = conn->sndNxt;
            if (emit(conn, F_FIN, conn->finSeq, 0, NULL, 0) == SUCCESS) {
                conn->sndNxt++;
                conn->finSent = TRUE;
                conn->state = ST_FIN_WAIT;
                conn->deadline = (uint32_t)now()+RTO;
                conn->retries = 0;
                dbg(TRANSPORT_CHANNEL, "t=%lu node=%hu %hu:%hhu->%hu:%hhu FIN_TX seq=%hu\n", (uint32_t)now(), TOS_NODE_ID, conn->local, conn->localPort, conn->remote, conn->remotePort, conn->finSeq);
                dbg(TRANSPORT_CHANNEL, "t=%lu node=%hu STATE FIN_WAIT conn=%hu:%hhu->%hu:%hhu\n", (uint32_t)now(), TOS_NODE_ID, conn->local, conn->localPort, conn->remote, conn->remotePort);
            } else if (!conn->deadline)
                conn->deadline = (uint32_t)now() + RTO;
        }

        // Data is queued but IP send failed; retry on the next timeout
        if (conn->txLen && conn->peerWnd>0 && conn->txFlight == 0 && !conn->deadline)
            conn->deadline = (uint32_t)now() + RTO;
    }

    // Copy into the send buffer, then try to transmit immediately
    // dataAccepted is capped so the test client cannot enqueue past 32764
    uint16_t queueBytes(conn_t *conn, uint8_t *data, uint16_t len) {
        uint16_t queued = 0, remaining;
        remaining = conn->dataAccepted>=32764?0:32764-conn->dataAccepted;
        if (len>remaining)len = remaining;
        while(queued<len&&conn->txUsed<CAP) { conn->tx[(conn->txBase+conn->txUsed)%CAP] = data[queued++]; conn->txUsed++; conn->txLen++; }
        conn->dataAccepted += queued;
        pump(conn); return queued;
    }

    // Bind only on this node, and only before listen/connect
    error_t bindConn(socket_t fd, socket_addr_t *addr) {
        if (fd >= NCONN || !conns[fd].used || conns[fd].state != ST_CLOSED || addr->addr != TOS_NODE_ID || addr->port == 0)
            return FAIL;
        conns[fd].local = addr->addr;
        conns[fd].localPort = addr->port;
        return SUCCESS;
    }

    // Client handshake: SYN consumes one sequence number (ISS = 1)
    error_t connectConn(socket_t fd, socket_addr_t *addr) {
        if (fd >= NCONN || !conns[fd].used || conns[fd].localPort == 0 || addr->addr == 0
            || addr->addr > 255 || addr->port == 0)
            return FAIL;

        if (lookup(conns[fd].local, conns[fd].localPort, addr->addr, addr->port) >= 0)
            return FAIL;

        conns[fd].remote = addr->addr;
        conns[fd].remotePort = addr->port;
        conns[fd].sndISS = 1;
        conns[fd].sndUna = 1;
        conns[fd].sndNxt = conns[fd].sndUna;
        conns[fd].state = ST_SYN_SENT;
        conns[fd].retries = 0;
        emit(&conns[fd], F_SYN, conns[fd].sndNxt, 0, NULL, 0);

        conns[fd].sndNxt++;
        conns[fd].deadline = now() + RTO;
        ensureTimer();
        dbg(TRANSPORT_CHANNEL, "t=%lu node=%hu %hu:%hhu->%hu:%hhu SYN_TX seq=%hu\n", now(), TOS_NODE_ID, conns[fd].local, conns[fd].localPort, conns[fd].remote, conns[fd].remotePort, conns[fd].sndUna);
        dbg(TRANSPORT_CHANNEL, "t=%lu node=%hu STATE SYN_SENT conn=%hu:%hhu->%hu:%hhu\n", now(), TOS_NODE_ID, conns[fd].local, conns[fd].localPort, conns[fd].remote, conns[fd].remotePort);
        return SUCCESS;
    }

    uint16_t readConn(socket_t fd, uint8_t *buf, uint16_t len) {
        uint16_t copied = 0;
        conn_t *conn;
        if (fd >= NCONN || !conns[fd].used)
            return 0;

        conn = &conns[fd];
        while (copied < len && conn->rxLen) {
            buf[copied++] = conn->rx[conn->rxBase];
            conn->rxBase = (conn->rxBase + 1) % CAP;
            conn->rxLen--;
        }

        // Advertise the newly opened receive window and probe until the peer
        // notices if it had previously seen a zero window
        if (copied) {
            conn->windowProbe = TRUE;
            conn->lastProbe = 0;
            sendAck(conn);
        }

        // A failed connection is kept only until the app drains leftover data
        if (conn->failed && conn->rxLen == 0)
            memset(conn, 0, sizeof(conn_t));

        return copied;
    }

    // Mark close; pump() sends FIN once the send buffer is empty
    error_t closeConn(socket_t fd) {
        if (fd >= NCONN || !conns[fd].used || conns[fd].state != ST_OPEN)
            return FAIL;

        conns[fd].closeRequested = TRUE;
        conns[fd].producerStopped = TRUE;
        pump(&conns[fd]);
        return SUCCESS;
    }

    command socket_t Transport.socket() {
        return allocate();
    }

    command error_t Transport.bind(socket_t fd, socket_addr_t *addr) {
        return bindConn(fd, addr);
    }

    command error_t Transport.listen(socket_t fd) {
        if (fd >= NCONN || !conns[fd].used || conns[fd].localPort == 0)
            return FAIL;

        // Listener stays in the table; incoming SYNs allocate a child socket
        conns[fd].state = ST_LISTEN;
        conns[fd].isListener = TRUE;
        ensureTimer();
        return SUCCESS;
    }

    // Return the first established child of this listening socket, if any
    command socket_t Transport.accept(socket_t fd) {
        uint8_t i;
        if (fd >= NCONN || !conns[fd].used || !conns[fd].isListener)
            return 255;

        for (i = 0; i < NCONN; i++) {
            if (conns[i].used && !conns[i].isListener && conns[i].state == ST_OPEN
                && conns[i].local == conns[fd].local && conns[i].localPort == conns[fd].localPort)
                return i;
        }
        return 255;
    }

    command error_t Transport.connect(socket_t fd, socket_addr_t *addr) {
        return connectConn(fd, addr);
    }

    command uint16_t Transport.write(socket_t fd, uint8_t *buff, uint16_t bufflen) {
        if (fd >= NCONN || !conns[fd].used || conns[fd].state != ST_OPEN || conns[fd].closeRequested)
            return 0;
        return queueBytes(&conns[fd], buff, bufflen);
    }

    command uint16_t Transport.read(socket_t fd, uint8_t *buff, uint16_t bufflen) {
        return readConn(fd,buff,bufflen);
    }

    command error_t Transport.close(socket_t fd) {
        return closeConn(fd);
    }

    // Hard close: refuse if unread or unsent data is still buffered
    command error_t Transport.release(socket_t fd) {
        if (fd >= NCONN || !conns[fd].used || conns[fd].rxLen || conns[fd].txUsed)
            return FAIL;

        memset(&conns[fd], 0, sizeof(conn_t));
        return SUCCESS;
    }

    // Idempotent listen used by the Project 3 test commands
    command error_t Transport.testServer(uint16_t address, uint8_t port) {
        uint8_t i;
        socket_addr_t listenAddr;
        socket_t fd;

        if (address != TOS_NODE_ID || port==0)
            return FAIL;

        for (i = 0; i < NCONN; i++)
            if (conns[i].used && conns[i].isListener && conns[i].localPort == port)
                return SUCCESS;

        fd = allocate();
        if (fd == 255)
            return FAIL;

        listenAddr.addr = address;
        listenAddr.port = port;
        bindConn(fd, &listenAddr);
        conns[fd].state = ST_LISTEN;
        conns[fd].isListener = TRUE;
        ensureTimer();
        dbg(TRANSPORT_CHANNEL, "t=%lu node=%hu TEST_SERVER listen=%hu:%hhu\n", (uint32_t)now(), TOS_NODE_ID, address,port);
        return SUCCESS;
    }

    command error_t Transport.testClient(uint16_t client, uint16_t server, uint8_t src, uint8_t dst, uint16_t length, bool stopWait) {
        socket_t fd;
        socket_addr_t localAddr, remoteAddr;

        if (client != TOS_NODE_ID || length == 0 || length > 32764)
            return FAIL;

        fd = allocate();
        if (fd == 255)
            return FAIL;

        localAddr.addr = client;
        localAddr.port = src;
        remoteAddr.addr = server;
        remoteAddr.port = dst;
        bindConn(fd, &localAddr);
        conns[fd].testClient = TRUE;
        conns[fd].testLength = length;

        // Stop-and-wait: at most one segment in flight. Sliding: FIXED_WND.
        conns[fd].sendWindow = stopWait ? DATA_MAX : FIXED_WND;
        if (connectConn(fd, &remoteAddr) != SUCCESS) {
            memset(&conns[fd], 0, sizeof(conn_t));
            return FAIL;
        }

        dbg(TRANSPORT_CHANNEL, "t=%lu node=%hu TEST_OPEN requested bytes=%hu conn=%hu:%hhu->%hu:%hhu mode=%s sendWindow=%hhu\n", (uint32_t)now(), TOS_NODE_ID, length, client, src, server, dst, stopWait ? "STOP_WAIT" : "SLIDING", conns[fd].sendWindow);
        return SUCCESS;
    }

    command error_t Transport.testClose(uint16_t client, uint16_t server, uint8_t src, uint8_t dst) {
        int8_t connId = lookup(client,src,server,dst);
        if (connId < 0)
            return FAIL;

        return closeConn(connId);
    }

    // Pause the server-side consumer so rx[] fills and the advertised window
    // shrinks (used to test zero-window / window-update behavior)
    command error_t Transport.testPause(uint16_t client, uint16_t server, uint8_t src, uint8_t dst, bool pause) {
        int8_t connId = lookup(server,dst,client,src);
        uint8_t i, slot = 255;
        if (connId < 0) {
            // Connection is not open yet: remember the pause until SYN is accepted
            bool listener = FALSE;
            for (i = 0; i < NCONN; i++) {
                if (conns[i].used && conns[i].isListener && conns[i].local == server && conns[i].localPort == dst)
                    listener=TRUE;
            }

            if (!listener)
                return FAIL;

            for (i = 0; i < 4; i++) {
                if (pauseRules[i].used && pauseRules[i].client == client
                    && pauseRules[i].server == server && pauseRules[i].srcPort == src
                    && pauseRules[i].dstPort == dst)
                    slot = i;
            }

            if (slot==255) {
                for (i = 0; i < 4; i++) {
                    if (!pauseRules[i].used) {
                        slot = i;
                        break;
                    }
                }
            }

            if (slot == 255)
                return FAIL;

            if (!pause) {
                pauseRules[slot].used = FALSE;
                return SUCCESS;
            }

            pauseRules[slot].used = TRUE;
            pauseRules[slot].paused = TRUE;
            pauseRules[slot].client = client;
            pauseRules[slot].server = server;
            pauseRules[slot].srcPort = src;
            pauseRules[slot].dstPort = dst;
            dbg(TRANSPORT_CHANNEL, "t=%lu node=%hu conn=%hu:%hhu<-%hu:%hhu CONSUMER_PAUSE armed_before_open\n", now(), TOS_NODE_ID, server, dst, client, src);
            return SUCCESS;
        }
        conns[connId].paused = pause;
        dbg(TRANSPORT_CHANNEL, "t=%lu node=%hu %hu:%hhu<- %hu:%hhu CONSUMER_%s buffered=%hu wnd=%hu\n", (uint32_t)now(), TOS_NODE_ID, server, dst, client, src, pause ? "PAUSE" : "RESUME", conns[connId].rxLen, recvWindow(&conns[connId]));
        return SUCCESS;
    }

    command error_t Transport.receive(pack *packet) {
        uint8_t *payload = (uint8_t*)packet->payload, flags, dataLen, i;
        int8_t connId;
        uint16_t seq, ackNum, ackedBytes;
        conn_t *conn;

        if (packet->protocol != PROTOCOL_TCP || PACKET_MAX_PAYLOAD_SIZE < HDR)
            return FAIL;

        flags = payload[2];
        dataLen = payload[8];

        // Reject unknown flags, oversized payloads, and mixed control + data
        if ((flags &~ (F_SYN | F_ACK | F_FIN)) || dataLen > DATA_MAX || HDR + dataLen > PACKET_MAX_PAYLOAD_SIZE)
            return FAIL;

        if ((flags & (F_SYN | F_FIN)) && dataLen)
            return FAIL;

        if ((flags & F_SYN) && (flags & F_FIN))
            return FAIL;

        if (dataLen && flags != 0)
            return FAIL;

        if (!dataLen && flags == 0)
            return FAIL;

        // Header src/dst ports are from the sender's view, so they swap here
        connId = lookup(packet->dest, payload[1], packet->src, payload[0]);
        if (connId<0&&(flags&F_SYN)) {
            // Only a matching listener may create a connected record. Repeated SYNs
            // match the pending tuple above and retransmit its original SYN-ACK
            bool listening=FALSE;
            for (i = 0; i < NCONN; i++) {
                if (conns[i].used && conns[i].isListener && conns[i].local == packet->dest && conns[i].localPort == payload[1])
                    listening = TRUE;
            }

            if (!listening)
                return FAIL;

            connId = allocate();
            if (connId < 0)
                return FAIL;

            conn = &conns[connId];
            conn->local = packet->dest;
            conn->localPort = payload[1];
            conn->remote = packet->src;
            conn->remotePort = payload[0];
            conn->state = ST_SYN_RCVD;
            conn->serverSide = TRUE;
            dbg(TRANSPORT_CHANNEL, "t=%lu node=%hu conn=%hu:%hhu<-%hu:%hhu SYN_RX seq=%hu wnd=%hhu\n", (uint32_t)now(), TOS_NODE_ID, conn->local, conn->localPort, conn->remote, conn->remotePort, get16(payload,3),payload[7]);
            applyPauseRule(conn);

            // SYN occupies one sequence number; data will start at rcvNxt
            conn->rcvNxt = get16(payload, 3) + 1;
            conn->sndISS = 1;
            conn->sndUna = 1;

            // SYN-ACK also consumes one send sequence number
            conn->sndNxt = conn->sndUna + 1;
            conn->peerWnd = payload[7];
            conn->retries = 0;
            conn->deadline = now() + RTO;
            sendSynAck(conn);
            ensureTimer();
            dbg(TRANSPORT_CHANNEL, "t=%lu node=%hu ALLOC conn=%hu:%hhu<-%hu:%hhu state=SYN_RCVD\n", (uint32_t)now(), TOS_NODE_ID, conn->local, conn->localPort, conn->remote, conn->remotePort);
            return SUCCESS;
        }

        if (connId < 0)
            return FAIL;
        conn = &conns[connId];
        seq = get16(payload, 3);
        ackNum = get16(payload, 5);

        if (flags & F_SYN) {
            // Client: SYN-ACK that acknowledges our SYN completes the handshake
            if (conn->state == ST_SYN_SENT && (flags & F_ACK) && ackNum == conn->sndNxt) {
                dbg(TRANSPORT_CHANNEL, "t=%lu node=%hu conn=%hu:%hhu->%hu:%hhu SYN_ACK_RX seq=%hu ack=%hu wnd=%hhu\n", (uint32_t)now(), TOS_NODE_ID, conn->local, conn->localPort, conn->remote, conn->remotePort, seq, ackNum, payload[7]);
                conn->rcvNxt = seq + 1;
                conn->sndUna = ackNum;
                conn->peerWnd = payload[7];
                conn->peerWndAck = ackNum;
                conn->state = ST_OPEN;
                conn->retries = 0;
                conn->deadline = 0;
                sendAck(conn);
                pump(conn);
                dbg(TRANSPORT_CHANNEL, "t=%lu node=%hu STATE ESTABLISHED conn=%hu:%hhu->%hu:%hhu\n", (uint32_t)now(), TOS_NODE_ID, conn->local, conn->localPort, conn->remote, conn->remotePort);
            } else if (conn->state == ST_SYN_RCVD)
                sendSynAck(conn); // duplicate SYN while waiting for the client's ACK
            else if (conn->state == ST_OPEN) {
                // Retransmitted handshake: server resends SYN-ACK, client ACKs
                if (conn->serverSide)
                    sendSynAck(conn);
                else
                    sendAck(conn);
            }
            return SUCCESS;
        }

        if (flags & F_ACK) {
            if (ackNum >= conn->sndUna && ackNum <= conn->sndNxt) {
                dbg(TRANSPORT_CHANNEL, "t=%lu node=%hu conn=%hu:%hhu<-%hu:%hhu ACK_RX ack=%hu wnd=%hhu outstanding=%hu\n", (uint32_t)now(), TOS_NODE_ID, conn->local, conn->localPort, conn->remote, conn->remotePort, ackNum, payload[7], conn->sndNxt-conn->sndUna);
                // Ignore stale window updates. During SYN_RCVD also require the
                // ACK's seq to match rcvNxt so a stray ACK cannot open us
                if (ackNum >= conn->peerWndAck && (conn->state != ST_SYN_RCVD || seq == conn->rcvNxt)) {
                    conn->peerWnd=payload[7];conn->peerWndAck=ackNum;}
                ackedBytes = ackNum-conn->sndUna;
                // Server: client's ACK of our SYN-ACK establishes the connection
                if (conn->state == ST_SYN_RCVD && ackNum == conn->sndNxt && seq == conn->rcvNxt) {
                    conn->sndUna = ackNum;
                    conn->state = ST_OPEN;
                    conn->retries = 0;
                    conn->deadline = 0;
                    dbg(TRANSPORT_CHANNEL, "t=%lu node=%hu STATE ESTABLISHED conn=%hu:%hhu<-%hu:%hhu\n", (uint32_t)now(), TOS_NODE_ID, conn->local, conn->localPort, conn->remote, conn->remotePort);}
                else if (ackedBytes <= conn->txFlight && ackedBytes > 0) {
                    // Slide the send window: drop the ACKed prefix from tx[]
                    conn->sndUna = ackNum;
                    conn->txBase = (conn->txBase + ackedBytes) % CAP;
                    conn->txUsed -= ackedBytes;
                    conn->txFlight -= ackedBytes;
                    conn->txLen = conn->txUsed - conn->txFlight;
                    conn->acknowledged += ackedBytes;
                    conn->retries = 0;
                    conn->deadline = conn->txFlight ? (uint32_t)now() + RTO : 0;
                    if (conn->testClient)
                        dbg(TRANSPORT_CHANNEL, "t=%lu node=%hu conn=%hu:%hhu->%hu:%hhu TEST_ACKED total=%hu\n",(uint32_t)now(), TOS_NODE_ID, conn->local, conn->localPort, conn->remote, conn->remotePort, conn->acknowledged);
                }
                if (conn->finSent && ackNum == conn->finSeq + 1) {
                    // Peer ACKed our FIN; enter TIME_WAIT if they already FINed
                    conn->sndUna = ackNum;
                    conn->finSent = FALSE;
                    conn->finAcked = TRUE;
                    if (conn->peerFin)
                        finishTimeWait(conn);
                }
                // Zero window with nothing in flight: wait for a window update
                // instead of retransmitting
                if (conn->txFlight == 0 && conn->txLen && conn->peerWnd == 0)
                    conn->deadline = 0;
                pump(conn);
            }
        }

        // In-order data only. Out-of-order or window-full segments are ACKed
        // so the sender can retransmit from rcvNxt
        if (dataLen && (conn->state==ST_OPEN||conn->state==ST_FIN_WAIT)) {
            if (seq == conn->rcvNxt && dataLen <= recvWindow(conn)) {
                for (i = 0; i < dataLen; i++)
                    conn->rx[(conn->rxBase + conn->rxLen + i) % CAP] = payload[HDR+i];
                conn->rxLen += dataLen;
                conn->rcvNxt += dataLen;
                conn->windowProbe = FALSE;
                dbg(TRANSPORT_CHANNEL, "t=%lu node=%hu %hu:%hhu<-%hu:%hhu DATA_RX seq=%hu len=%hhu ACK=%hu wnd=%hhu\n", (uint32_t)now(), TOS_NODE_ID, conn->local, conn->localPort, conn->remote, conn->remotePort, seq, dataLen, conn->rcvNxt,recvWindow(conn));
            } else
                dbg(TRANSPORT_CHANNEL, "t=%lu node=%hu conn=%hu:%hhu<-%hu:%hhu DATA_DISCARD seq=%hu expected=%hu len=%hhu wnd=%hhu reason=%s\n", (uint32_t)now(), TOS_NODE_ID, conn->local, conn->localPort, conn->remote, conn->remotePort, seq, conn->rcvNxt, dataLen, recvWindow(conn), seq == conn->rcvNxt ? "NO_SPACE" : "OUT_OF_ORDER");
            sendAck(conn);
        }

        if ((flags & F_FIN) && (conn->state == ST_OPEN || conn->state == ST_FIN_WAIT || conn->state == ST_TIME_WAIT)) {
            if (seq == conn->rcvNxt) {
                // FIN is valid only at the next expected seq (after all data)
                conn->rcvNxt++;
                conn->peerFin = TRUE;
                sendAck(conn);
                dbg(TRANSPORT_CHANNEL, "t=%lu node=%hu conn=%hu:%hhu<-%hu:%hhu FIN_RX accepted seq=%hu\n", (uint32_t)now(), TOS_NODE_ID, conn->local, conn->localPort, conn->remote, conn->remotePort, seq);
                if (conn->finAcked)
                    finishTimeWait(conn);
                else {
                    // Peer closed first: send our FIN after draining tx[]
                    conn->closeRequested = TRUE;
                    pump(conn);
                }
            } else
                sendAck(conn); // duplicate or out-of-order FIN
        }
        return SUCCESS;
    }

    // Periodic work: test producer/consumer, window probes, and retransmission
    event void RetryTimer.fired() {
        uint8_t i, j, k;
        uint16_t count, tmpLen;
        uint32_t nowMs = now();
        uint8_t user[16];
        for (i = 0; i < NCONN; i++) {
            if (conns[i].used) {
                conn_t *conn = &conns[i];
                // Test client: generate a byte stream of 0,1,2,... up to testLength
                if (conn->testClient && !conn->producerStopped && conn->state == ST_OPEN && conn->produced < conn->testLength) {
                    count = conn->testLength-conn->produced;
                    if (count > sizeof(user))
                        count = sizeof(user);
                    for (k = 0; k < count; k++)
                        user[k] = (uint8_t)((conn->produced + k) & 0xff);
                    k = queueBytes(conn, user,count);
                    conn->produced += k;
                    conn->accepted += k;
                    if (k)
                        dbg(TRANSPORT_CHANNEL, "t=%lu node=%hu conn=%hu:%hhu->%hu:%hhu TEST_ACCEPTED total=%hu requested=%hu\n", nowMs,TOS_NODE_ID, conn->local, conn->localPort, conn->remote, conn->remotePort, conn->accepted, conn->testLength);
                    if (conn->produced == conn->testLength) {
                        conn->closeRequested = TRUE;
                        conn->producerStopped = TRUE;
                    }
                    pump(conn);
                }
                // Test server: drain the receive buffer and check the expected pattern
                if (!conn->isListener && !conn->testClient && !conn->paused && conn->rxLen && conn->state >= ST_OPEN) {
                    count = conn->rxLen;
                    if (count > sizeof(user))
                        count = sizeof(user);
                    for (k = 0; k < count; k++)
                        user[k] = conn->rx[(conn->rxBase + k) % CAP];
                    readConn(i, user, count);

                    for (k = 0; k < count; k++) {
                        if (user[k] != (uint8_t)(conn->consumed & 0xff)) {
                            conn->mismatches++;
                            dbg(TRANSPORT_CHANNEL, "t=%lu node=%hu conn=%hu:%hhu<-%hu:%hhu CONTENT_MISMATCH offset=%hu got=%hhu expected=%hhu\n", nowMs, TOS_NODE_ID, conn->local, conn->localPort, conn->remote, conn->remotePort, conn->consumed, user[k], (uint8_t)conn->consumed);
                        }
                        conn->consumed++;
                    }
                    dbg(TRANSPORT_CHANNEL, "t=%lu node=%hu conn=%hu:%hhu<-%hu:%hhu TEST_CONSUMED total=%hu mismatches=%hu\n", nowMs, TOS_NODE_ID, conn->local, conn->localPort, conn->remote, conn->remotePort, conn->consumed, conn->mismatches);
                }

                // After the app reads, keep advertising the new window until
                // the peer sends more data (clears windowProbe in receive)
                if (conn->windowProbe && recvWindow(conn) > 0 && nowMs - conn->lastProbe >= WINDOW_PROBE_MS) {
                    sendAck(conn);
                    conn->lastProbe = nowMs;
                }

                if (conn->deadline && nowMs >= conn->deadline) {
                    if (conn->state==ST_TIME_WAIT) {
                        // Do not free the slot while the test consumer still has unread bytes; extend TIME_WAIT instead
                        if (conn->rxLen == 0) {
                            if (conn->testClient)
                                dbg(TRANSPORT_CHANNEL, "t=%lu node=%hu conn=%hu:%hhu->%hu:%hhu TEST_RESULT requested=%hu accepted=%hu acknowledged=%hu status=%s\n", nowMs, TOS_NODE_ID, conn->local, conn->localPort, conn->remote, conn->remotePort, conn->testLength, conn->accepted, conn->acknowledged, (conn->accepted == conn->testLength && conn->acknowledged == conn->testLength) ? "SUCCESS" : "FAILURE");
                            else if (conn->serverSide)
                                dbg(TRANSPORT_CHANNEL, "t=%lu node=%hu conn=%hu:%hhu<-%hu:%hhu TEST_RECEIVER_RESULT consumed=%hu mismatches=%hu\n", nowMs, TOS_NODE_ID, conn->local, conn->localPort, conn->remote, conn->remotePort, conn->consumed, conn->mismatches);
                            dbg(TRANSPORT_CHANNEL, "t=%lu node=%hu CLEANUP conn=%hu:%hhu<-%hu:%hhu TIME_WAIT expired\n", nowMs, TOS_NODE_ID, conn->local, conn->localPort, conn->remote, conn->remotePort);
                            memset(conn,0,sizeof(conn_t));
                        } else
                            conn->deadline = nowMs + TIME_WAIT_MS;
                    } else if (conn->retries >= MAX_RETRIES) {
                        // Keep the slot until rx[] is drained so test stats can print
                        dbg(TRANSPORT_CHANNEL, "t=%lu node=%hu FAILURE conn=%hu:%hhu<-%hu:%hhu retries=%hhu accepted=%hu acked=%hu consumed=%hu\n", nowMs, TOS_NODE_ID, conn->local, conn->localPort, conn->remote, conn->remotePort, conn->retries, conn->accepted, conn->acknowledged, conn->consumed);
                        conn->failed = TRUE;
                        conn->deadline = 0;
                        if (conn->rxLen == 0)
                            memset(conn, 0, sizeof(conn_t));
                    } else {
                        conn->retries++;
                        if (conn->state == ST_SYN_SENT)
                            emit(conn, F_SYN, conn->sndISS, 0, NULL, 0);
                        else if (conn->state == ST_SYN_RCVD)
                            sendSynAck(conn);
                        else if (conn->finSent)
                            emit(conn, F_FIN, conn->finSeq, 0, NULL, 0);
                        else if (conn->txFlight) {
                            // Retransmit the whole unacked prefix from sndUna
                            uint16_t pos=0;
                            while (pos < conn->txFlight) {
                                uint8_t tmp[DATA_MAX];
                                count = conn->txFlight-pos;

                                if (count > DATA_MAX)
                                    count = DATA_MAX;
                                tmpLen = count;
                                for (j = 0; j < tmpLen; j++)
                                    tmp[j] = conn->tx[(conn->txBase + pos + j) % CAP];
                                if (emit(conn, 0, conn->sndUna + pos, 0, tmp, tmpLen) != SUCCESS)
                                    break;
                                dbg(TRANSPORT_CHANNEL, "t=%lu node=%hu conn=%hu:%hhu->%hu:%hhu RETX seq=%hu len=%hhu retry=%hhu\n", nowMs, TOS_NODE_ID, conn->local, conn->localPort, conn->remote, conn->remotePort, conn->sndUna + pos, tmpLen, conn->retries);
                                pos+=tmpLen;
                            }
                        } else
                            pump(conn);
                        conn->deadline = nowMs + RTO;
                        dbg(TRANSPORT_CHANNEL, "t=%lu node=%hu TIMEOUT conn=%hu:%hhu<-%hu:%hhu state=%hhu retry=%hhu outstanding=%hu wnd=%hu\n", nowMs, TOS_NODE_ID, conn->local, conn->localPort, conn->remote, conn->remotePort, conn->state, conn->retries, conn->sndNxt - conn->sndUna, conn->peerWnd);
                    }
                }
                // Catch newly opened window or queued data between timeouts
                if (conn->state == ST_OPEN || conn->state == ST_FIN_WAIT)
                    pump(conn);
            }
        }
    }

    // Transport never consumes ping replies, but IP includes this event for components that share the routed IP service
    event void IP.pingReply(uint16_t source, uint8_t *payload) { }
}
