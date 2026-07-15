import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:saf_util/saf_util.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:zap_share/widgets/tv_widgets.dart';
import 'package:zap_share/widgets/SearchPulseWidget.dart';
import 'package:zap_share/widgets/cast_remote_control.dart';
import 'package:zap_share/services/device_discovery_service.dart';
import 'package:zap_share/Screens/android/AndroidCastScreen.dart'; // For CastMode enum
import 'package:zap_share/Views/TV/TvRemoteControlScreen.dart';

class TvCastScreen extends StatefulWidget {
  final CastMode initialMode;
  const TvCastScreen({super.key, required this.initialMode});

  @override
  State<TvCastScreen> createState() => _TvCastScreenState();
}

class _TvCastScreenState extends State<TvCastScreen> {
  final SafUtil _safUtil = SafUtil();
  final NetworkInfo _networkInfo = NetworkInfo();
  final DeviceDiscoveryService _discoveryService = DeviceDiscoveryService();

  static const _channel = MethodChannel('zapshare.saf');

  List<DiscoveredDevice> _devices = [];
  StreamSubscription? _devicesSubscription;

  String? _selectedFileName;
  String? _selectedUri;
  String? _selectedSubtitleName;
  String? _selectedSubtitleUri;

  String? _serverUrl;
  bool _isServerRunning = false;

  String? _castTargetIp;
  String? _castTargetName;

  bool _isMirroring = false;
  String? _mirrorTargetIp;
  String? _mirrorTargetName;

  @override
  void initState() {
    super.initState();
    _initDiscovery();
  }

  Future<void> _initDiscovery() async {
    await _discoveryService.initialize();
    _devicesSubscription = _discoveryService.devicesStream.listen((devices) {
      if (mounted) {
        setState(() {
          _devices = devices;
        });
      }
    });
    await _discoveryService.start();
  }

  Future<void> _pickVideo() async {
    try {
      final result = await _safUtil.pickFiles(
        multiple: false,
        mimeTypes: ['video/*'],
      );
      if (result != null && result.isNotEmpty) {
        final file = result.first;
        setState(() {
          _selectedFileName = file.name;
          _selectedUri = file.uri;
          _isServerRunning = false;
          _serverUrl = null;
        });
        await _startServer();
      }
    } catch (e) {
      print('Error picking video: $e');
    }
  }

  Future<void> _pickSubtitle() async {
    try {
      final result = await _safUtil.pickFiles(
        multiple: false,
        mimeTypes: ['*/*'],
      );
      if (result != null && result.isNotEmpty) {
        final file = result.first;
        setState(() {
          _selectedSubtitleUri = file.uri;
          _selectedSubtitleName = file.name;
        });
        if (_isServerRunning) {
          await _startServer();
        }
      }
    } catch (e) {
      print('Error picking subtitle: $e');
    }
  }

  Future<void> _startServer() async {
    if (_selectedUri == null) return;
    try {
      String? ip = await _networkInfo.getWifiIP();
      if (ip == null) {
        final interfaces = await NetworkInterface.list();
        for (var interface in interfaces) {
          for (var addr in interface.addresses) {
            if (addr.type == InternetAddressType.IPv4 && !addr.isLoopback) {
              ip = addr.address;
              break;
            }
          }
          if (ip != null) break;
        }
      }
      if (ip == null) throw Exception('No local IP');

      try {
        await _channel.invokeMethod('stopVideoServer');
      } catch (_) {}

      final filesList = [
        {'uri': _selectedUri!, 'name': _selectedFileName ?? 'video.mp4'},
      ];
      if (_selectedSubtitleUri != null) {
        filesList.add({
          'uri': _selectedSubtitleUri!,
          'name': _selectedSubtitleName ?? 'subtitle.srt',
        });
      }

      final port = await _channel.invokeMethod<int>('startVideoServer', {
        'files': filesList,
      });

      setState(() {
        _serverUrl = 'http://$ip:$port/video/0';
        _isServerRunning = true;
      });
    } catch (e) {
      print('Error starting server: $e');
    }
  }

  Future<void> _castToDevice(DiscoveredDevice device) async {
    if (widget.initialMode == CastMode.screenMirror) {
      await _startScreenMirror(device);
      return;
    }

    if (_serverUrl == null) return;
    try {
      String? subtitleUrl;
      if (_selectedSubtitleUri != null && _selectedSubtitleName != null) {
        subtitleUrl = _serverUrl!.replaceAll(
          '/video/0',
          '/video/1/$_selectedSubtitleName',
        );
      }

      await _discoveryService.sendCastUrl(
        device.ipAddress,
        _serverUrl!,
        fileName: _selectedFileName,
        subtitleUrl: subtitleUrl,
      );

      _discoveryService.startCastSession(
        device.ipAddress,
        device.deviceName,
        _selectedFileName ?? 'Video',
      );

      setState(() {
        _castTargetIp = device.ipAddress;
        _castTargetName = device.deviceName;
      });
    } catch (e) {
      print('Cast failed: $e');
    }
  }

