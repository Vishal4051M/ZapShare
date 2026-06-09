import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../services/device_discovery_service.dart';
import '../services/udp_audio_receiver_service.dart';
import '../Screens/shared/native_platform_mpv_player.dart';

class AudioReceiverController extends ChangeNotifier {
  final String senderIp;
  final bool useLanAudio;
  final String? audioUrl;
  final DeviceDiscoveryService _discoveryService = DeviceDiscoveryService();
  final UdpAudioReceiverService _udpAudioService = UdpAudioReceiverService();

  bool _isReceiving = false;
  bool get isReceiving => _isReceiving;

  bool _isPlaying = true;
  bool get isPlaying => _isPlaying;

  double _volume = 80;
  double get volume => _volume;

  int _cushionMs = 40; // Default
  int get cushionMs => _cushionMs;

  bool _startingReceiver = false;
  Process? _receiverProcess;

  NativePlatformMpvPlayer? _mpvPlayer;
  NativePlatformMpvPlayer? get mpvPlayer => _mpvPlayer;

  StreamSubscription<bool>? _audioStateSub;

  AudioReceiverController({
    required this.senderIp,
    this.useLanAudio = true,
    this.audioUrl,
  });

  void init() {
    _discoveryService.setPreferredCushionMs(_cushionMs);
    if (useLanAudio || (audioUrl != null && audioUrl!.isNotEmpty)) {
      _discoveryService.pauseDiscovery();
      _startReceiving();
    } else {
      _isReceiving = _discoveryService.isAudioActive;
      notifyListeners();
    }

    _audioStateSub = _discoveryService.activeAudioStream.listen((active) {
      if (_isReceiving != active) {
        _isReceiving = active;
        notifyListeners();
      }
    });
  }

  void setCushion(int ms) {
    _cushionMs = ms;
    _discoveryService.setPreferredCushionMs(ms);
    _udpAudioService.cushionMs =
        ms; // Instantly apply cushion to running receiver

    // For Windows, restart the process with the new cushion
    if (Platform.isWindows && _receiverProcess != null) {
      _receiverProcess?.kill();
      _receiverProcess = null;
      _startReceiving();
    }

    notifyListeners();
    // Only restart if NOT currently receiving — apply next session
    if (useLanAudio && !_isReceiving && !Platform.isWindows) {
      _startReceiving();
    }
  }

  void setVolume(double val) {
    _volume = val;
    _mpvPlayer?.setVolume(val);
    notifyListeners();
  }

  void togglePlay() {
    if (_isPlaying) {
      _mpvPlayer?.pause();
      if (Platform.isWindows && _receiverProcess != null) {
        _receiverProcess?.kill();
        _receiverProcess = null;
      }
    } else {
      _mpvPlayer?.play();
      if (Platform.isWindows &&
          _receiverProcess == null &&
          (audioUrl == null || audioUrl!.isEmpty)) {
        _startReceiving();
      }
    }
    _isPlaying = !_isPlaying;
    notifyListeners();
  }

  Future<void> _startReceiving() async {
    if (_startingReceiver) return;
    _startingReceiver = true;
    try {
      _isReceiving = true;
      notifyListeners();

      if (Platform.isWindows && (audioUrl == null || audioUrl!.isEmpty)) {
        // Stop any previous process
        _receiverProcess?.kill();
        _receiverProcess = null;

        final exeFile = File(Platform.resolvedExecutable);
        final appDir = exeFile.parent.path;
        final receiverPath = '$appDir/ZapShareAudioReceiver.exe';
        final fallbackReceiverPath =
            '${Directory.current.path}/build/windows/x64/runner/Debug/ZapShareAudioReceiver.exe';

        String finalPath = receiverPath;
        if (!await File(receiverPath).exists() &&
            await File(fallbackReceiverPath).exists()) {
          finalPath = fallbackReceiverPath;
        }

        print(
          '🔊 Launching native Windows audio receiver: $finalPath --port 50005 --cushion $_cushionMs',
        );
        try {
          _receiverProcess = await Process.start(finalPath, [
            '--port',
            '50005',
            '--cushion',
            '$_cushionMs',
          ]);

          _receiverProcess?.stdout.transform(const Utf8Decoder()).listen((
            data,
          ) {
            print('🔊 [Native Receiver]: $data');
          });
          _receiverProcess?.stderr.transform(const Utf8Decoder()).listen((
            data,
          ) {
            print('🔊 [Native Receiver Error]: $data');
          });
        } catch (e) {
          print(
            '❌ Failed to launch native receiver: $e. Falling back to HTTP loopback.',
          );
          await _startUdpHttpFallback();
        }
      } else if (Platform.isLinux || Platform.isWindows) {
        // For Windows HTTP WAV casting or Linux, use the Dart/MPV path
        await _startUdpHttpFallback();
      } else if (Platform.isAndroid) {
        await _discoveryService.stopLanAudioSender();
        await _discoveryService.startLanAudioReceiver(cushionMs: _cushionMs);
      }
    } finally {
      _startingReceiver = false;
    }
  }

  Future<void> _startUdpHttpFallback() async {
    _udpAudioService.stop();
    _mpvPlayer?.dispose();

    _mpvPlayer = NativePlatformMpvPlayer();
    await _mpvPlayer?.setVolume(_volume);

    if (audioUrl != null && audioUrl!.isNotEmpty) {
      // Play HTTP WAV stream directly with MPV low-latency properties!
      await _mpvPlayer?.setProperty('profile', 'low-latency');
      await _mpvPlayer?.setProperty('untimed', '');
      await _mpvPlayer?.setProperty('cache', 'no');
      await _mpvPlayer?.setProperty('cache-pause', 'no');
      await _mpvPlayer?.setProperty('audio-buffer', '0.05');
      await _mpvPlayer?.setProperty('demuxer-lavf-format', 'wav');
      await _mpvPlayer?.setProperty(
        'demuxer-lavf-o',
        'fflags=nobuffer,probesize=32,analyzeduration=0',
      );
      await _mpvPlayer?.setProperty('demuxer-max-bytes', '4096');
      await _mpvPlayer?.setProperty('demuxer-max-back-bytes', '0');
      await _mpvPlayer?.setProperty('hr-seek-framedrop', 'yes');
      await _mpvPlayer?.setProperty('network-timeout', '100');

      await _mpvPlayer?.open(audioUrl!);
    } else {
      // Fallback to UDP/PCM loopback
      _udpAudioService.setOnDataReceived(() async {
        if (_isPlaying && _mpvPlayer != null) {
          await _mpvPlayer?.setProperty('cache', 'no');
          await _mpvPlayer?.setProperty('audio-buffer', '0.08');
          await _mpvPlayer?.setProperty('demuxer-max-bytes', '1048576');
          _mpvPlayer?.open('http://localhost:50006/live.wav');
        }
      });

      _udpAudioService.cushionMs = _cushionMs; // Set initial cushion
      await _udpAudioService.start();
    }
  }

  @override
  void dispose() {
    _audioStateSub?.cancel();
    _discoveryService.resumeDiscovery();

    _receiverProcess?.kill();
    _receiverProcess = null;

    if (Platform.isLinux || Platform.isWindows) {
      _mpvPlayer?.dispose();
      _udpAudioService.stop();
    } else {
      if (!useLanAudio) {
        _discoveryService.stopWebRtcAudio();
      }
      if (useLanAudio) {
        _discoveryService.stopLanAudioReceiver();
      }
    }
    super.dispose();
  }
}
