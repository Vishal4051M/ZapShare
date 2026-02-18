import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/services.dart';
// import 'wifi_direct_service.dart'; // REMOVED: Using Bluetooth + Hotspot instead

// Connection request model
class ConnectionRequest {
  final String deviceId;
  final String deviceName;
  final String platform;
  final String ipAddress;
  final int port;
  final int fileCount;
  final List<String> fileNames;
  final int totalSize;
  final DateTime timestamp;

  ConnectionRequest({
    required this.deviceId,
    required this.deviceName,
    required this.platform,
    required this.ipAddress,
    required this.port,
    required this.fileCount,
    required this.fileNames,
    required this.totalSize,
    required this.timestamp,
  });
}

// Connection response model
class ConnectionResponse {
  final String deviceId;
  final String deviceName;
  final String ipAddress;
  final bool accepted;
  final DateTime timestamp;

  ConnectionResponse({
    required this.deviceId,
    required this.deviceName,
    required this.ipAddress,
    required this.accepted,
    required this.timestamp,
  });
}

class CastRequest {
  final String deviceId;
  final String deviceName;
  final String url;
  final String? fileName;
  final String? subtitleUrl;
  final String senderIp;
  final DateTime timestamp;

  CastRequest({
    required this.deviceId,
    required this.deviceName,
    required this.url,
    this.fileName,
    this.subtitleUrl,
    required this.senderIp,
    required this.timestamp,
  });
}

/// Remote control command sent from controller to player
class CastControl {
  final String action; // play, pause, seek, volume, stop
  final double? seekPosition; // in seconds
  final double? volume; // 0.0 - 1.0
  final String senderIp;

  CastControl({
    required this.action,
    this.seekPosition,
    this.volume,
    required this.senderIp,
  });
}

/// Playback status sent from player back to controller
class CastStatus {
  final double position; // seconds
  final double duration; // seconds
  final double buffered; // seconds
  final bool isPlaying;
  final bool isBuffering;
  final double volume;
  final String? fileName;
  final String senderIp;

  CastStatus({
    required this.position,
    required this.duration,
    required this.buffered,
    required this.isPlaying,
    required this.isBuffering,
    required this.volume,
    this.fileName,
    required this.senderIp,
  });
}

/// Acknowledgement sent from receiver back to sender when cast is accepted/declined
class CastAck {
  final bool accepted;
  final String senderIp;
  final String deviceName;

  CastAck({
    required this.accepted,
    required this.senderIp,
    required this.deviceName,
  });
}

/// Screen mirror request: Android sender wants to share screen to another device
class ScreenMirrorRequest {
  final String deviceId;
  final String deviceName;
  final String streamUrl;
  final String senderIp;
  final DateTime timestamp;

  ScreenMirrorRequest({
    required this.deviceId,
    required this.deviceName,
    required this.streamUrl,
    required this.senderIp,
    required this.timestamp,
  });
}

/// Remote control command sent from the mirror viewer to the mirroring Android device
class ScreenMirrorControl {
  /// Action: 'back', 'home', 'recents', 'volume_up', 'volume_down',
  ///         'power', 'scroll_up', 'scroll_down', 'tap', 'click',
  ///         'long_press', 'swipe', 'drag', 'scroll', 'type', 'key',
  ///         'brightness_up', 'brightness_down', 'notifications'
  final String action;

  /// For positional actions: normalized x/y (0.0 - 1.0)
  final double? tapX;
  final double? tapY;

  /// For swipe/drag: end coordinates (normalized)
  final double? endX;
  final double? endY;

  /// For 'type' action: text to type, for 'key': key name
  final String? text;

  /// For 'scroll' action: scroll delta (positive=up, negative=down)
  final double? scrollDelta;

  /// Duration in ms for swipe/drag
  final int? duration;
  final String senderIp;

  ScreenMirrorControl({
    required this.action,
    this.tapX,
    this.tapY,
    this.endX,
    this.endY,
    this.text,
    this.scrollDelta,
    this.duration,
    required this.senderIp,
  });
}

enum DiscoveryMethod { udp, wifiDirect, bluetooth }

class DiscoveredDevice {
  final String deviceId;
  final String deviceName;
  final String ipAddress;
  final int port;
  final String platform;
  final DateTime lastSeen;
  bool isFavorite;
  final DiscoveryMethod discoveryMethod;
  final String? wifiDirectAddress; // MAC address for Wi-Fi Direct peers
  final String? bleAddress; // BLE address for Bluetooth-discovered peers
  final String? avatarUrl;
  final String? userName;

  DiscoveredDevice({
    required this.deviceId,
    required this.deviceName,
    required this.ipAddress,
    required this.port,
    required this.platform,
    required this.lastSeen,
    this.isFavorite = false,
    this.discoveryMethod = DiscoveryMethod.udp,
    this.wifiDirectAddress,
    this.bleAddress,
    this.avatarUrl,
    this.userName,
  });

  Map<String, dynamic> toJson() => {
    'deviceId': deviceId,
    'deviceName': deviceName,
    'ipAddress': ipAddress,
    'port': port,
    'platform': platform,
    'lastSeen': lastSeen.toIso8601String(),
    'isFavorite': isFavorite,
    'discoveryMethod': discoveryMethod.index,
    'wifiDirectAddress': wifiDirectAddress,
    'userName': userName,
  };

  factory DiscoveredDevice.fromJson(Map<String, dynamic> json) {
    return DiscoveredDevice(
      deviceId: json['deviceId'] ?? '',
      deviceName: json['deviceName'] ?? 'Unknown Device',
      ipAddress: json['ipAddress'] ?? '',
      port: json['port'] ?? 8080,
      platform: json['platform'] ?? 'unknown',
      lastSeen: DateTime.parse(
        json['lastSeen'] ?? DateTime.now().toIso8601String(),
      ),
      isFavorite: json['isFavorite'] ?? false,
      discoveryMethod:
          json['discoveryMethod'] != null
              ? DiscoveryMethod.values[json['discoveryMethod']]
              : DiscoveryMethod.udp,
      wifiDirectAddress: json['wifiDirectAddress'] as String?,
      avatarUrl: json['avatarUrl'] as String?,
      userName: json['userName'] as String?,
    );
  }

  String get shareCode {
    final parts = ipAddress.split('.');
    if (parts.length != 4) return '';
    final n =
        (int.parse(parts[0]) << 24) |
        (int.parse(parts[1]) << 16) |
        (int.parse(parts[2]) << 8) |
        int.parse(parts[3]);
    String ipCode = n.toRadixString(36).toUpperCase().padLeft(8, '0');
    String portCode = port.toRadixString(36).toUpperCase().padLeft(3, '0');
    return ipCode + portCode;
  }

