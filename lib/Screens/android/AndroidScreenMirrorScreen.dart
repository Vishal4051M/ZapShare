import 'dart:math';
import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../services/device_discovery_service.dart';
import '../../blocs/discovery/discovery_bloc.dart';
import '../../blocs/discovery/discovery_event.dart';
import '../../blocs/discovery/discovery_state.dart';
import '../../widgets/CustomAvatarWidget.dart';
import '../../widgets/SearchPulseWidget.dart';

class AndroidScreenMirrorScreen extends StatefulWidget {
  const AndroidScreenMirrorScreen({super.key});

  @override
  State<AndroidScreenMirrorScreen> createState() =>
      _AndroidScreenMirrorScreenState();
}

class _AndroidScreenMirrorScreenState extends State<AndroidScreenMirrorScreen> {
  final DeviceDiscoveryService _discoveryService = DeviceDiscoveryService();
  final NetworkInfo _networkInfo = NetworkInfo();
  static const _channel = MethodChannel('zapshare.saf');

  late DiscoveryBloc _discoveryBloc;
  bool _isMirrorRequesting = false;
  bool _isMirroring = false;
  String? _mirrorTargetIp;
  String? _mirrorTargetName;
  String? _customAvatar;

  StreamSubscription<ScreenMirrorControl>? _mirrorControlSubscription;

  @override
  void initState() {
    super.initState();
    _loadAvatar();

    _discoveryBloc = DiscoveryBloc(discoveryService: _discoveryService)
      ..add(StartDiscovery());
  }

  Future<void> _loadAvatar() async {
    try {
      final avatar = await CustomAvatarWidget.getEffectiveLocalAvatar();
      if (mounted) {
        setState(() {
          _customAvatar = avatar;
        });
      }
    } catch (_) {}
  }

  Future<String?> _getLocalIp() async {
    try {
      final ip = await _networkInfo.getWifiIP();
      if (ip != null && ip.isNotEmpty) return ip;
    } catch (_) {}
    try {
      final interfaces = await NetworkInterface.list();
      for (var iface in interfaces) {
        for (var addr in iface.addresses) {
          if (addr.type == InternetAddressType.IPv4 && !addr.isLoopback) {
            return addr.address;
          }
        }
      }
    } catch (_) {}
    return null;
  }

  Future<void> _startScreenMirror(DiscoveredDevice device) async {
    // Capture constraints/size safely in building or before gap
    setState(() {
      _isMirrorRequesting = true;
      _mirrorTargetIp = device.ipAddress;
      _mirrorTargetName = device.deviceName;
    });

    try {
      await _channel.invokeMethod('stopScreenMirror');
      await Future.delayed(const Duration(milliseconds: 300));
      await Permission.microphone.request();

      bool granted = await _channel.invokeMethod('requestScreenCapture');
      if (!granted) {
        setState(() => _isMirrorRequesting = false);
        return;
      }

      int port = 0;
      for (int attempt = 0; attempt < 15; attempt++) {
        await Future.delayed(const Duration(milliseconds: 400));
        final result = await _channel.invokeMethod('getScreenMirrorPort');
        if (result is int && result > 0) {
          port = result;
          break;
        }
      }

      if (port <= 0) {
        setState(() => _isMirrorRequesting = false);
        return;
      }

      final ip = await _getLocalIp();
      if (ip == null) {
        setState(() => _isMirrorRequesting = false);
        return;
      }

      final streamUrl = 'http://$ip:$port/stream';
      await _discoveryService.sendScreenMirrorRequest(
        device.ipAddress,
        streamUrl,
        width: 1080.0,
        height: 1920.0,
      );

      setState(() {
        _isMirroring = true;
        _isMirrorRequesting = false;
      });

      _mirrorControlSubscription = _discoveryService.screenMirrorControlStream
          .listen((control) {
            _channel.invokeMethod('mirrorControl', {
              'action': control.action,
              if (control.tapX != null) 'tapX': control.tapX,
              if (control.tapY != null) 'tapY': control.tapY,
              if (control.endX != null) 'endX': control.endX,
              if (control.endY != null) 'endY': control.endY,
              if (control.text != null) 'text': control.text,
              if (control.scrollDelta != null)
                'scrollDelta': control.scrollDelta,
              if (control.duration != null) 'duration': control.duration,
            });
          });
    } catch (_) {
      setState(() => _isMirrorRequesting = false);
    }
  }

  Future<void> _stopScreenMirror() async {
    _mirrorControlSubscription?.cancel();
    _mirrorControlSubscription = null;
    await _channel.invokeMethod('stopScreenMirror');
    setState(() {
      _isMirroring = false;
      _mirrorTargetIp = null;
      _mirrorTargetName = null;
    });
  }

