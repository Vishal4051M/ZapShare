import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../services/device_discovery_service.dart';
import '../../services/DesktopCastServer.dart';
import '../../widgets/CustomAvatarWidget.dart';
import '../../widgets/SearchPulseWidget.dart';

class WindowsScreenMirrorScreen extends StatefulWidget {
  const WindowsScreenMirrorScreen({super.key});

  @override
  State<WindowsScreenMirrorScreen> createState() =>
      _WindowsScreenMirrorScreenState();
}

class _WindowsScreenMirrorScreenState extends State<WindowsScreenMirrorScreen> {
  final DeviceDiscoveryService _discoveryService = DeviceDiscoveryService();
  final DesktopCastServer _castServer = DesktopCastServer();

  List<DiscoveredDevice> _devices = [];
  bool _isScanning = false;
  bool _isCasting = false;
  String? _castingToDeviceName;
  String? _localIp;
  int? _serverPort;

  @override
  void initState() {
    super.initState();
    _initDiscoveryAndServer();
  }

  Future<void> _initDiscoveryAndServer() async {
    try {
      // Get local IP
      String? ip;
      final interfaces = await NetworkInterface.list();
      for (var interface in interfaces) {
        if (interface.name.toLowerCase().contains('pseudo') ||
            interface.name.toLowerCase().contains('loopback')) {
          continue;
        }
        for (var addr in interface.addresses) {
          if (addr.type == InternetAddressType.IPv4 && !addr.isLoopback) {
            ip = addr.address;
            break;
          }
        }
        if (ip != null) break;
      }

      if (ip == null) {
        throw Exception(
          'Could not determine local IP. Check network connection.',
        );
      }

      _localIp = ip;

      // Start server
      await _castServer.start();
      _serverPort = _castServer.port;

      // Init discovery
      await _discoveryService.initialize();
      _discoveryService.devicesStream.listen((devices) {
        if (mounted) {
          setState(() {
            _devices = devices;
          });
        }
      });

      _startScanning();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error starting cast server: $e')),
        );
      }
    }
  }

  Future<void> _startScanning() async {
    setState(() => _isScanning = true);
    await _discoveryService.start();
  }

  Future<void> _mirrorToDevice(DiscoveredDevice device) async {
    if (_localIp == null || _serverPort == null) return;
    try {
      final streamUrl = 'http://$_localIp:$_serverPort/desktop-mirror';

      // Send invitation
      await _discoveryService.sendScreenMirrorRequest(
        device.ipAddress,
        streamUrl,
        width: 1920.0,
        height: 1080.0,
      );

      setState(() {
        _isCasting = true;
        _castingToDeviceName = device.deviceName;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Sent screen mirror invitation to ${device.deviceName}',
            style: const TextStyle(
              color: Color(0xFF101010),
              fontWeight: FontWeight.w600,
            ),
          ),
          backgroundColor: const Color(0xFFFFD600),
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to mirror screen: $e')));
      }
    }
  }

  Future<void> _stopCasting() async {
    setState(() {
      _isCasting = false;
      _castingToDeviceName = null;
    });
  }

  @override
  void dispose() {
    _castServer.stop();
    _discoveryService.stop();
    super.dispose();
  }

  String _getDeviceEmoji(String name, {String? platform}) {
    if (platform != null) {
      final p = platform.toLowerCase();
      if (p.contains('ios') || p.contains('iphone') || p.contains('ipad')) {
        return '📱';
      } else if (p.contains('mac')) {
        return '💻';
      } else if (p.contains('android')) {
        return '🤖';
      } else if (p.contains('windows') || p.contains('pc')) {
        return '💻';
      }
    }

    name = name.toLowerCase();
    if (name.contains('iphone') ||
        name.contains('ipad') ||
        name.contains('ios')) {
      return '📱';
    } else if (name.contains('mac') || name.contains('apple')) {
      return '💻';
    } else if (name.contains('windows') ||
        name.contains('pc') ||
        name.contains('desktop')) {
      return '💻';
    } else if (name.contains('android') ||
        name.contains('phone') ||
        name.contains('pixel') ||
        name.contains('samsung')) {
      return '🤖';
    }
    return '🔌';
  }

  Widget _buildDeviceNode(DiscoveredDevice device) {
    String name = device.deviceName;
    String? platform = device.platform;
    String? userName = device.userName;
    String displayName = userName ?? name;

    String emoji = '📱';
    if (device.avatarUrl != null) {
      bool found = false;
      for (final cat in CustomAvatarWidget.categories.values) {
        for (final item in cat) {
          if (item['id'] == device.avatarUrl) {
            emoji = item['emoji'] as String;
            found = true;
            break;
          }
        }
        if (found) break;
      }
      if (!found) {
        emoji = device.avatarUrl!;
      }
    } else {
      emoji = _getDeviceEmoji(name, platform: platform);
    }

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () {
          HapticFeedback.lightImpact();
          _mirrorToDevice(device);
        },
        child: Padding(
          padding: const EdgeInsets.all(4.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: const Color(0xFF1E1E1E),
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.3),
                      blurRadius: 8,
                      offset: const Offset(0, 4),
                    ),
                  ],
                  border: Border.all(
                    color: const Color(0xFFFFD600).withOpacity(0.3),
                    width: 1.5,
                  ),
                ),
                child: Center(
                  child: DefaultTextStyle(
                    style: const TextStyle(),
                    child: Text(
                      emoji,
                      style: const TextStyle(
                        fontSize: 32,
                        fontFamily: 'Segoe UI Emoji',
                        fontFamilyFallback: [
                          'Apple Color Emoji',
                          'Segoe UI Emoji',
                          'Noto Color Emoji',
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Container(
                constraints: const BoxConstraints(maxWidth: 70),
                child: Text(
                  displayName.length > 8
                      ? '${displayName.substring(0, 8)}...'
                      : displayName,
                  style: GoogleFonts.outfit(
                    color: Colors.white70,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDiscoveryStatusLabel(int deviceCount) {
    String text;
    IconData icon;
    bool isLoading = false;

    if (_isScanning && deviceCount == 0) {
      text = 'Scanning...';
      icon = Icons.radar_rounded;
      isLoading = true;
    } else if (deviceCount > 0) {
      text = '$deviceCount device${deviceCount > 1 ? 's' : ''} nearby';
      icon = Icons.check_circle_outline_rounded;
    } else {
      text = 'No devices nearby';
      icon = Icons.device_unknown_rounded;
    }

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFFFFD600).withOpacity(0.15),
        border: Border.all(color: const Color(0xFFFFD600).withOpacity(0.3)),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isLoading)
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 1.5,
                valueColor: AlwaysStoppedAnimation<Color>(Color(0xFFFFD600)),
              ),
            )
          else
            Icon(icon, color: const Color(0xFFFFD600), size: 14),
          const SizedBox(width: 6),
          Text(
            text,
            style: GoogleFonts.outfit(
              color: const Color(0xFFFFD600),
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRadarArea({required double width, required double height}) {
    final double pulseSize = min(width, height) * 0.82;
    final double clampedPulseSize = pulseSize.clamp(200.0, 360.0);

    final List<Widget> deviceNodes = [];
    final int totalCount = _devices.length;
    final int maxVisibleDevices = 8;
    final int visibleCount = totalCount.clamp(0, maxVisibleDevices);

    final double deviceScale =
        totalCount <= 4 ? 1.0 : (totalCount <= 6 ? 0.9 : 0.8);
    final double deviceNodeSize = 56.0 * deviceScale;

    final double pulseRadius = clampedPulseSize / 2;
    final double orbitPadding = 12.0;
    final double orbitRadius =
        pulseRadius - (deviceNodeSize / 2) - orbitPadding;
    final double startAngle = -3.14159 / 2;

    for (int i = 0; i < visibleCount; i++) {
      final double angle = startAngle + (2 * 3.14159 * i / visibleCount);
      final double offsetX = orbitRadius * cos(angle);
      final double offsetY = orbitRadius * sin(angle);

      deviceNodes.add(
        Transform.translate(
          offset: Offset(offsetX, offsetY),
          child: Transform.scale(
            scale: deviceScale,
            child: _buildDeviceNode(_devices[i]),
          ),
        ),
      );
    }

    return SizedBox(
      width: width,
      height: height,
      child: Stack(
        alignment: Alignment.center,
        children: [
          SearchPulseWidget(
            key: const ValueKey('pulse_effect_windows_mirror'),
            size: clampedPulseSize,
            color: const Color(0xFFFFD600),
            showCenterDot: false,
          ),
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: const Color(0xFF1E1E1E),
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.3),
                  blurRadius: 10,
                  offset: const Offset(0, 5),
                ),
              ],
              border: Border.all(
                color: const Color(0xFFFFD600).withOpacity(0.5),
                width: 2.0,
              ),
            ),
            child: const Icon(
              Icons.laptop_chromebook_rounded,
              color: Color(0xFFFFD600),
              size: 36,
            ),
          ),
          ...deviceNodes,
        ],
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: Colors.transparent,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white.withOpacity(0.12)),
            ),
            child: IconButton(
              icon: const Icon(
                Icons.arrow_back_ios_new_rounded,
                color: Colors.white,
                size: 20,
              ),
              onPressed: () => Navigator.pop(context),
            ),
          ),
          Expanded(
            child: Text(
              'Desktop Mirror',
              style: GoogleFonts.outfit(
                color: Colors.white,
                fontSize: 24,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.5,
              ),
              textAlign: TextAlign.center,
            ),
          ),
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: Colors.transparent,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white.withOpacity(0.12)),
            ),
            child: IconButton(
              icon: Icon(
                _isScanning ? Icons.sync_rounded : Icons.refresh_rounded,
                color: Colors.white,
                size: 20,
              ),
              onPressed: _startScanning,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF101010), Color(0xFF1E1E1E)],
          ),
        ),
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth;
              final height = constraints.maxHeight;
              final isLandscape = width > height;

              return Column(
                children: [
                  _buildHeader(context),
                  Expanded(
                    child:
                        _isCasting
                            ? Center(
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 24.0,
                                ),
                                child: Container(
                                  constraints: const BoxConstraints(
                                    maxWidth: 400,
                                  ),
                                  padding: const EdgeInsets.all(24),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF1E1E1E),
                                    borderRadius: BorderRadius.circular(24),
                                    border: Border.all(
                                      color: const Color(
                                        0xFFFFD600,
                                      ).withOpacity(0.3),
                                      width: 1.5,
                                    ),
                                    boxShadow: [
                                      BoxShadow(
                                        color: Colors.black.withOpacity(0.4),
                                        blurRadius: 15,
                                        offset: const Offset(0, 10),
                                      ),
                                    ],
                                  ),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Row(
                                        mainAxisAlignment:
                                            MainAxisAlignment.center,
                                        children: [
                                          const Icon(
                                            Icons.radio_button_checked,
                                            color: Colors.red,
                                            size: 20,
                                          ),
                                          const SizedBox(width: 8),
                                          Text(
                                            'Desktop Mirror Active',
                                            style: GoogleFonts.outfit(
                                              color: Colors.white,
                                              fontWeight: FontWeight.bold,
                                              fontSize: 18,
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 12),
                                      Text(
                                        'Mirroring to $_castingToDeviceName',
                                        style: GoogleFonts.outfit(
                                          color: Colors.white70,
                                          fontSize: 14,
                                        ),
                                        textAlign: TextAlign.center,
                                      ),
                                      const SizedBox(height: 24),
                                      SizedBox(
                                        width: double.infinity,
                                        height: 50,
                                        child: ElevatedButton(
                                          style: ElevatedButton.styleFrom(
                                            backgroundColor: Colors.red,
                                            foregroundColor: Colors.white,
                                            shape: RoundedRectangleBorder(
                                              borderRadius:
                                                  BorderRadius.circular(16),
                                            ),
                                            elevation: 0,
                                          ),
                                          onPressed: _stopCasting,
                                          child: Text(
                                            'Stop Mirroring',
                                            style: GoogleFonts.outfit(
                                              fontWeight: FontWeight.bold,
                                              fontSize: 16,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            )
                            : isLandscape
                            ? Row(
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                Expanded(
                                  flex: 5,
                                  child: _buildRadarArea(
                                    width: width * 5 / 9,
                                    height: height - 80,
                                  ),
                                ),
                                Expanded(
                                  flex: 4,
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 24.0,
                                    ),
                                    child: Column(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                        _buildDiscoveryStatusLabel(
                                          _devices.length,
                                        ),
                                        const SizedBox(height: 24),
                                        Text(
                                          'Tap any discovered Android device to start mirroring.',
                                          style: GoogleFonts.outfit(
                                            fontSize: 14,
                                            color: Colors.white60,
                                          ),
                                          textAlign: TextAlign.center,
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            )
                            : Column(
                              children: [
                                Expanded(
                                  child: _buildRadarArea(
                                    width: width,
                                    height: height - 200,
                                  ),
                                ),
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 24.0),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      _buildDiscoveryStatusLabel(
                                        _devices.length,
                                      ),
                                      const SizedBox(height: 16),
                                      Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 24.0,
                                        ),
                                        child: Text(
                                          'Tap any discovered Android device to start mirroring.',
                                          style: GoogleFonts.outfit(
                                            fontSize: 14,
                                            color: Colors.white60,
                                          ),
                                          textAlign: TextAlign.center,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
