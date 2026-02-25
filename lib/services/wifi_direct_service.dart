import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';

/// Wi-Fi Direct Peer Model
class WiFiDirectPeer {
  final String deviceName;
  final String deviceAddress;
  final int status;
  final bool isGroupOwner;
  final String primaryDeviceType;
  final String secondaryDeviceType;

  WiFiDirectPeer({
    required this.deviceName,
    required this.deviceAddress,
    required this.status,
    required this.isGroupOwner,
    required this.primaryDeviceType,
    required this.secondaryDeviceType,
  });

  factory WiFiDirectPeer.fromMap(Map<dynamic, dynamic> map) {
    return WiFiDirectPeer(
      deviceName: map['deviceName'] as String? ?? 'Unknown Device',
      deviceAddress: map['deviceAddress'] as String? ?? '',
      status: map['status'] as int? ?? 0,
      isGroupOwner: map['isGroupOwner'] as bool? ?? false,
      primaryDeviceType: map['primaryDeviceType'] as String? ?? '',
      secondaryDeviceType: map['secondaryDeviceType'] as String? ?? '',
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'deviceName': deviceName,
      'deviceAddress': deviceAddress,
      'status': status,
      'isGroupOwner': isGroupOwner,
      'primaryDeviceType': primaryDeviceType,
      'secondaryDeviceType': secondaryDeviceType,
    };
  }
}

/// Wi-Fi Direct group information
class WiFiDirectGroupInfo {
  final String? ssid;
  final String? password;
  final String? ownerAddress;
  final bool isGroupOwner;
  final int? networkId;
  final String? interface;

  WiFiDirectGroupInfo({
    this.ssid,
    this.password,
    this.ownerAddress,
    this.isGroupOwner = false,
    this.networkId,
    this.interface,
  });

  factory WiFiDirectGroupInfo.fromMap(Map<String, dynamic> map) {
    return WiFiDirectGroupInfo(
      ssid: map['ssid'] as String?,
      password: map['password'] as String?,
      ownerAddress: map['ownerAddress'] as String?,
      isGroupOwner: map['isGroupOwner'] as bool? ?? false,
      networkId: map['networkId'] as int?,
      interface: map['interface'] as String?,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'ssid': ssid,
      'password': password,
      'ownerAddress': ownerAddress,
      'isGroupOwner': isGroupOwner,
      'networkId': networkId,
      'interface': interface,
    };
  }

  @override
  String toString() {
    return 'WiFiDirectGroupInfo(ssid: $ssid, password: ***, ownerAddress: $ownerAddress, isGroupOwner: $isGroupOwner)';
  }
}

/// Wi-Fi Direct Connection Info Model
class WiFiDirectConnectionInfo {
  final bool groupFormed;
  final bool isGroupOwner;
  final String groupOwnerAddress;

  WiFiDirectConnectionInfo({
    required this.groupFormed,
    required this.isGroupOwner,
    required this.groupOwnerAddress,
  });

  factory WiFiDirectConnectionInfo.fromMap(Map<dynamic, dynamic> map) {
    return WiFiDirectConnectionInfo(
      groupFormed: map['groupFormed'] as bool? ?? false,
      isGroupOwner: map['isGroupOwner'] as bool? ?? false,
      groupOwnerAddress: map['groupOwnerAddress'] as String? ?? '',
    );
  }
}

/// Custom Wi-Fi Direct service that uses platform channels to directly
/// access Android's WifiP2pManager API for peer discovery and creating
/// non-persistent groups.
///
/// This uses manager.connect() instead of manager.createGroup() to avoid
/// persistent groups being saved in Android settings.
class WiFiDirectService {
  static const MethodChannel _channel = MethodChannel('zapshare.wifi_direct');

  static final WiFiDirectService _instance = WiFiDirectService._internal();

  factory WiFiDirectService() {
    return _instance;
  }

  WiFiDirectService._internal() {
    _setupMethodCallHandler();
  }

  // Group info
  String? _groupSsid;
  String? _groupPassword;
  String? _groupOwnerAddress;
  bool _isGroupOwner = false;
  bool _isGroupCreated = false;
  bool _isInitialized = false;
  bool _isDiscovering = false;
  bool _isWifiP2pEnabled = false;

  // Discovered peers
  List<WiFiDirectPeer> _discoveredPeers = [];

