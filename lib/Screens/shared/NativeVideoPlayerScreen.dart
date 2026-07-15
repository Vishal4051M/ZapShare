import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:zap_share/services/device_discovery_service.dart';

/// Launches [NativeVideoPlayerActivity] (Android-only) for butter-smooth
/// SurfaceView playback, bypassing Flutter's Texture pipeline entirely.
///
/// When [castControllerIp] is set, this widget relays cast commands between
/// Flutter's DeviceDiscoveryService (UDP port 37020) and the native Activity
/// via a MethodChannel, avoiding UDP port conflicts.
class NativeVideoPlayerScreen extends StatefulWidget {
  final String videoSource;
  final String? title;
  final String? subtitlePath;
  final int startPosition;
  final String? castControllerIp;

  const NativeVideoPlayerScreen({
    super.key,
    required this.videoSource,
    this.title,
    this.subtitlePath,
    this.startPosition = 0,
    this.castControllerIp,
  });

  @override
  State<NativeVideoPlayerScreen> createState() =>
      _NativeVideoPlayerScreenState();
}

class _NativeVideoPlayerScreenState extends State<NativeVideoPlayerScreen> {
  static const _channel = MethodChannel('zapshare.saf');
  static const _castChannel = MethodChannel('zapshare.native_cast');

  StreamSubscription<CastControl>? _castControlSub;
  Timer? _statusTimer;

  @override
  void initState() {
    super.initState();
    _launch();
  }

  @override
  void dispose() {
    _castControlSub?.cancel();
    _statusTimer?.cancel();
    super.dispose();
  }

  Future<void> _launch() async {
    if (!Platform.isAndroid) {
      if (mounted) Navigator.of(context).pop();
      return;
    }

    // Start cast relay BEFORE launching native Activity
    // (the relay runs via event loop while _channel.invokeMethod awaits)
    if (widget.castControllerIp != null &&
        widget.castControllerIp!.isNotEmpty) {
      _startCastRelay();
    }

    try {
      final result = await _channel
          .invokeMethod<Map>('launchNativeVideoPlayer', {
            'source': widget.videoSource,
            'title': widget.title ?? '',
            'subtitlePath': widget.subtitlePath ?? '',
            'position': widget.startPosition,
            'castControllerIp': widget.castControllerIp ?? '',
          });

      final lastPosition = (result?['position'] as num?)?.toInt() ?? 0;
      if (widget.castControllerIp != null &&
          widget.castControllerIp!.isNotEmpty) {
        try {
          DeviceDiscoveryService().sendCastStatus(
            widget.castControllerIp!,
            position: lastPosition / 1000.0,
            duration: 0,
            buffered: 0,
            isPlaying: false,
            isBuffering: false,
            volume: 1.0,
            fileName: widget.title,
            active: false,
          );
        } catch (_) {}
      }
      _stopCastRelay();
      if (mounted) Navigator.of(context).pop(lastPosition);
    } on PlatformException catch (e) {
      debugPrint('[NativeVideoPlayer] PlatformException: ${e.message}');
      if (widget.castControllerIp != null &&
          widget.castControllerIp!.isNotEmpty) {
        try {
          DeviceDiscoveryService().sendCastStatus(
            widget.castControllerIp!,
            position: 0,
            duration: 0,
            buffered: 0,
            isPlaying: false,
            isBuffering: false,
            volume: 1.0,
            fileName: widget.title,
            active: false,
          );
        } catch (_) {}
      }
      _stopCastRelay();
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      debugPrint('[NativeVideoPlayer] error: $e');
      if (widget.castControllerIp != null &&
          widget.castControllerIp!.isNotEmpty) {
        try {
          DeviceDiscoveryService().sendCastStatus(
            widget.castControllerIp!,
            position: 0,
            duration: 0,
            buffered: 0,
            isPlaying: false,
            isBuffering: false,
            volume: 1.0,
            fileName: widget.title,
            active: false,
          );
        } catch (_) {}
      }
      _stopCastRelay();
      if (mounted) Navigator.of(context).pop();
    }
  }

  /// Start relaying cast commands from DeviceDiscoveryService → native Activity
  /// and polling native status → DeviceDiscoveryService → cast controller.
  void _startCastRelay() {
    final discoveryService = DeviceDiscoveryService();
    final controllerIp = widget.castControllerIp!;

    void forwardStatus(Map? status) {
      if (status == null) return;
      discoveryService.sendCastStatus(
        controllerIp,
        position: (status['position'] as num?)?.toDouble() ?? 0,
        duration: (status['duration'] as num?)?.toDouble() ?? 0,
        buffered: (status['buffered'] as num?)?.toDouble() ?? 0,
        isPlaying: status['isPlaying'] as bool? ?? false,
        isBuffering: status['isBuffering'] as bool? ?? false,
        volume: (status['volume'] as num?)?.toDouble() ?? 1.0,
        fileName: status['fileName'] as String?,
        audioTracks: (status['audioTracks'] as List?)?.cast<String>(),
        subtitleTracks: (status['subtitleTracks'] as List?)?.cast<String>(),
        activeAudioTrack: (status['activeAudioTrack'] as num?)?.toInt(),
        activeAudioTrackLabel: status['activeAudioTrackLabel'] as String?,
        activeSubtitleTrack: (status['activeSubtitleTrack'] as num?)?.toInt(),
        audioOutput: status['audioOutput'] as String?,
        active: status['active'] as bool? ?? true,
      );
    }

    _castControlSub = discoveryService.castControlStream.listen((control) {
      _castChannel.invokeMethod('castCommand', {
        'action': control.action,
        if (control.seekPosition != null) 'seekPosition': control.seekPosition,
        if (control.volume != null) 'volume': control.volume,
        if (control.trackIndex != null) 'trackIndex': control.trackIndex,
        if (control.propertyValue != null)
          'propertyValue': control.propertyValue,
      });
    });

    _castChannel.setMethodCallHandler((call) async {
      if (call.method == 'statusChanged') {
        forwardStatus((call.arguments as Map?)?.cast());
      }
      return null;
    });

    // Poll native player status every 1 second and send to controller
    _statusTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
      try {
        final status = await _castChannel.invokeMethod<Map>('getStatus');
        forwardStatus(status);
      } catch (_) {}
    });

    // Send initial status after short delay
    Future.delayed(const Duration(milliseconds: 500), () async {
      if (!mounted) return;
      try {
        final status = await _castChannel.invokeMethod<Map>('getStatus');
        forwardStatus(status);
      } catch (_) {}
    });
  }

  void _stopCastRelay() {
    _castControlSub?.cancel();
    _castControlSub = null;
    _statusTimer?.cancel();
    _statusTimer = null;
    _castChannel.setMethodCallHandler(null);
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: SizedBox(
          width: 36,
          height: 36,
          child: CircularProgressIndicator(
            color: Color(0xFFFFD600),
            strokeWidth: 2.5,
          ),
        ),
      ),
    );
  }
}
