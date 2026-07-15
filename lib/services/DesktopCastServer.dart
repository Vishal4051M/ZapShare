import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/services.dart';

class DesktopCastServer {
  HttpServer? _server;
  bool _isStreaming = false;
  static const _channel = MethodChannel('zapshare/desktop_capture');

  /// Target ~30 fps = 33ms per frame budget
  static const _frameBudgetMs = 33;

  int get port => _server?.port ?? 0;

  Future<void> start() async {
    if (_server != null) return;
    try {
      _server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      _isStreaming = true;
      _listen();
    } catch (e) {
      try {
        _server = await HttpServer.bind(InternetAddress.anyIPv4, 8083);
        _isStreaming = true;
        _listen();
      } catch (ex) {
        rethrow;
      }
    }
  }

  void _listen() {
    _server?.listen(
      (HttpRequest request) async {
        final path = request.uri.path;
        if (path == '/desktop-mirror') {
          request.response.headers.contentType = ContentType(
            'multipart',
            'x-mixed-replace',
            parameters: {'boundary': 'frame'},
          );
          request.response.headers.set('Connection', 'keep-alive');
          request.response.headers.set(
            'Cache-Control',
            'no-cache, no-store, must-revalidate',
          );
          request.response.headers.set('Pragma', 'no-cache');
          request.response.headers.set('Expires', '0');

          while (_isStreaming) {
            final frameStart = DateTime.now();
            try {
              final Uint8List? frameBytes = await _channel
                  .invokeMethod<Uint8List>('captureFrame');
              if (frameBytes == null || frameBytes.isEmpty) {
                // No frame available — short yield and retry
                await Future.delayed(const Duration(milliseconds: 16));
                continue;
              }
              request.response.write('--frame\r\n');
              request.response.write('Content-Type: image/jpeg\r\n');
              request.response.write(
                'Content-Length: ${frameBytes.length}\r\n\r\n',
              );
              request.response.add(frameBytes);
              request.response.write('\r\n');
              await request.response.flush();
            } catch (e) {
              break;
            }

            // Adaptive frame timing: sleep only the remainder of the frame budget.
            // This prevents frame stacking when capture is fast, and drops the
            // extra delay when capture is slow (heavy load / large display).
            final elapsed =
                DateTime.now().difference(frameStart).inMilliseconds;
            final remaining = _frameBudgetMs - elapsed;
            if (remaining > 2) {
              await Future.delayed(Duration(milliseconds: remaining));
            }
          }
          await request.response.close();
        } else {
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
        }
      },
      onError: (err) {
        // no silent failures
      },
    );
  }

  Future<void> stop() async {
    _isStreaming = false;
    await _server?.close(force: true);
    _server = null;
  }
}