  bool get isOnline {
    if (discoveryMethod == DiscoveryMethod.wifiDirect) return true;
    return DateTime.now().difference(lastSeen).inSeconds < 30;
  }
}

// Helper class to store network interface info for broadcasting
class _NetworkInterfaceInfo {
  final NetworkInterface interface;
  final List<InternetAddress> ipv4Addresses;

  _NetworkInterfaceInfo(this.interface, this.ipv4Addresses);

  // Calculate broadcast address for a given IP and subnet mask
  // For /24 networks (most common): 192.168.43.1 -> 192.168.43.255
  String? getBroadcastAddress() {
    if (ipv4Addresses.isEmpty) return null;

    // Use first IPv4 address
    final ip = ipv4Addresses.first.address;
    final parts = ip.split('.');
    if (parts.length != 4) return null;

    // Assume /24 subnet (255.255.255.0) - most common for hotspots and home networks
    // Broadcast address is: network address + 255 in last octet
    return '${parts[0]}.${parts[1]}.${parts[2]}.255';
  }
}

class DeviceDiscoveryService {
  static const int DISCOVERY_PORT = 37020; // ZapShare discovery port
  static const String MULTICAST_GROUP =
      '224.0.0.167'; // Compatible with all Android devices (LocalSend uses this)
  static const int BROADCAST_INTERVAL_SECONDS =
      8; // Reduced frequency for better performance

  // Singleton instance
  static final DeviceDiscoveryService _instance =
      DeviceDiscoveryService._internal();

  factory DeviceDiscoveryService() {
    return _instance;
  }

  DeviceDiscoveryService._internal();

  List<RawDatagramSocket> _sockets =
      []; // Multiple sockets, one per network interface
  List<_NetworkInterfaceInfo> _networkInterfaces =
      []; // Store interface info for broadcasting
  Timer? _broadcastTimer;
  Timer? _cleanupTimer;
  Timer? _keepAliveTimer;
  bool _isRunning = false;
  bool _isRestarting = false; // Flag to prevent multiple restart attempts

  final Map<String, DiscoveredDevice> _discoveredDevices = {};
  final StreamController<List<DiscoveredDevice>> _devicesController =
      StreamController<List<DiscoveredDevice>>.broadcast();

  // Connection request streams
  final StreamController<ConnectionRequest> _connectionRequestController =
      StreamController<ConnectionRequest>.broadcast();
  final StreamController<ConnectionResponse> _connectionResponseController =
      StreamController<ConnectionResponse>.broadcast();

  // Cast request stream
  final StreamController<CastRequest> _castRequestController =
      StreamController<CastRequest>.broadcast();

  // Cast control stream (remote commands received by player)
  final StreamController<CastControl> _castControlController =
      StreamController<CastControl>.broadcast();

  // Cast status stream (status updates received by controller)
  final StreamController<CastStatus> _castStatusController =
      StreamController<CastStatus>.broadcast();

  // Cast acknowledgement stream (receiver accepted/declined)
  final StreamController<CastAck> _castAckController =
      StreamController<CastAck>.broadcast();

  // Screen mirror request stream
  final StreamController<ScreenMirrorRequest> _screenMirrorRequestController =
      StreamController<ScreenMirrorRequest>.broadcast();

  // Screen mirror control stream (remote input commands from viewer)
  final StreamController<ScreenMirrorControl> _screenMirrorControlController =
      StreamController<ScreenMirrorControl>.broadcast();

  String? _myDeviceId;
  String? _myDeviceName;

  String? get myDeviceId => _myDeviceId;
  String? get myDeviceName => _myDeviceName;

  Stream<List<DiscoveredDevice>> get devicesStream => _devicesController.stream;
  Stream<ConnectionRequest> get connectionRequestStream =>
      _connectionRequestController.stream;
  Stream<ConnectionResponse> get connectionResponseStream =>
      _connectionResponseController.stream;
  Stream<CastRequest> get castRequestStream => _castRequestController.stream;
  Stream<CastControl> get castControlStream => _castControlController.stream;
  Stream<CastStatus> get castStatusStream => _castStatusController.stream;
  Stream<CastAck> get castAckStream => _castAckController.stream;
  Stream<ScreenMirrorRequest> get screenMirrorRequestStream =>
      _screenMirrorRequestController.stream;
  Stream<ScreenMirrorControl> get screenMirrorControlStream =>
      _screenMirrorControlController.stream;
  List<DiscoveredDevice> get discoveredDevices =>
      _discoveredDevices.values.toList();

  // Connection request deduplication
  // Map<deviceId, timestamp> to track recent connection requests
  final Map<String, DateTime> _recentConnectionRequests = {};
  static const Duration _requestDeduplicationWindow = Duration(seconds: 10);

  Future<void> initialize() async {
    await _loadDeviceInfo();
    await _loadFavoriteDevices();

    // WiFi Direct removed - using Bluetooth + Hotspot instead
  }

  Future<void> _loadDeviceInfo() async {
    final prefs = await SharedPreferences.getInstance();

    // Get current IP address
    String? currentIp = await _getCurrentIpAddress();

    _myDeviceId = prefs.getString('device_id');
    _myDeviceName = prefs.getString('device_name');

    // Generate device ID if not exists or if IP changed (for better uniqueness per network)
    if (_myDeviceId == null || currentIp != null) {
      // Use IP-based ID if available, otherwise use timestamp
      if (currentIp != null) {
        final timestamp = DateTime.now().millisecondsSinceEpoch;
        final ipHash = currentIp.replaceAll('.', '');
        _myDeviceId = '${ipHash}_$timestamp';
        print('🆔 Generated IP-based device ID: $_myDeviceId (IP: $currentIp)');
      } else {
        // Fallback to timestamp + random if IP not available
        final timestamp = DateTime.now().millisecondsSinceEpoch;
        final random = (timestamp % 100000);
        _myDeviceId = '${timestamp}_$random';
        print('🆔 Generated timestamp-based device ID: $_myDeviceId');
      }
      await prefs.setString('device_id', _myDeviceId!);
    } else {
      print('🆔 Loaded existing device ID: $_myDeviceId');
    }

    // Set default device name if not exists
    if (_myDeviceName == null) {
      if (Platform.isAndroid) {
        _myDeviceName = 'Android Device';
      } else if (Platform.isWindows) {
        _myDeviceName = 'Windows PC';
      } else if (Platform.isIOS) {
        _myDeviceName = 'iOS Device';
      } else if (Platform.isMacOS) {
        _myDeviceName = 'Mac';
      } else {
        _myDeviceName = 'ZapShare Device';
      }
      await prefs.setString('device_name', _myDeviceName!);
      print('📛 Generated new device name: $_myDeviceName');
    } else {
      print('📛 Loaded existing device name: $_myDeviceName');
    }
  }

