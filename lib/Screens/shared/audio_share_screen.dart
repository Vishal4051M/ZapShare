import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zap_share/blocs/navigation/smooth_page_route.dart';
import 'package:network_info_plus/network_info_plus.dart';
import '../../services/device_discovery_service.dart';
import '../../Constants/FocusSurface.dart';
import '../../Views/AudioSharePulseView.dart';
import '../../Views/AudioShareDeviceList.dart';
import '../../Views/AudioShareHeader.dart';
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
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _customAvatar = prefs.getString('custom_avatar');
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

  Future<void> _startHttpSystemAudio() async {
    bool granted = false;
    try {
      granted = await _channel.invokeMethod('requestScreenCapture');
    } catch (e) {
      print('Screen capture request failed: $e');
    }
    if (!granted) {
      throw 'Screen capture permission denied – cannot capture device audio';
    }

    int port = 0;
    String lastError = 'Server not ready';
    for (int attempt = 0; attempt < 25; attempt++) {
      await Future.delayed(const Duration(milliseconds: 300));
      try {
        final result = await _channel.invokeMethod('getScreenMirrorPort');
        if (result is int && result > 0) {
          port = result;
          break;
        }
        if (result is int && result == -1)
          lastError = 'Native mirror server error';
      } catch (e) {
        lastError = e.toString();
      }
    }

    if (port <= 0) {
      throw 'Audio capture failed: $lastError';
    }

    final ip = await _getLocalIp();
    if (ip == null) {
      throw 'Could not determine local IP for audio cast';
    }

    final audioUrl = 'http://$ip:$port/audio';
    print('🎵 HTTP Audio server started at $audioUrl');

    final ips = _selectedTargets.toList();
    for (final targetIp in ips) {
      await _discoveryService.sendHttpAudioOffer(targetIp, audioUrl);
    }
  }

  Future<String?> _getLocalIp() async {
    try {
      // 1. Try to get the Wi-Fi IP from network_info_plus (ignores VPNs)
      String? ip = await _networkInfo.getWifiIP();
      if (ip != null &&
          ip.isNotEmpty &&
          ip != "0.0.0.0" &&
          !ip.startsWith('100.')) {
        return ip;
      }

      // 2. Fall back to scanning interfaces, but filter out loopback and VPN/Tailscale interfaces
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
            // 100.x.x.x is CGNAT/Tailscale
            return addr.address;
          }
        }
      }

      // 3. Last resort fallback to any valid IPv4 address
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

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final isLandscape = media.orientation == Orientation.landscape;
    final isTvLayout = media.size.shortestSide >= 600;
    final useTvLayout = isLandscape && isTvLayout;

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Hero(
          tag: 'cast_audio_card',
          createRectTween:
              (begin, end) => SmoothRectTween(begin: begin, end: end),
          child: Material(
            color: Colors.black,
            child: FocusTraversalGroup(
              policy: ReadingOrderTraversalPolicy(),
              child:
                  useTvLayout
                      ? _buildTvLandscapeLayout()
                      : _buildDefaultLayout(),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDefaultLayout() {
    return Column(
      children: [
        AudioShareHeader(
          isTvLayout: false,
          isScanning: _isScanning,
          onBackTap: () => Navigator.pop(context),
          onRefreshTap: _startScanning,
        ),
        Expanded(
          child: SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            child: Column(
              children: [
                AudioSharePulseView(
                  isTvLayout: false,
                  isCasting: _isCasting,
                  isPhoneMuted: _isPhoneMuted,
                  onMuteToggle: () => _setPhoneMute(!_isPhoneMuted),
                  pulseAnimation: _pulseAnimation,
                  avatarId: _customAvatar,
                ),
                AudioShareSourceToggle(
                  isTvLayout: false,
                  isSystemAudio: _isSystemAudio,
                  onSourceChanged:
                      (val) => setState(() => _isSystemAudio = val),
                ),
                const SizedBox(height: 32),
                AudioShareDeviceList(
                  isTvLayout: false,
                  devices: _devices,
                  selectedTargets: _selectedTargets,
                  onDeviceSelect: (ip) {
                    HapticFeedback.lightImpact();
                    setState(() {
                      if (_selectedTargets.contains(ip)) {
                        _selectedTargets.remove(ip);
                      } else {
                        _selectedTargets.add(ip);
                      }
                    });
                  },
                ),
              ],
            ),
          ),
        ),
        _buildBottomAction(isTvLayout: false),
      ],
    );
  }

  Widget _buildTvLandscapeLayout() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 24),
      child: Row(
        children: [
          Expanded(
            flex: 5,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AudioShareHeader(
                  isTvLayout: true,
                  isScanning: _isScanning,
                  onBackTap: () => Navigator.pop(context),
                  onRefreshTap: _startScanning,
                ),
                const SizedBox(height: 20),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      AudioSharePulseView(
                        isTvLayout: true,
                        isCasting: _isCasting,
                        isPhoneMuted: _isPhoneMuted,
                        onMuteToggle: () => _setPhoneMute(!_isPhoneMuted),
                        pulseAnimation: _pulseAnimation,
                        avatarId: _customAvatar,
                      ),
                      const SizedBox(height: 24),
                      AudioShareSourceToggle(
                        isTvLayout: true,
                        isSystemAudio: _isSystemAudio,
                        onSourceChanged:
                            (val) => setState(() => _isSystemAudio = val),
                      ),
                      const SizedBox(height: 24),
                      _buildBottomAction(isTvLayout: true),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 40),
          Expanded(
            flex: 6,
            child: AudioShareDeviceList(
              isTvLayout: true,
              devices: _devices,
              selectedTargets: _selectedTargets,
              onDeviceSelect: (ip) {
                HapticFeedback.lightImpact();
                setState(() {
                  if (_selectedTargets.contains(ip)) {
                    _selectedTargets.remove(ip);
                  } else {
                    _selectedTargets.add(ip);
                  }
                });
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBottomAction({required bool isTvLayout}) {
    return FocusSurface(
      onTap: () {
        HapticFeedback.mediumImpact();
        _toggleCast();
      },
      builder: (isFocused) {
        return Padding(
          padding: EdgeInsets.symmetric(
            horizontal: isTvLayout ? 0 : 24,
            vertical: 24,
          ),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(22),
              border: Border.all(
                color: isFocused ? const Color(0xFFFFD600) : Colors.transparent,
                width: isFocused ? 2 : 0,
              ),
            ),
            child: SizedBox(
              width: double.infinity,
              height: isTvLayout ? 72 : 64,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor:
                      _isCasting
                          ? const Color(0xFFE11D48)
                          : const Color(0xFFFFD600),
                  foregroundColor: _isCasting ? Colors.white : Colors.black,
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
                    fontSize: isTvLayout ? 18 : 16,
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
