import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
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
  final double? duration;

  CastRequest({
    required this.deviceId,
    required this.deviceName,
    required this.url,
    this.fileName,
    this.subtitleUrl,
    required this.senderIp,
    required this.timestamp,
    this.duration,
  });
}

/// Remote control command sent from controller to player
class CastControl {
  final String action; // play, pause, seek, volume, stop, setAudioTrack, setSubtitleTrack
  final double? seekPosition; // in seconds
  final double? volume; // 0.0 - 1.0
  final int? trackIndex; // audio/subtitle track index
  final String? propertyKey;
  final dynamic propertyValue;
  final String senderIp;

  CastControl({
    required this.action,
    this.seekPosition,
    this.volume,
    this.trackIndex,
    this.propertyKey,
    this.propertyValue,
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
  final List<String>? audioTracks;
  final List<String>? subtitleTracks;
  final int? activeAudioTrack;
  final String? activeAudioTrackLabel;
  final int? activeSubtitleTrack;
  final String? audioOutput; // "default" or "castSource"
  final bool active;
  final int? timestamp;

  CastStatus({
    required this.position,
    required this.duration,
    required this.buffered,
    required this.isPlaying,
    required this.isBuffering,
    required this.volume,
    this.fileName,
    required this.senderIp,
    this.audioTracks,
    this.subtitleTracks,
    this.activeAudioTrack,
    this.activeAudioTrackLabel,
    this.activeSubtitleTrack,
    this.audioOutput,
    this.active = true,
    this.timestamp,
  });
}

/// WebRTC audio offer (sender -> receiver)
class AudioOffer {
  final String deviceId;
  final String deviceName;
  final String senderIp;
  final String sdp;
  final List<Map<String, dynamic>> iceCandidates;

  AudioOffer({
    required this.deviceId,
    required this.deviceName,
    required this.senderIp,
    required this.sdp,
    required this.iceCandidates,
  });
}

/// WebRTC audio answer (receiver -> sender)
class AudioAnswer {
  final String deviceId;
  final String deviceName;
  final String senderIp;
  final String sdp;
  final List<Map<String, dynamic>> iceCandidates;

  AudioAnswer({
    required this.deviceId,
    required this.deviceName,
    required this.senderIp,
    required this.sdp,
    required this.iceCandidates,
  });
}

class _AudioSession {
  final String peerIp;
  final bool isInitiator;
  final RTCPeerConnection pc;
  MediaStream? localStream;
  MediaStream? remoteStream;
  final List<Map<String, dynamic>> iceCandidates = [];
  bool closed = false;
  bool offerSent = false;

  _AudioSession({
    required this.peerIp,
    required this.isInitiator,
    required this.pc,
  });

  Future<void> dispose() async {
    if (closed) return;
    closed = true;
    try {
      await pc.close();
    } catch (_) {}
    try {
      await localStream?.dispose();
    } catch (_) {}
    try {
      await remoteStream?.dispose();
    } catch (_) {}
  }
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
  final double? width;
  final double? height;

  ScreenMirrorRequest({
    required this.deviceId,
    required this.deviceName,
    required this.streamUrl,
    required this.senderIp,
    required this.timestamp,
    this.width,
    this.height,
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
      2; // Aggressive discovery for faster device visibility
    static const int _DISCOVERY_BURST_COUNT = 2;
    static const int _DISCOVERY_BURST_SPACING_MS = 180;
  static const MethodChannel _nativeChannel = MethodChannel('zapshare.saf');

  // Singleton instance
  static final DeviceDiscoveryService _instance = DeviceDiscoveryService._internal();

  factory DeviceDiscoveryService() {
    return _instance;
  }

  DeviceDiscoveryService._internal() {
    _nativeChannel.setMethodCallHandler((call) async {
       if (call.method == 'audioStateChanged') {
         final bool active = call.arguments['active'] ?? false;
         _audioForegroundActive = active;
         _audioActiveController.add(active);
         print('🎵 [Discovery] Native audio state changed: active=$active');
       }
    });
  }

  List<RawDatagramSocket> _sockets =
      []; // Multiple sockets, one per network interface
  final List<StreamSubscription<RawSocketEvent>> _socketSubscriptions = [];
  List<_NetworkInterfaceInfo> _networkInterfaces =
      []; // Store interface info for broadcasting
  Timer? _broadcastTimer;
  Timer? _cleanupTimer;
  Timer? _keepAliveTimer;
  Timer? _multicastRenewTimer; // Periodic multicast lock renewal for long-running cast sessions
  ServerSocket? _tcpControlServer; // TCP control channel for reliable cast commands
  bool _isRunning = false;
  bool _isRestarting = false; // Flag to prevent multiple restart attempts
  bool _isStopping = false; // Flag to prevent restart when stop() is intentional
  final Map<String, int> _lastCastStatusTcpSentAt = {};
  final Map<String, int> _lastCastTracksSentAt = {};
  final Map<String, String> _lastCastTrackSignature = {};

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

    // Low-latency WebRTC audio signaling
    final StreamController<AudioOffer> _audioOfferController =
      StreamController<AudioOffer>.broadcast();
    final StreamController<AudioAnswer> _audioAnswerController =
      StreamController<AudioAnswer>.broadcast();

      // WebRTC audio state
      final Map<String, _AudioSession> _audioSessions = {};
      RTCVideoRenderer? _audioRenderer;
      MediaStream? _currentAudioStream;
      bool? _currentStreamIsSystem;
      bool _autoHandleWebRtcAudio = true;
      bool _webRtcReady = false;
      bool _webRtcInitInProgress = false;
    bool _audioForegroundActive = false;
    final StreamController<bool> _audioActiveController = StreamController<bool>.broadcast();

  String? _myDeviceId;
  String? _myDeviceName;
  String? _lastKnownIp;

  int _preferredCushionMs = 20;
  void setPreferredCushionMs(int ms) => _preferredCushionMs = ms;

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
  Stream<AudioOffer> get audioOfferStream => _audioOfferController.stream;
  Stream<AudioAnswer> get audioAnswerStream => _audioAnswerController.stream;
  Stream<bool> get activeAudioStream => _audioActiveController.stream;
  bool get isAudioActive => _audioSessions.isNotEmpty;
  List<DiscoveredDevice> get discoveredDevices =>
      _discoveredDevices.values.toList();

  // Connection request deduplication
  // Map<deviceId, timestamp> to track recent connection requests
  final Map<String, DateTime> _recentConnectionRequests = {};
  static const Duration _requestDeduplicationWindow = Duration(seconds: 10);

  Future<void> initialize() async {
    await _loadDeviceInfo();
    await _loadFavoriteDevices();
    await _initWebRtcAudio();
    // Ensure foreground helper can be reached when running in background
    if (Platform.isAndroid) {
      // No-op, just verify channel exists
      const MethodChannel('zapshare.saf');
    }

    // WiFi Direct removed - using Bluetooth + Hotspot instead
  }

  Future<void> _loadDeviceInfo() async {
    final prefs = await SharedPreferences.getInstance();

    // Get current IP address
    String? currentIp = await _getCurrentIpAddress();
    _lastKnownIp = currentIp;

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
      } else if (Platform.isLinux) {
        _myDeviceName = 'Linux PC';
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

  Future<void> _initWebRtcAudio() async {
    if (_webRtcReady || _webRtcInitInProgress) return;
    _webRtcInitInProgress = true;
    try {
      _audioRenderer = RTCVideoRenderer();
      await _audioRenderer!.initialize();
      _webRtcReady = true;
      print('✅ WebRTC audio renderer ready');
    } catch (e) {
      print('❌ WebRTC audio init failed: $e');
    } finally {
      _webRtcInitInProgress = false;
    }
  }

  Future<void> _startAudioForeground() async {
    if (!Platform.isAndroid) return;
    print('🚀 [Discovery] _startAudioForeground called. Active status: $_audioForegroundActive');
    if (_audioForegroundActive) return;
    try {
      print('🚀 [Discovery] Invoking native startForegroundService with useMediaProjection = true');
      await _nativeChannel.invokeMethod('startForegroundService', {
        'title': 'ZapShare Audio',
        'content': 'Interactive low-latency audio active',
        'useMediaProjection': true,
      });
      _audioForegroundActive = true;
      print('✅ [Discovery] Foreground service started successfully');
    } catch (e) {
      print('⚠️  Could not start audio foreground: $e');
    }
  }

  Future<void> _stopAudioForeground() async {
    if (!Platform.isAndroid) return;
    print('🛑 [Discovery] _stopAudioForeground called');
    try {
      await _nativeChannel.invokeMethod('stopForegroundService');
      await _nativeChannel.invokeMethod('stopLanAudioSender'); 
    } catch (e) {
      print('⚠️  Could not stop audio foreground: $e');
    } finally {
      _audioForegroundActive = false;
    }
  }

  Future<void> stopLanAudioSender() async {
    if (!Platform.isAndroid) return;
    try {
      await _nativeChannel.invokeMethod('stopLanAudioSender');
    } catch (e) {
      print('⚠️  Error stopping LAN audio sender: $e');
    }
  }

  Future<void> startLanAudioSender(List<String> targetIps) async {
    if (!Platform.isAndroid) return;
    try {
      final status = await _nativeChannel.invokeMethod('startLanAudioSender', {'ips': targetIps});
      if (status == true) {
         for (final ip in targetIps) {
           await sendNativeSystemAudioOffer(ip, 50005);
         }
      }
    } catch (e) {
      print('⚠️  Error starting LAN audio sender: $e');
    }
  }

  Future<void> stopLanAudioReceiver() async {
    if (!Platform.isAndroid) return;
    try {
      await _nativeChannel.invokeMethod('stopLanAudioReceiver');
      await _stopAudioForeground();
    } catch (e) {
      print('⚠️  Error stopping LAN audio receiver: $e');
    }
  }

  Future<void> startLanAudioReceiver({int port = 50005, int cushionMs = 20}) async {
    if (!Platform.isAndroid) return;
    try {
      await _nativeChannel.invokeMethod('startLanAudioReceiver', {
        'port': port,
        'cushionMs': cushionMs,
      });
      print('✅ Requested native LAN audio receiver start on port $port with ${cushionMs}ms cushion');
    } catch (e) {
      print('⚠️  Error starting LAN audio receiver: $e');
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
    _isPaused = false;
    if (_isRunning) {
      // Refresh by stopping exactly before starting
      // This fixes "jittery connection" that previously required app restart
      await stop();
    }
    _isRunning = true;

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

      // Create a single main socket for receiving on all interfaces
      RawDatagramSocket? mainSocket;
      try {
        mainSocket = await RawDatagramSocket.bind(
          InternetAddress.anyIPv4,
          DISCOVERY_PORT,
          reusePort: !Platform.isWindows && !Platform.isAndroid, // Avoid on Android too to be safe
        );
      } catch (e) {
        print('⚠️  Initial bind with reusePort failed, retrying without it: $e');
        mainSocket = await RawDatagramSocket.bind(
          InternetAddress.anyIPv4,
          DISCOVERY_PORT,
          reusePort: false,
        );
      }

      mainSocket.broadcastEnabled = true;
      _sockets.add(mainSocket);

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

          if (ipv4Addresses.isEmpty) continue;

          // Store interface info for broadcasting
          final interfaceInfo = _NetworkInterfaceInfo(interface, ipv4Addresses);
          _networkInterfaces.add(interfaceInfo);

          // Join multicast group ON THIS SPECIFIC INTERFACE on our main socket
          mainSocket.joinMulticast(InternetAddress(MULTICAST_GROUP), interface);
          
          print('✅ Joined multicast $MULTICAST_GROUP on ${interface.name}');
        } catch (e) {
          print('⚠️  Could not join multicast on ${interface.name}: $e');
        }
      }

      // Listen for incoming messages on the main socket
      final sub = mainSocket.listen(
        (RawSocketEvent event) {
          if (event == RawSocketEvent.read) {
            final datagram = mainSocket?.receive();
            if (datagram != null) {
              _handleDiscoveryMessage(datagram);
            }
          }
        },
        onError: (error) {
          print('❌ Main socket error: $error');
          Future.delayed(Duration(seconds: 1), () => _handleSocketError(error));
        },
        onDone: () {
          print('⚠️  Main discovery socket closed');
          if (_isRunning && !_isStopping) {
            Future.delayed(Duration(seconds: 2), () => _handleSocketClosed());
          }
        },
        cancelOnError: false,
      );
      _socketSubscriptions.add(sub);

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

      // Start TCP control server for reliable cast commands during heavy streaming
      _startTcpControlServer();

      // Periodically re-acquire multicast lock to prevent it from being released
      // during long-running cast sessions (especially with 18GB+ files)
      if (Platform.isAndroid) {
        _multicastRenewTimer?.cancel();
        _multicastRenewTimer = Timer.periodic(const Duration(seconds: 60), (_) {
          _ensureMulticastLock();
        });
      }

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
    print('▶️ Discovery RESUMING (Force Re-initialization)');
    _isPaused = false;
    // Forcing a full start() ensure a fresh device list (wipe stale)
    // and new sockets as requested by the user.
    start();
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
    _burstBroadcastPresence();
  }

  void _burstBroadcastPresence() {
    for (int i = 0; i < _DISCOVERY_BURST_COUNT; i++) {
      Future.delayed(
        Duration(milliseconds: _DISCOVERY_BURST_SPACING_MS * (i + 1)),
        () {
          if (_isRunning && !_isPaused) {
            _broadcastPresence();
          }
        },
      );
    }
  }

  void _broadcastPresence() async {
    if (!_isRunning || _networkInterfaces.isEmpty) {
      print('⚠️  Broadcast skipped - not running or no interfaces');
      return;
    }

    // Detect IP changes dynamically to restart sockets and refresh discovery
    final currentIp = await _getCurrentIpAddress();
    if (currentIp != null && _lastKnownIp != null && currentIp != _lastKnownIp) {
      print('🔄 IP change detected in discovery: $_lastKnownIp -> $currentIp. Restarting...');
      _lastKnownIp = currentIp;
      Future.microtask(() async {
        try {
          await stop();
          await start();
        } catch (e) {
          print('Error restarting discovery on IP change: $e');
        }
      });
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

      if (messageType != 'ZAPSHARE_DISCOVERY') {
        print('📡 [Discovery] Incoming: $messageType from ${datagram.address.address}');
      }
      
      // Ignore our own broadcasts
      if (senderDeviceId == _myDeviceId) {
        return;
      }

      // Handle different message types
      switch (messageType) {
        case 'ZAPSHARE_DISCOVERY':
          _handleDiscoveryBroadcast(data, datagram.address.address);
          break;
        case 'ZAPSHARE_BYE':
          final byeId = data['deviceId'] as String?;
          if (byeId != null) {
            print('👋 [Discovery] Device $byeId is going offline');
            _discoveredDevices.remove(byeId);
            _notifyListeners();
          }
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
        case 'ZAPSHARE_AUDIO_OFFER':
          _handleAudioOffer(data, datagram.address.address);
          break;
        case 'ZAPSHARE_AUDIO_ANSWER':
          _handleAudioAnswer(data, datagram.address.address);
          break;
        case 'ZAPSHARE_AUDIO_ICE':
          _handleAudioIce(data, datagram.address.address);
          break;
        case 'ZAPSHARE_AUDIO_STOP':
          print('🔴 [WEB-RTC] Audio stop request from ${datagram.address.address}');
          stopWebRtcAudio(datagram.address.address, false);
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

  Future<void> sendCastUrl(
    String targetIp,
    String url, {
    String? fileName,
    String? subtitleUrl,
    double? duration,
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
        'duration': duration,
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
            url: data['url'],
            fileName: data['fileName'],
            subtitleUrl: data['subtitleUrl'],
            senderIp: senderIp,
            timestamp: DateTime.now(),
            duration: (data['duration'] as num?)?.toDouble(),
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
      trackIndex: (data['trackIndex'] as num?)?.toInt(),
      propertyKey: data['propertyKey'] as String?,
      propertyValue: data['propertyValue'],
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
      audioTracks: (data['audioTracks'] as List?)?.cast<String>(),
      subtitleTracks: (data['subtitleTracks'] as List?)?.cast<String>(),
      activeAudioTrack: (data['activeAudioTrack'] as num?)?.toInt(),
      activeAudioTrackLabel: data['activeAudioTrackLabel'] as String?,
      activeSubtitleTrack: (data['activeSubtitleTrack'] as num?)?.toInt(),
      audioOutput: data['audioOutput'] as String?,
      active: data['active'] as bool? ?? true,
      timestamp: data['timestamp'] as int?,
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
    int? trackIndex,
    String? propertyKey,
    dynamic propertyValue,
  }) async {
    if (_sockets.isEmpty) return;
    try {
      final message = jsonEncode({
        'type': 'ZAPSHARE_CAST_CONTROL',
        'deviceId': _myDeviceId,
        'action': action,
        if (seekPosition != null) 'seekPosition': seekPosition,
        if (volume != null) 'volume': volume,
        if (trackIndex != null) 'trackIndex': trackIndex,
        if (propertyKey != null) 'propertyKey': propertyKey,
        if (propertyValue != null) 'propertyValue': propertyValue,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      });
      final data = utf8.encode(message);
      for (final socket in _sockets) {
        try {
          // Send 5 times with staggered delays for robustness during 18GB+ streaming congestion
          for (int i = 0; i < 5; i++) {
            socket.send(data, InternetAddress(targetIp), DISCOVERY_PORT);
            if (i < 4) await Future.delayed(const Duration(milliseconds: 25));
          }
        } catch (_) {}
      }
      // Also attempt TCP delivery for critical commands (play/pause/seek/stop)
      if (action != 'ping') {
        _sendCastControlViaTcp(targetIp, message);
      }
    } catch (_) {}
  }

  /// Reliable TCP fallback for cast control commands.
  /// Fires-and-forgets a TCP connection to deliver the message when UDP may be congested.
  void _sendCastControlViaTcp(String targetIp, String message) {
    // Use a dedicated TCP port for reliable cast control
    const tcpControlPort = 53218;
    Socket.connect(targetIp, tcpControlPort, timeout: const Duration(seconds: 2))
        .then((socket) {
      socket.write(message);
      socket.flush().then((_) => socket.destroy()).catchError((_) => socket.destroy());
    }).catchError((_) {
      // TCP fallback failed silently - UDP retries are primary
    });
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
    List<String>? audioTracks,
    List<String>? subtitleTracks,
    int? activeAudioTrack,
    String? activeAudioTrackLabel,
    int? activeSubtitleTrack,
    String? audioOutput,
    bool active = true,
  }) async {
    if (_sockets.isEmpty) return;
    try {
      final nowMs = DateTime.now().millisecondsSinceEpoch;

      // Keep frequent status packets small under network pressure.
      // Track lists are sent immediately when changed, and then at a low keepalive cadence.
      final trackSignature =
          '${audioTracks?.join('|') ?? ''}::${subtitleTracks?.join('|') ?? ''}';
      final lastTrackSig = _lastCastTrackSignature[targetIp];
      final lastTracksSentAt = _lastCastTracksSentAt[targetIp] ?? 0;
      final tracksChanged = trackSignature != lastTrackSig;
      final shouldSendTracks =
          tracksChanged || (nowMs - lastTracksSentAt) >= 8000;

      if (shouldSendTracks) {
        _lastCastTracksSentAt[targetIp] = nowMs;
        _lastCastTrackSignature[targetIp] = trackSignature;
      }

      final payload = {
        'type': 'ZAPSHARE_CAST_STATUS',
        'deviceId': _myDeviceId,
        'position': position,
        'duration': duration,
        'buffered': buffered,
        'isPlaying': isPlaying,
        'isBuffering': isBuffering,
        'volume': volume,
        if (fileName != null) 'fileName': fileName,
        if (shouldSendTracks && audioTracks != null) 'audioTracks': audioTracks,
        if (shouldSendTracks && subtitleTracks != null)
          'subtitleTracks': subtitleTracks,
        if (activeAudioTrack != null) 'activeAudioTrack': activeAudioTrack,
        if (activeAudioTrackLabel != null) 'activeAudioTrackLabel': activeAudioTrackLabel,
        if (activeSubtitleTrack != null) 'activeSubtitleTrack': activeSubtitleTrack,
        if (audioOutput != null) 'audioOutput': audioOutput,
        'active': active,
        'timestamp': nowMs,
      };

      final message = jsonEncode(payload);
      final data = utf8.encode(message);
      for (final socket in _sockets) {
        try {
          // Keep status traffic lighter than control traffic to avoid congestion lockups.
          for (int i = 0; i < 2; i++) {
            socket.send(data, InternetAddress(targetIp), DISCOVERY_PORT);
            if (i == 0) await Future.delayed(const Duration(milliseconds: 12));
          }
        } catch (_) {}
      }

      // Periodic TCP status lifeline keeps controller connected if UDP is congested.
      final lastTcpAt = _lastCastStatusTcpSentAt[targetIp] ?? 0;
      if ((nowMs - lastTcpAt) >= 2000) {
        _lastCastStatusTcpSentAt[targetIp] = nowMs;
        _sendCastControlViaTcp(targetIp, message);
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

  // Deduplication for audio offers (since we now send 3 retries)
  final Map<String, DateTime> _recentAudioOffers = {};

  void _handleAudioOffer(Map<String, dynamic> data, String senderIp) {
    print('📡 [Discovery] Received ZAPSHARE_AUDIO_OFFER from $senderIp');
    final sdp = data['sdp'] as String?;
    if (sdp == null || sdp.isEmpty) return;
    final deviceId = data['deviceId'] as String? ?? 'unknown';
    final deviceName = data['deviceName'] as String? ?? 'Unknown Device';

    // Deduplicate: Ignore duplicate offers from the same sender within 5 seconds
    final now = DateTime.now();
    final lastOffer = _recentAudioOffers[senderIp];
    if (lastOffer != null && now.difference(lastOffer).inSeconds < 5) {
      print('⏭️  Ignoring duplicate audio offer from $senderIp');
      return;
    }
    _recentAudioOffers[senderIp] = now;

    // ── LAN Audio (native Opus/UDP) path ────────────────────────────────────
    // Sender sets sdp = 'LAN_AUDIO_STREAM_PORT:<port>;cushion=<ms>' for native streaming.
    if (sdp.startsWith('LAN_AUDIO_STREAM_PORT:')) {
      final parts = sdp.replaceFirst('LAN_AUDIO_STREAM_PORT:', '').split(';');
      final port = int.tryParse(parts[0]) ?? 50005;
      final cushion = int.tryParse(
        parts.firstWhere((p) => p.startsWith('cushion='), orElse: () => 'cushion=$_preferredCushionMs')
             .replaceFirst('cushion=', '')
      ) ?? _preferredCushionMs;

      print('🎵 [Discovery] LAN Audio offer from $senderIp on port $port — starting native receiver');
      if (Platform.isAndroid) {
        // Stop any running sender first so we don't send and receive simultaneously
        stopLanAudioSender();
        // Start the native AudioStreamReceiverService
        startLanAudioReceiver(port: port, cushionMs: cushion);
      }
      // Also emit to the stream so UI layers can react (e.g. show receiving screen)
      final offer = AudioOffer(
        deviceId: deviceId,
        deviceName: deviceName,
        senderIp: senderIp,
        sdp: sdp,
        iceCandidates: [],
      );
      if (!_audioOfferController.isClosed) _audioOfferController.add(offer);
      return;
    }

    // ── WebRTC path ─────────────────────────────────────────────────────────
    final iceList = <Map<String, dynamic>>[];
    final raw = data['iceCandidates'];
    if (raw is List) {
      for (final entry in raw) {
        if (entry is Map) {
          iceList.add(entry.map((key, value) => MapEntry('$key', value)));
        }
      }
    }

    final offer = AudioOffer(
      deviceId: deviceId,
      deviceName: deviceName,
      senderIp: senderIp,
      sdp: sdp,
      iceCandidates: iceList,
    );

    if (!_audioOfferController.isClosed) {
      _audioOfferController.add(offer);
    }

    if (_autoHandleWebRtcAudio) {
      processIncomingAudioOffer(offer);
    }
  }

  void _handleAudioAnswer(Map<String, dynamic> data, String senderIp) {
    final sdp = data['sdp'] as String?;
    if (sdp == null || sdp.isEmpty) return;
    final deviceId = data['deviceId'] as String? ?? 'unknown';
    final deviceName = data['deviceName'] as String? ?? 'Unknown Device';
    final iceList = <Map<String, dynamic>>[];
    final raw = data['iceCandidates'];
    if (raw is List) {
      for (final entry in raw) {
        if (entry is Map) {
          iceList.add(entry.map((key, value) => MapEntry('$key', value)));
        }
      }
    }

    final answer = AudioAnswer(
      deviceId: deviceId,
      deviceName: deviceName,
      senderIp: senderIp,
      sdp: sdp,
      iceCandidates: iceList,
    );

    if (!_audioAnswerController.isClosed) {
      _audioAnswerController.add(answer);
    }

    if (_autoHandleWebRtcAudio) {
      _processIncomingAudioAnswer(answer);
    }
  }

  void _handleAudioIce(Map<String, dynamic> data, String senderIp) {
    final session = _audioSessions[senderIp];
    if (session == null) return;
    final candidateData = data['candidate'];
    if (candidateData is Map) {
      final cand = candidateData['candidate'];
      if (cand is String && cand.isNotEmpty) {
        try {
          session.pc.addCandidate(
            RTCIceCandidate(
              cand,
              (candidateData['sdpMid'] as String?) ?? '',
              (candidateData['sdpMLineIndex'] as int?) ?? 0,
            ),
          );
          print('❄️ [WEB-RTC] Added trickled ICE candidate from $senderIp');
        } catch (e) {
          print('❌ [WEB-RTC] Error adding trickled ICE candidate: $e');
        }
      }
    }
  }

  Future<void> sendAudioIce(String targetIp, RTCIceCandidate candidate) async {
    if (_sockets.isEmpty) return;
    try {
      final message = jsonEncode({
        'type': 'ZAPSHARE_AUDIO_ICE',
        'deviceId': _myDeviceId,
        'deviceName': _myDeviceName,
        'candidate': candidate.toMap(),
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

  // ─── Low-latency WebRTC audio signaling ─────────────────

  Future<void> sendAudioOffer(
    String targetIp, {
    required String sdp,
    required List<Map<String, dynamic>> iceCandidates,
  }) async {
    if (_sockets.isEmpty) {
      print('❌ [Discovery] No sockets available to send AUDIO_OFFER');
      return;
    }
    try {
      final message = jsonEncode({
        'type': 'ZAPSHARE_AUDIO_OFFER',
        'deviceId': _myDeviceId,
        'deviceName': _myDeviceName,
        'sdp': sdp,
        'iceCandidates': iceCandidates,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      });
      final data = utf8.encode(message);
      print('📡 [Discovery] Sending AUDIO_OFFER to $targetIp');
      for (int attempt = 0; attempt < 3; attempt++) {
        for (final socket in _sockets) {
          try {
            socket.send(data, InternetAddress(targetIp), DISCOVERY_PORT);
          } catch (e) {
            print('❌ [Discovery] Failed to send AUDIO_OFFER on socket: $e');
          }
        }
        if (attempt < 2) {
          await Future.delayed(const Duration(milliseconds: 150));
        }
      }
    } catch (e) {
      print('❌ [Discovery] Error in sendAudioOffer: $e');
    }
  }

  Future<void> sendAudioAnswer(
    String targetIp, {
    required String sdp,
    required List<Map<String, dynamic>> iceCandidates,
  }) async {
    if (_sockets.isEmpty) return;
    try {
      final message = jsonEncode({
        'type': 'ZAPSHARE_AUDIO_ANSWER',
        'deviceId': _myDeviceId,
        'deviceName': _myDeviceName,
        'sdp': sdp,
        'iceCandidates': iceCandidates,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      });
      final data = utf8.encode(message);
      for (int attempt = 0; attempt < 3; attempt++) {
        for (final socket in _sockets) {
          try {
            socket.send(data, InternetAddress(targetIp), DISCOVERY_PORT);
          } catch (_) {}
        }
        if (attempt < 2) {
          await Future.delayed(const Duration(milliseconds: 150));
        }
      }
    } catch (_) {}
  }

  // ─── WebRTC audio sessions ──────────────────────────────

  Future<bool> startWebRtcAudio(String targetIp, {bool systemAudio = false}) async {
    debugPrint('🔥 [WEB-RTC] STARTING AUDIO SHARE FOR: $targetIp');

    // Pause background discovery during high-bandwidth audio sessions
    // This dramatically reduces CPU/Network jitter
    pauseDiscovery();

    // Request microphone permission first so foreground service can use it
    if (Platform.isAndroid) {
      await Permission.microphone.request();
    }

    await _initWebRtcAudio();
    if (!_webRtcReady) {
      debugPrint('❌ [WEB-RTC] WebRtc not ready, aborting');
      return false;
    }

    // One session per target IP
    final existingSession = _audioSessions.remove(targetIp);
    if (existingSession != null) {
      await existingSession.dispose();
    }

    try {
      debugPrint('🔥 [WEB-RTC] Creating Peer Connection...');
      final pc = await _createAudioPeer();
      final session = _AudioSession(peerIp: targetIp, isInitiator: true, pc: pc);
      _audioSessions[targetIp] = session;
      _attachAudioHandlers(session);

      MediaStream stream;
      var useSystemAudio = systemAudio;

      // Reuse existing stream if type matches
      if (_currentAudioStream != null && _currentStreamIsSystem == useSystemAudio) {
        stream = _currentAudioStream!;
        debugPrint('🔥 [WEB-RTC] Reusing existing stream');
      } else {
        await _currentAudioStream?.dispose();

        final audioConstraints = {
          'echoCancellation': false,
          'noiseSuppression': false,
          'autoGainControl': false,
        };

        debugPrint('🔥 [WEB-RTC] Requesting MediaStream (Permission Dialog should show)...');
        if (useSystemAudio) {
          if (Platform.isAndroid) {
            await _startAudioForeground();
            // Give the OS a moment to register the foreground service
            await Future.delayed(const Duration(milliseconds: 500));

            stream = await navigator.mediaDevices.getDisplayMedia({
              'audio': audioConstraints,
              'video': true,
            });
            debugPrint('🔥 [WEB-RTC] capture successful, checking for audio track...');
            // CRITICAL: We keep the video track alive but disabled to satisfy
            // Android's MediaProjection requirements, but we WON'T send it.
            for (final track in stream.getVideoTracks()) {
              track.enabled = false;
            }
          } else {
            try {
              stream = await navigator.mediaDevices.getDisplayMedia({
                'audio': audioConstraints,
                'video': false,
              });
            } catch (e) {
              debugPrint('🔥 [WEB-RTC] System audio capture failed, falling back to mic: $e');
              useSystemAudio = false;
              stream = await navigator.mediaDevices.getUserMedia({
                'audio': audioConstraints,
                'video': false,
              });
            }
          }
        } else {
          debugPrint('🔥 [WEB-RTC] Requesting Microphone MediaStream...');
          stream = await navigator.mediaDevices.getUserMedia({
            'audio': audioConstraints,
            'video': false,
          });
          debugPrint('🔥 [WEB-RTC] Microphone capture successful. Tracks: ${stream.getAudioTracks().length}');
        }
        _currentAudioStream = stream;
        _currentStreamIsSystem = useSystemAudio;
      }

      session.localStream = stream;
      debugPrint('🔥 [WEB-RTC] Stream captured. Tracks: ${stream.getTracks().length}');
      bool foundAudio = false;
      for (final track in stream.getTracks()) {
        debugPrint('🔥 [WEB-RTC]   - Checking track: ${track.kind}, id: ${track.id}');

        // ONLY send audio tracks for Audio Share feature
        if (track.kind == 'audio') {
          debugPrint('🔥 [WEB-RTC]     -> Adding AUDIO track to connection');
          await pc.addTrack(track, stream);
          foundAudio = true;
        } else {
          debugPrint('🔥 [WEB-RTC]     -> Skipping non-audio track');
        }
      }

      // Fallback to microphone if system audio capture failed to return an audio track
      if (!foundAudio && systemAudio) {
        debugPrint('🔥 [WEB-RTC] System audio track missing. Falling back to Microphone...');
        try {
          // Dispose the video-only stream since it doesn't have what we need
          for (final track in stream.getTracks()) {
            track.stop();
          }
          await stream.dispose();
        } catch (_) {}

        stream = await navigator.mediaDevices.getUserMedia({
          'audio': {
            'echoCancellation': false,
            'noiseSuppression': false,
            'autoGainControl': false,
          },
          'video': false,
        });

        _currentAudioStream = stream;
        _currentStreamIsSystem = false;
        session.localStream = stream;

        debugPrint('🔥 [WEB-RTC] Fallback stream captured. Tracks: ${stream.getTracks().length}');
        for (final track in stream.getTracks()) {
          debugPrint('🔥 [WEB-RTC]   - Checking fallback track: ${track.kind}, id: ${track.id}');
          if (track.kind == 'audio') {
            debugPrint('🔥 [WEB-RTC]     -> Adding AUDIO track to connection');
            await pc.addTrack(track, stream);
            foundAudio = true;
          }
        }
      }

      if (!foundAudio) {
        throw 'NO AUDIO FOUND: Your device captured the screen but not the audio. \n\n'
              'HINT: When the "Start recording" dialog appears, you MUST look for an "Audio" toggle and select "Device Audio" or "System Audio". If you don\'t see it, try switching to Microphone mode in ZapShare.';
      }

      pc.onIceGatheringState = (state) async {
        debugPrint('🔥 [WEB-RTC] ICE State: $state');
        if (state == RTCIceGatheringState.RTCIceGatheringStateComplete && !session.offerSent) {
          session.offerSent = true;
          debugPrint('🔥 [WEB-RTC] Gathering complete, sending offer');
          await _sendAudioOfferPayload(targetIp, session);
        }
      };

      debugPrint('🔥 [WEB-RTC] Creating SDP Offer...');
      RTCSessionDescription offer = await pc.createOffer({'offerToReceiveAudio': true});

      // MUNGE SDP for 10ms latency (Standard is 20ms)
      String mungedSdp = _mungeAudioSdp(offer.sdp ?? '');
      offer = RTCSessionDescription(mungedSdp, offer.type);

      debugPrint('🔥 [WEB-RTC] Setting Local Description (Munged for Low Latency)...');
      await pc.setLocalDescription(offer);
      debugPrint('🔥 [WEB-RTC] Local Description DONE');

      // Send offer immediately for dynamic trickle ICE
      session.offerSent = true;
      await _sendAudioOfferPayload(targetIp, session);

      // Heavy backup: If no offer sent in 1.5s, force it
      Future.delayed(const Duration(milliseconds: 1500), () async {
        if (!session.closed && !session.offerSent) {
          debugPrint('🔥 [WEB-RTC] TIMEOUT: Forcing offer send to $targetIp');
          session.offerSent = true;
          await _sendAudioOfferPayload(targetIp, session);
        }
      });

      await _startAudioForeground();
      _audioActiveController.add(true);
      return true;
    } catch (e) {
      print('❌ startWebRtcAudio failed: $e');
      await stopWebRtcAudio(targetIp);
      return false;
    }
  }

  Future<void> stopWebRtcAudio([String? targetIp, bool notifyPeer = true]) async {
    if (targetIp != null) {
      // 1. Notify peer to stop their side too (Signaling)
      if (notifyPeer) {
        print('📡 [Discovery] Sending AUDIO_STOP signal to $targetIp');
        await _sendAudioStopSignal(targetIp);
      }

      final session = _audioSessions.remove(targetIp);
      await session?.dispose();
      _audioActiveController.add(_audioSessions.isNotEmpty);
      if (_audioSessions.isEmpty) {
        resumeDiscovery();
        await _stopAudioForeground();
        await _currentAudioStream?.dispose();
        _currentAudioStream = null;
        _currentStreamIsSystem = null;
        try {
          _audioRenderer?.srcObject = null;
        } catch (_) {}
      }
      return;
    }

    // Global stop
    final sessions = _audioSessions.values.toList();
    for (final s in sessions) {
      if (notifyPeer) {
        await _sendAudioStopSignal(s.peerIp);
      }
    }

    _audioSessions.clear();
    for (final s in sessions) {
      await s.dispose();
    }
    await _currentAudioStream?.dispose();
    _currentAudioStream = null;
    _currentStreamIsSystem = null;
    try {
      _audioRenderer?.srcObject = null;
    } catch (_) {}
    _audioActiveController.add(false);
    await _stopAudioForeground();
    resumeDiscovery();
  }

  Future<void> _sendAudioStopSignal(String targetIp) async {
    if (_sockets.isEmpty) return;
    try {
      final payload = {
        'type': 'ZAPSHARE_AUDIO_STOP',
        'deviceId': _myDeviceId,
        'senderIp': await _getCurrentIpAddress(),
      };
      final msg = utf8.encode(jsonEncode(payload));
      for (final s in _sockets) {
        try {
          s.send(msg, InternetAddress(targetIp), DISCOVERY_PORT);
        } catch (_) {}
      }
    } catch (_) {}
  }

  Future<void> sendNativeSystemAudioOffer(String targetIp, int port, {int cushionMs = 20}) async {
    print('🔥 [AudioShare] Sending LAN Audio Offer to $targetIp on port $port');
    
    // NOTE: We no longer call pauseDiscovery() here.
    // Pausing discovery was preventing the receiving device from seeing our 
    // broadcasts, causing the 'I see device but clicking does nothing' bug.

    final payload = {
      'type': 'ZAPSHARE_AUDIO_OFFER',
      'deviceId': _myDeviceId,
      'deviceName': _myDeviceName,
      'sdp': 'LAN_AUDIO_STREAM_PORT:$port;cushion=$cushionMs', // Special flag for new LAN audio
    };
    final msgData = utf8.encode(jsonEncode(payload));
    
    // CRITICAL FIX: Send the offer multiple times with spacing.
    // UDP is unreliable, and the receiving device may be mid-socket-rebind
    // after a role swap (resumeDiscovery -> start -> stop -> start).
    // A single packet was being silently dropped, causing the dialog to never appear.
    for (int attempt = 0; attempt < 3; attempt++) {
      for (final socket in _sockets) {
        try {
          socket.send(msgData, InternetAddress(targetIp), DISCOVERY_PORT);
        } catch (e) {
          print('⚠️  Error sending over a socket: $e');
        }
      }
      if (attempt < 2) {
        await Future.delayed(const Duration(milliseconds: 300));
      }
    }
    print('✅ [AudioShare] LAN Audio Offer sent (3 attempts) to $targetIp');
  }

  Future<RTCPeerConnection> _createAudioPeer() async {
    final config = {
      'iceServers': [
        {'urls': ['stun:stun.l.google.com:19302']},
      ],
    };
    final constraints = {
      'mandatory': {},
      'optional': [
        {'DtlsSrtpKeyAgreement': true},
      ],
    };
    return await createPeerConnection(config, constraints);
  }

  void _attachAudioHandlers(_AudioSession session) {
    final pc = session.pc;
    pc.onIceCandidate = (candidate) {
      if (candidate == null) {
        print('❄️ [WEB-RTC] ICE Candidate gathering complete for ${session.peerIp}');
        return;
      }
      print('❄️ [WEB-RTC] Generated ICE candidate: ${candidate.candidate}');
      session.iceCandidates.add(candidate.toMap());
      sendAudioIce(session.peerIp, candidate);
    };

    pc.onTrack = (event) async {
      final track = event.track;
      debugPrint('🔊 [WEB-RTC] onTrack event: kind=${track.kind}, id=${track.id}, label=${track.label}');
      
      if (track.kind != 'audio') {
        debugPrint('⏭️ [WEB-RTC] Ignoring non-audio track of kind: ${track.kind}');
        return;
      }
      if (event.streams.isEmpty) {
        debugPrint('⚠️ [WEB-RTC] Audio track received but event.streams is empty!');
        return;
      }
      
      session.remoteStream = event.streams.first;
      debugPrint('🎧 [WEB-RTC] Stream received. Tracks count: ${session.remoteStream?.getTracks().length}');
      await _initWebRtcAudio();
      
      try {
        debugPrint('🎧 [WEB-RTC] Attaching remote stream to _audioRenderer...');
        _audioRenderer?.srcObject = session.remoteStream;
        await _audioRenderer?.setVolume(1.0);
        debugPrint('✅ [WEB-RTC] Stream attached and volume set to 1.0');
        
        // Start foreground service on receiver end too
        await _startAudioForeground();
        _audioActiveController.add(true);

        if (Platform.isAndroid) {
          debugPrint('📱 [WEB-RTC] Forcing speaker ON for Android');
          const MethodChannel('zapshare.saf').invokeMethod('setSpeakerOn', {'enabled': true});
        }
      } catch (e) {
        debugPrint('❌ [WEB-RTC] Error attaching remote audio stream: $e');
      }
    };

    // Fallback for older onAddStream callback
    pc.onAddStream = (stream) async {
      debugPrint('🔊 [WEB-RTC] onAddStream event: streamId=${stream.id}');
      session.remoteStream = stream;
      await _initWebRtcAudio();
      try {
        _audioRenderer?.srcObject = stream;
        debugPrint('✅ [WEB-RTC] onAddStream: Stream attached to _audioRenderer');
      } catch (e) {
        debugPrint('❌ [WEB-RTC] onAddStream error: $e');
      }
    };

    pc.onConnectionState = (state) async {
      print('🔥 [WEB-RTC] PeerConnection State changed: $state for ${session.peerIp}');
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
        print('🚨 [WEB-RTC] Connection lost or closed. Stopping audio sharing...');
        await stopWebRtcAudio(session.peerIp, false);
      }
    };

    pc.onIceConnectionState = (state) async {
      print('❄️ [WEB-RTC] ICE Connection State changed: $state for ${session.peerIp}');
    };

    pc.onSignalingState = (state) async {
      print('📣 [WEB-RTC] Signaling State changed: $state for ${session.peerIp}');
    };
  }

  Future<void> _sendAudioOfferPayload(String targetIp, _AudioSession session) async {
    final desc = await session.pc.getLocalDescription();
    if (desc == null) {
      print('❌ [Discovery] Failed to get LocalDescription for offer');
      return;
    }
    print('📡 [Discovery] Preparing AUDIO_OFFER payload for $targetIp. SDP length: ${desc.sdp?.length}');
    await sendAudioOffer(
      targetIp,
      sdp: desc.sdp ?? '',
      iceCandidates: List<Map<String, dynamic>>.from(session.iceCandidates),
    );
  }

  Future<void> _sendAudioAnswerPayload(String targetIp, _AudioSession session) async {
    final desc = await session.pc.getLocalDescription();
    if (desc == null) {
      print('❌ [Discovery] Failed to get LocalDescription for answer');
      return;
    }
    print('📡 [Discovery] Preparing AUDIO_ANSWER payload for $targetIp. SDP length: ${desc.sdp?.length}');
    await sendAudioAnswer(
      targetIp,
      sdp: desc.sdp ?? '',
      iceCandidates: List<Map<String, dynamic>>.from(session.iceCandidates),
    );
  }

  Future<void> processIncomingAudioOffer(AudioOffer offer) async {
    if (offer.sdp.startsWith('LAN_AUDIO_STREAM_PORT:')) {
      print('ℹ️ [WEB-RTC] Ignoring LAN Audio offer in WebRTC handler');
      return;
    }

    await _initWebRtcAudio();
    if (!_webRtcReady) return;

    // Tear down any previous session from this sender
    await stopWebRtcAudio(offer.senderIp, false);

    try {
      final pc = await _createAudioPeer();
      final session = _AudioSession(peerIp: offer.senderIp, isInitiator: false, pc: pc);
      _audioSessions[offer.senderIp] = session;
      _attachAudioHandlers(session);

      // MUNGE SDP for 10ms latency (Standard is 20ms)
      String mungedSdp = _mungeAudioSdp(offer.sdp);
      await pc.setRemoteDescription(RTCSessionDescription(mungedSdp, 'offer'));
      // Add remote ICE from offer
      for (final ice in offer.iceCandidates) {
        final cand = ice['candidate'];
        if (cand is String && cand.isNotEmpty) {
          try {
            await pc.addCandidate(
              RTCIceCandidate(
                cand,
                (ice['sdpMid'] as String?) ?? '',
                (ice['sdpMLineIndex'] as int?) ?? 0,
              ),
            );
          } catch (_) {}
        }
      }

      pc.onIceGatheringState = (state) async {
        debugPrint('🔥 [WEB-RTC] Responder ICE State: $state');
        if (state == RTCIceGatheringState.RTCIceGatheringStateComplete && !session.offerSent) {
          session.offerSent = true;
          await _sendAudioAnswerPayload(offer.senderIp, session);
        }
      };

      final answer = await pc.createAnswer({'offerToReceiveAudio': true});
      await pc.setLocalDescription(answer);

      // Send answer immediately for dynamic trickle ICE
      session.offerSent = true;
      await _sendAudioAnswerPayload(offer.senderIp, session);

      // Answer fallback
      Future.delayed(const Duration(milliseconds: 1500), () async {
        if (!session.offerSent) {
          debugPrint('🔥 [WEB-RTC] Responder TIMEOUT: Forcing answer send');
          session.offerSent = true;
          await _sendAudioAnswerPayload(offer.senderIp, session);
        }
      });
      await _startAudioForeground();
    } catch (e) {
      print('❌ Failed to process audio offer: $e');
      await stopWebRtcAudio(offer.senderIp);
    }
  }

  Future<void> _processIncomingAudioAnswer(AudioAnswer answer) async {
    final session = _audioSessions[answer.senderIp];
    if (session == null) return;
    try {
      // Check state to avoid "Called in wrong state: stable" error
      final state = session.pc.signalingState;
      if (state != RTCSignalingState.RTCSignalingStateHaveLocalOffer) {
        debugPrint('⏭️ [WEB-RTC] Ignoring redundant audio answer (State: $state)');
        return;
      }

      await session.pc.setRemoteDescription(
        RTCSessionDescription(answer.sdp, 'answer'),
      );
      for (final ice in answer.iceCandidates) {
        final cand = ice['candidate'];
        if (cand is String && cand.isNotEmpty) {
          try {
            await session.pc.addCandidate(
              RTCIceCandidate(
                cand,
                (ice['sdpMid'] as String?) ?? '',
                (ice['sdpMLineIndex'] as int?) ?? 0,
              ),
            );
          } catch (_) {}
        }
      }
    } catch (e) {
      print('❌ Failed to apply audio answer: $e');
      await stopWebRtcAudio(answer.senderIp);
    }
  }

  // ─── Screen Mirror Protocol ────────────────────────────────

  /// Send screen mirror request to a target device (e.g., Windows)
  Future<void> sendScreenMirrorRequest(
    String targetIp,
    String streamUrl, {
    double? width,
    double? height,
  }) async {
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
        'width': width,
        'height': height,
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
          width: (data['width'] as num?)?.toDouble(),
          height: (data['height'] as num?)?.toDouble(),
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

  /// Deduplication for screen mirror control messages
  final Set<String> _recentControlMessageIds = {};

  void _handleScreenMirrorControl(Map<String, dynamic> data, String senderIp) {
    final action = data['action'] as String?;
    if (action == null) return;

    final deviceId = data['deviceId'] as String?;
    final timestamp = data['timestamp'] as int?;

    if (deviceId != null && timestamp != null) {
      final messageId = '${deviceId}_${action}_$timestamp';
      if (_recentControlMessageIds.contains(messageId)) {
        // Skip duplicate command (caused by broadcasting over multiple Windows network interfaces)
        return;
      }
      _recentControlMessageIds.add(messageId);
      if (_recentControlMessageIds.length > 50) {
        _recentControlMessageIds.remove(_recentControlMessageIds.first);
      }
    }

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
      // PRO-QUICK: Remove non-favorites not seen in 20 seconds for seamless UI
      if (!device.isFavorite &&
          device.discoveryMethod != DiscoveryMethod.wifiDirect &&
          now.difference(device.lastSeen).inSeconds > 20) {
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

  DateTime? _lastRestartAttempt;

  void _handleSocketClosed() {
    // Don't restart if stop() was called intentionally
    if (_isStopping || !_isRunning) return;

    // Rate-limit restarts during playback or high-load
    if (_lastRestartAttempt != null &&
        DateTime.now().difference(_lastRestartAttempt!).inSeconds < 10) {
      print('⏭️  Discovery restart rate-limited (cooldown active)');
      return;
    }

    print('⚠️  Socket closed unexpectedly');
    if (_isRestarting) {
      print('⏭️  Restart already in progress, skipping...');
      return;
    }

    _isRestarting = true;
    _lastRestartAttempt = DateTime.now();
    // Try to restart
    Future.delayed(Duration(seconds: 5), () async {
      if (_isRunning && !_isStopping) {
        if (!_isPaused) {
           print('🔄 Attempting to restart after socket closure...');
        }
        try {
          await stop();
          await start();
          if (!_isPaused) print('✅ Restart successful');
        } catch (e) {
          if (!_isPaused) print('❌ Restart failed: $e');
        } finally {
          _isRestarting = false;
        }
      } else {
        _isRestarting = false;
      }
    });
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

  Future<void> stop({bool notifyPeers = false}) async {
    _isStopping = true; // Prevent socket-closed handlers from restarting
    _isRunning = false;
    _broadcastTimer?.cancel();
    _cleanupTimer?.cancel();
    _keepAliveTimer?.cancel();
    _multicastRenewTimer?.cancel();
    _stopTcpControlServer();

    // Only notify peers if we're actually closing (dispose), not on internal restart
    if (notifyPeers) {
      try {
        final byeMsg = jsonEncode({
          'type': 'ZAPSHARE_BYE',
          'deviceId': _myDeviceId,
        });
        final byeData = utf8.encode(byeMsg);
        for (final socket in _sockets) {
          try {
            socket.send(byeData, InternetAddress('255.255.255.255'), DISCOVERY_PORT);
          } catch (_) {}
        }
      } catch (_) {}
    }

    try {
      // Cancel all socket subscriptions first
      for (final sub in _socketSubscriptions) {
        try {
          sub.cancel();
        } catch (_) {}
      }
      _socketSubscriptions.clear();

      // Close all sockets
      for (final socket in _sockets) {
        socket.close();
      }
      _sockets.clear();
      _networkInterfaces.clear();
    } catch (e) {
      print('Error closing sockets: $e');
    }

    // Explicitly kill any remaining audio foreground bits
    await _stopAudioForeground();
    // NOTE: We intentionally do NOT call stopLanAudioReceiver() here.
    // stop() is called during resumeDiscovery() which happens during role swaps.
    // Killing the receiver here was the root cause of jitter during vice-versa.
    // Receiver cleanup is done explicitly by screen dispose() or stopLanAudioReceiver().

    // Only clear devices if we are truly stopping (final disposal)
    if (notifyPeers) {
      _discoveredDevices.removeWhere((id, device) => !device.isFavorite);
    }
    _lastCastStatusTcpSentAt.clear();
    _lastCastTracksSentAt.clear();
    _lastCastTrackSignature.clear();
    _notifyListeners();

    print('Device discovery stopped');
    _isStopping = false; // Reset for future start()
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

  /// Start a TCP server to receive reliable cast control commands.
  /// This is a fallback for when UDP is congested during large file streaming.
  void _startTcpControlServer() {
    _stopTcpControlServer();
    const tcpControlPort = 53218;
    ServerSocket.bind(InternetAddress.anyIPv4, tcpControlPort, shared: true)
        .then((server) {
      _tcpControlServer = server;
      print('✅ TCP cast control server listening on port $tcpControlPort');
      server.listen(
        (Socket client) {
          final buffer = StringBuffer();
          client.listen(
            (data) {
              buffer.write(utf8.decode(data));
              // Try to parse the accumulated buffer as JSON
              try {
                final message = buffer.toString().trim();
                if (message.isEmpty) return;
                final parsed = jsonDecode(message) as Map<String, dynamic>;
                final type = parsed['type'] as String?;
                final senderIp = client.remoteAddress.address;
                if (type == 'ZAPSHARE_CAST_CONTROL') {
                  print('📡 [TCP] Received cast control from $senderIp');
                  _handleCastControl(parsed, senderIp);
                } else if (type == 'ZAPSHARE_CAST_STATUS') {
                  _handleCastStatus(parsed, senderIp);
                }
              } catch (_) {
                // Incomplete JSON, wait for more data
              }
            },
            onDone: () => client.destroy(),
            onError: (_) => client.destroy(),
            cancelOnError: true,
          );
        },
        onError: (e) {
          print('⚠️  TCP control server error: $e');
        },
        cancelOnError: false,
      );
    }).catchError((e) {
      print('⚠️  Could not start TCP control server: $e');
    });
  }

  void _stopTcpControlServer() {
    try {
      _tcpControlServer?.close();
      _tcpControlServer = null;
    } catch (_) {}
  }

  void dispose() {
    stop(notifyPeers: true);
    // Do NOT close controllers as this is a singleton service
    // _devicesController.close();
    // _connectionRequestController.close();
    // _connectionResponseController.close();
    // _castRequestController.close();
  }

  String _mungeAudioSdp(String sdp) {
    if (sdp.isEmpty) return sdp;
    String newSdp = sdp;
    
    // Using standard 20ms frames for optimized network performance on Wi-Fi.
    if (newSdp.contains('useinbandfec=1')) {
      newSdp = newSdp.replaceAll(
        'useinbandfec=1', 
        'useinbandfec=1; ptime=20; minptime=20; maxaveragebitrate=128000; stereo=1'
      );
    } else {
      final regExp = RegExp(r'a=fmtp:(\d+) (.+)');
      newSdp = newSdp.replaceAllMapped(regExp, (match) {
        if (match.group(2)!.contains('opus')) {
          return '${match.group(0)}; ptime=20; minptime=20; maxaveragebitrate=128000; stereo=1';
        }
        return match.group(0)!;
      });
    }
    return newSdp;
  }
}