  Future<void> _startScreenMirror(DiscoveredDevice device) async {
    try {
      final granted =
          await _channel.invokeMethod<bool>('requestScreenCapture') ?? false;
      if (!granted) return;

      int port = 0;
      for (int i = 0; i < 15; i++) {
        await Future.delayed(const Duration(milliseconds: 500));
        final res = await _channel.invokeMethod('getScreenMirrorPort');
        if (res is int && res > 0) {
          port = res;
          break;
        }
      }
      if (port <= 0) return;

      final ip = await _networkInfo.getWifiIP();
      final streamUrl = 'http://$ip:$port/live.mp4';

      await _discoveryService.sendScreenMirrorRequest(
        device.ipAddress,
        streamUrl,
      );

      setState(() {
        _isMirroring = true;
        _mirrorTargetIp = device.ipAddress;
        _mirrorTargetName = device.deviceName;
      });
    } catch (e) {
      print('Mirror failed: $e');
    }
  }

  Future<void> _stopMirroring() async {
    try {
      await _channel.invokeMethod('stopScreenMirror');
      setState(() {
        _isMirroring = false;
        _mirrorTargetIp = null;
        _mirrorTargetName = null;
      });
    } catch (e) {
      print('Stop mirror error: $e');
    }
  }

  @override
  void dispose() {
    _devicesSubscription?.cancel();
    _discoveryService.stopCastSession();
    _channel.invokeMethod('stopVideoServer');
    _channel.invokeMethod('stopForegroundService');
    if (_isMirroring) {
      _channel.invokeMethod('stopScreenMirror');
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final modeLabel = widget.initialMode == CastMode.screenMirror
        ? 'Screen Mirror'
        : 'Video Cast';
    return Scaffold(
      backgroundColor: Colors.black,
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFF0E0E10), Color(0xFF08080A)],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 48.0, vertical: 24.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // â”€â”€ Android-style header â”€â”€
                Row(
                  children: [
                    Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: const Color(0xFF1C1C1E),
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
                      ),
                      child: TVFocusableButton(
                        borderRadius: BorderRadius.circular(24),
                        padding: EdgeInsets.zero,
                        onPressed: () => Navigator.of(context).pop(),
                        child: const Icon(Icons.arrow_back_ios_new_rounded, color: Colors.white, size: 20),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: RichText(
                        text: TextSpan(
                          children: [
                            TextSpan(
                              text: '${modeLabel.split(' ').first} ',
                              style: GoogleFonts.outfit(
                                color: const Color(0xFFFFD600),
                                fontSize: 26,
                                fontWeight: FontWeight.w800,
                                letterSpacing: -0.5,
                              ),
                            ),
                            TextSpan(
                              text: modeLabel.split(' ').skip(1).join(' '),
                              style: GoogleFonts.outfit(
                                color: Colors.white,
                                fontSize: 26,
                                fontWeight: FontWeight.bold,
                                letterSpacing: -0.5,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 24),

                // â”€â”€ Two-panel body â”€â”€
                Expanded(
                  child: Row(
                    children: [
                      // Left: File Setup / Cast Controls
                      Expanded(
                        flex: 2,
                        child: _buildLeftPanel(),
                      ),
                      const SizedBox(width: 32),
                      Container(width: 1, color: Colors.white.withValues(alpha: 0.06)),
                      const SizedBox(width: 32),
                      // Right: Device Discovery
                      Expanded(
                        flex: 3,
                        child: _buildRightPanel(),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLeftPanel() {
    if (widget.initialMode == CastMode.screenMirror) {
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _isMirroring ? 'MIRRORING ACTIVE' : 'SCREEN MIRROR',
            style: GoogleFonts.outfit(
              color: Colors.white38,
              fontSize: 12,
              fontWeight: FontWeight.w800,
              letterSpacing: 2.0,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            _isMirroring
                ? 'Sharing TV Screen to $_mirrorTargetName'
                : 'Select a target device on the right to start mirroring your TV screen.',
            style: GoogleFonts.outfit(
              color: Colors.white,
              fontSize: 20,
              height: 1.5,
            ),
          ),
          if (_isMirroring) ...[
            const SizedBox(height: 24),
            TVFocusableButton(
              onPressed: _stopMirroring,
              backgroundColor: Colors.red.withValues(alpha: 0.15),
              focusColor: Colors.redAccent,
              borderRadius: BorderRadius.circular(14),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              child: Text(
                'Stop Mirroring',
                style: GoogleFonts.outfit(
                  color: Colors.redAccent,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ],
      );
    }

    if (_castTargetIp != null) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CastRemoteControlWidget(
            targetDeviceIp: _castTargetIp!,
            targetDeviceName: _castTargetName ?? 'Device',
            fileName: _selectedFileName ?? 'Video',
            videoUrl: _serverUrl,
            onDisconnect: () {
              setState(() {
                _castTargetIp = null;
                _castTargetName = null;
              });
            },
          ),
          const SizedBox(height: 16),
          TVFocusableButton(
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => TvRemoteControlScreen(
                    targetDeviceIp: _castTargetIp!,
                    targetDeviceName: _castTargetName ?? 'Device',
                    fileName: _selectedFileName ?? 'Video',
                  ),
                ),
              );
            },
            backgroundColor: const Color(0xFFFFD600),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            borderRadius: BorderRadius.circular(14),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.open_in_full_rounded, color: Colors.black, size: 18),
                const SizedBox(width: 8),
                Text(
                  'Full Remote Control',
                  style: GoogleFonts.outfit(color: Colors.black, fontWeight: FontWeight.bold, fontSize: 14),
                ),
              ],
            ),
          ),
        ],
      );
    }

    // Video setup
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          'MEDIA SETUP',
          style: GoogleFonts.outfit(
            color: Colors.white38,
            fontSize: 12,
            fontWeight: FontWeight.w800,
            letterSpacing: 2.0,
          ),
        ),
        const SizedBox(height: 16),
        Text(
          _selectedFileName ?? 'No video selected',
          style: GoogleFonts.outfit(
            color: Colors.white,
            fontSize: 22,
            fontWeight: FontWeight.bold,
          ),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 24),
        Row(
          children: [
            TVFocusableButton(
              onPressed: _pickVideo,
              autofocus: _selectedFileName == null,
              backgroundColor: const Color(0xFFFFD600),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              borderRadius: BorderRadius.circular(14),
              child: Text(
                'Choose Video',
                style: GoogleFonts.outfit(color: Colors.black, fontWeight: FontWeight.bold),
              ),
            ),
            if (_selectedFileName != null) ...[
              const SizedBox(width: 16),
              TVFocusableButton(
                onPressed: _pickSubtitle,
                backgroundColor: Colors.white.withValues(alpha: 0.05),
                focusColor: const Color(0xFFFFD600),
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                borderRadius: BorderRadius.circular(14),
                child: Text(
                  _selectedSubtitleName == null ? 'Add Subtitle' : 'Change Subtitle',
                  style: GoogleFonts.outfit(color: Colors.white, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }

  Widget _buildRightPanel() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'DISCOVERED DEVICES',
          style: GoogleFonts.outfit(
            color: Colors.white38,
            fontSize: 12,
            fontWeight: FontWeight.w800,
            letterSpacing: 2.0,
          ),
        ),
        const SizedBox(height: 16),
        Expanded(
          child: _devices.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      SearchPulseWidget(
                        size: 180,
                        color: const Color(0xFFFFD600),
                        showCenterDot: false,
                        child: Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.04),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.wifi_tethering_rounded, color: Colors.white, size: 36),
                        ),
                      ),
                      const SizedBox(height: 24),
                      Text(
                        'Scanning for devices...',
                        style: GoogleFonts.outfit(color: Colors.white70, fontSize: 15, fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Make sure other devices are on the same Wi-Fi',
                        style: GoogleFonts.outfit(color: Colors.white38, fontSize: 12),
                      ),
                    ],
                  ),
                )
              : ListView.separated(
                  itemCount: _devices.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 12),
                  itemBuilder: (context, index) {
                    final d = _devices[index];
                    final isDisabled = widget.initialMode == CastMode.video && _selectedFileName == null;
                    return TVFocusableCard(
                      borderRadius: const BorderRadius.all(Radius.circular(20)),
                      onPressed: isDisabled ? null : () => _castToDevice(d),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                        child: Row(
                          children: [
                            const Icon(Icons.tv_rounded, color: Colors.white, size: 24),
                            const SizedBox(width: 16),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    d.deviceName,
                                    style: GoogleFonts.outfit(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    d.ipAddress,
                                    style: GoogleFonts.outfit(color: Colors.white38, fontSize: 12),
                                  ),
                                ],
                              ),
                            ),
                            isDisabled
                                ? Text(
                                    'Select Video First',
                                    style: GoogleFonts.outfit(color: Colors.white38, fontSize: 12),
                                  )
                                : const Icon(Icons.chevron_right_rounded, color: Colors.white38),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