  // Stream controllers
  final StreamController<WiFiDirectGroupInfo> _groupInfoController =
      StreamController<WiFiDirectGroupInfo>.broadcast();
  final StreamController<List<WiFiDirectPeer>> _peersController =
      StreamController<List<WiFiDirectPeer>>.broadcast();
  final StreamController<WiFiDirectConnectionInfo> _connectionInfoController =
      StreamController<WiFiDirectConnectionInfo>.broadcast();
  final StreamController<bool> _wifiP2pStateController =
      StreamController<bool>.broadcast();
  final StreamController<Map<String, dynamic>> _connectionFailedController =
      StreamController<Map<String, dynamic>>.broadcast();

  // Streams
  Stream<WiFiDirectGroupInfo> get groupInfoStream =>
      _groupInfoController.stream;
  Stream<List<WiFiDirectPeer>> get peersStream => _peersController.stream;
  Stream<WiFiDirectConnectionInfo> get connectionInfoStream =>
      _connectionInfoController.stream;
  Stream<bool> get wifiP2pStateStream => _wifiP2pStateController.stream;
  Stream<Map<String, dynamic>> get connectionFailedStream =>
      _connectionFailedController.stream;

  // Getters
  WiFiDirectGroupInfo? get currentGroupInfo {
    if (!_isGroupCreated) return null;
    return WiFiDirectGroupInfo(
      ssid: _groupSsid,
      password: _groupPassword,
      ownerAddress: _groupOwnerAddress,
      isGroupOwner: _isGroupOwner,
    );
  }

  List<WiFiDirectPeer> get discoveredPeers => _discoveredPeers;
  bool get isInitialized => _isInitialized;
  bool get isDiscovering => _isDiscovering;
  bool get isWifiP2pEnabled => _isWifiP2pEnabled;

  /// Setup method call handler for callbacks from native code
  void _setupMethodCallHandler() {
    _channel.setMethodCallHandler((call) async {
      print('📱 WiFiDirectService received: ${call.method}');

      switch (call.method) {
        case 'onPeersDiscovered':
          _handlePeersDiscovered(call.arguments);
          break;
        case 'onGroupInfoAvailable':
          _handleGroupInfoAvailable(call.arguments);
          break;
        case 'onConnectionInfoAvailable':
          _handleConnectionInfoAvailable(call.arguments);
          break;
        case 'onWifiP2pStateChanged':
          _handleWifiP2pStateChanged(call.arguments);
          break;
        case 'onConnectionFailed':
          _handleConnectionFailed(call.arguments);
          break;
        case 'onGroupRemoved':
          _handleGroupRemoved();
          break;
        case 'onThisDeviceChanged':
          _handleThisDeviceChanged(call.arguments);
          break;
        default:
          print('⚠️  Unknown method: ${call.method}');
      }
    });
  }

  /// Initialize the Wi-Fi Direct service
  Future<bool> initialize() async {
    if (!Platform.isAndroid) {
      print('⚠️ Wi-Fi Direct is only supported on Android');
      return false;
    }

    try {
      print('🔧 Initializing Wi-Fi Direct...');
      final result = await _channel.invokeMethod<bool>('initialize');
      _isInitialized = result ?? false;
      print('✅ Wi-Fi Direct initialized: $_isInitialized');
      return _isInitialized;
    } catch (e) {
      print('❌ Error initializing Wi-Fi Direct: $e');
      return false;
    }
  }

  /// Start discovering Wi-Fi Direct peers
  Future<bool> startPeerDiscovery() async {
    if (!Platform.isAndroid) {
      return false;
    }

    if (!_isInitialized) {
      print('⚠️  Wi-Fi Direct not initialized');
      return false;
    }

    try {
      print('🔍 Starting peer discovery...');
      final result = await _channel.invokeMethod<bool>('startPeerDiscovery');
      _isDiscovering = result ?? false;
      print('✅ Peer discovery started: $_isDiscovering');
      return _isDiscovering;
    } catch (e) {
      print('❌ Error starting peer discovery: $e');
      return false;
    }
  }

  /// Stop discovering Wi-Fi Direct peers
  Future<bool> stopPeerDiscovery() async {
    if (!Platform.isAndroid) {
      return false;
    }

    try {
      print('🛑 Stopping peer discovery...');
      final result = await _channel.invokeMethod<bool>('stopPeerDiscovery');
      _isDiscovering = false;
      // Clear discovered peers when stopping discovery
      _discoveredPeers = [];
      _peersController.add(_discoveredPeers);
      print('✅ Peer discovery stopped, peers cleared');
      return result ?? false;
    } catch (e) {
      print('❌ Error stopping peer discovery: $e');
      return false;
    }
  }

