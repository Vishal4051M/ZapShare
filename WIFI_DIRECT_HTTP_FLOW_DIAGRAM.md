# WiFi Direct + HTTP Flow Diagram

## Visual Flow Representation

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         WIFI DIRECT + HTTP FLOW                         │
└─────────────────────────────────────────────────────────────────────────┘

DEVICE A (Sender)                                    DEVICE B (Receiver)
═════════════════                                    ═══════════════════

┌──────────────────┐                                ┌──────────────────┐
│   Open Send      │                                │  Open Receive/   │
│     Screen       │                                │   Send Screen    │
└────────┬─────────┘                                └────────┬─────────┘
         │                                                   │
         ▼                                                   ▼
┌──────────────────┐                                ┌──────────────────┐
│  Select Files    │                                │  WiFi Direct     │
│   to Share       │                                │  Discoverable    │
└────────┬─────────┘                                └────────┬─────────┘
         │                                                   │
         ▼                                                   │
┌──────────────────┐     WiFi Direct Discovery     ┌────────▼─────────┐
│ WiFi Direct      │◄───────────────────────────────┤  Advertising     │
│ Start Discovery  │                                │  as Peer         │
└────────┬─────────┘                                └──────────────────┘
         │                                                   
         ▼                                                   
┌──────────────────┐                                        
│ Device B Appears │                                        
│   in Peer List   │                                        
└────────┬─────────┘                                        
         │                                                   
         ▼                                                   
┌──────────────────┐                                        
│   User Clicks    │                                        
│   on Device B    │                                        
└────────┬─────────┘                                        
         │                                                   
         ▼                                                   
┌──────────────────┐                                ┌──────────────────┐
│  WiFi Direct     │    Connect Request (P2P)      │  Receive Connect │
│  connectToPeer() │────────────────────────────────▶│     Request      │
│  (Group Owner)   │                                │                  │
└────────┬─────────┘                                └────────┬─────────┘
         │                                                   │
         │                                                   ▼
         │                                          ┌──────────────────┐
         │                                          │  User Accepts    │
         │                                          │   Connection     │
         │                                          └────────┬─────────┘
         │                                                   │
         ▼                  WiFi Direct Group Formed         ▼
┌──────────────────┐◄───────────────────────────────┌──────────────────┐
│  Group Owner     │                                │    Client        │
│  192.168.49.1    │                                │  192.168.49.2    │
└────────┬─────────┘                                └────────┬─────────┘
         │                                                   │
         ▼                                                   ▼
┌──────────────────┐                                ┌──────────────────┐
│  Start HTTP      │                                │  Start HTTP      │
│  Server :8080    │                                │  Server :8080    │
└────────┬─────────┘                                └────────┬─────────┘
         │                                                   │
         ▼                                                   ▼
┌──────────────────┐                                ┌──────────────────┐
│  UDP Discovery   │    UDP Broadcast (224.0.0.167)│  UDP Discovery   │
│  on WiFi Direct  │◄───────────────────────────────┤  on WiFi Direct  │
│    Network       │────────────────────────────────▶│    Network       │
└────────┬─────────┘    Device Info Exchange        └────────┬─────────┘
         │                                                   │
         ▼                                                   │
┌──────────────────┐                                        │
│ Discover Device  │                                        │
│ B at 192.168.49.2│                                        │
└────────┬─────────┘                                        │
         │                                                   │
         ▼                                                   ▼
┌──────────────────┐                                ┌──────────────────┐
│  Send HTTP       │   HTTP Connection Request      │  Receive HTTP    │
│  Request to      │────────────────────────────────▶│  Request         │
│  192.168.49.2    │   (File Info: Names, Sizes)    │                  │
└────────┬─────────┘                                └────────┬─────────┘
         │                                                   │
         │                                                   ▼
         │                                          ┌──────────────────┐
         │                                          │  Show Accept/    │
         │                                          │  Reject Dialog   │
         │                                          └────────┬─────────┘
         │                                                   │
         │                                                   ▼
         │                                          ┌──────────────────┐
         │                                          │  User Accepts    │
         │                                          └────────┬─────────┘
         │                                                   │
         ▼                  HTTP Response (Accept)           ▼
┌──────────────────┐◄───────────────────────────────┌──────────────────┐
│  Receive Accept  │                                │  Send Accept     │
│   Response       │                                │   Response       │
└────────┬─────────┘                                └────────┬─────────┘
         │                                                   │
         ▼                                                   ▼
┌──────────────────┐                                ┌──────────────────┐
│  Start File      │    HTTP GET /file/0,1,2...     │  Receive File    │
│  Transfer        │────────────────────────────────▶│  Requests        │
│                  │                                │                  │
│  Send File Data  │    File Data (Chunked/Range)   │  Download Files  │
│  via HTTP        │────────────────────────────────▶│  Save to Storage │
│                  │                                │                  │
│  With Progress   │    Progress Updates             │  Show Progress   │
│  Tracking        │◄───────────────────────────────│  Bar             │
└────────┬─────────┘                                └────────┬─────────┘
         │                                                   │
         ▼                                                   ▼
