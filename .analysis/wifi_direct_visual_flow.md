# Wi-Fi Direct Flow - Visual Diagram

## Complete Flow from Start to Finish

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         INITIAL STATE                                        │
│  Device A (Sender)              │              Device B (Receiver)           │
│  - Opens ZapShare               │              - Opens ZapShare              │
│  - Selects files                │              - Just browsing               │
│  - NOT on same network          │              - NOT on same network         │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                    PHASE 1: WI-FI DIRECT DISCOVERY                          │
│                                                                              │
│  Device A                       │              Device B                      │
│  ┌──────────────────────┐       │       ┌──────────────────────┐           │
│  │ Wi-Fi Direct         │       │       │ Wi-Fi Direct         │           │
│  │ Discovery Running    │◄──────┼──────►│ Discovery Running    │           │
│  └──────────────────────┘       │       └──────────────────────┘           │
│           │                     │                    │                      │
│           ▼                     │                    ▼                      │
│  ┌──────────────────────┐       │       ┌──────────────────────┐           │
│  │ Discovers Device B   │       │       │ Discovers Device A   │           │
│  │ (via Wi-Fi Direct)   │       │       │ (via Wi-Fi Direct)   │           │
│  └──────────────────────┘       │       └──────────────────────┘           │
│           │                     │                    │                      │
│           ▼                     │                    ▼                      │
│  ┌──────────────────────┐       │       ┌──────────────────────┐           │
│  │ Shows "Device B"     │       │       │ Shows "Device A"     │           │
│  │ in nearby devices    │       │       │ in nearby devices    │           │
│  └──────────────────────┘       │       └──────────────────────┘           │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│              PHASE 2: USER INITIATES CONNECTION                             │
│                                                                              │
│  Device A (Sender)              │              Device B (Receiver)           │
│  ┌──────────────────────┐       │                                           │
│  │ USER TAPS            │       │                                           │
│  │ "Device B"           │       │                                           │
│  └──────────────────────┘       │                                           │
│           │                     │                                           │
│           ▼                     │                                           │
│  ┌──────────────────────┐       │                                           │
│  │ _sendConnectionRequest│       │                                           │
│  │ (device)             │       │                                           │
│  └──────────────────────┘       │                                           │
│           │                     │                                           │
│           ▼                     │                                           │
│  ┌──────────────────────┐       │                                           │
│  │ Stores:              │       │                                           │
│  │ _pendingDevice = B   │       │                                           │
│  └──────────────────────┘       │                                           │
│           │                     │                                           │
│           ▼                     │                                           │
│  ┌──────────────────────┐       │       ┌──────────────────────┐           │
│  │ connectToWifiDirect  │       │       │ Android System       │           │
│  │ Peer(B.macAddress)   │──────►│──────►│ Shows Dialog:        │           │
│  └──────────────────────┘       │       │ "Device A wants to   │           │
│           │                     │       │  connect"            │           │
│           ▼                     │       └──────────────────────┘           │
│  ┌──────────────────────┐       │                    │                      │
│  │ Shows SnackBar:      │       │                    ▼                      │
│  │ "Connecting to       │       │       ┌──────────────────────┐           │
│  │  Device B..."        │       │       │ USER ACCEPTS         │           │
│  └──────────────────────┘       │       └──────────────────────┘           │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│              PHASE 3: WI-FI DIRECT GROUP FORMATION                          │
│                                                                              │
│  ┌────────────────────────────────────────────────────────────────┐         │
│  │              Wi-Fi Direct P2P Network Created                  │         │
│  │                                                                 │         │
│  │  Device A: Group Owner (GO)  │  Device B: Client               │         │
│  │  IP: 192.168.49.1            │  IP: 192.168.49.2               │         │
│  └────────────────────────────────────────────────────────────────┘         │
│                                    │                                         │
│  ┌─────────────────────────────────┼─────────────────────────────┐         │
│  │ connectionInfoStream FIRES      │                              │         │
│  │ on BOTH devices simultaneously  │                              │         │
│  └─────────────────────────────────┼─────────────────────────────┘         │
│                                    │                                         │
│  Device A (GO)                     │              Device B (Client)          │
│  ┌──────────────────────┐          │       ┌──────────────────────┐        │
│  │ connectionInfo:      │          │       │ connectionInfo:      │        │
│  │ - groupFormed: true  │          │       │ - groupFormed: true  │        │
│  │ - isGroupOwner: true │          │       │ - isGroupOwner: false│        │
│  │ - goAddress:         │          │       │ - goAddress:         │        │
│  │   192.168.49.1       │          │       │   192.168.49.1       │        │
│  └──────────────────────┘          │       └──────────────────────┘        │
│           │                        │                    │                   │
│           ▼                        │                    ▼                   │
│  ┌──────────────────────┐          │       ┌──────────────────────┐        │
│  │ Starts HTTP Server   │          │       │ Starts HTTP Server   │        │
│  │ on 192.168.49.1:8080 │          │       │ on 192.168.49.2:8080 │        │
│  └──────────────────────┘          │       └──────────────────────┘        │
│           │                        │                    │                   │
│           ▼                        │                    ▼                   │
│  ┌──────────────────────┐          │       ┌──────────────────────┐        │
│  │ Waits 2 seconds for  │          │       │ Waits 2 seconds for  │        │
│  │ IP assignment        │          │       │ IP assignment        │        │
│  └──────────────────────┘          │       └──────────────────────┘        │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│         PHASE 4: CONNECTION REQUEST (Over Wi-Fi Direct Network)             │
│                                                                              │
│  Device A (Sender/GO)              │              Device B (Receiver/Client) │
│  ┌──────────────────────┐          │                                        │
│  │ Has _pendingDevice   │          │                                        │
│  │ (set in Phase 2)     │          │                                        │
│  └──────────────────────┘          │                                        │
│           │                        │                                        │
│           ▼                        │                                        │
│  ┌──────────────────────┐          │                                        │
│  │ Updates Device B IP: │          │                                        │
│  │ 192.168.49.2         │          │                                        │
│  └──────────────────────┘          │                                        │
│           │                        │                                        │
│           ▼                        │                                        │
│  ┌──────────────────────┐          │                                        │
│  │ Sends UDP Request    │          │                                        │
│  │ to 192.168.49.2      │──────────┼───────►┌──────────────────────┐       │
│  │                      │          │        │ Receives UDP Request │       │
│  │ Contains:            │          │        │ from 192.168.49.1    │       │
│  │ - Device name        │          │        └──────────────────────┘       │
│  │ - File list          │          │                    │                  │
│  │ - Total size         │          │                    ▼                  │
│  └──────────────────────┘          │        ┌──────────────────────┐       │
│           │                        │        │ Shows Dialog:        │       │
│           ▼                        │        │ ┌──────────────────┐ │       │
│  ┌──────────────────────┐          │        │ │ Device A wants   │ │       │
│  │ Starts 10s timeout   │          │        │ │ to send files    │ │       │
│  │ timer                │          │        │ │                  │ │       │
│  └──────────────────────┘          │        │ │ • photo.jpg      │ │       │
│           │                        │        │ │ • video.mp4      │ │       │
│           ▼                        │        │ │                  │ │       │
│  ┌──────────────────────┐          │        │ │ Total: 48.7 MB   │ │       │
│  │ Waits for response   │          │        │ │                  │ │       │
│  └──────────────────────┘          │        │ │ [Decline][Accept]│ │       │
│                                    │        │ └──────────────────┘ │       │
│                                    │        └──────────────────────┘       │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                    PHASE 5: USER ACCEPTS                                    │
│                                                                              │
│  Device A (Sender/GO)              │              Device B (Receiver/Client) │
│                                    │       ┌──────────────────────┐         │
│                                    │       │ USER TAPS "ACCEPT"   │         │
│                                    │       └──────────────────────┘         │
│                                    │                    │                    │
│                                    │                    ▼                    │
│  ┌──────────────────────┐          │       ┌──────────────────────┐         │
│  │ Receives UDP         │◄─────────┼───────│ Sends UDP Response   │         │
│  │ Response:            │          │       │ to 192.168.49.1:     │         │
│  │ { accepted: true }   │          │       │ { accepted: true }   │         │
│  └──────────────────────┘          │       └──────────────────────┘         │
│           │                        │                    │                    │
│           ▼                        │                    ▼                    │
│  ┌──────────────────────┐          │       ┌──────────────────────┐         │
│  │ Cancels timeout      │          │       │ Navigates to         │         │
│  │ timer                │          │       │ AndroidReceiveScreen │         │
│  └──────────────────────┘          │       └──────────────────────┘         │
│           │                        │                    │                    │
│           ▼                        │                    ▼                    │
│  ┌──────────────────────┐          │       ┌──────────────────────┐         │
│  │ HTTP server ready    │          │       │ Shows share code     │         │
│  │ at 192.168.49.1:8080 │          │       │ (auto-filled)        │         │
│  └──────────────────────┘          │       └──────────────────────┘         │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                    PHASE 6: FILE TRANSFER                                   │
│                                                                              │
│  Device A (Sender/GO)              │              Device B (Receiver/Client) │
│  ┌──────────────────────┐          │       ┌──────────────────────┐         │
│  │ HTTP Server          │          │       │ Connects to:         │         │
│  │ 192.168.49.1:8080    │          │       │ http://192.168.49.1  │         │
│  │                      │          │       │      :8080           │         │
│  │ Serves files:        │          │       └──────────────────────┘         │
│  │ • photo.jpg          │◄─────────┼───────┐                                │
│  │ • video.mp4          │          │       │ HTTP GET Requests    │         │
│  │                      │          │       └──────────────────────┘         │
│  └──────────────────────┘          │                    │                    │
│           │                        │                    ▼                    │
│           ▼                        │       ┌──────────────────────┐         │
│  ┌──────────────────────┐          │       │ Downloads files      │         │
│  │ Shows progress:      │          │       │ Shows progress       │         │
│  │ "Device B is         │          │       │ Saves to storage     │         │
│  │  downloading..."     │          │       └──────────────────────┘         │
│  └──────────────────────┘          │                    │                    │
│           │                        │                    ▼                    │
│           ▼                        │       ┌──────────────────────┐         │
│  ┌──────────────────────┐          │       │ Transfer Complete!   │         │
│  │ Transfer Complete!   │          │       └──────────────────────┘         │
│  └──────────────────────┘          │                                        │
└─────────────────────────────────────────────────────────────────────────────┘

