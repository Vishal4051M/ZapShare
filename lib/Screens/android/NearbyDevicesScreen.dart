import 'package:flutter/material.dart';
import 'dart:async';
import 'package:permission_handler/permission_handler.dart';
import '../../services/wifi_direct_service.dart';

/// Shows nearby Wi-Fi Direct peers.
///
/// When the user taps a device:
///   1. Initiates a Wi-Fi Direct connection to the selected peer
///   2. Returns the peer info to the calling screen
class NearbyDevicesScreen extends StatefulWidget {
  /// If true, this device is looking to send files (starts hotspot on tap).
  /// If false, this device is looking to receive files (connects to sender's hotspot on tap).
  final bool isSender;

  const NearbyDevicesScreen({super.key, this.isSender = true});

  @override
  State<NearbyDevicesScreen> createState() => _NearbyDevicesScreenState();
}

class _NearbyDevicesScreenState extends State<NearbyDevicesScreen>
    with SingleTickerProviderStateMixin {
  final WiFiDirectService _service = WiFiDirectService();
  List<WiFiDirectPeer> _devices = [];
  bool _isScanning = false;
  bool _isConnecting = false;
  String? _connectingDeviceAddress;
  String _statusMessage = '';

  late AnimationController _pulseController;
  StreamSubscription? _devicesSub;
  StreamSubscription? _connectionInfoSub;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();

    _initDiscovery();
  }

  Future<void> _initDiscovery() async {
    // Request permissions first
    Map<Permission, PermissionStatus> statuses =
        await [Permission.location, Permission.nearbyWifiDevices].request();

    if (statuses[Permission.nearbyWifiDevices] == PermissionStatus.denied ||
        statuses[Permission.nearbyWifiDevices] ==
            PermissionStatus.permanentlyDenied) {
      // On Android 13+, this is fatal for Wi-Fi Direct
      if (mounted) {
        _showError('Nearby Devices permission is required for Wi-Fi Direct');
      }
    }

    await _service.initialize();

    _devicesSub = _service.peersStream.listen((devices) {
      if (mounted) setState(() => _devices = devices);
    });

    setState(() {
      _isScanning = true;
      _statusMessage = 'Looking for Wi-Fi Direct devices...';
    });

    final ok = await _service.startPeerDiscovery();
    if (!ok && mounted) {
      setState(() {
        _isScanning = false;
        _statusMessage = 'Failed to start Wi-Fi Direct discovery.';
      });
    }

    // Listen for incoming connections (if we are Receiver and Sender connects to us)
    _connectionInfoSub = _service.connectionInfoStream.listen((info) {
      if (info.groupFormed && mounted && !_isConnecting) {
        // Connection established externally (invited by peer)
        // We need to return to the parent screen to handle the file transfer

        // Find the peer if possible, or create a placeholder
        WiFiDirectPeer? connectedPeer;
        try {
          connectedPeer = _devices.firstWhere(
            (d) => d.status == 0,
          ); // Status 0 is connected? No, usually 1. 0 is connected.
          // Actually status: 3=Connected, 0=Connected?
          // WifiP2pDevice.CONNECTED = 0
          // WifiP2pDevice.INVITED = 1
          // WifiP2pDevice.FAILED = 2
          // WifiP2pDevice.AVAILABLE = 3
          // WifiP2pDevice.UNAVAILABLE = 4
          // Let's just pick the first one checking status if possible, or just a dummy
        } catch (e) {}

        final peer =
            connectedPeer ??
            WiFiDirectPeer(
              deviceName: 'Connected Device',
              deviceAddress: info.groupOwnerAddress,
              status: 0,
              isGroupOwner: info.isGroupOwner,
              primaryDeviceType: '',
              secondaryDeviceType: '',
            );

        Navigator.pop(
          context,
          NearbyDeviceResult(
            peer: peer,
            role: widget.isSender ? TransferRole.sender : TransferRole.receiver,
          ),
        );
      }
    });
  }

  Future<void> _refreshScan() async {
    await _service.stopPeerDiscovery();
    setState(() {
      _devices = [];
      _isScanning = true;
      _statusMessage = 'Scanning...';
    });
    await _service.startPeerDiscovery();
  }

  // ────────────────────────────────────────────────
  //  Tap handler — Wi-Fi Direct connection
  // ────────────────────────────────────────────────

  Future<void> _onDeviceTapped(WiFiDirectPeer device) async {
    if (_isConnecting) return;

    setState(() {
      _isConnecting = true;
      _connectingDeviceAddress = device.deviceAddress;
      _statusMessage = 'Connecting to ${device.deviceName}...';
    });

    try {
      // Connect to the peer (as client or GO depending on negotiation)
      // Usually, if we are the sender (Group Owner), we wait for connections.
      // If we are the receiver (Client), we connect to the GO.
      // But in Wi-Fi Direct, either can initiate.

      final connected = await _service.connectToPeer(
        device.deviceAddress,
        isGroupOwner: widget.isSender, // Prefer being GO if sender
      );

      if (connected && mounted) {
        setState(() => _statusMessage = 'Connection initiated...');

        // Wait for connection info callback (handled via stream in parent or service event)
        // For now, return the peer info
        Navigator.pop(
          context,
          NearbyDeviceResult(
            peer: device,
            role: widget.isSender ? TransferRole.sender : TransferRole.receiver,
          ),
        );
      } else if (mounted) {
        _showError('Failed to connect to ${device.deviceName}');
      }
    } catch (e) {
      if (mounted) _showError('Connection error: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isConnecting = false;
          _connectingDeviceAddress = null;
        });
      }
    }
  }

  void _showError(String message) {
    setState(() => _statusMessage = message);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: Colors.red[700],
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _devicesSub?.cancel();
    _connectionInfoSub?.cancel();
    _service.stopPeerDiscovery();
    super.dispose();
  }

  // ────────────────────────────────────────────────
  //  UI
  // ────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_rounded, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          widget.isSender ? 'Send to Device' : 'Receive from Device',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 22,
            fontWeight: FontWeight.w300,
            letterSpacing: -0.5,
          ),
        ),
        actions: [
          if (!_isConnecting)
            IconButton(
              icon: Icon(
                _isScanning ? Icons.wifi_find : Icons.refresh,
                color: _isScanning ? Colors.blue[300] : Colors.yellow[300],
              ),
              onPressed: _refreshScan,
              tooltip: 'Refresh',
            ),
        ],
      ),
      body: Column(
        children: [
          // Status bar
          _buildStatusBar(),

          // Device count
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
            child: Row(
              children: [
                Icon(Icons.wifi, color: Colors.blue[300], size: 16),
                const SizedBox(width: 8),
                Text(
                  '${_devices.length} Wi-Fi Direct device${_devices.length != 1 ? 's' : ''} nearby',
                  style: TextStyle(
                    color: Colors.grey[400],
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),

          // Device list
          Expanded(
            child: _devices.isEmpty ? _buildEmptyState() : _buildDeviceList(),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusBar() {
    final Color barColor;
    final IconData barIcon;

    if (_isConnecting) {
      barColor = Colors.orange;
      barIcon = Icons.sync;
    } else if (_isScanning) {
      barColor = Colors.blue;
      barIcon = Icons.wifi_find;
    } else {
      barColor = Colors.grey;
      barIcon = Icons.wifi_off;
    }

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 20),
      margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      decoration: BoxDecoration(
        color: barColor.withOpacity(0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: barColor.withOpacity(0.3)),
      ),
      child: Row(
        children: [
          if (_isConnecting || _isScanning)
            RotationTransition(
              turns: _pulseController,
              child: Icon(barIcon, color: barColor, size: 20),
            )
          else
            Icon(barIcon, color: barColor, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              _statusMessage,
              style: TextStyle(
                color: barColor,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.wifi_find, size: 80, color: Colors.grey[800]),
          const SizedBox(height: 16),
          Text(
            _isScanning
                ? 'Searching for Wi-Fi Direct devices...'
                : 'No Wi-Fi Direct devices found',
            style: TextStyle(
              color: Colors.grey[400],
              fontSize: 18,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Make sure Wi-Fi is on and ZapShare\nis open on the other device',
            style: TextStyle(color: Colors.grey[600], fontSize: 14),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          if (!_isScanning)
            ElevatedButton.icon(
              onPressed: _refreshScan,
              icon: const Icon(Icons.wifi_find),
              label: const Text('Scan Again'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blue[400],
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 12,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildDeviceList() {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      itemCount: _devices.length,
      itemBuilder: (context, index) => _buildDeviceCard(_devices[index]),
    );
  }

  Widget _buildDeviceCard(WiFiDirectPeer device) {
    final isConnecting = _connectingDeviceAddress == device.deviceAddress;
    final platformColor =
        Colors.green; // Default to Android green for Wi-Fi Direct
    // Wi-Fi Direct doesn't give us signal strength easily in the peer list usually
    const signalIcon = Icons.signal_cellular_4_bar;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color:
            isConnecting ? Colors.orange.withOpacity(0.08) : Colors.grey[900],
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color:
              isConnecting ? Colors.orange.withOpacity(0.5) : Colors.grey[800]!,
          width: 1.5,
        ),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: _isConnecting ? null : () => _onDeviceTapped(device),
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                // Platform icon
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    color: platformColor.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child:
                      isConnecting
                          ? const Center(
                            child: SizedBox(
                              width: 24,
                              height: 24,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.5,
                                color: Colors.orange,
                              ),
                            ),
                          )
                          : Icon(
                            Icons
                                .phone_android, // Assume Android for Wi-Fi Direct
                            color: platformColor,
                            size: 28,
                          ),
                ),
                const SizedBox(width: 16),

                // Device info
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        device.deviceName,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Icon(Icons.wifi, size: 12, color: Colors.blue[300]),
                          const SizedBox(width: 4),
                          Text(
                            device.deviceAddress,
                            style: TextStyle(
                              color: Colors.grey[500],
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),

                // Signal strength (placeholder)
                Column(
                  children: [
                    Icon(signalIcon, color: Colors.green, size: 20),
                    const SizedBox(height: 2),
                    Text(
                      'Good',
                      style: TextStyle(color: Colors.grey[600], fontSize: 10),
                    ),
                  ],
                ),

                const SizedBox(width: 8),

                // Tap arrow
                if (!isConnecting)
                  Icon(Icons.chevron_right, color: Colors.grey[600], size: 24),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════
//  Result model returned to calling screen
// ════════════════════════════════════════════════════════════════════

enum TransferRole { sender, receiver }

class NearbyDeviceResult {
  final WiFiDirectPeer peer;
  final TransferRole role;

  NearbyDeviceResult({required this.peer, required this.role});
}