  Future<String?> _getCurrentIpAddress() async {
    try {
      final interfaces = await NetworkInterface.list();
      for (var interface in interfaces) {
        for (var addr in interface.addresses) {
          // Get IPv4 address that's not loopback
          if (addr.type == InternetAddressType.IPv4 && !addr.isLoopback) {
            return addr.address;
          }
        }
      }
    } catch (e) {
      print('Error getting IP address: $e');
    }
    return null;
  }

  Future<void> setDeviceName(String name) async {
    _myDeviceName = name;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('device_name', name);

    // Restart broadcasting with new name
    if (_isRunning) {
      await stop();
      await start();
    }
  }

  // Force regenerate device ID (useful if duplicate detected)
  Future<void> regenerateDeviceId() async {
    final prefs = await SharedPreferences.getInstance();

    // Try to get IP-based ID
    String? currentIp = await _getCurrentIpAddress();

    if (currentIp != null) {
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final ipHash = currentIp.replaceAll('.', '');
      _myDeviceId = '${ipHash}_$timestamp';
      print(
        '🆔 Force regenerated IP-based device ID: $_myDeviceId (IP: $currentIp)',
      );
    } else {
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final random = (timestamp % 100000);
      _myDeviceId = '${timestamp}_$random';
      print('🆔 Force regenerated timestamp-based device ID: $_myDeviceId');
    }

    await prefs.setString('device_id', _myDeviceId!);

    // Restart if running
    if (_isRunning) {
      await stop();
      await start();
    }
  }

  Future<void> _loadFavoriteDevices() async {
    final prefs = await SharedPreferences.getInstance();
    final favoritesJson = prefs.getStringList('favorite_devices') ?? [];
    for (final jsonStr in favoritesJson) {
      try {
        final device = DiscoveredDevice.fromJson(jsonDecode(jsonStr));
        device.isFavorite = true;
        _discoveredDevices[device.deviceId] = device;
      } catch (e) {
        print('Error loading favorite device: $e');
      }
    }
  }

  Future<void> toggleFavorite(String deviceId) async {
    final device = _discoveredDevices[deviceId];
    if (device != null) {
      device.isFavorite = !device.isFavorite;
      await _saveFavoriteDevices();
      _notifyListeners();
    }
  }

  Future<void> _saveFavoriteDevices() async {
    final prefs = await SharedPreferences.getInstance();
    final favorites =
        _discoveredDevices.values
            .where((d) => d.isFavorite)
            .map((d) => jsonEncode(d.toJson()))
            .toList();
    await prefs.setStringList('favorite_devices', favorites);
  }

  Future<void> start() async {
    if (_isRunning) {
      print('⚠️  Device discovery already running');
      return;
    }

    try {
      // WiFi Direct removed - using Bluetooth + Hotspot instead

      // On Android, ensure multicast lock is acquired
      if (Platform.isAndroid) {
        await _ensureMulticastLock();
      }

      // Get all network interfaces
      final interfaces = await NetworkInterface.list();
      print('📡 Found ${interfaces.length} network interfaces');

      // Clear previous interface info
      _networkInterfaces.clear();
      _sockets.clear();

      // LocalSend approach: Create ONE socket per interface, each bound to anyIPv4 with the discovery port
      // Then join multicast group ON THAT SPECIFIC INTERFACE
      // This ensures packets from that interface are received

      for (final interface in interfaces) {
        try {
          // Filter IPv4 addresses (skip loopback)
          final ipv4Addresses =
              interface.addresses
                  .where(
                    (addr) =>
                        addr.type == InternetAddressType.IPv4 &&
                        !addr.isLoopback,
                  )
                  .toList();

          if (ipv4Addresses.isEmpty) {
            print('⏭️  Skipping ${interface.name} (no valid IPv4)');
            continue;
          }

          // Store interface info for broadcasting
          final interfaceInfo = _NetworkInterfaceInfo(interface, ipv4Addresses);
          _networkInterfaces.add(interfaceInfo);

          // CRITICAL: Bind to anyIPv4 with the DISCOVERY_PORT (like LocalSend)
          // This allows receiving on this port from all addresses
          // Note: Windows doesn't support reusePort, so we skip it on Windows
          final socket = await RawDatagramSocket.bind(
            InternetAddress.anyIPv4,
            DISCOVERY_PORT,
            reusePort: !Platform.isWindows, // Windows doesn't support reusePort
          );

          // Join multicast group ON THIS SPECIFIC INTERFACE
          // This is the key - tell the OS to route multicast from THIS interface to THIS socket
          socket.joinMulticast(InternetAddress(MULTICAST_GROUP), interface);
          socket.broadcastEnabled = true;

          print(
            '✅ Bound socket for ${interface.name} (${ipv4Addresses.map((a) => a.address).join(", ")})',
          );
          print('   Joined multicast $MULTICAST_GROUP on ${interface.name}');

          // Listen for incoming messages
          socket.listen(
            (RawSocketEvent event) {
              if (event == RawSocketEvent.read) {
                final datagram = socket.receive();
                if (datagram != null) {
                  _handleDiscoveryMessage(datagram);
                }
              }
            },
            onError: (error) {
              print('❌ Socket error on ${interface.name}: $error');
              _handleSocketError(error);
            },
            onDone: () {
              print('⚠️  Socket on ${interface.name} closed');
              _handleSocketClosed();
            },
            cancelOnError: false,
          );

          _sockets.add(socket);
        } catch (e) {
          print('⚠️  Could not setup socket for ${interface.name}: $e');
          // Continue with other interfaces
        }
      }

      if (_sockets.isEmpty) {
        throw Exception('Failed to bind to any network interface');
      }

      print('✅ Successfully created ${_sockets.length} receiver socket(s)');
      print('   Tracking ${_networkInterfaces.length} network interface(s)');

      _isRunning = true;

      // Start broadcasting presence
      _startBroadcasting();

      // Start cleanup timer (remove stale devices)
      _startCleanupTimer();

      // Start keep-alive timer to ensure service stays running
      _startKeepAliveTimer();

      print('✅ Device discovery started successfully');
    } catch (e) {
      print('❌ Error starting device discovery: $e');
      _isRunning = false;
      rethrow;
    }
  }

  // WiFi Direct methods removed - using Bluetooth + Hotspot instead

  bool _isPaused = false;

  void pauseDiscovery() {
    if (_isPaused) return;
    _isPaused = true;
    _broadcastTimer?.cancel();
    print(
      '⏸️ Discovery broadcasts PAUSED (saving resources for video playback)',
    );
  }

