import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

/// A service that receives raw PCM UDP packets from Android (Port 50005)
/// and exposes them via a local HTTP server as a WAV stream for media_kit.
class UdpAudioReceiverService {
  static const int UDP_PORT = 50005;
  static const int HTTP_PORT = 50006;

  RawDatagramSocket? _udpSocket;
  HttpServer? _httpServer;
  bool _isRunning = false;
  bool _audioDetected = false;
  Function? _onDataReceived;
  int cushionMs = 20; // Customizable jitter cushion in milliseconds

  void setOnDataReceived(Function callback) {
    _onDataReceived = callback;
  }

  // Audio configuration (must match Android sender)
  static const int SAMPLE_RATE = 48000;
  static const int CHANNELS = 2;
  static const int BITS_PER_SAMPLE = 16;

  final StreamController<Uint8List> _audioDataController =
      StreamController<Uint8List>.broadcast();
  Stream<Uint8List> get audioStream => _audioDataController.stream;

  // Sorted Jitter Buffer (Android Style)
  final List<_AudioPacket> _jitterList = [];
  int? _lastReleasedSeq;
  Uint8List? _lastGoodFrame;

  Uint8List _applyFade(Uint8List source, double fadeLevel) {
    final result = Uint8List(source.length);
    final byteData = ByteData.view(
      source.buffer,
      source.offsetInBytes,
      source.length,
    );
    final resultByteData = ByteData.view(
      result.buffer,
      result.offsetInBytes,
      result.length,
    );
    final int sampleCount = source.length ~/ 2;
    for (int i = 0; i < sampleCount; i++) {
      final int offset = i * 2;
      final int sample = byteData.getInt16(offset, Endian.little);
      final int fadedSample = (sample * fadeLevel).round().clamp(-32768, 32767);
      resultByteData.setInt16(offset, fadedSample, Endian.little);
    }
    return result;
  }

  Future<void> start() async {
    if (_isRunning) return;
    _isRunning = true;
    _lastReleasedSeq = null;
    _lastGoodFrame = null;

    try {
      // 1. Start UDP Receiver
      _udpSocket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        UDP_PORT,
      );
      print('🔊 UDP Receiver bound to port $UDP_PORT');

      _udpSocket?.listen((event) {
        if (event == RawSocketEvent.read) {
          while (true) {
            final datagram = _udpSocket?.receive();
            if (datagram == null) break;

            if (datagram.data.length > 10) {
              final data = datagram.data;
              final type = data[0];
              if (type == 0x02) {
                print('🔊 CONFIG packet received');
                continue; // Skip config for raw PCM for now
              }
              if (type == 0x03) {
                continue; // Skip FEC parity packets
              }
              if (type != 0x01) {
                continue;
              }

              final seq = ((data[1] & 0xFF) << 8) | (data[2] & 0xFF);
              final ts =
                  ((data[3] & 0xFF).toBigInt() << 56) |
                  ((data[4] & 0xFF).toBigInt() << 48) |
                  ((data[5] & 0xFF).toBigInt() << 40) |
                  ((data[6] & 0xFF).toBigInt() << 32) |
                  ((data[7] & 0xFF).toBigInt() << 24) |
                  ((data[8] & 0xFF).toBigInt() << 16) |
                  ((data[9] & 0xFF).toBigInt() << 8) |
                  (data[10] & 0xFF).toBigInt();

              final payload = data.sublist(11);

              _jitterList.add(_AudioPacket(seq, payload));

              // Keep buffer sorted by sequence
              _jitterList.sort((a, b) {
                int dist = a.seq - b.seq;
                if (dist > 32767) return -1;
                if (dist < -32768) return 1;
                return dist;
              });

              // DYNAMIC CUSHION (each packet is 10ms: 1920 bytes for PCM stereo 48k 16-bit)
              final int targetCushion = (cushionMs / 10).round().clamp(1, 50);
              const int MAX_BUFFER = 50; // 500ms limit

              if (_jitterList.length > MAX_BUFFER) {
                print('⚠️ Jitter buffer overflow, catching up...');
                _jitterList.removeRange(0, _jitterList.length - targetCushion);
              }

              while (_jitterList.length > targetCushion) {
                final packet = _jitterList.removeAt(0);

                if (_lastReleasedSeq != null) {
                  int diff = packet.seq - _lastReleasedSeq!;
                  if (diff > 32767) diff -= 65536;
                  if (diff < -32768) diff += 65536;

                  if (diff < 0) {
                    print(
                      '⚠️ Discarding late packet: seq=${packet.seq}, expected=${(_lastReleasedSeq! + 1) % 65536}',
                    );
                    continue;
                  }

                  int expected = (_lastReleasedSeq! + 1) % 65536;
                  if (packet.seq != expected) {
                    int missing = (packet.seq - expected) % 65536;
                    if (missing > 0 && missing < 15) {
                      // PLC: Fading PCM frame insertion instead of silence
                      double fadeLevel = 1.0;
                      for (int i = 0; i < missing; i++) {
                        fadeLevel *= 0.65;
                        if (_lastGoodFrame != null && fadeLevel > 0.05) {
                          _audioDataController.add(
                            _applyFade(_lastGoodFrame!, fadeLevel),
                          );
                        } else {
                          _audioDataController.add(
                            Uint8List(packet.data.length),
                          );
                        }
                      }
                    }
                  }
                }

                _lastReleasedSeq = packet.seq;
                _lastGoodFrame = packet.data;
                _audioDataController.add(packet.data);

                if (!_audioDetected) {
                  _audioDetected = true;
                  _onDataReceived?.call();
                }
              }
            }
          }
        }
      });

      // 2. Start HTTP Streamer
      _httpServer = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        HTTP_PORT,
      );
      print('🔊 Audio HTTP Streamer at http://localhost:$HTTP_PORT/live.wav');

