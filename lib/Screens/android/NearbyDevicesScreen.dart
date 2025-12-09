import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:async';
import '../../services/device_discovery_service.dart';

class NearbyDevicesScreen extends StatefulWidget {
  const NearbyDevicesScreen({super.key});

  @override
  State<NearbyDevicesScreen> createState() => _NearbyDevicesScreenState();
}

class _NearbyDevicesScreenState extends State<NearbyDevicesScreen>
    with SingleTickerProviderStateMixin {
  final DeviceDiscoveryService _discoveryService = DeviceDiscoveryService();
  List<DiscoveredDevice> _devices = [];
  bool _isScanning = false;
  late AnimationController _scanAnimationController;
  StreamSubscription? _devicesSubscription;

  @override
  void initState() {
    super.initState();
    _scanAnimationController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();

    _initializeDiscovery();
  }

  Future<void> _initializeDiscovery() async {
    await _discoveryService.initialize();

    _devicesSubscription = _discoveryService.devicesStream.listen((devices) {
      if (mounted) {
        setState(() {
          _devices = devices;
        });
      }
    });

    await _startScanning();
  }

  Future<void> _startScanning() async {
    setState(() => _isScanning = true);
    await _discoveryService.start();
  }

  Future<void> _stopScanning() async {
    setState(() => _isScanning = false);
    await _discoveryService.stop();
  }

  @override
  void dispose() {
    _scanAnimationController.dispose();
    _devicesSubscription?.cancel();
    _discoveryService.dispose();
    super.dispose();
  }

  IconData _getPlatformIcon(String platform) {
    switch (platform.toLowerCase()) {
      case 'android':
        return Icons.phone_android;
      case 'ios':
        return Icons.phone_iphone;
      case 'windows':
        return Icons.computer;
      case 'macos':
        return Icons.laptop_mac;
      case 'linux':
        return Icons.laptop;
      default:
        return Icons.devices;
    }
  }

  Color _getPlatformColor(String platform) {
    switch (platform.toLowerCase()) {
      case 'android':
        return Colors.green;
      case 'ios':
        return Colors.blue;
      case 'windows':
        return Colors.lightBlue;
      case 'macos':
        return Colors.grey;
      default:
        return Colors.yellow[300]!;
    }
  }

  void _connectToDevice(DiscoveredDevice device) {
    // Navigate to send screen with device info
    Navigator.pop(context, device);
  }

  Future<void> _requestFilesFromDevice(DiscoveredDevice device) async {
    print(
      '📤 [NearbyDevices] Sending connection request to ${device.deviceName} at ${device.ipAddress}',
    );

    // Send a connection request to the device asking them to share files
    // This will trigger a dialog on the receiver's device
    await _discoveryService.sendConnectionRequest(device.ipAddress, [
      'File transfer request',
    ], 1024); // 1KB placeholder

    print('✅ [NearbyDevices] Connection request sent successfully');

    // Show confirmation
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              Icon(Icons.send, color: Colors.white, size: 20),
              SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Request sent to ${device.deviceName}',
                  style: TextStyle(fontSize: 14),
                ),
              ),
            ],
          ),
          backgroundColor: Colors.green[700],
          duration: Duration(seconds: 2),
          action: SnackBarAction(
            label: 'OK',
            textColor: Colors.white,
            onPressed: () {},
          ),
        ),
      );
    }
  }

  void _copyShareCode(DiscoveredDevice device) {
    Clipboard.setData(ClipboardData(text: device.shareCode));
    print('Share code copied: ${device.shareCode}');
  }

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
        title: const Text(
          'Nearby Devices',
          style: TextStyle(
            color: Colors.white,
            fontSize: 24,
            fontWeight: FontWeight.w300,
            letterSpacing: -0.5,
          ),
        ),
        actions: [
          IconButton(
            icon: Icon(
              _isScanning ? Icons.stop_circle_outlined : Icons.refresh_rounded,
              color: _isScanning ? Colors.red[300] : Colors.yellow[300],
            ),
            onPressed: _isScanning ? _stopScanning : _startScanning,
            tooltip: _isScanning ? 'Stop Scanning' : 'Refresh',
          ),
        ],
      ),
      body: Column(
        children: [
          // Scanning indicator
          if (_isScanning)
            Container(
              padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 20),
              margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              decoration: BoxDecoration(
                color: Colors.grey[900],
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.yellow[300]!.withOpacity(0.3)),
              ),
              child: Row(
                children: [
                  RotationTransition(
                    turns: _scanAnimationController,
                    child: Icon(
                      Icons.radar,
                      color: Colors.yellow[300],
                      size: 20,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    'Scanning for nearby devices...',
                    style: TextStyle(
                      color: Colors.yellow[300],
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),

          // Device count
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            child: Row(
              children: [
                Icon(Icons.devices, color: Colors.grey[600], size: 16),
                const SizedBox(width: 8),
                Text(
                  '${_devices.length} device${_devices.length != 1 ? 's' : ''} found',
                  style: TextStyle(
                    color: Colors.grey[400],
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),

          // Devices list
          Expanded(
            child:
                _devices.isEmpty
                    ? _buildEmptyState()
                    : ListView.builder(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 8,
                      ),
                      itemCount: _devices.length,
                      itemBuilder: (context, index) {
                        final device = _devices[index];
                        return _buildDeviceCard(device);
                      },
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
          Icon(Icons.search_off, size: 80, color: Colors.grey[800]),
          const SizedBox(height: 16),
          Text(
            _isScanning
                ? 'No devices found yet'
                : 'Start scanning to find devices',
            style: TextStyle(
              color: Colors.grey[400],
              fontSize: 18,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            _isScanning
                ? 'Make sure ZapShare is open on other devices'
                : 'Tap the refresh button to scan',
            style: TextStyle(color: Colors.grey[600], fontSize: 14),
            textAlign: TextAlign.center,
          ),
          if (!_isScanning) ...[
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: _startScanning,
              icon: const Icon(Icons.radar),
              label: const Text('Start Scanning'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.yellow[300],
                foregroundColor: Colors.black,
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
        ],
      ),
    );
  }

  Widget _buildDeviceCard(DiscoveredDevice device) {
    final isOnline = device.isOnline;
    final platformColor = _getPlatformColor(device.platform);

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.grey[900],
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color:
              device.isFavorite
                  ? Colors.yellow[300]!.withOpacity(0.5)
                  : Colors.grey[800]!,
          width: 1.5,
        ),
        boxShadow:
            device.isFavorite
                ? [
                  BoxShadow(
                    color: Colors.yellow[300]!.withOpacity(0.1),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ]
                : null,
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: isOnline ? () => _connectToDevice(device) : null,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                // Device icon with status indicator
                Stack(
                  children: [
                    Container(
                      width: 56,
                      height: 56,
                      decoration: BoxDecoration(
                        color: platformColor.withOpacity(0.15),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(
                        _getPlatformIcon(device.platform),
                        color: platformColor,
                        size: 28,
                      ),
                    ),
                    Positioned(
                      right: 0,
                      bottom: 0,
                      child: Container(
                        width: 16,
                        height: 16,
                        decoration: BoxDecoration(
                          color: isOnline ? Colors.green : Colors.grey[700],
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: Colors.grey[900]!,
                            width: 2,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(width: 16),

                // Device info
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              device.deviceName,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (device.isFavorite) ...[
                            const SizedBox(width: 6),
                            Icon(
                              Icons.star,
                              color: Colors.yellow[300],
                              size: 16,
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        device.platform,
                        style: TextStyle(color: Colors.grey[400], fontSize: 13),
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          Icon(
                            Icons.circle,
                            size: 8,
                            color: isOnline ? Colors.green : Colors.grey[600],
                          ),
                          const SizedBox(width: 6),
                          Text(
                            isOnline ? device.ipAddress : 'Offline',
                            style: TextStyle(
                              color: Colors.grey[500],
                              fontSize: 12,
                              fontFamily: 'monospace',
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),

                // Actions
                Column(
                  children: [
                    // Favorite button
                    IconButton(
                      icon: Icon(
                        device.isFavorite ? Icons.star : Icons.star_border,
                        color:
                            device.isFavorite
                                ? Colors.yellow[300]
                                : Colors.grey[600],
                      ),
                      onPressed: () {
                        _discoveryService.toggleFavorite(device.deviceId);
                      },
                      tooltip:
                          device.isFavorite
                              ? 'Remove from favorites'
                              : 'Add to favorites',
                    ),
                    // More options
                    PopupMenuButton<String>(
                      icon: Icon(Icons.more_vert, color: Colors.grey[600]),
                      color: Colors.grey[850],
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      itemBuilder:
                          (context) => [
                            PopupMenuItem(
                              value: 'copy_code',
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.copy,
                                    size: 18,
                                    color: Colors.grey[400],
                                  ),
                                  const SizedBox(width: 12),
                                  const Text('Copy Share Code'),
                                ],
                              ),
                            ),
                            PopupMenuItem(
                              value: 'request_files',
                              enabled: isOnline,
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.download_rounded,
                                    size: 18,
                                    color:
                                        isOnline
                                            ? Colors.green[300]
                                            : Colors.grey[600],
                                  ),
                                  const SizedBox(width: 12),
                                  const Text('Request Files'),
                                ],
                              ),
                            ),
                            PopupMenuItem(
                              value: 'connect',
                              enabled: isOnline,
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.send,
                                    size: 18,
                                    color:
                                        isOnline
                                            ? Colors.yellow[300]
                                            : Colors.grey[600],
                                  ),
                                  const SizedBox(width: 12),
                                  const Text('Send Files'),
                                ],
                              ),
                            ),
                          ],
                      onSelected: (value) {
                        switch (value) {
                          case 'copy_code':
                            _copyShareCode(device);
                            break;
                          case 'request_files':
                            if (isOnline) _requestFilesFromDevice(device);
                            break;
                          case 'connect':
                            if (isOnline) _connectToDevice(device);
                            break;
                        }
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