  void resumeDiscovery() {
    if (!_isPaused) return;
    _isPaused = false;
    print('▶️ Discovery broadcasts RESUMED');
    if (_isRunning) {
      _startBroadcasting();
    }
  }

  void _startBroadcasting() {
    if (_isPaused) return;
    _broadcastTimer?.cancel();
    _broadcastTimer = Timer.periodic(
      Duration(seconds: BROADCAST_INTERVAL_SECONDS),
      (_) => _broadcastPresence(),
    );
    // Send first broadcast immediately
    _broadcastPresence();
  }

  void _broadcastPresence() async {
    if (!_isRunning || _networkInterfaces.isEmpty) {
      print('⚠️  Broadcast skipped - not running or no interfaces');
      return;
    }

    try {
      String? avatarUrl;
      String? userName;
      final prefs = await SharedPreferences.getInstance();

      // 1. Start with custom avatar from local preferences
      avatarUrl = prefs.getString('custom_avatar');
      print('🔍 Custom avatar from prefs: $avatarUrl');

      // 2. Google Profile logic removed as per user request to use local only.
      // We rely on 'custom_avatar' loaded above and 'device_name' loaded in _myDeviceName.

      print(
        '🔍 Final avatar before broadcast: $avatarUrl, userName: $userName',
      );

      final message = jsonEncode({
        'type': 'ZAPSHARE_DISCOVERY',
        'deviceId': _myDeviceId,
        'deviceName': _myDeviceName,
        'platform': _getPlatformName(),
        'port': 8080, // File sharing port
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'avatarUrl': avatarUrl,
        'userName': userName,
      });

      // Debug: Log what we're broadcasting
      print(
        '📡 Broadcasting discovery with avatar: $avatarUrl, userName: $userName',
      );

      final data = utf8.encode(message);

      // CRITICAL FIX: Create TEMPORARY sockets for sending (like LocalSend does!)
      // Do NOT use the listening sockets for sending - this causes conflicts
      int totalBytesSent = 0;

      for (final interfaceInfo in _networkInterfaces) {
        try {
          // Create a temporary socket for THIS interface (bound to port 0 = dynamic port)
          // Note: Windows doesn't support reusePort
          final tempSocket = await RawDatagramSocket.bind(
            InternetAddress.anyIPv4,
            0, // Port 0 = let OS choose a free port
            reusePort: false, // Ephemeral sending port doesn't need reusePort
          );

          // Join multicast on this interface (required for sending)
          tempSocket.joinMulticast(
            InternetAddress(MULTICAST_GROUP),
            interfaceInfo.interface,
          );
          tempSocket.broadcastEnabled = true;

          // 1. Send to multicast group
          final bytesSent1 = tempSocket.send(
            data,
            InternetAddress(MULTICAST_GROUP),
            DISCOVERY_PORT,
          );

          // 2. Send to general broadcast
          final bytesSent2 = tempSocket.send(
            data,
            InternetAddress('255.255.255.255'),
            DISCOVERY_PORT,
          );

          // 3. Send to subnet-specific broadcast (for hotspot)
          int bytesSent3 = 0;
          final subnetBroadcast = interfaceInfo.getBroadcastAddress();
          if (subnetBroadcast != null && subnetBroadcast != '255.5.255.255') {
            bytesSent3 = tempSocket.send(
              data,
              InternetAddress(subnetBroadcast),
              DISCOVERY_PORT,
            );
          }

          totalBytesSent += bytesSent1 + bytesSent2 + bytesSent3;

          // Close the temporary socket immediately after sending
          tempSocket.close();
        } catch (e) {
          print('❌ Error broadcasting on ${interfaceInfo.interface.name}: $e');
        }
      }

      print(
        '📡 Broadcasting presence: $totalBytesSent bytes total across ${_networkInterfaces.length} interfaces',
      );
    } catch (e) {
      print('❌ Error broadcasting presence: $e');
      // If broadcasting fails, try to restart the service
      _handleBroadcastError(e);
    }
  }

  void _handleBroadcastError(dynamic error) {
    print('⚠️  Broadcast error detected, attempting to recover...');
    if (_isRestarting) {
      print('⏭️  Restart already in progress, skipping...');
      return;
    }

    _isRestarting = true;
    // Schedule a restart of the discovery service
    Future.delayed(Duration(seconds: 2), () async {
      if (_isRunning) {
        print('🔄 Restarting discovery service...');
        try {
          await stop();
          await start();
          print('✅ Discovery service restarted successfully');
        } catch (e) {
          print('❌ Failed to restart discovery service: $e');
        } finally {
          _isRestarting = false;
        }
      } else {
        _isRestarting = false;
      }
    });
  }

  // Send connection request to a specific device
  Future<void> sendConnectionRequest(
    String targetIp,
    List<String> fileNames,
    int totalSize,
    int port,
  ) async {
    if (_sockets.isEmpty) {
      print('ERROR: Cannot send connection request - no sockets available');
      return;
    }

    if (_myDeviceId == null || _myDeviceName == null) {
      print(
        'ERROR: Cannot send connection request - device info not initialized',
      );
      return;
    }

    try {
      final message = jsonEncode({
        'type': 'ZAPSHARE_CONNECTION_REQUEST',
        'deviceId': _myDeviceId,
        'deviceName': _myDeviceName,
        'platform': _getPlatformName(),
        'port': port,
        'fileCount': fileNames.length,
        'fileNames': fileNames,
        'totalSize': totalSize,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      });

      final data = utf8.encode(message);

      // Try to send on all sockets (at least one should work)
      int totalBytesSent = 0;
      for (final socket in _sockets) {
        try {
          final bytesSent = socket.send(
            data,
            InternetAddress(targetIp),
            DISCOVERY_PORT,
          );
          totalBytesSent += bytesSent;
        } catch (e) {
          // Ignore errors on individual sockets
        }
      }

      print('✅ Sent connection request to $targetIp ($totalBytesSent bytes)');
      print('   Device: $_myDeviceName ($_myDeviceId)');
      print(
        '   Files: ${fileNames.length} files, ${(totalSize / 1024 / 1024).toStringAsFixed(2)} MB',
      );
    } catch (e) {
      print('❌ Error sending connection request: $e');
    }
  }

  // Send connection response (accept/deny)
  Future<void> sendConnectionResponse(String targetIp, bool accepted) async {
    if (_sockets.isEmpty) return;

    try {
      final message = jsonEncode({
        'type': 'ZAPSHARE_CONNECTION_RESPONSE',
        'deviceId': _myDeviceId,
        'deviceName': _myDeviceName,
        'accepted': accepted,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      });

      final data = utf8.encode(message);

      // Send on all sockets
      for (final socket in _sockets) {
        try {
          socket.send(data, InternetAddress(targetIp), DISCOVERY_PORT);
        } catch (e) {
          // Ignore errors on individual sockets
        }
      }

      print('Sent connection response to $targetIp: $accepted');
    } catch (e) {
      print('Error sending connection response: $e');
    }
  }

