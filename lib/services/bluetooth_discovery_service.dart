import 'dart:async';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

/// BLE-based discovery for ZapShare devices.
///
/// Uses a custom ZapShare BLE service UUID so **only** devices with ZapShare open
/// are visible.  Also provides GATT-based credential exchange:
///   • Sender stores hotspot SSID+password → GATT server → receiver reads them
///   • This eliminates the need for manual pairing or QR codes
class BluetoothDiscoveryService {
  static const String SERVICE_UUID = '0000face-0000-1000-8000-00805f9b34fb';

  static const MethodChannel _channel =
      MethodChannel('zapshare.bluetooth_discovery');

  final Map<String, DiscoveredBluetoothDevice> _devices = {};
  Timer? _cleanupTimer;
  bool _isScanning = false;
  bool _isAdvertising = false;

  String? _localDeviceName;
  String? _localDeviceId;

  final StreamController<List<DiscoveredBluetoothDevice>> _devicesController =
      StreamController<List<DiscoveredBluetoothDevice>>.broadcast();

  final StreamController<BleInvite> _inviteController =
      StreamController<BleInvite>.broadcast();

  /// Stream of discovered ZapShare devices – updates on every BLE event
  Stream<List<DiscoveredBluetoothDevice>> get devicesStream =>
      _devicesController.stream;

  /// Stream of incoming transfer invites from sender devices
  Stream<BleInvite> get inviteStream => _inviteController.stream;

  BluetoothDiscoveryService() {
    // Listen for native callbacks
    _channel.setMethodCallHandler(_handleNativeCallback);
    // Periodic cleanup of stale devices
    _cleanupTimer =
        Timer.periodic(const Duration(seconds: 10), (_) => _cleanupStaleDevices());
  }

  // ────────────────────────────────────────────────
  //  Native → Dart callbacks
  // ────────────────────────────────────────────────

  Future<dynamic> _handleNativeCallback(MethodCall call) async {
    switch (call.method) {
      case 'onDeviceDiscovered':
        final map = Map<String, dynamic>.from(call.arguments);
        final device = DiscoveredBluetoothDevice(
          deviceId: map['deviceId'] ?? '',
          deviceName: map['deviceName'] ?? 'ZapShare Device',
          bleAddress: map['bleAddress'] ?? '',
          port: map['port'] ?? 8080,
          platform: map['platform'] ?? 'android',
          rssi: map['rssi'] ?? -100,
          lastSeen: DateTime.now(),
        );
        final isNew = !_devices.containsKey(device.deviceId);
        _devices[device.deviceId] = device;
        if (isNew) {
          print('📱 New ZapShare peer: ${device.deviceName}');
        }
        _emitDevices();
        break;

      case 'onDeviceLost':
        final deviceId = call.arguments as String;
        _devices.remove(deviceId);
        _emitDevices();
        break;

      case 'onInviteReceived':
        final map = Map<String, dynamic>.from(call.arguments);
        final invite = BleInvite(
          senderName: map['senderName'] ?? 'Unknown',
          senderBleAddress: map['senderBleAddress'] ?? '',
          senderDeviceId: map['senderDeviceId'] ?? '',
        );
        print('🔔 BLE invite received from ${invite.senderName}');
        if (!_inviteController.isClosed) {
          _inviteController.add(invite);
        }
        break;
    }
  }

  void _emitDevices() {
    final list = _devices.values.toList()
      ..sort((a, b) => b.rssi.compareTo(a.rssi));
    if (!_devicesController.isClosed) {
      _devicesController.add(list);
    }
  }

  // ────────────────────────────────────────────────
  //  Permissions
  // ────────────────────────────────────────────────

  Future<bool> requestPermissions() async {
    final statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothAdvertise,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();

    return statuses[Permission.bluetoothScan]!.isGranted &&
        statuses[Permission.bluetoothAdvertise]!.isGranted &&
        statuses[Permission.bluetoothConnect]!.isGranted;
  }

  // ────────────────────────────────────────────────
  //  Advertising
  // ────────────────────────────────────────────────

  Future<bool> startAdvertising({
    required String deviceName,
    required String deviceId,
    required int port,
  }) async {
    try {
      _localDeviceName = deviceName;
      _localDeviceId = deviceId;

      final ok = await requestPermissions();
      if (!ok) {
        print('❌ BLE permissions denied');
        return false;
      }

      final result = await _channel.invokeMethod('startAdvertising', {
        'deviceName': deviceName,
        'deviceId': deviceId,
        'port': port,
      });

      _isAdvertising = result == true;
      return _isAdvertising;
    } catch (e) {
      print('❌ startAdvertising error: $e');
      return false;
    }
  }

  Future<void> stopAdvertising() async {
    try {
      await _channel.invokeMethod('stopAdvertising');
      _isAdvertising = false;
    } catch (e) {
      print('⚠️ stopAdvertising error: $e');
    }
  }

  // ────────────────────────────────────────────────
  //  Scanning
  // ────────────────────────────────────────────────

  Future<bool> startScanning() async {
    if (_isScanning) return true;
    try {
      final ok = await requestPermissions();
      if (!ok) return false;

      final result = await _channel.invokeMethod('startScanning');
      _isScanning = result == true;
      return _isScanning;
    } catch (e) {
      print('❌ startScanning error: $e');
      return false;
    }
  }

  Future<void> stopScanning() async {
    try {
      _isScanning = false;
      await _channel.invokeMethod('stopScanning');
    } catch (e) {
      print('⚠️ stopScanning error: $e');
    }
  }

