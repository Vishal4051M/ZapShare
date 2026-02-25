const WebSocket = require('ws');
const http = require('http');

/**
 * ⚡ ZapShare Signaling Server
 * 
 * This server facilitates the initial WebRTC handshake between a sender and a receiver.
 * It DOES NOT store, see, or transmit actual file data.
 */

const server = http.createServer((req, res) => {
    res.writeHead(200);
    res.end("ZapShare Signaling Server is running.");
});

const wss = new WebSocket.Server({ server });

wss.on('error', (err) => {
    console.error('WebSocket Server Error:', err);
});

// Prevent process crashes on unhandled errors
process.on('uncaughtException', (err) => {
    console.error('Uncaught Exception:', err);
});
process.on('unhandledRejection', (reason, promise) => {
    console.error('Unhandled Rejection at:', promise, 'reason:', reason);
});

// Active pairing sessions (code -> { sender, receiver })
const sessions = new Map();

wss.on('connection', (ws) => {
    let userCode = null;
    let userRole = null;

    ws.on('message', (message) => {
        try {
            // Ensure message is a string (handles both Buffer and string formats)
            const payload = JSON.parse(message.toString());
            const { type, code, role, data } = payload;

            switch (type) {
                case 'join':
                    userCode = code;
                    userRole = role;

                    if (!sessions.has(code)) {
                        sessions.set(code, { sender: null, receiver: null });
                    }

                    const session = sessions.get(code);
                    if (role === 'sender') {
                        session.sender = ws;
                    } else {
                        session.receiver = ws;
                    }

                    // Handshake Trigger: If BOTH are present, notify the sender
                    if (session.sender && session.receiver) {
                        if (session.sender.readyState === WebSocket.OPEN) {
                            try {
                                session.sender.send(JSON.stringify({ type: 'peer-joined' }));
                                console.log(`[${code}] Handshake triggered (Both present)`);
                            } catch (e) {
                                console.error(`[${code}] Error triggering handshake:`, e.message);
                            }
                        }
                    }

                    console.log(`[${code}] ${role} joined`);
                    break;

                case 'signal':
                    const targetSession = sessions.get(userCode);
                    if (targetSession) {
                        const recipient = userRole === 'sender' ? targetSession.receiver : targetSession.sender;
                        if (recipient && recipient.readyState === WebSocket.OPEN) {
                            try {
                                recipient.send(JSON.stringify({ type: 'signal', data }));
                                if (data.sdp) {
                                    console.log(`[${userCode}] Relayed SDP: ${data.sdp.type} from ${userRole}`);
                                } else if (data.ice) {
                                    // Log simple info about ICE
                                    console.log(`[${userCode}] Relayed ICE (${data.ice.candidate ? 'candidate' : 'end'}) from ${userRole}`);
                                }
                            } catch (e) {
                                console.error(`[${userCode}] Error relaying signal:`, e.message);
                            }
                        } else {
                            console.log(`[${userCode}] Failed to relay: recipient not ready or gone`);
                        }
                    }
                    break;

                case 'heartbeat':
                    if (ws.readyState === WebSocket.OPEN) {
                        try {
                            ws.send(JSON.stringify({ type: 'heartbeat-ack' }));
                        } catch (e) { }
                    }
                    break;
            }
        } catch (err) {
            console.error('Error processing message:', err.message);
        }
    });

    ws.on('close', () => {
        if (userCode && sessions.has(userCode)) {
            const session = sessions.get(userCode);
            if (userRole === 'sender') session.sender = null;
            else session.receiver = null;

            if (!session.sender && !session.receiver) {
                sessions.delete(userCode);
                console.log(`[${userCode}] Session closed and cleaned up`);
            }
        }
    });
});

const PORT = process.env.PORT || 3000;
server.listen(PORT, () => {
    console.log(`🚀 ZapShare Signaling Server running on port ${PORT}`);
});