  void _handleDiscoveryMessage(Datagram datagram) {
    try {
      final message = utf8.decode(datagram.data);
      final data = jsonDecode(message);

      final senderDeviceId = data['deviceId'] as String?;
      final messageType = data['type'] as String?;

      // Ignore our own broadcasts
      if (senderDeviceId == _myDeviceId) {
        return;
      }

      // Handle different message types
      switch (messageType) {
        case 'ZAPSHARE_DISCOVERY':
          _handleDiscoveryBroadcast(data, datagram.address.address);
          break;
        case 'ZAPSHARE_CONNECTION_REQUEST':
          print('   🎯 Handling connection request...');
          _handleConnectionRequest(data, datagram.address.address);
          break;
        case 'ZAPSHARE_CONNECTION_RESPONSE':
          _handleConnectionResponse(data, datagram.address.address);
          break;
        case 'ZAPSHARE_CAST_URL':
          _handleCastUrl(data, datagram.address.address);
          break;
        case 'ZAPSHARE_CAST_CONTROL':
          _handleCastControl(data, datagram.address.address);
          break;
        case 'ZAPSHARE_CAST_STATUS':
          _handleCastStatus(data, datagram.address.address);
          break;
        case 'ZAPSHARE_CAST_ACK':
          _handleCastAck(data, datagram.address.address);
          break;
        case 'ZAPSHARE_SCREEN_MIRROR':
          _handleScreenMirror(data, datagram.address.address);
          break;
        case 'ZAPSHARE_SCREEN_MIRROR_CONTROL':
          _handleScreenMirrorControl(data, datagram.address.address);
          break;
        default:
        // Unknown message type
      }
    } catch (e) {
      // print('❌ Error handling discovery message: $e');
    }
  }

  void _handleDiscoveryBroadcast(Map<String, dynamic> data, String ipAddress) {
    final deviceId = data['deviceId'] as String;
    final deviceName = data['deviceName'] as String;
    final platform = data['platform'] as String;
    final port = data['port'] as int;
    final avatarUrl = data['avatarUrl'] as String?;
    final userName = data['userName'] as String?;

    // Ignore own device
    if (deviceId == _myDeviceId) {
      return;
    }

    // Check for duplicates by IP address (prevent same device with different IDs)
    DiscoveredDevice? duplicateByIp;
    String? duplicateKey;
    for (var entry in _discoveredDevices.entries) {
      if (entry.value.ipAddress == ipAddress && entry.key != deviceId) {
        duplicateByIp = entry.value;
        duplicateKey = entry.key;
        break;
      }
    }

    // If found duplicate by IP, remove the old entry
    if (duplicateByIp != null && duplicateKey != null) {
      print(
        '🔄 Removing duplicate device: $duplicateKey (same IP: $ipAddress)',
      );
      _discoveredDevices.remove(duplicateKey);
    }

    // Check if device is already in favorites
    final existingDevice = _discoveredDevices[deviceId];
    final isFavorite =
        existingDevice?.isFavorite ?? duplicateByIp?.isFavorite ?? false;

    // Update or add device
    _discoveredDevices[deviceId] = DiscoveredDevice(
      deviceId: deviceId,
      deviceName: deviceName,
      ipAddress: ipAddress,
      port: port,
      platform: platform,
      lastSeen: DateTime.now(),
      isFavorite: isFavorite,
      avatarUrl: avatarUrl,
      userName: userName,
    );

    _notifyListeners();
  }

  void _handleConnectionRequest(Map<String, dynamic> data, String ipAddress) {
    final deviceId = data['deviceId'] as String;
    final deviceName = data['deviceName'] as String;

    print('📩 Received connection request from $ipAddress');
    print('   Device: $deviceName ($deviceId)');
    print(
      '   Files: ${data['fileCount']} files, ${(data['totalSize'] / 1024 / 1024).toStringAsFixed(2)} MB',
    );

    // DEDUPLICATION: Check if we've already received a request from this device recently
    final now = DateTime.now();
    final lastRequestTime = _recentConnectionRequests[deviceId];

    if (lastRequestTime != null) {
      final timeSinceLastRequest = now.difference(lastRequestTime);
      if (timeSinceLastRequest < _requestDeduplicationWindow) {
        print(
          '   ⏭️  IGNORING duplicate request (received ${timeSinceLastRequest.inSeconds}s ago)',
        );
        print('   This prevents multiple connection dialogs from appearing');
        return; // Ignore duplicate request
      }
    }

    // Record this request
    _recentConnectionRequests[deviceId] = now;
    print(
      '   ✅ First request from this device (or outside deduplication window)',
    );

    // Clean up old entries from deduplication map (keep it from growing indefinitely)
    _recentConnectionRequests.removeWhere((key, timestamp) {
      return now.difference(timestamp) > _requestDeduplicationWindow;
    });

    final request = ConnectionRequest(
      deviceId: deviceId,
      deviceName: deviceName,
      platform: data['platform'] as String,
      ipAddress: ipAddress,
      port: (data['port'] as int?) ?? 8080,
      fileCount: data['fileCount'] as int,
      fileNames: List<String>.from(data['fileNames'] as List),
      totalSize: data['totalSize'] as int,
      timestamp: DateTime.fromMillisecondsSinceEpoch(data['timestamp'] as int),
    );

    // Check if controller is closed before adding
    if (!_connectionRequestController.isClosed) {
      _connectionRequestController.add(request);
      print('✅ Connection request added to stream (will show dialog)');
    } else {
      print('⚠️  Connection request controller is closed, skipping');
    }
  }

  void _handleConnectionResponse(Map<String, dynamic> data, String ipAddress) {
    print('📨 Received connection response from $ipAddress');
    print('   Device: ${data['deviceName']} (${data['deviceId']})');
    print('   Accepted: ${data['accepted']}');

    final response = ConnectionResponse(
      deviceId: data['deviceId'] as String,
      deviceName: data['deviceName'] as String,
      ipAddress: ipAddress,
      accepted: data['accepted'] as bool,
      timestamp: DateTime.fromMillisecondsSinceEpoch(data['timestamp'] as int),
    );

    // Check if controller is closed before adding
    if (!_connectionResponseController.isClosed) {
      _connectionResponseController.add(response);
      print('✅ Connection response added to stream');
    } else {
      print('⚠️  Connection response controller is closed, skipping');
    }
  }

