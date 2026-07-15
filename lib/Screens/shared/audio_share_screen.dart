import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zap_share/blocs/navigation/smooth_page_route.dart';
import 'package:network_info_plus/network_info_plus.dart';
import '../../services/device_discovery_service.dart';
import '../../Constants/FocusSurface.dart';
import '../../widgets/CustomAvatarWidget.dart';
import '../../widgets/SearchPulseWidget.dart';
import '../../Views/AudioShareSourceToggle.dart';

class AudioShareScreen extends StatefulWidget {
  const AudioShareScreen({super.key});

  @override
  State<AudioShareScreen> createState() => _AudioShareScreenState();
}

class _AudioShareScreenState extends State<AudioShareScreen>
    with SingleTickerProviderStateMixin {
  final DeviceDiscoveryService _discoveryService = DeviceDiscoveryService();
  final NetworkInfo _networkInfo = NetworkInfo();

  List<DiscoveredDevice> _devices = [];
  bool _isScanning = false;
  bool _isSystemAudio = true;
  bool _isCasting = false;
  bool _isPhoneMuted = false;
  bool _isHttpCasting = false;

  final Set<String> _selectedTargets = {};
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;
  Process? _windowsAudioSenderProcess;

  static const _channel = MethodChannel('zapshare.saf');

  String? _customAvatar;

  Future<void> _loadAvatar() async {
    final avatar = await CustomAvatarWidget.getEffectiveLocalAvatar();
    if (mounted) {
      setState(() {
        _customAvatar = avatar;
      });
    }
  }

  @override
  void initState() {
    super.initState();
    _loadAvatar();
    _isSystemAudio = true;
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);

    _pulseAnimation = Tween<double>(begin: 0.8, end: 1.2).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    _initDiscovery();
  }

  Future<void> _initDiscovery() async {
    await _discoveryService.initialize();
    _discoveryService.devicesStream.listen((devices) {
      if (mounted) setState(() => _devices = devices);
    });
    _startScanning();
  }

  Future<void> _startScanning() async {
    setState(() => _isScanning = true);
    if (Platform.isAndroid) {
      await _discoveryService.stopLanAudioReceiver();
    }
    await _discoveryService.start();
  }

  Future<void> _toggleCast() async {
    if (_isCasting) {
      await _stopCasting();
    } else {
      await _startCasting();
    }
  }

  Future<bool> _startNativeSystemAudio() async {
    if (Platform.isAndroid) {
      final status = await Permission.microphone.request();
      if (!status.isGranted) {
        throw 'Microphone permission denied';
      }
    }

    final ips = _selectedTargets.toList();
    bool success = false;
    try {
      if (Platform.isWindows) {
        await _startWindowsAudioSender(ips);
        success = true;
      } else {
        success = await _channel.invokeMethod('startLanAudioSender', {
          'ips': ips,
          'usePcm': false,
        });
      }
    } catch (e) {
      print('LAN Audio Sender failed: $e');
    }
    if (!success) {
      throw 'Permission denied - cannot capture audio';
    }

    await Future.delayed(const Duration(milliseconds: 200));

    for (final targetIp in ips) {
      await _discoveryService.sendNativeSystemAudioOffer(
        targetIp,
        50005,
        cushionMs: 40,
      );
    }
    return true;
  }

  Future<void> _startWindowsAudioSender(List<String> ips) async {
    await _stopWindowsAudioSender();
    final appDir = File(Platform.resolvedExecutable).parent.path;
    final bundledPath = '$appDir/ZapShareAudioSender.exe';
    final debugPath =
        '${Directory.current.path}/build/windows/x64/runner/Debug/ZapShareAudioSender.exe';
    final senderPath =
        await File(bundledPath).exists() ? bundledPath : debugPath;
    final args = <String>['--port', '50005'];
    for (final ip in ips) {
      args.addAll(['--target', ip]);
    }
    _windowsAudioSenderProcess = await Process.start(
      senderPath,
      args,
      mode: ProcessStartMode.detachedWithStdio,
    );
    _windowsAudioSenderProcess!.stdout
        .transform(SystemEncoding().decoder)
        .listen((line) => print('[WindowsAudioSender] $line'));
    _windowsAudioSenderProcess!.stderr
        .transform(SystemEncoding().decoder)
        .listen((line) => print('[WindowsAudioSender:err] $line'));
  }

  Future<void> _stopWindowsAudioSender() async {
    _windowsAudioSenderProcess?.stdin.writeln('q');
    _windowsAudioSenderProcess?.kill();
    _windowsAudioSenderProcess = null;
  }

  Future<void> _startCasting() async {
    if (_selectedTargets.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Select at least one device')),
      );
      return;
    }

    try {
      setState(() => _isCasting = true);

      if (!_isPhoneMuted && Platform.isAndroid) {
        await _setPhoneMute(true);
      }

      final useLanAudio =
          _isSystemAudio && (Platform.isAndroid || Platform.isWindows);
      if (useLanAudio) {
        _isHttpCasting = false;
        await _startNativeSystemAudio();
      } else {
        for (final ip in _selectedTargets) {
          await _discoveryService.startWebRtcAudio(
            ip,
            systemAudio: _isSystemAudio,
          );
        }
      }
    } catch (e) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed: $e')));
      setState(() {
        _isCasting = false;
        _isHttpCasting = false;
      });
    }
  }

  Future<String?> _getLocalIp() async {
    try {
      String? ip = await _networkInfo.getWifiIP();
      if (ip != null &&
          ip.isNotEmpty &&
          ip != "0.0.0.0" &&
          !ip.startsWith('100.')) {
        return ip;
      }

      final interfaces = await NetworkInterface.list();
      for (var iface in interfaces) {
        final name = iface.name.toLowerCase();
        if (name.contains('loopback') ||
            name.contains('tun') ||
            name.contains('tap') ||
            name.contains('ppp') ||
            name.contains('dummy') ||
            name.contains('p2p') ||
            name.contains('tailscale') ||
            name.contains('vpn')) {
          continue;
        }

        for (var addr in iface.addresses) {
          if (addr.type == InternetAddressType.IPv4 &&
              !addr.isLoopback &&
              !addr.address.startsWith('100.')) {
            return addr.address;
          }
        }
      }

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

  Future<void> _stopCasting() async {
    if (_isSystemAudio && (Platform.isAndroid || Platform.isWindows)) {
      try {
        if (Platform.isWindows) {
          await _stopWindowsAudioSender();
        } else if (_isHttpCasting) {
          await _channel.invokeMethod('stopScreenMirror');
        } else {
          await _channel.invokeMethod('stopLanAudioSender');
        }
      } catch (_) {}
    } else {
      await _discoveryService.stopWebRtcAudio();
    }
    if (_isPhoneMuted) await _setPhoneMute(false);
    setState(() {
      _isCasting = false;
      _isPhoneMuted = false;
      _isHttpCasting = false;
    });
  }

  Future<void> _setPhoneMute(bool mute) async {
    try {
      await _channel.invokeMethod('setPhoneMute', {'mute': mute});
      setState(() => _isPhoneMuted = mute);
    } catch (e) {
      print('Mute error: $e');
    }
  }

  @override
  void dispose() {
    _pulseController.dispose();
    if (_isCasting) {
      _stopCasting();
    }
    _discoveryService.resumeDiscovery();
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
    bool isSelected = _selectedTargets.contains(device.ipAddress);

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
          setState(() {
            if (_selectedTargets.contains(device.ipAddress)) {
              _selectedTargets.remove(device.ipAddress);
            } else {
              _selectedTargets.add(device.ipAddress);
            }
          });
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
                  color: const Color(0xFF1C1C1E),
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.15),
                      blurRadius: 8,
                      offset: const Offset(0, 4),
                    ),
                    if (isSelected)
                      const BoxShadow(
                        color: Colors.greenAccent,
                        blurRadius: 12,
                        spreadRadius: 2,
                      ),
                  ],
                  border: Border.all(
                    color:
                        isSelected
                            ? Colors.greenAccent
                            : Colors.white.withOpacity(0.15),
                    width: 2.0,
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
                    if (isSelected)
                      Positioned(
                        right: 0,
                        bottom: 0,
                        child: Container(
                          padding: const EdgeInsets.all(2),
                          decoration: const BoxDecoration(
                            color: Colors.greenAccent,
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.check,
                            color: Colors.black,
                            size: 12,
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
                    color: Colors.black87,
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
        color: Colors.black.withOpacity(0.75),
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
                valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
              ),
            )
          else
            Icon(icon, color: Colors.white, size: 14),
          const SizedBox(width: 6),
          Text(
            text,
            style: GoogleFonts.outfit(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
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
              border: Border.all(color: Colors.black.withOpacity(0.12)),
            ),
            child: IconButton(
              icon: const Icon(
                Icons.arrow_back_ios_new_rounded,
                color: Colors.black,
                size: 20,
              ),
              onPressed: () => Navigator.pop(context),
            ),
          ),
          Expanded(
            child: Text(
              'Audio Share',
              style: GoogleFonts.outfit(
                color: Colors.black,
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
              border: Border.all(color: Colors.black.withOpacity(0.12)),
            ),
            child: IconButton(
              icon: Icon(
                _isScanning ? Icons.sync_rounded : Icons.refresh_rounded,
                color: Colors.black,
                size: 20,
              ),
              onPressed: _startScanning,
            ),
          ),
        ],
      ),
    );
  }

  // Helper widget to paint the radar with orbiting emojis
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
          // Pulse Waves only (no duplicate center dot)
          SearchPulseWidget(
            key: const ValueKey('pulse_effect_audio'),
            size: clampedPulseSize,
            color: Colors.black,
            showCenterDot: false,
          ),
          // User Avatar in the Center
          CustomAvatarWidget(
            avatarId: _customAvatar,
            size: 60,
            useBackground: true,
            showBorder: true,
            borderColor: Colors.black.withOpacity(0.3),
          ),
          // Orbiting Device Nodes
          ...deviceNodes,
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
            colors: [Color(0xFFFFD84D), Color(0xFFF5C400)],
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
                  // Header (fixed height)
                  _buildHeader(context),

                  // Main body area
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
                                    boxShadow: [
                                      BoxShadow(
                                        color: Colors.black.withOpacity(0.25),
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
                                            'Audio Share Active',
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
                                        'Casting audio to ${_selectedTargets.length} device(s)',
                                        style: GoogleFonts.outfit(
                                          color: Colors.white70,
                                          fontSize: 14,
                                        ),
                                        textAlign: TextAlign.center,
                                      ),
                                      if (Platform.isAndroid) ...[
                                        const SizedBox(height: 16),
                                        GestureDetector(
                                          onTap:
                                              () =>
                                                  _setPhoneMute(!_isPhoneMuted),
                                          child: Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 14,
                                              vertical: 8,
                                            ),
                                            decoration: BoxDecoration(
                                              color:
                                                  _isPhoneMuted
                                                      ? const Color(0xFFE11D48)
                                                      : Colors.white12,
                                              borderRadius:
                                                  BorderRadius.circular(20),
                                            ),
                                            child: Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                Icon(
                                                  _isPhoneMuted
                                                      ? Icons.volume_off_rounded
                                                      : Icons.volume_up_rounded,
                                                  color: Colors.white,
                                                  size: 16,
                                                ),
                                                const SizedBox(width: 8),
                                                Text(
                                                  _isPhoneMuted
                                                      ? 'Phone Muted'
                                                      : 'Mute Phone',
                                                  style: GoogleFonts.outfit(
                                                    color: Colors.white,
                                                    fontSize: 13,
                                                    fontWeight: FontWeight.bold,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      ],
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
                                            'Stop Audio Share',
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
                                // Radar on the left
                                Expanded(
                                  flex: 5,
                                  child: _buildRadarArea(
                                    width: width * 5 / 9,
                                    height: height - 80,
                                  ),
                                ),
                                // Controls on the right
                                Expanded(
                                  flex: 4,
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 16.0,
                                    ),
                                    child: Column(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                        _buildDiscoveryStatusLabel(
                                          _devices.length,
                                        ),
                                        const SizedBox(height: 24),
                                        AudioShareSourceToggle(
                                          isTvLayout: false,
                                          isSystemAudio: _isSystemAudio,
                                          onSourceChanged:
                                              (val) => setState(
                                                () => _isSystemAudio = val,
                                              ),
                                        ),
                                        const SizedBox(height: 12),
                                        _buildBottomAction(),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            )
                            : Column(
                              children: [
                                // Radar in the center
                                Expanded(
                                  child: _buildRadarArea(
                                    width: width,
                                    height: height - 240,
                                  ),
                                ),
                                // Bottom controls
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 16.0),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      _buildDiscoveryStatusLabel(
                                        _devices.length,
                                      ),
                                      const SizedBox(height: 12),
                                      AudioShareSourceToggle(
                                        isTvLayout: false,
                                        isSystemAudio: _isSystemAudio,
                                        onSourceChanged:
                                            (val) => setState(
                                              () => _isSystemAudio = val,
                                            ),
                                      ),
                                      _buildBottomAction(),
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

  Widget _buildBottomAction() {
    return FocusSurface(
      onTap: () {
        HapticFeedback.mediumImpact();
        _toggleCast();
      },
      builder: (isFocused) {
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(22),
              border: Border.all(
                color: isFocused ? Colors.black : Colors.transparent,
                width: isFocused ? 2 : 0,
              ),
            ),
            child: SizedBox(
              width: double.infinity,
              height: 56,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.black,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20),
                  ),
                  elevation: 0,
                ),
                onPressed: () {
                  HapticFeedback.mediumImpact();
                  _toggleCast();
                },
                child: Text(
                  _isCasting ? 'STOP SHARING' : 'START AUDIO SHARE',
                  style: GoogleFonts.outfit(
                    fontSize: 15,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 1,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
