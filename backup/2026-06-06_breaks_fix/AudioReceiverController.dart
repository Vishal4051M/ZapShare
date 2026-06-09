// import 'dart:async';
// import 'dart:io';
// import 'package:flutter/foundation.dart';
// import '../services/device_discovery_service.dart';
// import '../services/udp_audio_receiver_service.dart';
// import '../Screens/shared/native_platform_mpv_player.dart';

// class AudioReceiverController extends ChangeNotifier {
//   final String senderIp;
//   final bool useLanAudio;
//   final DeviceDiscoveryService _discoveryService = DeviceDiscoveryService();
//   final UdpAudioReceiverService _udpAudioService = UdpAudioReceiverService();

//   bool _isReceiving = false;
//   bool get isReceiving => _isReceiving;

//   bool _isPlaying = true;
//   bool get isPlaying => _isPlaying;

//   double _volume = 80;
//   double get volume => _volume;

//   int _cushionMs = 15; // Default
//   int get cushionMs => _cushionMs;

//   bool _startingReceiver = false;

//   NativePlatformMpvPlayer? _mpvPlayer;
//   NativePlatformMpvPlayer? get mpvPlayer => _mpvPlayer;

//   StreamSubscription<bool>? _audioStateSub;

//   AudioReceiverController({required this.senderIp, this.useLanAudio = true});

//   void init() {
//     _discoveryService.setPreferredCushionMs(_cushionMs);
//     if (useLanAudio) {
//       _discoveryService.pauseDiscovery();
//       _startReceiving();
//     } else {
//       _isReceiving = _discoveryService.isAudioActive;
//       notifyListeners();
//     }

//     _audioStateSub = _discoveryService.activeAudioStream.listen((active) {
//       if (_isReceiving != active) {
//         _isReceiving = active;
//         notifyListeners();
//       }
//     });
//   }

//   void setCushion(int ms) {
//     _cushionMs = ms;
//     _discoveryService.setPreferredCushionMs(ms);
//     _udpAudioService.cushionMs = ms; // Instantly apply cushion to running receiver
//     notifyListeners();
//     if (useLanAudio && !_isReceiving) {
//       _startReceiving();
//     }
//   }

//   void setVolume(double val) {
//     _volume = val;
//     _mpvPlayer?.setVolume(val);
//     notifyListeners();
//   }

//   void togglePlay() {
//     if (_isPlaying) {
//       _mpvPlayer?.pause();
//     } else {
//       _mpvPlayer?.play();
//     }
//     _isPlaying = !_isPlaying;
//     notifyListeners();
//   }

//   Future<void> _startReceiving() async {
//     if (_startingReceiver) return;
//     _startingReceiver = true;
//     try {
//       _isReceiving = true;
//       notifyListeners();

//       if (Platform.isLinux || Platform.isWindows) {
//         _udpAudioService.stop();
//         _mpvPlayer?.dispose();

//         _mpvPlayer = NativePlatformMpvPlayer();
//         await _mpvPlayer?.setVolume(_volume);

//         _udpAudioService.setOnDataReceived(() async {
//           if (_isPlaying && _mpvPlayer != null) {
//             await _mpvPlayer?.setProperty('profile', 'low-latency');
//             await _mpvPlayer?.setProperty('cache', 'no');
//             await _mpvPlayer?.setProperty('audio-buffer', '0.01');
//             await _mpvPlayer?.setProperty('demuxer-max-bytes', '4096');
//             _mpvPlayer?.open('http://localhost:50006/live.wav');
//           }
//         });

//         _udpAudioService.cushionMs = _cushionMs; // Set initial cushion
//         await _udpAudioService.start();
//       } else if (Platform.isAndroid) {
//         await _discoveryService.stopLanAudioSender();
//         await _discoveryService.startLanAudioReceiver(cushionMs: _cushionMs);
//       }
//     } finally {
//       _startingReceiver = false;
//     }
//   }

//   @override
//   void dispose() {
//     _audioStateSub?.cancel();
//     _discoveryService.resumeDiscovery();
//     if (Platform.isLinux || Platform.isWindows) {
//       _mpvPlayer?.dispose();
//       _udpAudioService.stop();
//     } else {
//       if (!useLanAudio) {
//         _discoveryService.stopWebRtcAudio();
//       }
//       if (useLanAudio) {
//         _discoveryService.stopLanAudioReceiver();
//       }
//     }
//     super.dispose();
//   }
// }