  /// Create a Wi-Fi Direct Group (act as Hotspot/GO)
  /// Uses automatic band selection for best compatibility across devices
  Future<bool> createGroup() async {
    if (!Platform.isAndroid) {
      return false;
    }

    if (!_isInitialized) {
      print('⚠️  Wi-Fi Direct not initialized');
      return false;
    }

    try {
      print('🌐 Creating Wi-Fi Direct Group (Auto Band)...');
      final result = await _channel.invokeMethod<bool>('createGroup');
      _isGroupCreated = result ?? false;
      print('✅ Group creation initiated: $_isGroupCreated');
      return _isGroupCreated;
    } catch (e) {
      print('❌ Error creating Wi-Fi Direct group: $e');
      return false;
    }
  }

  /// Connect to a Wi-Fi Direct peer using non-persistent group
  ///
  /// [deviceAddress] - MAC address of the peer device
  /// [isGroupOwner] - Whether this device should prefer being the group owner
  ///   - false (default): Let Android auto-negotiate based on device capabilities
  ///   - true: Strongly prefer this device as group owner
  Future<bool> connectToPeer(
    String deviceAddress, {
    bool isGroupOwner = false,
  }) async {
    if (!Platform.isAndroid) {
      return false;
    }

    if (!_isInitialized) {
      print('⚠️  Wi-Fi Direct not initialized');
      return false;
    }

    try {
      print(
        '🔗 Connecting to peer: $deviceAddress (as ${isGroupOwner ? "Group Owner" : "Client"})',
      );
      final result = await _channel.invokeMethod<bool>('connectToPeer', {
        'deviceAddress': deviceAddress,
        'isGroupOwner': isGroupOwner,
      });
      print('✅ Connection initiated: ${result ?? false}');
      return result ?? false;
    } catch (e) {
      print('❌ Error connecting to peer: $e');
      return false;
    }
  }

  /// Get list of discovered peers
  Future<List<WiFiDirectPeer>> getDiscoveredPeers() async {
    if (!Platform.isAndroid) {
      return [];
    }

    try {
      final result = await _channel.invokeMethod<List>('getDiscoveredPeers');
      if (result != null) {
        _discoveredPeers =
            result.map((peer) => WiFiDirectPeer.fromMap(peer as Map)).toList();
        return _discoveredPeers;
      }
      return [];
    } catch (e) {
      print('❌ Error getting discovered peers: $e');
      return [];
    }
  }

  /// Remove the Wi-Fi Direct group
  Future<bool> removeGroup() async {
    if (!Platform.isAndroid) {
      return false;
    }

    try {
      print('🗑️  Removing Wi-Fi Direct group...');
      final result = await _channel.invokeMethod<bool>('removeGroup');

      if (result == true) {
        print('✅ Wi-Fi Direct group removed');
        _isGroupCreated = false;
        _groupSsid = null;
        _groupPassword = null;
        _groupOwnerAddress = null;
        _isGroupOwner = false;
        return true;
      } else {
        print('❌ Failed to remove Wi-Fi Direct group');
        return false;
      }
    } catch (e) {
      print('❌ Error removing Wi-Fi Direct group: $e');
      return false;
    }
  }

  /// Request group info (SSID, password, etc.)
  Future<WiFiDirectGroupInfo?> requestGroupInfo() async {
    if (!Platform.isAndroid) {
      return null;
    }

    try {
      print('📡 Requesting group info...');
      await _channel.invokeMethod('requestGroupInfo');
      // Result will be sent via callback
      return null;
    } catch (e) {
      print('❌ Error requesting group info: $e');
      return null;
    }
  }

  /// Disconnect from current Wi-Fi Direct group
  Future<bool> disconnect() async {
    if (!Platform.isAndroid) {
      return false;
    }

    try {
      print('🔌 Disconnecting from Wi-Fi Direct...');
      final result = await _channel.invokeMethod<bool>('disconnect');
      print('✅ Disconnected: ${result ?? false}');
      return result ?? false;
    } catch (e) {
      print('❌ Error disconnecting: $e');
      return false;
    }
  }