┌──────────────────┐                                ┌──────────────────┐
│  Transfer        │                                │  Transfer        │
│  Complete        │                                │  Complete        │
└──────────────────┘                                └──────────────────┘
         │                                                   │
         ▼                                                   ▼
┌──────────────────┐                                ┌──────────────────┐
│  Connection      │                                │  Connection      │
│  Remains Active  │                                │  Remains Active  │
│  (for more files)│                                │  (for more files)│
└──────────────────┘                                └──────────────────┘
```

## Key Network Details

### WiFi Direct Network Formation
```
┌─────────────────────────────────────────────────┐
│         WiFi Direct Group (DIRECT-XY)           │
├─────────────────────────────────────────────────┤
│                                                 │
│  Group Owner: 192.168.49.1 (Device A)           │
│      ↓                                          │
│      └── Client: 192.168.49.2 (Device B)        │
│                                                 │
│  Subnet: 192.168.49.0/24                        │
│  DHCP Range: 192.168.49.2 - 192.168.49.254      │
│                                                 │
└─────────────────────────────────────────────────┘
```

### HTTP Communication After WiFi Direct
```
┌──────────────┐                    ┌──────────────┐
│  Device A    │                    │  Device B    │
│  (Sender)    │                    │  (Receiver)  │
├──────────────┤                    ├──────────────┤
│ HTTP Server  │                    │ HTTP Server  │
│ Port: 8080   │◄──────────────────▶│ Port: 8080   │
│              │  Both servers run  │              │
│              │  for bidirectional │              │
│              │    file sharing    │              │
└──────────────┘                    └──────────────┘

HTTP Endpoints Available on Both Devices:
├── GET  /                    (Device info)
├── GET  /file/{index}        (Download file)
├── POST /connection-request  (Initiate transfer)
└── POST /connection-response (Accept/Reject)
```

## State Transitions

### Device A (Sender) State Machine
```
[Idle] 
  → Select Files 
  → [Files Selected]
     → Click WiFi Direct Peer
     → [Connecting] 
        → WiFi Direct Success
        → [Connected]
           → Start HTTP Server
           → [Server Running]
              → Discover Peer IP
              → [Peer Discovered]
                 → Send HTTP Request
                 → [Request Sent]
                    → Receive Accept
                    → [Transferring]
                       → Transfer Complete
                       → [Complete]
```

### Device B (Receiver) State Machine
```
[Idle/Discoverable]
  → Receive WiFi Direct Request
  → [Connection Requested]
     → Accept Connection
     → [Connected]
        → Start HTTP Server
        → [Server Running]
           → Receive HTTP Request
           → [Request Received]
              → Show Dialog
              → User Accepts
              → [Transferring]
                 → Transfer Complete
                 → [Complete]
```

## Error Handling Paths

```
Connection Failures:
├── WiFi Direct Connection Failed
│   └── Show Error + Stay Discoverable
├── IP Discovery Timeout
│   └── Try Common IPs (192.168.49.1, .2, .3)
├── HTTP Request Timeout
│   └── Show Retry Dialog
└── Transfer Interrupted
    └── Resume via HTTP Range Requests
```

## Technology Stack Integration

```
┌─────────────────────────────────────────────┐
│           Application Layer                 │
│  (AndroidHttpFileShareScreen.dart)          │
├─────────────────────────────────────────────┤
│                                             │
│  ┌─────────────┐    ┌──────────────────┐   │
│  │   WiFi      │    │   HTTP Server    │   │
│  │   Direct    │    │   (Dart:io)      │   │
│  │   Service   │    │   Port 8080      │   │
│  └──────┬──────┘    └────────┬─────────┘   │
│         │                    │             │
├─────────┼────────────────────┼─────────────┤
│         │                    │             │
│  ┌──────▼──────┐    ┌────────▼─────────┐   │
│  │  Platform   │    │   UDP/Multicast  │   │
│  │  Channel    │    │   Discovery      │   │
│  │  (Android)  │    │   Port 37020     │   │
│  └──────┬──────┘    └────────┬─────────┘   │
│         │                    │             │
├─────────┼────────────────────┼─────────────┤
│         │                    │             │
│  ┌──────▼──────────────┐  ┌──▼──────────┐  │
│  │  WifiP2pManager     │  │  Datagram   │  │
│  │  (Android Native)   │  │  Socket     │  │
│  └─────────────────────┘  └─────────────┘  │
│                                             │
└─────────────────────────────────────────────┘
          Network Layer (WiFi Direct)
```

---

**Key Benefits of This Architecture:**

1. ✅ **Direct Connection**: No router needed (WiFi Direct creates P2P network)
2. ✅ **High Speed**: Direct device-to-device transfer at WiFi speeds
3. ✅ **Reliable Protocol**: HTTP/TCP ensures reliable delivery
4. ✅ **Resume Support**: HTTP range requests enable transfer resume
5. ✅ **Dual Discovery**: Both WiFi Direct and UDP discovery work together
6. ✅ **Bidirectional**: Both devices can send/receive files
7. ✅ **User Control**: Clear UI feedback at each step