      _httpServer?.listen((HttpRequest request) {
        if (request.uri.path == '/live.wav') {
          _handleHttpRequest(request);
        } else {
          request.response.statusCode = HttpStatus.notFound;
          request.response.close();
        }
      });
    } catch (e) {
      print('❌ Error starting UDP Audio Receiver: $e');
      stop();
    }
  }

  void _handleHttpRequest(HttpRequest request) async {
    request.response.headers.contentType = ContentType('audio', 'wav');
    request.response.headers.set('Transfer-Encoding', 'chunked');

    // CRITICAL: Disable internal buffering to stop the 0.5s lag
    request.response.bufferOutput = false;

    // Write WAV Header with dummy infinite length
    final header = _createWavHeader(0x7FFFFFFF); // Use a very large number
    request.response.add(header);

    final subscription = _audioDataController.stream.listen((data) {
      try {
        request.response.add(data);
        request.response.flush();
      } catch (_) {
        // Handled by done
      }
    });

    // CRITICAL: Cancel subscription when player disconnects
    // This prevents "Lag like hell" caused by multiple streams or ghost buffers
    request.response.done.then((_) {
      subscription.cancel();
      print('🔊 Audio client disconnected');
    });
  }

  Uint8List _createWavHeader(int dataSize) {
    final header = ByteData(44);

    // RIFF
    header.setUint8(0, 0x52); // R
    header.setUint8(1, 0x49); // I
    header.setUint8(2, 0x46); // F
    header.setUint8(3, 0x46); // F
    header.setUint32(4, dataSize + 36, Endian.little);

    // WAVE
    header.setUint8(8, 0x57); // W
    header.setUint8(9, 0x41); // A
    header.setUint8(10, 0x56); // V
    header.setUint8(11, 0x45); // E

    // fmt
    header.setUint8(12, 0x66); // f
    header.setUint8(13, 0x6D); // m
    header.setUint8(14, 0x74); // t
    header.setUint8(15, 0x20); //
    header.setUint32(16, 16, Endian.little); // Subchunk1Size
    header.setUint16(20, 1, Endian.little); // PCM
    header.setUint16(22, CHANNELS, Endian.little);
    header.setUint32(24, SAMPLE_RATE, Endian.little);
    header.setUint32(
      28,
      SAMPLE_RATE * CHANNELS * BITS_PER_SAMPLE ~/ 8,
      Endian.little,
    ); // ByteRate
    header.setUint16(
      32,
      CHANNELS * BITS_PER_SAMPLE ~/ 8,
      Endian.little,
    ); // BlockAlign
    header.setUint16(34, BITS_PER_SAMPLE, Endian.little);

    // data
    header.setUint8(36, 0x64); // d
    header.setUint8(37, 0x61); // a
    header.setUint8(38, 0x74); // t
    header.setUint8(39, 0x61); // a
    header.setUint32(40, dataSize, Endian.little);

    return header.buffer.asUint8List();
  }

  void stop() {
    _isRunning = false;
    _udpSocket?.close();
    _udpSocket = null;
    _httpServer?.close();
    _httpServer = null;
    _jitterList.clear();
    _audioDetected = false;
    print('🔊 UDP Audio Receiver stopped');
  }
}

class _AudioPacket {
  final int seq;
  final Uint8List data;
  _AudioPacket(this.seq, this.data);
}

extension IntToBigInt on int {
  BigInt toBigInt() => BigInt.from(this);
}
