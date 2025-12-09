# Wi-Fi Direct Implementation for ZapShare

## Overview

This implementation provides custom Wi-Fi Direct (Wi-Fi P2P) functionality for ZapShare, similar to how EasyShare handles local hotspot SSID and password sharing. Instead of relying on Flutter plugins with limitations, we use platform channels to directly access Android's `WifiP2pManager` API.

## Architecture

### Flutter Side (`lib/services/wifi_direct_service.dart`)

The `WiFiDirectService` class provides a Dart interface for Wi-Fi Direct operations:

- **Group Management**: Create and remove Wi-Fi Direct groups (hotspots)
- **Credential Access**: Get SSID and password of created groups
- **Connection**: Connect to Wi-Fi Direct groups
- **Event Streaming**: Real-time updates on group state changes

### Android Side (`android/app/src/main/kotlin/com/example/zap_share/WiFiDirectManager.kt`)

The `WiFiDirectManager` class implements the native Android functionality:

- Uses `WifiP2pManager` API for direct access to Wi-Fi Direct features
- Handles broadcast receivers for Wi-Fi P2P events
- Provides group information including SSID and password
- Manages group lifecycle (create, remove, cleanup)

## Key Features

### 1. Group Creation
```dart
final wifiDirectService = WiFiDirectService();
await wifiDirectService.initialize();
await wifiDirectService.createGroup();
```

When a group is created, the service automatically requests group info and provides:
- SSID (network name)
- Password (passphrase)
- Group owner address
- Whether this device is the group owner

### 2. Getting Group Credentials
```dart
// Listen to group info stream
wifiDirectService.groupInfoStream.listen((info) {
  print('SSID: ${info.ssid}');
  print('Password: ${info.password}');
  print('Owner Address: ${info.ownerAddress}');
});

// Or request manually
final info = await wifiDirectService.requestGroupInfo();
```

### 3. Connecting to a Group
```dart
await wifiDirectService.connectToGroup(ssid, password);
```

### 4. Cleanup
```dart
await wifiDirectService.removeGroup();
```

## How It Works (Similar to EasyShare)

### Sender Device (Group Owner)
1. Creates a Wi-Fi Direct group using `createGroup()`
2. Receives group info callback with SSID and password
3. Shares credentials with receiver via BLE or QR code
4. Waits for receiver to connect
5. Starts file transfer over HTTP

### Receiver Device
1. Receives SSID and password from sender (via BLE/QR)
2. Connects to the Wi-Fi Direct group using `connectToGroup()`
3. Discovers sender via UDP broadcast
4. Receives files over HTTP

## Integration with Device Discovery Service

The `DeviceDiscoveryService` can now use Wi-Fi Direct credentials:

```dart
// In device_discovery_service.dart
final wifiDirectService = WiFiDirectService();
await wifiDirectService.initialize();

// Create group
await wifiDirectService.createGroup();

// Listen for group info
wifiDirectService.groupInfoStream.listen((info) {
  if (info.ssid != null && info.password != null) {
    // Share via BLE
    setHotspotCredentials(info.ssid!, info.password!);
  }
});
```

## Advantages Over Plugin-Based Approach

### 1. **Direct API Access**
- No plugin limitations or bugs
- Full control over Wi-Fi Direct features
- Access to all `WifiP2pManager` capabilities

### 2. **Reliable Credential Access**
- Direct access to `WifiP2pGroup.getNetworkName()` and `WifiP2pGroup.getPassphrase()`
- No workarounds needed
- Works consistently across Android versions

### 3. **Better Event Handling**
- Native broadcast receivers for Wi-Fi P2P events
- Real-time updates via method channel callbacks
- Proper lifecycle management

### 4. **EasyShare-Like Experience**
- Similar workflow to popular file-sharing apps
- Automatic credential sharing
- Seamless connection process

## Android Permissions Required

Already included in `AndroidManifest.xml`:
```xml
<uses-permission android:name="android.permission.ACCESS_WIFI_STATE"/>
<uses-permission android:name="android.permission.CHANGE_WIFI_STATE"/>
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION"/>
<uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION"/>
<uses-permission android:name="android.permission.NEARBY_WIFI_DEVICES"/>
```

## Method Channel API

### Channel: `zapshare.wifi_direct`

#### Methods (Flutter → Android)

