import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';
import 'package:zap_share/services/device_discovery_service.dart';

class ScreenMirrorController {
  final String streamUrl;
  final String? senderIp;
  final VoidCallback onFrameUpdated;
  final Function(String) onError;
  final Function(double) onRatioDetected;

  Uint8List? currentFrame;
  bool isConnected = false;
  bool isConnecting = true;
  String? error;

  HttpClient? _httpClient;
  int _frameCount = 0;
  DateTime? _startTime;
  DateTime? _lastFrameTime;
  Player? audioPlayer;
  bool audioAvailable = false;
  bool isDisposed = false;

  int _reconnectAttempts = 0;
  static const _maxReconnectAttempts = 10;
  Timer? _reconnectTimer;
  Timer? _idleTimer;

  final DeviceDiscoveryService _discoveryService = DeviceDiscoveryService();

  ScreenMirrorController({
    required this.streamUrl,
    required this.senderIp,
    required this.onFrameUpdated,
    required this.onError,
    required this.onRatioDetected,
  }) {
    _discoveryService.pauseDiscovery();
    connect();
    connectAudio();
  }

  String get audioUrl {
    final uri = Uri.parse(streamUrl);
    return '${uri.scheme}://${uri.host}:${uri.port}/audio';
  }

  double get fps {
    if (_startTime == null || _frameCount == 0) return 0.0;
    final elapsed = DateTime.now().difference(_startTime!).inSeconds;
    if (elapsed == 0) return 0.0;
    return _frameCount / elapsed;
  }

  String get statusText {
    if (!isConnected && _reconnectAttempts > 0) {
      return 'Reconnecting ($_reconnectAttempts/$_maxReconnectAttempts)';
    }
    return '${fps.toStringAsFixed(1)} fps • $_frameCount frames';
  }

  Future<void> connectAudio() async {
    try {
      audioPlayer = Player();
      if (audioPlayer?.platform is NativePlayer) {
        final np = audioPlayer?.platform as NativePlayer;
        await np.setProperty('profile', 'low-latency');
        await np.setProperty('untimed', '');
        await np.setProperty('cache', 'no');
        await np.setProperty('cache-pause', 'no');
        await np.setProperty('audio-buffer', '0.05');
        await np.setProperty('demuxer-lavf-format', 'wav');
        await np.setProperty(
          'demuxer-lavf-o',
          'fflags=nobuffer,probesize=32,analyzeduration=0',
        );
        await np.setProperty('demuxer-max-bytes', '4096');
        await np.setProperty('demuxer-max-back-bytes', '0');
        await np.setProperty('hr-seek-framedrop', 'yes');
        await np.setProperty('network-timeout', '100');
      }
      await audioPlayer!.open(Media(audioUrl));
      await audioPlayer!.setVolume(100);
      if (!isDisposed) {
        audioAvailable = true;
        onFrameUpdated();
      }
    } catch (e) {
      audioPlayer?.dispose();
      audioPlayer = null;
      if (!isDisposed) {
        audioAvailable = false;
        onFrameUpdated();
      }
    }
  }

