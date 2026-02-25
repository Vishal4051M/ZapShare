# Complete Wi-Fi Direct Flow - Step by Step

## Scenario
- **Device A (Sender)**: Opens app, selects files, wants to send
- **Device B (Receiver)**: Opens app, just browsing
- **Initial State**: Both devices are NOT on the same network

## Detailed Flow

### Phase 1: Discovery (Both Devices Not Connected)

#### Device A (Sender)
1. Opens ZapShare app
2. Wi-Fi Direct discovery starts automatically
3. Discovers Device B via Wi-Fi Direct peer discovery
4. Shows "Device B" in nearby devices list (with Wi-Fi Direct icon)
5. Selects files to send
6. Taps on "Device B" in discovery section

#### Device B (Receiver)
1. Opens ZapShare app
2. Wi-Fi Direct discovery starts automatically
3. Discovers Device A via Wi-Fi Direct peer discovery
4. Shows "Device A" in nearby devices list
5. Waits for incoming connection

### Phase 2: Wi-Fi Direct Connection Initiation

#### Device A (Sender) - When user taps Device B
```
User Action: Taps on Device B in nearby devices
↓
_sendConnectionRequest(device) is called
↓
Checks: device.discoveryMethod == DiscoveryMethod.wifiDirect
↓
Stores: _pendingDevice = device
↓
Calls: _discoveryService.connectToWifiDirectPeer(device.wifiDirectAddress)
↓
Shows: "Connecting to Device B via Wi-Fi Direct..." (SnackBar)
```

#### Device B (Receiver) - Automatically
```
Receives Wi-Fi Direct connection request from Device A
↓
Android shows system dialog: "Device A wants to connect"
↓
User accepts the connection
```

### Phase 3: Wi-Fi Direct Group Formation

**CRITICAL: This happens on BOTH devices simultaneously**

#### Network Formation
```
Wi-Fi Direct Group Formed
├── Device A becomes: Group Owner (GO) - IP: 192.168.49.1
└── Device B becomes: Client - IP: 192.168.49.2

Both devices are now on the SAME network (192.168.49.x)
```

#### Device A (Sender - Group Owner)
```
connectionInfoStream fires
↓
connectionInfo.groupFormed = true
connectionInfo.isGroupOwner = true
connectionInfo.groupOwnerAddress = "192.168.49.1"
↓
Starts HTTP server on 192.168.49.1:8080
↓
Waits for Device B to send connection request via UDP
```

#### Device B (Receiver - Client)
```
connectionInfoStream fires
↓
connectionInfo.groupFormed = true
connectionInfo.isGroupOwner = false
connectionInfo.groupOwnerAddress = "192.168.49.1"
↓
Starts HTTP server on 192.168.49.2:8080 (for receiving)
↓
Starts UDP discovery to announce presence on new network
```

### Phase 4: Connection Request (Over Wi-Fi Direct Network)

#### Device A (Sender)
```
Has pending device from Phase 2
↓
Updates device IP: updateWifiDirectDeviceIp(macAddress, "192.168.49.2")
↓
Calculates total file size
↓
Sends UDP connection request to 192.168.49.2
  - Contains: device name, file list, total size
↓
Starts 10-second timeout timer
↓
Waits for response
```

#### Device B (Receiver)
```
Receives UDP connection request from 192.168.49.1
↓
Shows dialog to user:
  ┌─────────────────────────────────┐
  │  Device A wants to send files   │
  │                                 │
  │  • photo1.jpg (2.5 MB)         │
  │  • video.mp4 (45 MB)           │
  │  • document.pdf (1.2 MB)       │
  │                                 │
  │  Total: 48.7 MB                │
  │                                 │
  │  [Decline]  [Accept]           │
  └─────────────────────────────────┘
```

### Phase 5: User Response

#### Device B (Receiver) - User Accepts
```
User taps "Accept"
↓
Sends UDP response to 192.168.49.1: { accepted: true }
↓
Navigates to AndroidReceiveScreen
↓
Shows share code for Device A's IP
↓
Ready to download files from http://192.168.49.1:8080
```

#### Device A (Sender) - Receives Response
```
Receives UDP response: { accepted: true }
↓
Cancels timeout timer
↓
HTTP server already running on 192.168.49.1:8080
↓
Shows: "Connection accepted! Device B is downloading..."
↓
Waits for HTTP requests from Device B
```

### Phase 6: File Transfer

#### Device B (Receiver)
```
On AndroidReceiveScreen
↓
Enters share code (auto-filled from connection request)
↓
Connects to http://192.168.49.1:8080
↓
Downloads files via HTTP GET requests
↓
Shows progress for each file
↓
Saves files to selected location
```