| Method | Arguments | Returns | Description |
|--------|-----------|---------|-------------|
| `initialize` | - | `bool` | Initialize Wi-Fi Direct manager |
| `createGroup` | - | `bool` | Create Wi-Fi Direct group |
| `removeGroup` | - | `bool` | Remove Wi-Fi Direct group |
| `requestGroupInfo` | - | `Map?` | Get group SSID, password, etc. |
| `connectToGroup` | `ssid`, `password` | `bool` | Connect to Wi-Fi Direct group |
| `disconnect` | - | `bool` | Disconnect from group |
| `isWifiP2pEnabled` | - | `bool` | Check if Wi-Fi P2P is enabled |

#### Callbacks (Android → Flutter)

| Callback | Arguments | Description |
|----------|-----------|-------------|
| `onGroupInfoAvailable` | `Map<String, dynamic>` | Group info (SSID, password, etc.) |
| `onGroupRemoved` | - | Group was removed |
| `onConnectionInfoAvailable` | `Map<String, dynamic>` | Connection info updated |

## Usage Example

### Complete Flow

```dart
import 'package:zap_share/services/wifi_direct_service.dart';

class FileShareScreen extends StatefulWidget {
  @override
  _FileShareScreenState createState() => _FileShareScreenState();
}

class _FileShareScreenState extends State<FileShareScreen> {
  final wifiDirectService = WiFiDirectService();
  WiFiDirectGroupInfo? groupInfo;

  @override
  void initState() {
    super.initState();
    _setupWifiDirect();
  }

  Future<void> _setupWifiDirect() async {
    // Initialize
    await wifiDirectService.initialize();

    // Listen for group info
    wifiDirectService.groupInfoStream.listen((info) {
      setState(() {
        groupInfo = info;
      });
      print('Group created: ${info.ssid} / ${info.password}');
    });
  }

  Future<void> _startSharing() async {
    // Create Wi-Fi Direct group
    final success = await wifiDirectService.createGroup();
    if (success) {
      print('Group creation initiated...');
      // Group info will arrive via stream
    }
  }

  Future<void> _stopSharing() async {
    await wifiDirectService.removeGroup();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Wi-Fi Direct Share')),
      body: Column(
        children: [
          if (groupInfo != null) ...[
            Text('SSID: ${groupInfo!.ssid}'),
            Text('Password: ${groupInfo!.password}'),
            Text('Owner: ${groupInfo!.ownerAddress}'),
          ],
          ElevatedButton(
            onPressed: _startSharing,
            child: Text('Start Sharing'),
          ),
          ElevatedButton(
            onPressed: _stopSharing,
            child: Text('Stop Sharing'),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    wifiDirectService.dispose();
    super.dispose();
  }
}
```

## Troubleshooting

### Group Info Not Received
- Ensure location permissions are granted
- Check that Wi-Fi is enabled
- Verify Wi-Fi Direct is supported on device

### Connection Fails
- Ensure SSID and password are correct
- Check that devices are in range
- Verify no other Wi-Fi Direct groups are active

### Android 10+ Issues
- Android 10+ has restrictions on Wi-Fi configuration
- May need to use `WifiNetworkSpecifier` for connections
- Current implementation handles legacy devices (Android 9 and below)

## Future Enhancements

1. **Android 10+ Support**: Implement `WifiNetworkSpecifier` for newer Android versions
2. **QR Code Integration**: Generate QR codes with SSID/password for easy sharing
3. **Automatic Reconnection**: Handle connection drops and reconnect automatically
4. **Peer Discovery**: Discover other Wi-Fi Direct devices before creating group
5. **Group Negotiation**: Support for negotiating group owner role

## References

- [Android Wi-Fi P2P Documentation](https://developer.android.com/guide/topics/connectivity/wifip2p)
- [WifiP2pManager API](https://developer.android.com/reference/android/net/wifi/p2p/WifiP2pManager)
- [WifiP2pGroup API](https://developer.android.com/reference/android/net/wifi/p2p/WifiP2pGroup)

## Comparison with EasyShare

| Feature | EasyShare | ZapShare (This Implementation) |
|---------|-----------|-------------------------------|
| Wi-Fi Direct Groups | ✅ | ✅ |
| SSID/Password Access | ✅ | ✅ |
| BLE Credential Sharing | ✅ | ✅ (via existing BLE service) |
| QR Code Sharing | ✅ | 🔄 (planned) |
| Auto-reconnect | ✅ | 🔄 (planned) |
| Platform Channels | ✅ | ✅ |
| Plugin-free | ✅ | ✅ |

## License

This implementation is part of ZapShare and follows the same license.