  Future<void> connect() async {
    if (isDisposed) return;
    isConnecting = true;
    error = null;
    onFrameUpdated();

    try {
      _httpClient?.close(force: true);
      _httpClient = HttpClient();
      _httpClient!.connectionTimeout = const Duration(seconds: 10);
      _httpClient!.idleTimeout = const Duration(seconds: 60);

      final request = await _httpClient!.getUrl(Uri.parse(streamUrl));
      request.headers.set('Connection', 'keep-alive');
      final response = await request.close();

      if (isDisposed) return;
      if (response.statusCode != 200) {
        throw HttpException('Server returned ${response.statusCode}');
      }

      isConnected = true;
      isConnecting = false;
      _startTime = DateTime.now();
      _reconnectAttempts = 0;
      _resetIdleTimer();
      onFrameUpdated();

      final bytesBuilder = BytesBuilder(copy: false);
      int previousLength = 0;

      await for (final chunk in response) {
        if (isDisposed) break;
        bytesBuilder.add(chunk);

        if (bytesBuilder.length > 2000 * 1024) {
          bytesBuilder.clear();
          previousLength = 0;
          continue;
        }

        Uint8List currentBuffer = bytesBuilder.takeBytes();
        int searchOffset = 0;
        Uint8List? latestFrame;

        while (true) {
          final jpegStart = _findMarker(currentBuffer, 0xFF, 0xD8, searchOffset);
          if (jpegStart == -1) {
            bytesBuilder.add(currentBuffer.sublist(searchOffset));
            previousLength = currentBuffer.length - searchOffset;
            break;
          }

          int startSearchingForEnd = jpegStart + 2;
          if (previousLength > startSearchingForEnd) {
            startSearchingForEnd = previousLength - 1;
          }

          final jpegEnd = _findMarker(currentBuffer, 0xFF, 0xD9, startSearchingForEnd);
          if (jpegEnd == -1) {
            bytesBuilder.add(currentBuffer.sublist(jpegStart));
            previousLength = currentBuffer.length - jpegStart;
            break;
          }

          final frameEnd = jpegEnd + 2;
          latestFrame = Uint8List.view(
            currentBuffer.buffer,
            currentBuffer.offsetInBytes + jpegStart,
            frameEnd - jpegStart,
          );

          _frameCount++;
          searchOffset = frameEnd;
          previousLength = 0;
        }

        if (latestFrame != null) {
          _lastFrameTime = DateTime.now();
          _resetIdleTimer();
          currentFrame = latestFrame;
          onFrameUpdated();

          final size = _getJpegSize(latestFrame);
          if (size != null) {
            onRatioDetected(size.width / size.height);
          }
        }
      }

      if (!isDisposed) {
        isConnected = false;
        error = 'Stream ended';
        _scheduleReconnect();
      }
    } catch (e) {
      if (!isDisposed) {
        isConnected = false;
        isConnecting = false;
        error = e.toString();
        onError(error!);
        _scheduleReconnect();
      }
    }
  }

  void _resetIdleTimer() {
    _idleTimer?.cancel();
    _idleTimer = Timer(const Duration(seconds: 8), () {
      if (!isDisposed && isConnected) {
        isConnected = false;
        error = 'Stream stalled — reconnecting...';
        _httpClient?.close(force: true);
        _scheduleReconnect();
      }
    });
  }

  void _scheduleReconnect() {
    if (isDisposed || _reconnectAttempts >= _maxReconnectAttempts) {
      error = 'Connection lost after $_reconnectAttempts attempts. Tap Retry to reconnect.';
      onFrameUpdated();
      return;
    }
    _reconnectAttempts++;
    final delay = Duration(seconds: _reconnectAttempts.clamp(1, 5));
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(delay, () {
      if (!isDisposed) {
        connect();
      }
    });
  }

  int _findMarker(Uint8List data, int byte1, int byte2, [int start = 0]) {
    final len = data.length - 1;
    for (int i = start; i < len; i++) {
      if (data[i] == byte1 && data[i + 1] == byte2) return i;
    }
    return -1;
  }

  Size? _getJpegSize(Uint8List bytes) {
    int offset = 2;
    while (offset < bytes.length - 8) {
      if (bytes[offset] == 0xFF) {
        int marker = bytes[offset + 1];
        if (marker == 0xC0 || marker == 0xC2) {
          int height = (bytes[offset + 5] << 8) | bytes[offset + 6];
          int width = (bytes[offset + 7] << 8) | bytes[offset + 8];
          return Size(width.toDouble(), height.toDouble());
        } else if (marker == 0xD8 || marker == 0xD9 || marker == 0x00 || (marker >= 0xD0 && marker <= 0xD7)) {
          offset += 2;
        } else {
          int length = (bytes[offset + 2] << 8) | bytes[offset + 3];
          offset += 2 + length;
        }
      } else {
        offset++;
      }
    }
    return null;
  }

  void sendControl(
    String action, {
    double? tapX,
    double? tapY,
    double? endX,
    double? endY,
    String? text,
    double? scrollDelta,
    int? duration,
  }) {
    if (senderIp != null) {
      _discoveryService.sendScreenMirrorControl(
        senderIp!,
        action,
        tapX: tapX,
        tapY: tapY,
        endX: endX,
        endY: endY,
        text: text,
        scrollDelta: scrollDelta,
        duration: duration,
      );
    }
  }

  void dispose() {
    isDisposed = true;
    _reconnectTimer?.cancel();
    _idleTimer?.cancel();
    _httpClient?.close(force: true);
    audioPlayer?.dispose();
    _discoveryService.resumeDiscovery();
  }
}