## Key Points

1. **Discovery**: Wi-Fi Direct discovery runs automatically on both devices
2. **Filtering**: Only devices running ZapShare are shown
3. **Connection**: User taps device → Wi-Fi Direct connection initiated
4. **Group Formation**: Both devices get IPs on 192.168.49.x network
5. **HTTP Servers**: BOTH devices start HTTP servers after group formation
6. **Connection Request**: Sender sends UDP request to receiver
7. **Dialog**: Receiver shows dialog with file list
8. **Transfer**: HTTP-based transfer over Wi-Fi Direct network

## Network Topology

```
Before Wi-Fi Direct:
Device A: 192.168.1.100 (Home Wi-Fi)
Device B: 192.168.43.50 (Mobile Data)
❌ NOT on same network

After Wi-Fi Direct Group Formation:
Device A (GO): 192.168.49.1 (Wi-Fi Direct P2P)
Device B (Client): 192.168.49.2 (Wi-Fi Direct P2P)
✅ ON SAME NETWORK (192.168.49.x)
```

## Samsung Hotspot Issue - SOLVED

Samsung phones force hotspot off when connecting to Wi-Fi Direct.
This is NOT a problem because:
- Wi-Fi Direct creates its own network (192.168.49.x)
- No hotspot needed
- Both devices start HTTP servers independently
- File transfer happens over Wi-Fi Direct network