#### Device A (Sender)
```
HTTP server receives GET requests
↓
Serves files from SAF URIs
↓
Shows progress for each file
↓
Shows connected client: "Device B (192.168.49.2)"
↓
Transfer completes
```

## Key Implementation Points

### 1. Wi-Fi Direct Discovery (Always Running)
```dart
// In DeviceDiscoveryService.initialize()
if (Platform.isAndroid) {
  await _wifiDirectService.initialize();
  await _wifiDirectService.startPeerDiscovery();
  
  // Listen for discovered peers
  _wifiDirectPeersSubscription = _wifiDirectService.peersStream.listen((peers) {
    _handleWifiDirectPeers(peers); // Filters and adds to _discoveredDevices
  });
}
```

### 2. Connection Initiation (Device A)
```dart
// In _sendConnectionRequest() when Wi-Fi Direct device is tapped
if (device.discoveryMethod == DiscoveryMethod.wifiDirect) {
  setState(() {
    _pendingDevice = device; // CRITICAL: Store for later use
  });
  
  final success = await _discoveryService.connectToWifiDirectPeer(
    device.wifiDirectAddress!,
  );
  
  if (success) {
    // Show connecting message
    // Wait for group formation (handled by listener)
  }
}
```

### 3. Group Formation Handler (BOTH Devices)
```dart
// In initState() or _initDeviceDiscovery()
final wifiDirectService = WiFiDirectService();
wifiDirectService.connectionInfoStream.listen((connectionInfo) async {
  if (connectionInfo.groupFormed) {
    print('📡 Wi-Fi Direct group formed!');
    
    // BOTH devices start HTTP server
    if (!_isSharing) {
      await _startServer();
    }
    
    // Wait for IP assignment
    await Future.delayed(Duration(seconds: 2));
    
    // Only SENDER (Device A) sends connection request
    if (_pendingDevice != null && 
        _pendingDevice!.discoveryMethod == DiscoveryMethod.wifiDirect) {
      
      String? peerIp;
      if (connectionInfo.isGroupOwner) {
        // We are GO, peer will send request to us
        // We'll receive it via UDP
      } else {
        // We are Client, GO is at groupOwnerAddress
        peerIp = connectionInfo.groupOwnerAddress;
      }
      
      if (peerIp != null) {
        // Update device IP
        _discoveryService.updateWifiDirectDeviceIp(
          _pendingDevice!.wifiDirectAddress!,
          peerIp,
        );
        
        // Send connection request
        await _discoveryService.sendConnectionRequest(
          peerIp,
          _fileNames,
          totalSize,
        );
      }
    }
  }
});
```

### 4. Connection Request Dialog (Device B)
```dart
// Already implemented in _connectionRequestSubscription
_connectionRequestSubscription = _discoveryService.connectionRequestStream.listen((request) {
  _showConnectionRequestDialog(request);
});
```

## Critical Differences from Local Network Flow

| Aspect | Local Network | Wi-Fi Direct |
|--------|---------------|--------------|
| **Discovery** | UDP broadcast on existing network | Wi-Fi Direct peer discovery |
| **Network** | Already connected (same Wi-Fi) | Forms new P2P network (192.168.49.x) |
| **Connection** | Direct UDP request | Wi-Fi Direct connection → Group formation → UDP request |
| **HTTP Server** | Sender starts when sharing | BOTH devices start after group formation |
| **IP Discovery** | Via UDP broadcast | GO IP known, Client IP via UDP |

## Samsung Hotspot Handling

**Problem**: Samsung phones force hotspot off when connecting to Wi-Fi Direct

**Solution**: 
- Don't use hotspot for Wi-Fi Direct connections
- Wi-Fi Direct creates its own network (192.168.49.x)
- Both devices start HTTP servers independently
- No hotspot needed at all

## Testing Checklist

- [ ] Device A discovers Device B via Wi-Fi Direct (not on same network)
- [ ] Tapping Device B initiates Wi-Fi Direct connection
- [ ] Both devices form group successfully
- [ ] Both devices get IPs (192.168.49.1 and 192.168.49.2)
- [ ] Both devices start HTTP servers
- [ ] Device A sends connection request to Device B
- [ ] Device B shows dialog with file list
- [ ] Accepting on Device B starts file transfer
- [ ] Files transfer successfully over Wi-Fi Direct network
- [ ] Works on Samsung devices (hotspot not required)

## Common Issues & Solutions

### Issue 1: Device B not discovered
**Solution**: Ensure Wi-Fi Direct discovery is running on both devices

### Issue 2: Connection request not received
**Solution**: Ensure both devices are on Wi-Fi Direct network (192.168.49.x)

### Issue 3: HTTP server not accessible
**Solution**: Ensure both devices started HTTP servers after group formation

### Issue 4: Samsung hotspot interference
**Solution**: Already handled - Wi-Fi Direct doesn't need hotspot