  // Send Cast URL to a device
  Future<void> sendCastUrl(
    String targetIp,
    String url, {
    String? fileName,
    String? subtitleUrl,
  }) async {
    if (_sockets.isEmpty) return;

    try {
      final message = jsonEncode({
        'type': 'ZAPSHARE_CAST_URL',
        'deviceId': _myDeviceId,
        'deviceName': _myDeviceName,
        'url': url,
        'fileName': fileName,
        'subtitleUrl': subtitleUrl,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      });

      final data = utf8.encode(message);

      for (final socket in _sockets) {
        try {
          socket.send(data, InternetAddress(targetIp), DISCOVERY_PORT);
        } catch (e) {
          // Ignore errors
        }
      }
      print('✅ Sent cast URL to $targetIp: $url (sub: $subtitleUrl)');
    } catch (e) {
      print('❌ Error sending cast URL: $e');
    }
  }

  // Deduplicate Cast URLs
  String? _lastCastMessageId;

  Future<void> _handleCastUrl(
    Map<String, dynamic> data,
    String senderIp,
  ) async {
    final url = data['url'] as String?;
    final timestamp = data['timestamp'] as int?;
    final deviceId = data['deviceId'] as String?;
    final fileName = data['fileName'] as String?;
    final subtitleUrl = data['subtitleUrl'] as String?;
    final senderName = data['deviceName'] as String?;

    if (url != null && url.isNotEmpty) {
      // Deduplication
      final messageId = '${deviceId}_$timestamp';
      if (_lastCastMessageId == messageId) {
        print('⏭️ Skipping duplicate Cast URL message');
        return;
      }
      _lastCastMessageId = messageId;

      print(
        '🎬 Received Cast URL: $url (file: $fileName, sub: $subtitleUrl, from: $senderName)',
      );

      // Try to find device name from discovered devices, fall back to sender name
      String deviceName = senderName ?? 'Unknown Device';
      if (deviceId != null && _discoveredDevices.containsKey(deviceId)) {
        deviceName = _discoveredDevices[deviceId]!.deviceName;
      }

      // Emit event for UI to handle (show dialog) on all platforms
      if (!_castRequestController.isClosed) {
        _castRequestController.add(
          CastRequest(
            deviceId: deviceId ?? 'unknown',
            deviceName: deviceName,
            url: url,
            fileName: fileName,
            subtitleUrl: subtitleUrl,
            senderIp: senderIp,
            timestamp: DateTime.now(),
          ),
        );
        print(
          '✅ Cast request added to stream (platform: ${Platform.operatingSystem})',
        );
      } else {
        print('⚠️  Cast request controller is closed, skipping');
      }
    }
  }

  // ─── Cast remote control ───────────────────────────────────

  void _handleCastControl(Map<String, dynamic> data, String senderIp) {
    final action = data['action'] as String?;
    if (action == null) return;

    final control = CastControl(
      action: action,
      seekPosition: (data['seekPosition'] as num?)?.toDouble(),
      volume: (data['volume'] as num?)?.toDouble(),
      senderIp: senderIp,
    );

    if (!_castControlController.isClosed) {
      _castControlController.add(control);
    }
  }

  void _handleCastStatus(Map<String, dynamic> data, String senderIp) {
    final status = CastStatus(
      position: (data['position'] as num?)?.toDouble() ?? 0,
      duration: (data['duration'] as num?)?.toDouble() ?? 0,
      buffered: (data['buffered'] as num?)?.toDouble() ?? 0,
      isPlaying: data['isPlaying'] as bool? ?? false,
      isBuffering: data['isBuffering'] as bool? ?? false,
      volume: (data['volume'] as num?)?.toDouble() ?? 1.0,
      fileName: data['fileName'] as String?,
      senderIp: senderIp,
    );

    if (!_castStatusController.isClosed) {
      _castStatusController.add(status);
    }
  }

