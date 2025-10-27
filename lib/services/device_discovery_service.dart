import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:shared_preferences/shared_preferences.dart';

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

class DiscoveredDevice {
  final String deviceId;
  final String deviceName;
  final String ipAddress;
  final int port;
  final String platform;
  final DateTime lastSeen;
  bool isFavorite;

  DiscoveredDevice({
    required this.deviceId,
    required this.deviceName,
    required this.ipAddress,
    required this.port,
    required this.platform,
    required this.lastSeen,
    this.isFavorite = false,
  });

  Map<String, dynamic> toJson() => {
        'deviceId': deviceId,
        'deviceName': deviceName,
        'ipAddress': ipAddress,
        'port': port,
        'platform': platform,
        'lastSeen': lastSeen.toIso8601String(),
        'isFavorite': isFavorite,
      };

  factory DiscoveredDevice.fromJson(Map<String, dynamic> json) {
    return DiscoveredDevice(
      deviceId: json['deviceId'] ?? '',
      deviceName: json['deviceName'] ?? 'Unknown Device',
      ipAddress: json['ipAddress'] ?? '',
      port: json['port'] ?? 8080,
      platform: json['platform'] ?? 'unknown',
      lastSeen: DateTime.parse(json['lastSeen'] ?? DateTime.now().toIso8601String()),
      isFavorite: json['isFavorite'] ?? false,
    );
  }

  String get shareCode {
    final parts = ipAddress.split('.');
    if (parts.length != 4) return '';
    final n = (int.parse(parts[0]) << 24) |
        (int.parse(parts[1]) << 16) |
        (int.parse(parts[2]) << 8) |
        int.parse(parts[3]);
    return n.toRadixString(36).toUpperCase().padLeft(8, '0');
  }

  bool get isOnline {
    return DateTime.now().difference(lastSeen).inSeconds < 30;
  }
}

class DeviceDiscoveryService {
  static const int DISCOVERY_PORT = 37020; // ZapShare discovery port
  static const String MULTICAST_GROUP = '239.255.43.21'; // ZapShare multicast group
  static const int BROADCAST_INTERVAL_SECONDS = 5;
  
  // Singleton instance
  static final DeviceDiscoveryService _instance = DeviceDiscoveryService._internal();
  
  factory DeviceDiscoveryService() {
    return _instance;
  }
  
  DeviceDiscoveryService._internal();
  
  RawDatagramSocket? _socket;
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
  
  Stream<List<DiscoveredDevice>> get devicesStream => _devicesController.stream;
  Stream<ConnectionRequest> get connectionRequestStream => _connectionRequestController.stream;
  Stream<ConnectionResponse> get connectionResponseStream => _connectionResponseController.stream;
  List<DiscoveredDevice> get devices => _discoveredDevices.values.toList();

  Future<void> initialize() async {
    await _loadDeviceInfo();
    await _loadFavoriteDevices();
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
      print('🆔 Force regenerated IP-based device ID: $_myDeviceId (IP: $currentIp)');
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
    final favorites = _discoveredDevices.values
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
      // Create UDP socket for multicast
      _socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, DISCOVERY_PORT);
      
      print('✅ Socket bound to port $DISCOVERY_PORT');
      
      // Join multicast group
      _socket!.joinMulticast(InternetAddress(MULTICAST_GROUP));
      _socket!.broadcastEnabled = true;
      
      print('✅ Joined multicast group $MULTICAST_GROUP');
      
      // Listen for incoming discovery messages
      _socket!.listen(
        (RawSocketEvent event) {
          if (event == RawSocketEvent.read) {
            final datagram = _socket!.receive();
            if (datagram != null) {
              _handleDiscoveryMessage(datagram);
            }
          }
        },
        onError: (error) {
          print('❌ Socket error: $error');
          _handleSocketError(error);
        },
        onDone: () {
          print('⚠️  Socket closed unexpectedly');
          _handleSocketClosed();
        },
        cancelOnError: false, // Keep listening even if there are errors
      );
      
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

