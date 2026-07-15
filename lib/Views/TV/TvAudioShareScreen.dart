import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:zap_share/widgets/tv_widgets.dart';
import 'package:zap_share/widgets/SearchPulseWidget.dart';
import 'package:zap_share/services/device_discovery_service.dart';

class TvAudioShareScreen extends StatefulWidget {
  const TvAudioShareScreen({super.key});

  @override
  State<TvAudioShareScreen> createState() => _TvAudioShareScreenState();
}

class _TvAudioShareScreenState extends State<TvAudioShareScreen>
    with SingleTickerProviderStateMixin {
  final DeviceDiscoveryService _discoveryService = DeviceDiscoveryService();
  static const _channel = MethodChannel('zapshare.saf');

  List<DiscoveredDevice> _devices = [];
  StreamSubscription? _devicesSubscription;

  bool _isSending = false;
  bool _isReceiving = false;
  String? _activeTargetIp;
  String? _activeTargetName;
  bool _useSystemAudio = true;

  // Pulse animation for active state
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat(reverse: true);
    _pulseAnimation = Tween<double>(begin: 0.95, end: 1.05).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
    _initDiscovery();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (TVHelper.isTV(context)) {
        setState(() {
          _useSystemAudio = false;
        });
      }
    });
  }

  Future<void> _initDiscovery() async {
    await _discoveryService.initialize();
    _devicesSubscription = _discoveryService.devicesStream.listen((devices) {
      if (mounted) setState(() => _devices = devices);
    });
    await _discoveryService.start();
  }

  Future<void> _startSendingAudio(DiscoveredDevice device) async {
    if (_isSending || _isReceiving) return;

    if (!_useSystemAudio && Platform.isAndroid) {
      final status = await Permission.microphone.request();
      if (!status.isGranted) {
        _showMessage('Microphone permission denied', Colors.red);
        return;
      }
    }

    try {
      final success = await _channel.invokeMethod<bool>('startLanAudioSender', {
            'ips': [device.ipAddress],
            'usePcm': false,
            'useSystemAudio': _useSystemAudio,
          }) ??
          false;

      if (success) {
        await _discoveryService.sendNativeSystemAudioOffer(
          device.ipAddress,
          50005,
          cushionMs: 40,
        );
        setState(() {
          _isSending = true;
          _activeTargetIp = device.ipAddress;
          _activeTargetName = device.deviceName;
        });
        _showMessage('Streaming to ${device.deviceName}', const Color(0xFFFFD600));
      } else {
        _showMessage('Failed to start audio stream', Colors.red);
      }
    } catch (e) {
      _showMessage('Error: $e', Colors.red);
    }
  }

  Future<void> _stopSendingAudio() async {
    try {
      await _channel.invokeMethod('stopForegroundService');
      await _channel.invokeMethod('stopLanAudioSender');
      setState(() {
        _isSending = false;
        _activeTargetIp = null;
        _activeTargetName = null;
      });
      _showMessage('Audio stream stopped', Colors.white38);
    } catch (e) {
      _showMessage('Stop error: $e', Colors.red);
    }
  }

  Future<void> _toggleReceiveMode() async {
    if (_isSending) return;
    if (_isReceiving) {
      await _discoveryService.stopLanAudioReceiver();
      setState(() => _isReceiving = false);
      _showMessage('Receiver disabled', Colors.white38);
    } else {
      await _discoveryService.startLanAudioReceiver(port: 50005);
      setState(() => _isReceiving = true);
      _showMessage('Ready to receive audio', const Color(0xFF69C9FF));
    }
  }

  void _showMessage(String msg, Color color) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg, style: GoogleFonts.outfit(color: Colors.black, fontWeight: FontWeight.w600)),
        backgroundColor: color,
        duration: const Duration(seconds: 2),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.fromLTRB(48, 0, 48, 24),
      ),
    );
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _devicesSubscription?.cancel();
    if (_isSending) {
      _channel.invokeMethod('stopForegroundService');
      _channel.invokeMethod('stopLanAudioSender');
    }
    if (_isReceiving) {
      _discoveryService.stopLanAudioReceiver();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
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
                // ── Header ──
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
                              text: 'Audio ',
                              style: GoogleFonts.outfit(
                                color: const Color(0xFFFFD600),
                                fontSize: 26,
                                fontWeight: FontWeight.w800,
                                letterSpacing: -0.5,
                              ),
                            ),
                            TextSpan(
                              text: 'Share',
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
                    // Live status indicator
                    if (_isSending || _isReceiving)
                      AnimatedBuilder(
                        animation: _pulseAnimation,
                        builder: (_, __) => Transform.scale(
                          scale: _pulseAnimation.value,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                            decoration: BoxDecoration(
                              color: _isSending
                                  ? const Color(0xFFFFD600).withValues(alpha: 0.15)
                                  : const Color(0xFF69C9FF).withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(
                                color: _isSending
                                    ? const Color(0xFFFFD600).withValues(alpha: 0.5)
                                    : const Color(0xFF69C9FF).withValues(alpha: 0.5),
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Container(
                                  width: 8,
                                  height: 8,
                                  decoration: BoxDecoration(
                                    color: _isSending ? const Color(0xFFFFD600) : const Color(0xFF69C9FF),
                                    shape: BoxShape.circle,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  _isSending ? 'STREAMING' : 'RECEIVING',
                                  style: GoogleFonts.outfit(
                                    color: _isSending ? const Color(0xFFFFD600) : const Color(0xFF69C9FF),
                                    fontSize: 12,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: 1.0,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                  ],
                ),

                const SizedBox(height: 28),

                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // ── Left: Control Panel ──
                      SizedBox(
                        width: 320,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'CONTROLS',
                              style: GoogleFonts.outfit(
                                color: Colors.grey[400],
                                fontSize: 11,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 1.2,
                              ),
                            ),
                            const SizedBox(height: 16),

                            // Status card
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.all(20),
                              decoration: BoxDecoration(
                                color: const Color(0xFF1C1C1E),
                                borderRadius: BorderRadius.circular(20),
                                border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'STATUS',
                                    style: GoogleFonts.outfit(
                                      color: Colors.white38,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w800,
                                      letterSpacing: 1.2,
                                    ),
                                  ),
                                  const SizedBox(height: 10),
                                  Text(
                                    _isSending
                                        ? 'Streaming to $_activeTargetName'
                                        : _isReceiving
                                            ? 'Waiting for incoming audio…'
                                            : 'Inactive — pick an option below',
                                    style: GoogleFonts.outfit(
                                      color: Colors.white,
                                      fontSize: 15,
                                      fontWeight: FontWeight.w500,
                                      height: 1.4,
                                    ),
                                  ),
                                ],
                              ),
                            ),

                            const SizedBox(height: 20),

                            // Source toggle — only shown when idle and not on TV
                            if (!_isSending && !_isReceiving && !TVHelper.isTV(context)) ...[
                              Text(
                                'AUDIO SOURCE',
                                style: GoogleFonts.outfit(
                                  color: Colors.grey[400],
                                  fontSize: 11,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 1.2,
                                ),
                              ),
                              const SizedBox(height: 10),
                              TVSourceToggle(
                                value: _useSystemAudio,
                                firstLabel: 'System Audio',
                                firstIcon: Icons.speaker_rounded,
                                secondLabel: 'Microphone',
                                secondIcon: Icons.mic_rounded,
                                onChanged: (val) => setState(() => _useSystemAudio = val),
                              ),
                              const SizedBox(height: 20),
                            ],

                            // Receive mode toggle button
                            if (!_isSending)
                              TVFocusableButton(
                                autofocus: !(_isSending || _isReceiving),
                                backgroundColor: _isReceiving
                                    ? const Color(0xFF69C9FF).withValues(alpha: 0.15)
                                    : const Color(0xFF1C1C1E),
                                focusColor: const Color(0xFF69C9FF),
                                padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
                                borderRadius: BorderRadius.circular(18),
                                onPressed: _toggleReceiveMode,
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(
                                      _isReceiving ? Icons.stop_circle_rounded : Icons.hearing_rounded,
                                      color: _isReceiving ? const Color(0xFF69C9FF) : Colors.white,
                                      size: 22,
                                    ),
                                    const SizedBox(width: 10),
                                    Text(
                                      _isReceiving ? 'Disable Receiver' : 'Enable Receiver Mode',
                                      style: GoogleFonts.outfit(
                                        color: _isReceiving ? const Color(0xFF69C9FF) : Colors.white,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 15,
                                      ),
                                    ),
                                  ],
                                ),
                              ),

                            // Stop sending button
                            if (_isSending)
                              TVFocusableButton(
                                autofocus: true,
                                backgroundColor: Colors.red.withValues(alpha: 0.12),
                                focusColor: Colors.redAccent,
                                padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
                                borderRadius: BorderRadius.circular(18),
                                onPressed: _stopSendingAudio,
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    const Icon(Icons.stop_rounded, color: Colors.redAccent, size: 22),
                                    const SizedBox(width: 10),
                                    Text(
                                      'Stop Streaming',
                                      style: GoogleFonts.outfit(
                                        color: Colors.redAccent,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 15,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                          ],
                        ),
                      ),

                      const SizedBox(width: 24),
                      Container(width: 1, color: Colors.white.withValues(alpha: 0.06)),
                      const SizedBox(width: 24),

                      // ── Right: Device list ──
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'SELECT TARGET TO STREAM TO',
                              style: GoogleFonts.outfit(
                                color: Colors.grey[400],
                                fontSize: 11,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 1.2,
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
                                            size: 160,
                                            color: const Color(0xFFFFD600),
                                            showCenterDot: false,
                                            child: Container(
                                              padding: const EdgeInsets.all(18),
                                              decoration: BoxDecoration(
                                                color: Colors.white.withValues(alpha: 0.04),
                                                shape: BoxShape.circle,
                                              ),
                                              child: const Icon(
                                                Icons.wifi_tethering_rounded,
                                                color: Colors.white,
                                                size: 32,
                                              ),
                                            ),
                                          ),
                                          const SizedBox(height: 20),
                                          Text(
                                            'Scanning for devices…',
                                            style: GoogleFonts.outfit(
                                              color: Colors.white70,
                                              fontSize: 16,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                          const SizedBox(height: 6),
                                          Text(
                                            'Make sure devices are on the same Wi-Fi',
                                            style: GoogleFonts.outfit(
                                              color: Colors.white38,
                                              fontSize: 13,
                                            ),
                                          ),
                                        ],
                                      ),
                                    )
                                  : ListView.separated(
                                      itemCount: _devices.length,
                                      separatorBuilder: (_, __) => const SizedBox(height: 12),
                                      itemBuilder: (context, i) {
                                        final d = _devices[i];
                                        final isBusy = _isSending || _isReceiving;
                                        final isActive = _isSending && _activeTargetIp == d.ipAddress;

                                        return TVFocusableCard(
                                          autofocus: i == 0 && (_isSending || _isReceiving),
                                          borderRadius: const BorderRadius.all(Radius.circular(20)),
                                          backgroundColor: isActive
                                              ? const Color(0xFFFFD600).withValues(alpha: 0.1)
                                              : const Color(0xFF1C1C1E),
                                          focusColor: const Color(0xFFFFD600),
                                          onPressed: isBusy ? null : () => _startSendingAudio(d),
                                          child: Padding(
                                            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
                                            child: Row(
                                              children: [
                                                // Device icon
                                                Container(
                                                  width: 48,
                                                  height: 48,
                                                  decoration: BoxDecoration(
                                                    color: isActive
                                                        ? const Color(0xFFFFD600).withValues(alpha: 0.15)
                                                        : Colors.white.withValues(alpha: 0.05),
                                                    shape: BoxShape.circle,
                                                  ),
                                                  child: Icon(
                                                    Icons.phone_android_rounded,
                                                    color: isActive ? const Color(0xFFFFD600) : Colors.white54,
                                                    size: 24,
                                                  ),
                                                ),
                                                const SizedBox(width: 16),
                                                Expanded(
                                                  child: Column(
                                                    crossAxisAlignment: CrossAxisAlignment.start,
                                                    children: [
                                                      Text(
                                                        d.deviceName,
                                                        style: GoogleFonts.outfit(
                                                          color: Colors.white,
                                                          fontWeight: FontWeight.bold,
                                                          fontSize: 16,
                                                        ),
                                                      ),
                                                      const SizedBox(height: 2),
                                                      Text(
                                                        d.ipAddress,
                                                        style: GoogleFonts.outfit(
                                                          color: Colors.white38,
                                                          fontSize: 12,
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                                if (isActive)
                                                  Container(
                                                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                                    decoration: BoxDecoration(
                                                      color: const Color(0xFFFFD600).withValues(alpha: 0.15),
                                                      borderRadius: BorderRadius.circular(10),
                                                    ),
                                                    child: Text(
                                                      'STREAMING',
                                                      style: GoogleFonts.outfit(
                                                        color: const Color(0xFFFFD600),
                                                        fontSize: 11,
                                                        fontWeight: FontWeight.w800,
                                                        letterSpacing: 0.8,
                                                      ),
                                                    ),
                                                  )
                                                else if (isBusy)
                                                  Text(
                                                    'Busy',
                                                    style: GoogleFonts.outfit(color: Colors.white24, fontSize: 13),
                                                  )
                                                else
                                                  Row(
                                                    mainAxisSize: MainAxisSize.min,
                                                    children: [
                                                      const Icon(Icons.stream_rounded, color: Color(0xFFFFD600), size: 16),
                                                      const SizedBox(width: 6),
                                                      Text(
                                                        'Stream',
                                                        style: GoogleFonts.outfit(
                                                          color: const Color(0xFFFFD600),
                                                          fontWeight: FontWeight.w600,
                                                          fontSize: 13,
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                              ],
                                            ),
                                          ),
                                        );
                                      },
                                    ),
                            ),
                          ],
                        ),
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
}