  /// Send a remote control command to the player device
  Future<void> sendCastControl(
    String targetIp,
    String action, {
    double? seekPosition,
    double? volume,
  }) async {
    if (_sockets.isEmpty) return;
    try {
      final message = jsonEncode({
        'type': 'ZAPSHARE_CAST_CONTROL',
        'deviceId': _myDeviceId,
        'action': action,
        if (seekPosition != null) 'seekPosition': seekPosition,
        if (volume != null) 'volume': volume,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      });
      final data = utf8.encode(message);
      for (final socket in _sockets) {
        try {
          socket.send(data, InternetAddress(targetIp), DISCOVERY_PORT);
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// Send playback status back to the controller device
  Future<void> sendCastStatus(
    String targetIp, {
    required double position,
    required double duration,
    required double buffered,
    required bool isPlaying,
    required bool isBuffering,
    required double volume,
    String? fileName,
  }) async {
    if (_sockets.isEmpty) return;
    try {
      final message = jsonEncode({
        'type': 'ZAPSHARE_CAST_STATUS',
        'deviceId': _myDeviceId,
        'position': position,
        'duration': duration,
        'buffered': buffered,
        'isPlaying': isPlaying,
        'isBuffering': isBuffering,
        'volume': volume,
        'fileName': fileName,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      });
      final data = utf8.encode(message);
      for (final socket in _sockets) {
        try {
          socket.send(data, InternetAddress(targetIp), DISCOVERY_PORT);
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// Handle cast acknowledgement from receiver
  void _handleCastAck(Map<String, dynamic> data, String senderIp) {
    final accepted = data['accepted'] as bool? ?? false;
    final deviceName = data['deviceName'] as String? ?? 'Unknown';
    print('🎬 Cast ACK received from $senderIp: accepted=$accepted');

    if (!_castAckController.isClosed) {
      _castAckController.add(
        CastAck(accepted: accepted, senderIp: senderIp, deviceName: deviceName),
      );
    }
  }

  /// Send cast acknowledgement back to sender (called by receiver after accepting/declining)
  Future<void> sendCastAck(String targetIp, bool accepted) async {
    if (_sockets.isEmpty) return;
    try {
      final message = jsonEncode({
        'type': 'ZAPSHARE_CAST_ACK',
        'deviceId': _myDeviceId,
        'deviceName': _myDeviceName,
        'accepted': accepted,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      });
      final data = utf8.encode(message);
      for (final socket in _sockets) {
        try {
          socket.send(data, InternetAddress(targetIp), DISCOVERY_PORT);
        } catch (_) {}
      }
      print('✅ Sent cast ACK to $targetIp: accepted=$accepted');
    } catch (_) {}
  }

  // ─── Screen Mirror Protocol ────────────────────────────────

  /// Send screen mirror request to a target device (e.g., Windows)
  Future<void> sendScreenMirrorRequest(
    String targetIp,
    String streamUrl,
  ) async {
    print('\n📡 [Discovery] sendScreenMirrorRequest called');
    print('📡 [Discovery]   targetIp: $targetIp');
    print('📡 [Discovery]   streamUrl: $streamUrl');
    print('📡 [Discovery]   _sockets count: ${_sockets.length}');
    print('📡 [Discovery]   _myDeviceId: $_myDeviceId');
    print('📡 [Discovery]   _myDeviceName: $_myDeviceName');
    print('📡 [Discovery]   DISCOVERY_PORT: $DISCOVERY_PORT');
    if (_sockets.isEmpty) {
      print(
        '❌ [Discovery] sendScreenMirrorRequest ABORTED - no sockets available!',
      );
      return;
    }
    try {
      final payload = {
        'type': 'ZAPSHARE_SCREEN_MIRROR',
        'deviceId': _myDeviceId,
        'deviceName': _myDeviceName,
        'streamUrl': streamUrl,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      };
      final message = jsonEncode(payload);
      print(
        '📡 [Discovery] Encoded message (${message.length} bytes): $message',
      );
      final data = utf8.encode(message);
      // Send 3 times with short delays for UDP reliability
      int totalSent = 0;
      int totalFailed = 0;
      for (int attempt = 0; attempt < 3; attempt++) {
        for (int i = 0; i < _sockets.length; i++) {
          try {
            _sockets[i].send(data, InternetAddress(targetIp), DISCOVERY_PORT);
            totalSent++;
            print(
              '📡 [Discovery]   Attempt $attempt, socket $i -> sent to $targetIp:$DISCOVERY_PORT ✅',
            );
          } catch (e) {
            totalFailed++;
            print('📡 [Discovery]   Attempt $attempt, socket $i -> FAILED: $e');
          }
        }
        if (attempt < 2) {
          await Future.delayed(const Duration(milliseconds: 100));
        }
      }
      print(
        '📡 [Discovery] sendScreenMirrorRequest DONE: $totalSent sent, $totalFailed failed',
      );
    } catch (e) {
      print('❌ [Discovery] sendScreenMirrorRequest EXCEPTION: $e');
    }
  }

  /// Deduplication for screen mirror messages (supports multiple senders)
  final Set<String> _recentScreenMirrorIds = {};

  void _handleScreenMirror(Map<String, dynamic> data, String senderIp) {
    print('\n📺 [Discovery] _handleScreenMirror called from $senderIp');
    print('📺 [Discovery]   Full data: $data');
    final streamUrl = data['streamUrl'] as String?;
    final timestamp = data['timestamp'] as int?;
    final deviceId = data['deviceId'] as String?;
    final senderName = data['deviceName'] as String?;
    print('📺 [Discovery]   streamUrl: $streamUrl');
    print('📺 [Discovery]   timestamp: $timestamp');
    print('📺 [Discovery]   deviceId: $deviceId');
    print('📺 [Discovery]   senderName: $senderName');

    if (streamUrl != null && streamUrl.isNotEmpty) {
      // Deduplication using a set (handles multiple senders correctly)
      final messageId = '${deviceId}_$timestamp';
      print('📺 [Discovery]   messageId for dedup: $messageId');
      print('📺 [Discovery]   existing dedup IDs: $_recentScreenMirrorIds');
      if (_recentScreenMirrorIds.contains(messageId)) {
        print(
          '⏭️ [Discovery] Skipping DUPLICATE screen mirror message (messageId=$messageId)',
        );
        return;
      }
      _recentScreenMirrorIds.add(messageId);
      // Clean old IDs to prevent unbounded growth (keep last 20)
      if (_recentScreenMirrorIds.length > 20) {
        _recentScreenMirrorIds.remove(_recentScreenMirrorIds.first);
      }

      print(
        '📺 [Discovery] ✅ NEW screen mirror request: $streamUrl from $senderName ($senderIp)',
      );

      String deviceName = senderName ?? 'Unknown Device';
      if (deviceId != null && _discoveredDevices.containsKey(deviceId)) {
        deviceName = _discoveredDevices[deviceId]!.deviceName;
        print(
          '📺 [Discovery]   Resolved device name from discovered devices: $deviceName',
        );
      }

      print(
        '📺 [Discovery]   _screenMirrorRequestController.isClosed: ${_screenMirrorRequestController.isClosed}',
      );
      if (!_screenMirrorRequestController.isClosed) {
        final request = ScreenMirrorRequest(
          deviceId: deviceId ?? 'unknown',
          deviceName: deviceName,
          streamUrl: streamUrl,
          senderIp: senderIp,
          timestamp: DateTime.now(),
        );
        print(
          '📺 [Discovery]   Adding ScreenMirrorRequest to stream: deviceName=$deviceName, streamUrl=$streamUrl',
        );
        _screenMirrorRequestController.add(request);
        print(
          '📺 [Discovery] ✅ Screen mirror request ADDED to stream successfully',
        );
      } else {
        print(
          '❌ [Discovery] _screenMirrorRequestController is CLOSED! Cannot add request.',
        );
      }
    } else {
      print(
        '❌ [Discovery] _handleScreenMirror: streamUrl is null or empty! Ignoring.',
      );
    }
  }

  void _handleScreenMirrorControl(Map<String, dynamic> data, String senderIp) {
    final action = data['action'] as String?;
    if (action == null) return;

    final control = ScreenMirrorControl(
      action: action,
      tapX: (data['tapX'] as num?)?.toDouble(),
      tapY: (data['tapY'] as num?)?.toDouble(),
      endX: (data['endX'] as num?)?.toDouble(),
      endY: (data['endY'] as num?)?.toDouble(),
      text: data['text'] as String?,
      scrollDelta: (data['scrollDelta'] as num?)?.toDouble(),
      duration: (data['duration'] as num?)?.toInt(),
      senderIp: senderIp,
    );

    if (!_screenMirrorControlController.isClosed) {
      _screenMirrorControlController.add(control);
    }
  }

  /// Send a remote control command to the mirroring Android device
  Future<void> sendScreenMirrorControl(
    String targetIp,
    String action, {
    double? tapX,
    double? tapY,
    double? endX,
    double? endY,
    String? text,
    double? scrollDelta,
    int? duration,
  }) async {
    if (_sockets.isEmpty) return;
    try {
      final message = jsonEncode({
        'type': 'ZAPSHARE_SCREEN_MIRROR_CONTROL',
        'deviceId': _myDeviceId,
        'action': action,
        if (tapX != null) 'tapX': tapX,
        if (tapY != null) 'tapY': tapY,
        if (endX != null) 'endX': endX,
        if (endY != null) 'endY': endY,
        if (text != null) 'text': text,
        if (scrollDelta != null) 'scrollDelta': scrollDelta,
        if (duration != null) 'duration': duration,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      });
      final data = utf8.encode(message);
      for (final socket in _sockets) {
        try {
          socket.send(data, InternetAddress(targetIp), DISCOVERY_PORT);
        } catch (_) {}
      }
    } catch (_) {}
  }

  void _startCleanupTimer() {
    _cleanupTimer?.cancel();
    _cleanupTimer = Timer.periodic(Duration(seconds: 10), (_) {
      _cleanupStaleDevices();
    });
  }

  void _startKeepAliveTimer() {
    _keepAliveTimer?.cancel();
    // Check every 15 seconds if the service is still running properly
    _keepAliveTimer = Timer.periodic(Duration(seconds: 15), (_) {
      _checkServiceHealth();
    });
  }

  void _checkServiceHealth() {
    if (!_isRunning) {
      print('⚠️  Service should be running but _isRunning is false');
      return;
    }

    if (_sockets.isEmpty) {
      print('⚠️  Service health check failed: no sockets available');
      _handleSocketError('No sockets available during health check');
      return;
    }

    if (_broadcastTimer == null || !_broadcastTimer!.isActive) {
      print('⚠️  Service health check failed: broadcast timer not active');
      _startBroadcasting();
    }

    if (_cleanupTimer == null || !_cleanupTimer!.isActive) {
      print('⚠️  Service health check failed: cleanup timer not active');
      _startCleanupTimer();
    }

    print('✅ Service health check passed');
  }

  void _cleanupStaleDevices() {
    final now = DateTime.now();
    final staleDevices = <String>[];

    _discoveredDevices.forEach((id, device) {
      // Remove devices not seen in 30 seconds (unless they're favorites or Wi-Fi Direct)
      if (!device.isFavorite &&
          device.discoveryMethod != DiscoveryMethod.wifiDirect &&
          now.difference(device.lastSeen).inSeconds > 30) {
        staleDevices.add(id);
      }
    });

    if (staleDevices.isNotEmpty) {
      staleDevices.forEach(_discoveredDevices.remove);
      _notifyListeners();
      print('🧹 Cleaned up ${staleDevices.length} stale devices');
    }
  }

  void _handleSocketError(dynamic error) {
    print('⚠️  Socket error detected: $error');
    if (_isRestarting) {
      print('⏭️  Restart already in progress, skipping...');
      return;
    }

    _isRestarting = true;
    // Try to recover by restarting the service
    Future.delayed(Duration(seconds: 2), () async {
      if (_isRunning) {
        print('🔄 Attempting to recover from socket error...');
        try {
          await stop();
          await start();
          print('✅ Recovery successful');
        } catch (e) {
          print('❌ Recovery failed: $e');
        } finally {
          _isRestarting = false;
        }
      } else {
        _isRestarting = false;
      }
    });
  }

  void _handleSocketClosed() {
    print('⚠️  Socket closed unexpectedly');
    if (_isRestarting) {
      print('⏭️  Restart already in progress, skipping...');
      return;
    }

    if (_isRunning) {
      _isRestarting = true;
      // Try to restart
      Future.delayed(Duration(seconds: 2), () async {
        if (_isRunning) {
          print('🔄 Attempting to restart after socket closure...');
          try {
            await stop();
            await start();
            print('✅ Restart successful');
          } catch (e) {
            print('❌ Restart failed: $e');
          } finally {
            _isRestarting = false;
          }
        } else {
          _isRestarting = false;
        }
      });
    }
  }

  void _notifyListeners() {
    // Sort: favorites first, then online devices, then by name
    final sortedDevices =
        _discoveredDevices.values.toList()..sort((a, b) {
          if (a.isFavorite && !b.isFavorite) return -1;
          if (!a.isFavorite && b.isFavorite) return 1;
          if (a.isOnline && !b.isOnline) return -1;
          if (!a.isOnline && b.isOnline) return 1;
          return a.deviceName.compareTo(b.deviceName);
        });

    if (!_devicesController.isClosed) {
      _devicesController.add(sortedDevices);
    }
  }

  Future<void> stop() async {
    _isRunning = false;
    _broadcastTimer?.cancel();
    _cleanupTimer?.cancel();
    _keepAliveTimer?.cancel();

    // Cancel Wi-Fi Direct subscription
    // WiFi Direct removed - using Bluetooth + Hotspot instead

    try {
      // Close all sockets
      for (final socket in _sockets) {
        socket.close();
      }
      _sockets.clear();
      _networkInterfaces.clear();
    } catch (e) {
      print('Error closing sockets: $e');
    }

    // Clear non-favorite devices
    _discoveredDevices.removeWhere((id, device) => !device.isFavorite);
    _notifyListeners();

    print('Device discovery stopped');
  }

  String _getPlatformName() {
    if (Platform.isAndroid) return 'Android';
    if (Platform.isWindows) return 'Windows';
    if (Platform.isIOS) return 'iOS';
    if (Platform.isMacOS) return 'macOS';
    if (Platform.isLinux) return 'Linux';
    return 'Unknown';
  }

  /// Ensure multicast lock is acquired on Android
  Future<void> _ensureMulticastLock() async {
    if (!Platform.isAndroid) return;

    try {
      const channel = MethodChannel('zapshare.saf');

      // Check if multicast lock is already held
      final isHeld = await channel.invokeMethod<bool>('checkMulticastLock');
      print(
        '🔒 Multicast lock status: ${isHeld == true ? "HELD ✅" : "NOT HELD ❌"}',
      );

      if (isHeld != true) {
        // Try to acquire multicast lock
        print('🔓 Attempting to acquire multicast lock...');
        final success = await channel.invokeMethod<bool>(
          'acquireMulticastLock',
        );
        if (success == true) {
          print('✅ Multicast lock ACQUIRED successfully');
        } else {
          print('❌ Failed to acquire multicast lock');
        }
      } else {
        print('✅ Multicast lock already held');
      }
    } catch (e) {
      print('❌ Error checking/acquiring multicast lock: $e');
      print(
        '⚠️  WARNING: Multicast reception may not work (hotspot mode affected)',
      );
    }
  }

  // Cast URL is always handled via the built-in VideoPlayerScreen.
  // External player launching (VLC, etc.) has been removed to ensure
  // the integrated cast remote control protocol works correctly.

  void dispose() {
    stop();
    // Do NOT close controllers as this is a singleton service
    // _devicesController.close();
    // _connectionRequestController.close();
    // _connectionResponseController.close();
    // _castRequestController.close();
  }
}
