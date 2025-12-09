# Wi-Fi Direct Integration for ZapShare

## Overview
This document describes the Wi-Fi Direct integration for ZapShare that uses **non-persistent groups** to avoid saving connections in Android settings.

## Key Changes

### 1. WiFiDirectManager.kt (Android)
**Location:** `android/app/src/main/kotlin/com/example/zap_share/WiFiDirectManager.kt`

**Key Features:**
- **Peer Discovery:** Automatically discovers nearby Wi-Fi Direct devices
- **Non-Persistent Groups:** Uses `manager.connect()` with `WifiP2pConfig` instead of `manager.createGroup()`
- **Group Owner Intent:** Configurable (0-15) to control who becomes the group owner
  - Sender: `groupOwnerIntent = 15` (strongly prefer to be GO)
  - Receiver: `groupOwnerIntent = 0` (prefer to be client)

**Methods:**
- `initialize()` - Initialize Wi-Fi Direct manager
- `startPeerDiscovery()` - Start discovering nearby peers
- `stopPeerDiscovery()` - Stop peer discovery
- `connectToPeer(deviceAddress, isGroupOwner)` - Connect to a peer using non-persistent group
- `getDiscoveredPeers()` - Get list of discovered peers
- `requestGroupInfo()` - Get group SSID/password after connection
- `removeGroup()` - Remove the Wi-Fi Direct group
- `disconnect()` - Disconnect from Wi-Fi Direct

**Broadcast Receiver Events:**
- `WIFI_P2P_STATE_CHANGED_ACTION` - Wi-Fi P2P enabled/disabled
- `WIFI_P2P_PEERS_CHANGED_ACTION` - Peer list updated
- `WIFI_P2P_CONNECTION_CHANGED_ACTION` - Connection state changed
- `WIFI_P2P_THIS_DEVICE_CHANGED_ACTION` - This device info changed

### 2. MainActivity.kt Updates
**Location:** `android/app/src/main/kotlin/com/example/zap_share/MainActivity.kt`

**New Method Channel Handlers:**
- `startPeerDiscovery` - Start discovering Wi-Fi Direct peers
- `stopPeerDiscovery` - Stop peer discovery
- `connectToPeer` - Connect to a peer (deviceAddress, isGroupOwner)
- `getDiscoveredPeers` - Get list of discovered peers
- `removeGroup` - Remove Wi-Fi Direct group
- `requestGroupInfo` - Request group information
- `disconnect` - Disconnect from Wi-Fi Direct
- `isWifiP2pEnabled` - Check if Wi-Fi P2P is enabled

### 3. WiFiDirectService (Flutter)
**Location:** `lib/services/wifi_direct_service.dart`

**Models:**
- `WiFiDirectPeer` - Represents a discovered Wi-Fi Direct peer
- `WiFiDirectGroupInfo` - Group information (SSID, password, owner address)
- `WiFiDirectConnectionInfo` - Connection state information

**Streams:**
- `peersStream` - Stream of discovered peers
- `groupInfoStream` - Stream of group information updates
- `connectionInfoStream` - Stream of connection state changes
- `wifiP2pStateStream` - Stream of Wi-Fi P2P enabled/disabled state
- `connectionFailedStream` - Stream of connection failures

**Methods:**
- `initialize()` - Initialize Wi-Fi Direct service
- `startPeerDiscovery()` - Start discovering peers
- `stopPeerDiscovery()` - Stop discovering peers
- `connectToPeer(deviceAddress, {isGroupOwner})` - Connect to a peer
- `getDiscoveredPeers()` - Get list of discovered peers
- `requestGroupInfo()` - Request group info
- `removeGroup()` - Remove group
- `disconnect()` - Disconnect

### 4. DeviceDiscoveryService Updates
**Location:** `lib/services/device_discovery_service.dart`

**Changes:**
- Added `wifiDirect` to `DiscoveryMethod` enum
- Added `wifiDirectAddress` field to `DiscoveredDevice` for storing MAC addresses
- Imported `wifi_direct_service.dart` for future integration

## Usage Flow