  @override
  void dispose() {
    if (_isMirroring) {
      _channel.invokeMethod('stopScreenMirror');
    }
    _mirrorControlSubscription?.cancel();
    _discoveryBloc.close();
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
    bool isPending = _isMirrorRequesting && _mirrorTargetIp == device.ipAddress;

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
        onTap: _isMirrorRequesting ? null : () => _startScreenMirror(device),
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
                    if (isPending)
                      const BoxShadow(
                        color: Color(0xFFFFD600),
                        blurRadius: 12,
                        spreadRadius: 2,
                      ),
                  ],
                  border: Border.all(
                    color:
                        isPending
                            ? const Color(0xFFFFD600)
                            : const Color(0xFFFFD600).withOpacity(0.3),
                    width: 1.5,
                  ),
                ),
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    DefaultTextStyle(
                      style: const TextStyle(),
                      child: Text(
                        emoji,
                        style: const TextStyle(
                          fontSize: 32,
                          fontFamilyFallback: [
                            'Apple Color Emoji',
                            'Segoe UI Emoji',
                            'Noto Color Emoji',
                          ],
                        ),
                      ),
                    ),
                    if (isPending)
                      const Positioned.fill(
                        child: CircularProgressIndicator(
                          strokeWidth: 2.5,
                          valueColor: AlwaysStoppedAnimation<Color>(
                            Color(0xFFFFD600),
                          ),
                        ),
                      ),
                  ],
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

  Widget _buildDiscoveryStatusLabel(DiscoveryState state, int deviceCount) {
    String text;
    IconData icon;
    bool isLoading = false;

    if (state is DiscoveryInitial) {
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

  void _showAllDevicesSheet(List<DiscoveredDevice> devices) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder:
          (context) => _AllDevicesSheet(
            devices: devices,
            getDeviceEmoji: _getDeviceEmoji,
            onDeviceTap: (device) {
              Navigator.pop(context);
              _startScreenMirror(device);
            },
          ),
    );
  }

  Widget _buildRadarArea({
    required double width,
    required double height,
    required List<DiscoveredDevice> nearbyDevices,
  }) {
    final double pulseSize = min(width, height) * 0.82;
    final double clampedPulseSize = pulseSize.clamp(200.0, 360.0);

    final List<Widget> deviceNodes = [];
    final int totalCount = nearbyDevices.length;
    final int maxVisibleDevices = 8;
    final int visibleCount = totalCount.clamp(0, maxVisibleDevices);
    final int overflowCount = totalCount - visibleCount;

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
            child: _buildDeviceNode(nearbyDevices[i]),
          ),
        ),
      );
    }

    if (overflowCount > 0) {
      // Find a safe spot inside orbit radius, e.g. bottom-right
      final double angle = 3.14159 / 4;
      final double offsetX = orbitRadius * cos(angle);
      final double offsetY = orbitRadius * sin(angle);

      deviceNodes.add(
        Transform.translate(
          offset: Offset(offsetX, offsetY),
          child: GestureDetector(
            onTap: () => _showAllDevicesSheet(nearbyDevices),
            child: Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.85),
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white38, width: 1.5),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.3),
                    blurRadius: 8,
                    spreadRadius: 1,
                  ),
                ],
              ),
              child: Center(
                child: Text(
                  '+$overflowCount',
                  style: GoogleFonts.outfit(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.5,
                  ),
                ),
              ),
            ),
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
            key: const ValueKey('pulse_effect_android_mirror'),
            size: clampedPulseSize,
            color: const Color(0xFFFFD600),
            showCenterDot: false,
          ),
          CustomAvatarWidget(
            avatarId: _customAvatar,
            size: 60,
            useBackground: true,
            showBorder: true,
            borderColor: Colors.black.withOpacity(0.3),
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
              'Screen Mirror',
              style: GoogleFonts.outfit(
                color: Colors.white,
                fontSize: 24,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.5,
              ),
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(width: 48), // Balancer
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
                        _isMirroring
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
                                            'Mirroring Active',
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
                                        'Casting screen to $_mirrorTargetName',
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
                                          onPressed: _stopScreenMirror,
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
                            : BlocBuilder<DiscoveryBloc, DiscoveryState>(
                              bloc: _discoveryBloc,
                              builder: (context, state) {
                                List<DiscoveredDevice> nearbyDevices = [];
                                if (state is DiscoveryLoaded) {
                                  nearbyDevices = state.devices;
                                }

                                return isLandscape
                                    ? Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.center,
                                      children: [
                                        Expanded(
                                          flex: 5,
                                          child: _buildRadarArea(
                                            width: width * 5 / 9,
                                            height: height - 80,
                                            nearbyDevices: nearbyDevices,
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
                                                  state,
                                                  nearbyDevices.length,
                                                ),
                                                const SizedBox(height: 24),
                                                Text(
                                                  'Tap any discovered device to start mirroring your screen.',
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
                                            nearbyDevices: nearbyDevices,
                                          ),
                                        ),
                                        Padding(
                                          padding: const EdgeInsets.only(
                                            bottom: 24.0,
                                          ),
                                          child: Column(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              _buildDiscoveryStatusLabel(
                                                state,
                                                nearbyDevices.length,
                                              ),
                                              const SizedBox(height: 16),
                                              Padding(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                      horizontal: 24.0,
                                                    ),
                                                child: Text(
                                                  'Tap any discovered device to start mirroring your screen.',
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
                                    );
                              },
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

class _AllDevicesSheet extends StatefulWidget {
  final List<DiscoveredDevice> devices;
  final String Function(String name, {String? platform}) getDeviceEmoji;
  final void Function(DiscoveredDevice device) onDeviceTap;

  const _AllDevicesSheet({
    required this.devices,
    required this.getDeviceEmoji,
    required this.onDeviceTap,
  });

  @override
  State<_AllDevicesSheet> createState() => _AllDevicesSheetState();
}

class _AllDevicesSheetState extends State<_AllDevicesSheet> {
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  List<DiscoveredDevice> get filteredDevices {
    if (_searchQuery.isEmpty) return widget.devices;

    return widget.devices.where((device) {
      return device.deviceName.toLowerCase().contains(
        _searchQuery.toLowerCase(),
      );
    }).toList();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.7,
      ),
      decoration: const BoxDecoration(
        color: Color(0xFF1C1C1E),
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            margin: const EdgeInsets.only(top: 12),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.white24,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
            child: Row(
              children: [
                const Icon(
                  Icons.devices_rounded,
                  color: Colors.white70,
                  size: 22,
                ),
                const SizedBox(width: 12),
                Text(
                  'All Devices (${widget.devices.length})',
                  style: GoogleFonts.outfit(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                GestureDetector(
                  onTap: () => Navigator.pop(context),
                  child: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.1),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.close_rounded,
                      color: Colors.white70,
                      size: 18,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.08),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white12),
              ),
              child: TextField(
                controller: _searchController,
                onChanged: (value) => setState(() => _searchQuery = value),
                style: GoogleFonts.outfit(color: Colors.white, fontSize: 15),
                decoration: InputDecoration(
                  hintText: 'Search devices...',
                  hintStyle: GoogleFonts.outfit(
                    color: Colors.white38,
                    fontSize: 15,
                  ),
                  prefixIcon: const Icon(
                    Icons.search_rounded,
                    color: Colors.white38,
                    size: 20,
                  ),
                  suffixIcon:
                      _searchQuery.isNotEmpty
                          ? GestureDetector(
                            onTap: () {
                              _searchController.clear();
                              setState(() => _searchQuery = '');
                            },
                            child: const Icon(
                              Icons.clear_rounded,
                              color: Colors.white38,
                              size: 18,
                            ),
                          )
                          : null,
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 14,
                  ),
                ),
              ),
            ),
          ),
          const Divider(color: Colors.white12, height: 1),
          Flexible(
            child:
                filteredDevices.isEmpty
                    ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(40),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.search_off_rounded,
                              color: Colors.white24,
                              size: 48,
                            ),
                            const SizedBox(height: 12),
                            Text(
                              'No devices found',
                              style: GoogleFonts.outfit(
                                color: Colors.white38,
                                fontSize: 15,
                              ),
                            ),
                          ],
                        ),
                      ),
                    )
                    : ListView.builder(
                      shrinkWrap: true,
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      itemCount: filteredDevices.length,
                      itemBuilder: (context, index) {
                        final device = filteredDevices[index];
                        String name = device.deviceName;
                        String? platform = device.platform;

                        String emoji = '📱';
                        if (device.avatarUrl != null) {
                          bool found = false;
                          for (final cat
                              in CustomAvatarWidget.categories.values) {
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
                          emoji = widget.getDeviceEmoji(
                            name,
                            platform: platform,
                          );
                        }

                        return ListTile(
                          onTap: () => widget.onDeviceTap(device),
                          leading: Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              color: const Color(0xFF2C2C2E),
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: Colors.white.withOpacity(0.15),
                                width: 1,
                              ),
                            ),
                            child: Center(
                              child: Text(
                                emoji,
                                style: const TextStyle(
                                  fontSize: 22,
                                  fontFamilyFallback: [
                                    'Apple Color Emoji',
                                    'Segoe UI Emoji',
                                    'Noto Color Emoji',
                                  ],
                                ),
                              ),
                            ),
                          ),
                          title: Text(
                            name,
                            style: GoogleFonts.outfit(
                              color: Colors.white,
                              fontSize: 15,
                              fontWeight: FontWeight.w500,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            device.ipAddress,
                            style: GoogleFonts.outfit(
                              color: Colors.white54,
                              fontSize: 12,
                            ),
                          ),
                          trailing: const Icon(
                            Icons.chevron_right_rounded,
                            color: Colors.white38,
                            size: 24,
                          ),
                        );
                      },
                    ),
          ),
          SizedBox(height: MediaQuery.of(context).padding.bottom + 8),
        ],
      ),
    );
  }
}