  /// Check if Wi-Fi Direct is enabled
  Future<bool> isWifiP2pEnabledCheck() async {
    if (!Platform.isAndroid) {
      return false;
    }

    try {
      final result = await _channel.invokeMethod<bool>('isWifiP2pEnabled');
      _isWifiP2pEnabled = result ?? false;
      return _isWifiP2pEnabled;
    } catch (e) {
      print('❌ Error checking Wi-Fi P2P status: $e');
      return false;
    }
  }

  // Event handlers

  void _handlePeersDiscovered(dynamic arguments) {
    try {
      final Map<dynamic, dynamic> data = arguments as Map;
      final List peers = data['peers'] as List? ?? [];

      _discoveredPeers =
          peers.map((peer) => WiFiDirectPeer.fromMap(peer as Map)).toList();

      print('📡 Discovered ${_discoveredPeers.length} Wi-Fi Direct peers');
      _peersController.add(_discoveredPeers);
    } catch (e) {
      print('❌ Error handling peers discovered: $e');
    }
  }

  void _handleGroupInfoAvailable(dynamic arguments) {
    try {
      if (arguments is Map) {
        final info = WiFiDirectGroupInfo.fromMap(
          Map<String, dynamic>.from(arguments),
        );

        _groupSsid = info.ssid;
        _groupPassword = info.password;
        _groupOwnerAddress = info.ownerAddress;
        _isGroupOwner = info.isGroupOwner;
        _isGroupCreated = true;

        print('📡 Group info callback received:');
        print('   SSID: ${info.ssid}');
        print('   Password: ${info.password}');
        print('   Owner Address: ${info.ownerAddress}');
        print('   Is Group Owner: ${info.isGroupOwner}');

        _groupInfoController.add(info);
      }
    } catch (e) {
      print('❌ Error handling group info: $e');
    }
  }

  void _handleConnectionInfoAvailable(dynamic arguments) {
    try {
      final Map<dynamic, dynamic> data = arguments as Map;
      final connectionInfo = WiFiDirectConnectionInfo.fromMap(data);

      print('📡 Connection info available:');
      print('   Group Formed: ${connectionInfo.groupFormed}');
      print('   Is Group Owner: ${connectionInfo.isGroupOwner}');
      print('   Group Owner Address: ${connectionInfo.groupOwnerAddress}');

      // Update group owner address
      _groupOwnerAddress = connectionInfo.groupOwnerAddress;
      _isGroupOwner = connectionInfo.isGroupOwner;

      _connectionInfoController.add(connectionInfo);

      // Don't request group info here - it causes a callback cascade
      // Group info will be requested by the Kotlin side or explicitly when needed
    } catch (e) {
      print('❌ Error handling connection info: $e');
    }
  }

  void _handleWifiP2pStateChanged(dynamic arguments) {
    try {
      final Map<dynamic, dynamic> data = arguments as Map;
      _isWifiP2pEnabled = data['enabled'] as bool? ?? false;

      print(
        '📡 Wi-Fi P2P state changed: ${_isWifiP2pEnabled ? "ENABLED" : "DISABLED"}',
      );
      _wifiP2pStateController.add(_isWifiP2pEnabled);
    } catch (e) {
      print('❌ Error handling Wi-Fi P2P state change: $e');
    }
  }

  void _handleConnectionFailed(dynamic arguments) {
    try {
      final Map<dynamic, dynamic> data = arguments as Map;
      print('❌ Connection failed:');
      print('   Device: ${data['deviceAddress']}');
      print('   Reason: ${data['reason']}');

      _connectionFailedController.add({
        'deviceAddress': data['deviceAddress'] as String,
        'reason': data['reason'] as String,
      });
    } catch (e) {
      print('❌ Error handling connection failed: $e');
    }
  }

  void _handleGroupRemoved() {
    print('📡 Group removed callback received');
    _isGroupCreated = false;
    _groupSsid = null;
    _groupPassword = null;
    _groupOwnerAddress = null;
    _isGroupOwner = false;
  }

  void _handleThisDeviceChanged(dynamic arguments) {
    try {
      final Map<dynamic, dynamic> data = arguments as Map;
      print('📡 This device changed:');
      print('   Name: ${data['deviceName']}');
      print('   Address: ${data['deviceAddress']}');
      print('   Status: ${data['status']}');
    } catch (e) {
      print('❌ Error handling this device changed: $e');
    }
  }

  void dispose() {
    _groupInfoController.close();
    _peersController.close();
    _connectionInfoController.close();
    _wifiP2pStateController.close();
    _connectionFailedController.close();
  }
}