### Sender (File Sharing Device)
```dart
// 1. Initialize Wi-Fi Direct
final wifiDirect = WiFiDirectService();
await wifiDirect.initialize();

// 2. Start peer discovery
await wifiDirect.startPeerDiscovery();

// 3. Listen for discovered peers
wifiDirect.peersStream.listen((peers) {
  // Display peers in UI
  for (var peer in peers) {
    print('Found: ${peer.deviceName} (${peer.deviceAddress})');
  }
});

// 4. When user selects a device, connect as Group Owner
await wifiDirect.connectToPeer(
  selectedPeer.deviceAddress,
  isGroupOwner: true, // Sender is Group Owner
);

// 5. Listen for group info
wifiDirect.groupInfoStream.listen((groupInfo) {
  print('SSID: ${groupInfo.ssid}');
  print('Password: ${groupInfo.password}');
  // Start HTTP server for file sharing
});
```

### Receiver (Receiving Device)
```dart
// 1. Initialize Wi-Fi Direct
final wifiDirect = WiFiDirectService();
await wifiDirect.initialize();

// 2. Start peer discovery
await wifiDirect.startPeerDiscovery();

// 3. Listen for discovered peers
wifiDirect.peersStream.listen((peers) {
  // Display peers in UI
});

// 4. When user selects sender device, connect as Client
await wifiDirect.connectToPeer(
  senderPeer.deviceAddress,
  isGroupOwner: false, // Receiver is Client
);

// 5. Listen for connection info
wifiDirect.connectionInfoStream.listen((connectionInfo) {
  if (connectionInfo.groupFormed) {
    // Connected! Get group owner address
    final serverIp = connectionInfo.groupOwnerAddress;
    // Connect to HTTP server at serverIp:8080
  }
});
```

## Non-Persistent Group Implementation

### Why Non-Persistent?
Persistent groups are saved in Android settings and can cause issues:
- Groups persist across app restarts
- Can't easily remove them
- May interfere with future connections
- User has to manually remove them from settings

### Solution: manager.connect() with WifiP2pConfig
Instead of using `manager.createGroup()`, we use:

```kotlin
val config = WifiP2pConfig().apply {
    deviceAddress = receiverDevice.deviceAddress
    groupOwnerIntent = 15  // Sender wants to be GO
}
manager.connect(channel, config, actionListener)
```

This creates a **temporary group** that is automatically removed when:
- `manager.removeGroup()` is called
- `manager.disconnect()` is called
- App is closed
- Connection is lost

## Integration with Main App

### 1. App Startup (main.dart)
```dart
// Initialize Wi-Fi Direct on app startup
final wifiDirect = WiFiDirectService();
await wifiDirect.initialize();

// Start peer discovery in background
await wifiDirect.startPeerDiscovery();
```

### 2. Send Screen (AndroidHttpFileShareScreen.dart)
```dart
// Show Wi-Fi Direct peers alongside UDP-discovered devices
// When user clicks on a Wi-Fi Direct device:
// 1. Connect as Group Owner
// 2. Wait for group info
// 3. Start HTTP server
// 4. Share files
```

### 3. Receive Screen
```dart
// Show Wi-Fi Direct peers
// When user clicks on sender:
// 1. Connect as Client
// 2. Wait for connection info
// 3. Get group owner IP
// 4. Connect to HTTP server
```

## Permissions Required
Already included in AndroidManifest.xml:
- `ACCESS_WIFI_STATE`
- `CHANGE_WIFI_STATE`
- `ACCESS_FINE_LOCATION` (required for Wi-Fi Direct on Android 6+)
- `NEARBY_WIFI_DEVICES` (Android 13+)

## Benefits
1. **No Persistent Groups** - Groups are automatically cleaned up
2. **Automatic Discovery** - Peers are discovered automatically
3. **Seamless Integration** - Works alongside existing UDP discovery
4. **Better UX** - No manual group removal needed
5. **Faster Connection** - Direct peer-to-peer connection

## Next Steps
1. Update `main.dart` to initialize and start Wi-Fi Direct discovery on app startup
2. Update `AndroidHttpFileShareScreen.dart` to show Wi-Fi Direct peers
3. Add connection handling when user selects a Wi-Fi Direct device
4. Test the complete flow

## Notes
- Wi-Fi Direct is Android-only
- Requires location permission on Android 6+
- Group owner gets IP `192.168.49.1` by default
- Clients get IPs in `192.168.49.x` range
- Maximum 8 devices can connect to a group owner