  // ────────────────────────────────────────────────
  //  GATT credential exchange
  // ────────────────────────────────────────────────

  /// **Sender** calls this after starting the hotspot to store credentials
  /// in the GATT server so the receiver can read them.
  Future<bool> setHotspotCredentials({
    required String ssid,
    required String password,
    required String ipAddress,
    required int port,
  }) async {
    try {
      final result = await _channel.invokeMethod('setHotspotCredentials', {
        'ssid': ssid,
        'password': password,
        'ipAddress': ipAddress,
        'port': port,
      });
      return result == true;
    } catch (e) {
      print('❌ setHotspotCredentials error: $e');
      return false;
    }
  }

  /// **Sender** calls this to notify the receiver "credentials are ready".
  Future<bool> sendInvite({required String bleAddress}) async {
    try {
      final result = await _channel.invokeMethod('sendInvite', {
        'bleAddress': bleAddress,
      });
      return result == true;
    } catch (e) {
      print('❌ sendInvite error: $e');
      return false;
    }
  }

  /// **Receiver** calls this to connect to the sender's GATT server via BLE
  /// and read the hotspot SSID + password.
  Future<HotspotCredentials?> readHotspotCredentials({
    required String bleAddress,
  }) async {
    try {
      final result = await _channel.invokeMethod('readHotspotCredentials', {
        'bleAddress': bleAddress,
      });
      if (result != null) {
        final map = Map<String, dynamic>.from(result);
        return HotspotCredentials(
          ssid: map['ssid'] ?? '',
          password: map['password'] ?? '',
          ipAddress: map['ipAddress'] ?? '192.168.49.1',
          port: map['port'] ?? 8080,
        );
      }
      return null;
    } catch (e) {
      print('❌ readHotspotCredentials error: $e');
      return null;
    }
  }

  /// Clear credentials after transfer completes.
  Future<void> clearHotspotCredentials() async {
    try {
      await _channel.invokeMethod('clearHotspotCredentials');
    } catch (_) {}
  }

  // ────────────────────────────────────────────────
  //  Advertising-based invite (more reliable)
  // ────────────────────────────────────────────────

  /// Restart advertising with an invite flag embedded in the scan response.
  /// The targeted receiver will detect the flag via scanning and show the
  /// invite dialog — no GATT client connection needed, much more reliable.
  Future<bool> startInviteAdvertising({required String targetDeviceId}) async {
    try {
      final result = await _channel.invokeMethod('startInviteAdvertising', {
        'targetDeviceId': targetDeviceId,
      });
      return result == true;
    } catch (e) {
      print('❌ startInviteAdvertising error: $e');
      return false;
    }
  }

  /// Stop invite advertising and resume normal advertising.
  Future<void> stopInviteAdvertising() async {
    try {
      await _channel.invokeMethod('stopInviteAdvertising');
    } catch (e) {
      print('⚠️ stopInviteAdvertising error: $e');
    }
  }

  /// Clear the set of processed invites (allows re-inviting same device).
  Future<void> clearProcessedInvites() async {
    try {
      await _channel.invokeMethod('clearProcessedInvites');
    } catch (_) {}
  }

  // ────────────────────────────────────────────────
  //  Device list helpers
  // ────────────────────────────────────────────────

  List<DiscoveredBluetoothDevice> getDiscoveredDevices() {
    final list = _devices.values.toList()
      ..sort((a, b) => b.rssi.compareTo(a.rssi));
    return list;
  }

  void _cleanupStaleDevices() {
    final now = DateTime.now();
    final before = _devices.length;
    _devices.removeWhere(
        (_, d) => now.difference(d.lastSeen).inSeconds > 45);
    if (_devices.length != before) _emitDevices();
  }

  bool get isScanning => _isScanning;
  bool get isAdvertising => _isAdvertising;

  void dispose() {
    _cleanupTimer?.cancel();
    stopScanning();
    stopAdvertising();
    _devicesController.close();
    _inviteController.close();
  }
}

// ════════════════════════════════════════════════════════════════════
//  Models
// ════════════════════════════════════════════════════════════════════

class BleInvite {
  final String senderName;
  final String senderBleAddress;
  final String senderDeviceId;

  BleInvite({
    required this.senderName,
    required this.senderBleAddress,
    required this.senderDeviceId,
  });
}

class DiscoveredBluetoothDevice {
  final String deviceId;
  final String deviceName;
  final String bleAddress;
  final int port;
  final String platform;
  final int rssi;
  final DateTime lastSeen;

  DiscoveredBluetoothDevice({
    required this.deviceId,
    required this.deviceName,
    required this.bleAddress,
    required this.port,
    required this.platform,
    required this.rssi,
    required this.lastSeen,
  });

  bool get isOnline => DateTime.now().difference(lastSeen).inSeconds < 45;

  Map<String, dynamic> toMap() => {
        'deviceId': deviceId,
        'deviceName': deviceName,
        'bleAddress': bleAddress,
        'port': port,
        'platform': platform,
        'rssi': rssi,
      };
}

class HotspotCredentials {
  final String ssid;
  final String password;
  final String ipAddress;
  final int port;

  HotspotCredentials({
    required this.ssid,
    required this.password,
    required this.ipAddress,
    required this.port,
  });

  @override
  String toString() =>
      'HotspotCredentials(ssid: $ssid, ip: $ipAddress:$port)';
}
