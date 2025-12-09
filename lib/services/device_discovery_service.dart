import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/services.dart';
import 'wifi_direct_service.dart';

// Connection request model
class ConnectionRequest {
  final String deviceId;
  final String deviceName;
  final String platform;
  final String ipAddress;
  final int fileCount;
  final List<String> fileNames;
  final int totalSize;
  final DateTime timestamp;

  ConnectionRequest({
    required this.deviceId,
    required this.deviceName,
    required this.platform,
    required this.ipAddress,
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

enum DiscoveryMethod { udp, wifiDirect }

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
    return n.toRadixString(36).toUpperCase().padLeft(8, '0');
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

  String? _myDeviceId;
  String? _myDeviceName;

  String? get myDeviceId => _myDeviceId;
  String? get myDeviceName => _myDeviceName;

  final WiFiDirectService _wifiDirectService = WiFiDirectService();
  StreamSubscription? _wifiDirectPeersSubscription;

  Stream<List<DiscoveredDevice>> get devicesStream => _devicesController.stream;
  Stream<ConnectionRequest> get connectionRequestStream =>
      _connectionRequestController.stream;
  Stream<ConnectionResponse> get connectionResponseStream =>
      _connectionResponseController.stream;
  List<DiscoveredDevice> get discoveredDevices =>
      _discoveredDevices.values.toList();

  // Connection request deduplication
  // Map<deviceId, timestamp> to track recent connection requests
  final Map<String, DateTime> _recentConnectionRequests = {};
  static const Duration _requestDeduplicationWindow = Duration(seconds: 10);

  Future<void> initialize() async {
    await _loadDeviceInfo();
    await _loadFavoriteDevices();

    // Initialize Wi-Fi Direct service
    if (Platform.isAndroid) {
      await _wifiDirectService.initialize();

      // Listen for Wi-Fi Direct peers
      _wifiDirectPeersSubscription = _wifiDirectService.peersStream.listen((
        peers,
      ) {
        _handleWifiDirectPeers(peers);
      });

      // Listen for connection info changes to restart discovery on new interface
      _wifiDirectService.connectionInfoStream.listen((info) async {
        if (info.groupFormed) {
          print(
            '✅ Wi-Fi Direct group formed, restarting discovery to bind to new interface...',
          );
          // Wait a bit for IP address assignment
          await Future.delayed(Duration(seconds: 2));
          await stop();
          await start();
        }
      });
    }
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
      // Start Wi-Fi Direct discovery if on Android
      if (Platform.isAndroid) {
        await _wifiDirectService.startPeerDiscovery();
      }

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

  void _handleWifiDirectPeers(List<WiFiDirectPeer> peers) {
    bool changed = false;

    // Remove all current Wi-Fi Direct devices and re-add filtered ones
    final wifiDirectDeviceIds =
        _discoveredDevices.values
            .where((d) => d.discoveryMethod == DiscoveryMethod.wifiDirect)
            .map((d) => d.deviceId)
            .toList();

    for (final id in wifiDirectDeviceIds) {
      _discoveredDevices.remove(id);
      changed = true;
    }

    // FILTER: Smart Filter for ZapShare
    // Goal: Show phones/tablets, Hide desktops/printers/TVs, Always show "ZapShare"

    // 1. Blacklist: Keywords for devices we definitely want to HIDE (to reduce clutter)
    final blacklist = [
      'desktop', 'laptop', 'computer', 'server',
      'printer', 'scanner', 'canon', 'hp ', 'epson', 'brother',
      'tv', 'television', 'cast', 'chromecast', 'roku', 'firestick',
      'bravia', 'samsung tv', 'lg webos',
      'windows',
      'mac',
      'linux',
      'ubuntu', // Explicitly hide desktop OS names as requested
      'direct-', // Often printer prefixes like "DIRECT-xy-HP..."
      'mesh', 'router', 'gateway', 'repeater',
    ];

    // 2. Whitelist: Patterns that strongly suggest a phone/tablet or ZapShare itself
    final whitelist = [
      'zapshare',
      'android', 'ios', 'iphone', 'ipad', 'galaxy', 'pixel', 'phone', 'mobile',
      'sm-',
      'cph',
      'rmx',
      'v2',
      'cphs', // Common model prefixes (Samsung, Oppo, Realme, Vivo)
      'redmi',
      'xiaomi',
      'poco',
      'oneplus',
      'moto',
      'nokia',
      'sony',
      'xperia',
      'lg',
      'htc',
      'huawei',
      'honor',
    ];

    for (final peer in peers) {
      final deviceNameLower = peer.deviceName.toLowerCase();

      // Rule 1: Always show if explicitly whitelisted (contains any whitelist keyword)
      bool isWhitelisted = whitelist.any((w) => deviceNameLower.contains(w));

      // Rule 2: Hide if blacklisted (contains any blacklist keyword), UNLESS it was whitelisted (e.g. "My Desktop Phone" - rare but possible)
      // Note: We prioritize whitelist. If it says "ZapShare on Desktop", we show it.
      bool isBlacklisted = blacklist.any((b) => deviceNameLower.contains(b));

      // Rule 3: Allow if purely generic (unknown) but valid name, provided it's NOT blacklisted
      // This allows devices like "John's Device" or "Wonderland" to show up, which were previously hidden.

      bool shouldShow =
          isWhitelisted || (!isBlacklisted && deviceNameLower.isNotEmpty);

      if (shouldShow) {
        final deviceId = 'wd_${peer.deviceAddress.replaceAll(':', '')}';

        _discoveredDevices[deviceId] = DiscoveredDevice(
          deviceId: deviceId,
          deviceName: peer.deviceName,
          ipAddress:
              '0.0.0.0', // Wi-Fi Direct peers don't have IP until connected
          port: 8080,
          platform: 'android', // Wi-Fi Direct is mostly Android
          lastSeen: DateTime.now(),
          discoveryMethod: DiscoveryMethod.wifiDirect,
          wifiDirectAddress: peer.deviceAddress,
        );
        changed = true;
        // Highlighting for debug
        if (isWhitelisted) {
          print(
            '✅ Added Wi-Fi Direct device (Whitelisted): ${peer.deviceName}',
          );
        } else {
          print('✅ Added Wi-Fi Direct device (Generic): ${peer.deviceName}');
        }
      } else {
        print(
          '🚫 Filtered out Wi-Fi Direct device (Blacklisted): ${peer.deviceName}',
        );
      }
    }

    if (changed) {
      _notifyListeners();
    }
  }

  /// Update IP address for a Wi-Fi Direct device after connection is established
  /// This is called after Wi-Fi Direct group is formed and IP is assigned
  void updateWifiDirectDeviceIp(String macAddress, String ipAddress) {
    final deviceId = 'wd_${macAddress.replaceAll(':', '')}';
    final device = _discoveredDevices[deviceId];

    if (device != null) {
      print(
        '📡 Updating Wi-Fi Direct device IP: ${device.deviceName} -> $ipAddress',
      );
      _discoveredDevices[deviceId] = DiscoveredDevice(
        deviceId: device.deviceId,
        deviceName: device.deviceName,
        ipAddress: ipAddress,
        port: 8080,
        platform: device.platform,
        lastSeen: DateTime.now(),
        discoveryMethod: device.discoveryMethod,
        wifiDirectAddress: device.wifiDirectAddress,
        isFavorite: device.isFavorite,
      );
      _notifyListeners();
    }
  }

  Future<bool> connectToWifiDirectPeer(String deviceAddress) async {
    if (!Platform.isAndroid) return false;
    return await _wifiDirectService.connectToPeer(deviceAddress);
  }

  void _startBroadcasting() {
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
      final message = jsonEncode({
        'type': 'ZAPSHARE_DISCOVERY',
        'deviceId': _myDeviceId,
        'deviceName': _myDeviceName,
        'platform': _getPlatformName(),
        'port': 8080, // File sharing port
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      });

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
            reusePort: !Platform.isWindows, // Windows doesn't support reusePort
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

      print(
        '📨 Received UDP message from ${datagram.address.address}:${datagram.port}',
      );
      print('   Type: $messageType');
      print('   Sender Device ID: $senderDeviceId');
      print('   My Device ID: $_myDeviceId');

      // Ignore our own broadcasts
      if (senderDeviceId == _myDeviceId) {
        print('   ⏭️  Ignoring own message');
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
          print('   🎯 Handling connection response...');
          _handleConnectionResponse(data, datagram.address.address);
          break;
        default:
          print('   ⚠️  Unknown message type: $messageType');
      }
    } catch (e) {
      print('❌ Error handling discovery message: $e');
      print('   Stack trace: ${StackTrace.current}');
    }
  }

  void _handleDiscoveryBroadcast(Map<String, dynamic> data, String ipAddress) {
    final deviceId = data['deviceId'] as String;
    final deviceName = data['deviceName'] as String;
    final platform = data['platform'] as String;
    final port = data['port'] as int;

    // Ignore own device
    if (deviceId == _myDeviceId) {
      print('🚫 Ignoring own device broadcast: $deviceId');
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
      fileCount: data['fileCount'] as int,
      fileNames: List<String>.from(data['fileNames'] as List),
      totalSize: data['totalSize'] as int,
      timestamp: DateTime.fromMillisecondsSinceEpoch(data['timestamp'] as int),
    );

    _connectionRequestController.add(request);
    print('✅ Connection request added to stream (will show dialog)');
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

    _connectionResponseController.add(response);
    print('✅ Connection response added to stream');
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

    _devicesController.add(sortedDevices);
  }

  Future<void> stop() async {
    _isRunning = false;
    _broadcastTimer?.cancel();
    _cleanupTimer?.cancel();
    _keepAliveTimer?.cancel();

    // Cancel Wi-Fi Direct subscription
    _wifiDirectPeersSubscription?.cancel();
    _wifiDirectPeersSubscription = null;

    // Stop Wi-Fi Direct discovery
    if (Platform.isAndroid) {
      await _wifiDirectService.stopPeerDiscovery();
    }

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

  void dispose() {
    stop();
    _devicesController.close();
    _connectionRequestController.close();
    _connectionResponseController.close();
  }
}