  void _startBroadcasting() {
    _broadcastTimer?.cancel();
    _broadcastTimer = Timer.periodic(
      Duration(seconds: BROADCAST_INTERVAL_SECONDS),
      (_) => _broadcastPresence(),
    );
    // Send first broadcast immediately
    _broadcastPresence();
  }

  void _broadcastPresence() {
    if (!_isRunning || _socket == null) {
      print('⚠️  Broadcast skipped - not running or socket null');
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
      
      // Send to multicast group
      final bytesSent1 = _socket!.send(data, InternetAddress(MULTICAST_GROUP), DISCOVERY_PORT);
      
      // Also send broadcast for local network
      final bytesSent2 = _socket!.send(data, InternetAddress('255.255.255.255'), DISCOVERY_PORT);
      
      print('📡 Broadcasting presence: $bytesSent1 bytes (multicast), $bytesSent2 bytes (broadcast)');
      
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
  Future<void> sendConnectionRequest(String targetIp, List<String> fileNames, int totalSize) async {
    if (_socket == null) {
      print('ERROR: Cannot send connection request - socket is null');
      return;
    }
    
    if (_myDeviceId == null || _myDeviceName == null) {
      print('ERROR: Cannot send connection request - device info not initialized');
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
      final bytesSent = _socket!.send(data, InternetAddress(targetIp), DISCOVERY_PORT);
      
      print('✅ Sent connection request to $targetIp (${bytesSent} bytes)');
      print('   Device: $_myDeviceName ($_myDeviceId)');
      print('   Files: ${fileNames.length} files, ${(totalSize / 1024 / 1024).toStringAsFixed(2)} MB');
    } catch (e) {
      print('❌ Error sending connection request: $e');
    }
  }

  // Send connection response (accept/deny)
  Future<void> sendConnectionResponse(String targetIp, bool accepted) async {
    if (_socket == null) return;
    
    try {
      final message = jsonEncode({
        'type': 'ZAPSHARE_CONNECTION_RESPONSE',
        'deviceId': _myDeviceId,
        'deviceName': _myDeviceName,
        'accepted': accepted,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      });
      
      final data = utf8.encode(message);
      _socket!.send(data, InternetAddress(targetIp), DISCOVERY_PORT);
      
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
      
      print('📨 Received UDP message from ${datagram.address.address}:${datagram.port}');
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
      print('🔄 Removing duplicate device: $duplicateKey (same IP: $ipAddress)');
      _discoveredDevices.remove(duplicateKey);
    }
    
    // Check if device is already in favorites
    final existingDevice = _discoveredDevices[deviceId];
    final isFavorite = existingDevice?.isFavorite ?? duplicateByIp?.isFavorite ?? false;
    
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
    print('📩 Received connection request from $ipAddress');
    print('   Device: ${data['deviceName']} (${data['deviceId']})');
    print('   Files: ${data['fileCount']} files, ${(data['totalSize'] / 1024 / 1024).toStringAsFixed(2)} MB');
    
    final request = ConnectionRequest(
      deviceId: data['deviceId'] as String,
      deviceName: data['deviceName'] as String,
      platform: data['platform'] as String,
      ipAddress: ipAddress,
      fileCount: data['fileCount'] as int,
      fileNames: List<String>.from(data['fileNames'] as List),
      totalSize: data['totalSize'] as int,
      timestamp: DateTime.fromMillisecondsSinceEpoch(data['timestamp'] as int),
    );
    
    _connectionRequestController.add(request);
    print('✅ Connection request added to stream');
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
    
    if (_socket == null) {
      print('⚠️  Service health check failed: socket is null');
      _handleSocketError('Socket is null during health check');
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
      // Remove devices not seen in 30 seconds (unless they're favorites)
      if (!device.isFavorite && now.difference(device.lastSeen).inSeconds > 30) {
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
    final sortedDevices = _discoveredDevices.values.toList()
      ..sort((a, b) {
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
    
    try {
      _socket?.close();
    } catch (e) {
      print('Error closing socket: $e');
    }
    
    _socket = null;
    
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

  void dispose() {
    stop();
    _devicesController.close();
    _connectionRequestController.close();
    _connectionResponseController.close();
  }
}
