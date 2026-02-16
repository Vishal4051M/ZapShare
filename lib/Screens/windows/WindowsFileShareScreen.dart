import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../services/device_discovery_service.dart';
import '../../widgets/CustomAvatarWidget.dart';

// --- Ripple/Pulse Animation Widget (Android Style) ---

class RippleBackground extends StatefulWidget {
  final Color color;
  final Widget? child;
  final double size;

  const RippleBackground({
    super.key,
    this.color = Colors.grey,
    this.child,
    this.size = 300,
  });

  @override
  State<RippleBackground> createState() => _RippleBackgroundState();
}

class _RippleBackgroundState extends State<RippleBackground>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  // Slower, smoother duration like Android
  static const Duration _duration = Duration(milliseconds: 3000);

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: _duration)
      ..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // We render the pulse effect as a background stack
    return Stack(
      children: [
        // Base background - Removed to show gradient
        // Container(color: Colors.black),

        // Pulse Painter (Centered)
        Center(
          child: RepaintBoundary(
            child: SizedBox(
              // Make it large enough to cover screen or section
              width: MediaQuery.of(context).size.width,
              height: MediaQuery.of(context).size.height,
              child: AnimatedBuilder(
                animation: _controller,
                builder:
                    (_, __) => CustomPaint(
                      painter: _PulsePainter(
                        progress: _controller.value,
                        color: widget.color,
                      ),
                      isComplex: false,
                      willChange: true,
                    ),
              ),
            ),
          ),
        ),

        // Content
        if (widget.child != null) widget.child!,
      ],
    );
  }
}

// Minimal CustomPainter - all math inlined from Android logic
class _PulsePainter extends CustomPainter {
  final double progress;
  final Color color;

  const _PulsePainter({required this.progress, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    // Center of the canvas
    final center = Offset(size.width / 2, size.height / 2);
    // Use a reasonable max radius based on screen size
    final maxRadius = min(size.width, size.height) * 0.6;

    // 3 rings with phase offset
    for (int i = 0; i < 3; i++) {
      final p = (progress + i / 3) % 1.0;

      // EaseOutCubic inline
      final eased = 1.0 - (1.0 - p) * (1.0 - p) * (1.0 - p);

      // Radius: 20% to 100%
      final radius = maxRadius * (0.2 + eased * 0.8);

      // Opacity: inverse square + edge fade
      final d = (radius / maxRadius).clamp(0.3, 1.0);
      final opacity = ((0.3 / (d * d)) * (1.0 - p * p)).clamp(0.0, 0.35);

      // Stroke: 2.5 -> 0.5
      final stroke = 2.5 - eased * 2.0;

      if (opacity > 0.02) {
        // Updated: withOpacity -> withValues(alpha: ...)
        canvas.drawCircle(
          center,
          radius,
          Paint()
            ..color = color.withValues(alpha: opacity)
            ..style = PaintingStyle.stroke
            ..strokeWidth = stroke,
        );
      }
    }

    // Center dot - small, neat, darker
    final breathe = (0.5 + 0.5 * sin(progress * 2 * 3.14159)).abs();
    final dotR = maxRadius * 0.04 * (0.95 + breathe * 0.2); // ~4% of max radius

    // Subtle glow
    canvas.drawCircle(
      center,
      dotR * 1.5,
      Paint()
        ..color = color.withValues(alpha: 0.10)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
    );

    // Solid dot - darker
    canvas.drawCircle(
      center,
      dotR,
      Paint()..color = color.withValues(alpha: 0.5),
    );
  }

  @override
  bool shouldRepaint(covariant _PulsePainter oldDelegate) {
    return oldDelegate.progress != progress || oldDelegate.color != color;
  }
}

// --- Shared Components ---

class _StatusCapsule extends StatelessWidget {
  final String message;
  final String? subtitle;
  final IconData icon;
  final bool isSuccess;
  final bool isError;
  final VoidCallback onDismiss;

  const _StatusCapsule({
    Key? key,
    required this.message,
    this.subtitle,
    required this.icon,
    required this.isSuccess,
    required this.isError,
    required this.onDismiss,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    Color bgColor = Colors.black.withValues(alpha: 0.85);
    Color iconColor = Colors.white70;

    if (isSuccess) {
      bgColor = const Color(0xFF1B5E20).withValues(alpha: 0.95);
      iconColor = Colors.greenAccent;
    } else if (isError) {
      bgColor = const Color(0xFFB71C1C).withValues(alpha: 0.95);
      iconColor = Colors.redAccent;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.3),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: iconColor, size: 18),
          const SizedBox(width: 10),
          Flexible(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  message,
                  style: GoogleFonts.outfit(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (subtitle != null)
                  Text(
                    subtitle!,
                    style: GoogleFonts.outfit(
                      color: Colors.white60,
                      fontSize: 11,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: onDismiss,
            child: const Icon(
              Icons.close_rounded,
              color: Colors.white38,
              size: 16,
            ),
          ),
        ],
      ),
    );
  }
}

class WindowsFileShareScreen extends StatefulWidget {
  const WindowsFileShareScreen({super.key});

  @override
  State<WindowsFileShareScreen> createState() => _WindowsFileShareScreenState();
}

class _WindowsFileShareScreenState extends State<WindowsFileShareScreen> {
  // Logic State
  List<PlatformFile> _files = [];
  bool _loading = false;
  HttpServer? _server;
  ServerSocket? _tcpServer;
  String? _localIp;
  bool _isSharing = false;

  // Progress State
  List<double> _progressList = [];
  List<bool> _isPausedList = [];
  List<int> _downloadCounts = []; // Track successful downloads per file

  // Drag & Drop
  bool _isDragOver = false;
  static const MethodChannel _channel = MethodChannel('zapshare/drag_drop');

  // Discovery
  final DeviceDiscoveryService _discoveryService = DeviceDiscoveryService();
  List<DiscoveredDevice> _nearbyDevices = [];
  StreamSubscription? _devicesSubscription;
  StreamSubscription? _connectionRequestSubscription;
  StreamSubscription? _connectionResponseSubscription;

  // Status State
  String? _statusMessage;
  String? _statusSubtitle;
  IconData _statusIcon = Icons.sync_rounded;
  bool _statusIsSuccess = false;
  bool _statusIsError = false;
  Timer? _statusDismissTimer;

  // Constants
  final int _port = 8080;

  @override
  void initState() {
    super.initState();
    _fetchLocalIp();
    _setupDragDrop();
    _initDeviceDiscovery();
    _setupServiceListeners();
  }

  @override
  void dispose() {
    _stopServer();
    _devicesSubscription?.cancel();
    _connectionRequestSubscription?.cancel();
    _connectionResponseSubscription?.cancel();
    _statusDismissTimer?.cancel();
    super.dispose();
  }

  // --- Logic Methods ---

  Future<void> _fetchLocalIp() async {
    String? bestIp;
    try {
      final interfaces = await NetworkInterface.list(
        includeLinkLocal: false,
        type: InternetAddressType.IPv4,
      );
      for (final interface in interfaces) {
        for (final addr in interface.addresses) {
          final ip = addr.address;
          if (ip == '127.0.0.1' ||
              ip == 'localhost' ||
              ip.startsWith('169.254.'))
            continue;
          if (ip.startsWith('192.168.') ||
              ip.startsWith('10.') ||
              ip.startsWith('172.')) {
            bestIp = ip;
            break;
          }
          bestIp ??= ip;
        }
        if (bestIp != null) break;
      }
    } catch (e) {
      print('Error getting network interfaces: $e');
    }

    if (bestIp == null) {
      try {
        final info = NetworkInfo();
        bestIp = await info.getWifiIP();
      } catch (_) {}
    }

    bestIp ??= '127.0.0.1';

    setState(() {
      _localIp = bestIp;
    });

    if (_files.isNotEmpty) {
      _startServer();
    }
  }

  Future<void> _pickFiles() async {
    setState(() => _loading = true);
    final result = await FilePicker.platform.pickFiles(allowMultiple: true);
    if (result != null) {
      setState(() {
        _files.addAll(result.files);
        _progressList.addAll(List.filled(result.files.length, 0.0));
        _isPausedList.addAll(List.filled(result.files.length, false));
        _downloadCounts.addAll(List.filled(result.files.length, 0));
      });
      _startServer();
    }
    setState(() => _loading = false);
  }

  Future<void> _pickFolder() async {
    String? folderPath = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Select Folder to Share',
    );
    if (folderPath == null) return;

    setState(() => _loading = true);
    try {
      final dir = Directory(folderPath);
      final files =
          await dir
              .list(recursive: true, followLinks: false)
              .where((e) => e is File)
              .toList();
      final newFiles =
          files
              .map(
                (e) => PlatformFile(
                  name: e.path.split(Platform.pathSeparator).last,
                  path: e.path,
                  size: File(e.path).lengthSync(),
                ),
              )
              .toList();

      setState(() {
        _files.addAll(newFiles);
        _progressList.addAll(List.filled(newFiles.length, 0.0));
        _isPausedList.addAll(List.filled(newFiles.length, false));
        _downloadCounts.addAll(List.filled(newFiles.length, 0));
      });
      _startServer();
    } catch (e) {
      _showStatus(
        message: "Failed to load folder",
        isError: true,
        autoDismiss: Duration(seconds: 3),
      );
    } finally {
      setState(() => _loading = false);
    }
  }

  void _setupDragDrop() {
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onFilesDropped':
          final List<dynamic> filePaths = call.arguments;
          final List<String> paths = filePaths.cast<String>();
          _handleDroppedFiles(paths);
          setState(() {
            _isDragOver = true;
          });
          Future.delayed(Duration(milliseconds: 500), () {
            if (mounted) setState(() => _isDragOver = false);
          });
          break;
        case 'onDragEnter':
          setState(() => _isDragOver = true);
          break;
        case 'onDragLeave':
          setState(() => _isDragOver = false);
          break;
      }
    });
  }

  Future<void> _handleDroppedFiles(List<String> filePaths) async {
    setState(() => _loading = true);
    try {
      final newFiles = <PlatformFile>[];
      for (final path in filePaths) {
        final file = File(path);
        if (await file.exists()) {
          final stat = await file.stat();
          newFiles.add(
            PlatformFile(
              name: file.path.split(Platform.pathSeparator).last,
              path: file.path,
              size: stat.size,
            ),
          );
        }
      }
      if (newFiles.isNotEmpty) {
        setState(() {
          _files.addAll(newFiles);
          _progressList.addAll(List.filled(newFiles.length, 0.0));
          _isPausedList.addAll(List.filled(newFiles.length, false));
        });
        _startServer();
        _showStatus(
          message: "Added ${newFiles.length} files",
          icon: Icons.playlist_add_check,
          isSuccess: true,
          autoDismiss: Duration(seconds: 2),
        );
      }
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _startServer() async {
    // START ALWAYS: Allow server to start even with 0 files so QR code works
    // if (_files.isEmpty) return;
    await _server?.close(force: true);
    await _tcpServer?.close();

    try {
      _server = await HttpServer.bind(InternetAddress.anyIPv4, _port);
      _server!.listen(_handleHttpRequest);
      _tcpServer = await ServerSocket.bind(InternetAddress.anyIPv4, _port + 1);
      _tcpServer!.listen(_handleTcpClient);
      setState(() => _isSharing = true);
      _showStatus(
        message: "Server running",
        subtitle: "Ready to share",
        icon: Icons.wifi_tethering,
        isSuccess: true,
        autoDismiss: Duration(seconds: 3),
      );
    } catch (e) {
      _showStatus(
        message: "Server start failed",
        subtitle: e.toString(),
        isError: true,
      );
    }
  }

  Future<void> _stopServer() async {
    await _server?.close(force: true);
    await _tcpServer?.close();
    if (mounted) setState(() => _isSharing = false);
  }

  void _handleHttpRequest(HttpRequest request) async {
    final path = request.uri.path;
    request.response.headers.add('Access-Control-Allow-Origin', '*');

    // 1. Serve Web Interface (HTML) at Root
    if (path == '/' || path == '/index.html') {
      request.response.headers.contentType = ContentType.html;
      request.response.write('''
<!DOCTYPE html>
<html>
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>ZapShare - Download</title>
  <style>
    body { font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; background: #121212; color: #fff; text-align: center; padding: 20px; }
    h1 { color: #FFD600; }
    .card { background: #1e1e1e; padding: 15px; margin: 10px auto; max-width: 600px; border-radius: 12px; display: flex; align-items: center; justify-content: space-between; border: 1px solid #333; }
    .btn { background: #FFD600; color: #000; text-decoration: none; padding: 10px 20px; border-radius: 8px; font-weight: bold; }
    .info { text-align: left; }
    .size { font-size: 0.9em; color: #aaa; }
  </style>
</head>
<body>
  <h1>ZapShare Files</h1>
  <p>Available for download</p>
  <div id="file-list"></div>
  <script>
    fetch('/list').then(res => res.json()).then(files => {
      const container = document.getElementById('file-list');
      if(files.length === 0) {
        container.innerHTML = '<p>No files shared yet.</p>';
        return;
      }
      files.forEach(f => {
        const div = document.createElement('div');
        div.className = 'card';
        div.innerHTML = `
          <div class="info">
            <strong>\${f.name}</strong><br>
            <span class="size">\${(f.size/1024/1024).toFixed(2)} MB</span>
          </div>
          <a href="/file/\${f.index}" class="btn" download>Download</a>
        `;
        container.appendChild(div);
      });
    });
  </script>
</body>
</html>
      ''');
      await request.response.close();
      return;
    }

    if (path == '/list') {
      final list = List.generate(
        _files.length,
        (i) => {'index': i, 'name': _files[i].name, 'size': _files[i].size},
      );
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(list));
      await request.response.close();
      return;
    }

    if (path == '/connection-request' && request.method == 'POST') {
      try {
        final content = await utf8.decoder.bind(request).join();
        final data = jsonDecode(content);

        print('📩 Received HTTP Connection Request from ${data['deviceName']}');

        // Parse Request
        final connectionRequest = {
          'deviceId': data['deviceId'],
          'deviceName': data['deviceName'],
          'platform': data['platform'] ?? 'unknown',
          'port': (data['port'] as int?) ?? 8080,
          'ipAddress':
              request
                  .connectionInfo!
                  .remoteAddress
                  .address, // Correct IP from connection
          'fileCount': data['fileCount'],
          'fileNames': List<String>.from(data['fileNames']),
          'totalSize': data['totalSize'],
        };

        // Show Dialog
        final completer = Completer<bool>();
        if (mounted) {
          _showConnectionDialog(connectionRequest, completer);
        } else {
          completer.complete(false);
        }

        final accepted = await completer.future;

        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'accepted': accepted}));
        await request.response.close();
      } catch (e) {
        print('Error processing connection request: $e');
        request.response.statusCode = HttpStatus.badRequest;
        await request.response.close();
      }
      return;
    }

    final segments = request.uri.pathSegments;
    if (segments.length == 2 && segments[0] == 'file') {
      final index = int.tryParse(segments[1]);
      if (index != null && index < _files.length) {
        final file = _files[index];
        final fsFile = File(file.path!);
        if (await fsFile.exists()) {
          request.response.headers.contentType = ContentType.binary;
          request.response.headers.add(
            'Content-Disposition',
            'attachment; filename="${file.name}"',
          );
          request.response.headers.contentLength = file.size;

          // Manual Stream for HTTP Progress Tracking - RandomAccessFile
          RandomAccessFile? raf;
          try {
            int bytesSent = 0;
            final fileSize = file.size;
            DateTime lastUpdate = DateTime.now();

            raf = await fsFile.open();
            const int chunkSize = 64 * 1024; // 64KB chunks

            while (bytesSent < fileSize) {
              final chunk = await raf.read(chunkSize);
              if (chunk.isEmpty) break;

              request.response.add(chunk);
              bytesSent += chunk.length;

              // Flush EVERY chunk for exact progress
              await request.response.flush();

              // Update UI Progress
              final now = DateTime.now();
              if (now.difference(lastUpdate).inMilliseconds > 50) {
                lastUpdate = now;
                if (mounted) {
                  setState(() {
                    if (index < _progressList.length) {
                      _progressList[index] = bytesSent / fileSize;
                    }
                  });
                }
              }
            }
            // Finalize
            if (mounted) {
              setState(() {
                if (index < _progressList.length) {
                  _progressList[index] = 1.0;
                }
              });
            }
          } catch (e) {
            print("Error streaming file via HTTP: $e");
          } finally {
            await raf?.close();
            await request.response.close();
          }
          return;
        }
      }
    }
    request.response.statusCode = HttpStatus.notFound;
    request.response.close();
  }

  void _showConnectionDialog(
    Map<String, dynamic> request,
    Completer<bool> completer,
  ) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder:
          (context) => AlertDialog(
            backgroundColor: const Color(0xFF1C1C1E),
            title: Text(
              "Connection Request",
              style: GoogleFonts.outfit(color: Colors.white),
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  "${request['deviceName']} wants to connect.",
                  style: GoogleFonts.outfit(color: Colors.white70),
                ),
                const SizedBox(height: 8),
                Text(
                  "Files: ${request['fileCount']}",
                  style: GoogleFonts.outfit(
                    color: Colors.grey[400],
                    fontSize: 12,
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () {
                  Navigator.pop(context);
                  completer.complete(false);
                },
                child: Text(
                  "Decline",
                  style: TextStyle(color: Colors.redAccent),
                ),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFFFD600),
                ),
                onPressed: () {
                  Navigator.pop(context);
                  completer.complete(true);
                },
                child: Text("Accept", style: TextStyle(color: Colors.black)),
              ),
            ],
          ),
    );
  }

  void _handleTcpClient(Socket client) {
    Completer<void>? pendingAck;

    client
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) async {
          if (line == 'ACK') {
            print('✅ Received ACK');
            pendingAck?.complete();
            return;
          }

          if (line == 'LIST') {
            final list = List.generate(
              _files.length,
              (i) => {
                'index': i,
                'name': _files[i].name,
                'size': _files[i].size,
                'uri': 'file://$i',
              },
            );
            client.writeln(jsonEncode(list));
            await client.flush();
          } else if (line.startsWith('GET ')) {
            final indexStr = line.substring(4);
            final index = int.tryParse(indexStr);
            if (index != null && index < _files.length) {
              final file = _files[index];
              final fsFile = File(file.path!);
              final fileSize = file.size;

              client.writeln(fileSize.toString());

              // Track Progress
              int bytesSent = 0;
              DateTime lastUpdate = DateTime.now();

              pendingAck = Completer<void>();
              RandomAccessFile? raf;
              try {
                raf = await fsFile.open();
                const int chunkSize = 64 * 1024; // 64KB chunks

                while (bytesSent < fileSize) {
                  final chunk = await raf.read(chunkSize);
                  if (chunk.isEmpty) break;

                  client.add(chunk);
                  bytesSent += chunk.length;

                  // Flush EVERY chunk for exact progress
                  await client.flush();

                  final now = DateTime.now();
                  if (now.difference(lastUpdate).inMilliseconds > 50) {
                    lastUpdate = now;
                    if (mounted) {
                      setState(() {
                        if (index < _progressList.length) {
                          _progressList[index] = bytesSent / fileSize;
                        }
                      });
                    }
                  }
                }

                // Finalize 100%
                if (mounted) {
                  setState(() {
                    if (index < _progressList.length) {
                      _progressList[index] = 1.0;
                    }
                  });
                }

                // Wait for ACK
                print('⏳ Waiting for ACK...');
                try {
                  await pendingAck!.future.timeout(
                    const Duration(seconds: 15),
                    onTimeout: () => print('⚠️ ACK timed out'),
                  );

                  // Increment success count *after* ACK
                  if (mounted) {
                    setState(() {
                      if (index < _downloadCounts.length) {
                        _downloadCounts[index]++;
                      }
                    });

                    final count = _downloadCounts[index];
                    _showStatus(
                      message: "$count client${count == 1 ? '' : 's'} sent",
                      subtitle: "${_files[index].name} completed",
                      icon: Icons.check_circle_rounded,
                      isSuccess: true,
                      autoDismiss: const Duration(seconds: 5),
                    );
                  }
                } catch (e) {
                  print('Error waiting for ACK: $e');
                }
              } catch (e) {
                print("Error sending file: $e");
              } finally {
                await raf?.close();
                // Important: Close socket to signal EOF to receiver
                await client.close();
              }
            }
          }
        });
  }

  void _initDeviceDiscovery() async {
    await _discoveryService.initialize();
    await _discoveryService.start();
    _devicesSubscription = _discoveryService.devicesStream.listen((devices) {
      if (mounted) {
        setState(
          () => _nearbyDevices = devices.where((d) => d.isOnline).toList(),
        );
      }
    });
  }

  void _setupServiceListeners() {
    // Listen for incoming connection requests (via UDP)
    _connectionRequestSubscription = _discoveryService.connectionRequestStream
        .listen((request) {
          if (mounted) {
            // Convert ConnectionRequest to Map for dialog
            final reqMap = {
              'deviceName': request.deviceName,
              'fileCount': request.fileCount,
            };

            final completer = Completer<bool>();
            _showConnectionDialog(reqMap, completer);

            completer.future.then((accepted) {
              _discoveryService.sendConnectionResponse(
                request.ipAddress,
                accepted,
              );
              if (accepted) {
                // Logic to start receiving can go here or be handled by simple file transfer
              }
            });
          }
        });

    // Listen for responses to OUR requests
    _connectionResponseSubscription = _discoveryService.connectionResponseStream
        .listen((response) {
          if (mounted) {
            if (response.accepted) {
              _showStatus(
                message: "Connected to ${response.deviceName}",
                subtitle: "They accepted your request",
                icon: Icons.check_circle_rounded,
                isSuccess: true,
                autoDismiss: Duration(seconds: 3),
              );
            } else {
              _showStatus(
                message: "Connection refused",
                subtitle: "${response.deviceName} declined",
                isError: true,
                autoDismiss: Duration(seconds: 3),
              );
            }
            setState(() => _loading = false);
          }
        });
  }

  Future<void> _sendConnectionRequest(DiscoveredDevice device) async {
    setState(() => _loading = true);
    _showStatus(
      message: "Connecting to ${device.deviceName}...",
      icon: Icons.sync,
    );

    try {
      // Use UDP Discovery Service for Handshake (bypasses HTTP port blocking)
      final fileNames = _files.map((f) => f.name).toList();
      final totalSize = _files.fold(0, (sum, f) => sum + f.size);

      await _discoveryService.sendConnectionRequest(
        device.ipAddress,
        fileNames,
        totalSize,
        _port,
      );

      // We don't wait for HTTP response anymore. We wait for UDP Stream response.
      // Timeout fallback
      Future.delayed(Duration(seconds: 10), () {
        if (mounted && _loading) {
          setState(() => _loading = false);
          // Only show timeout if we haven't received a response (loading is still true)
          // But 'loading' might be used for other things, creating a flag for this request would be better.
          // For now, simple timeout status.
          if (_statusMessage?.contains("Connecting") == true) {
            _showStatus(message: "Connection timed out", isError: true);
          }
        }
      });
    } catch (e) {
      print("CONNECTION ERROR: $e");
      _showStatus(
        message: "Connection error",
        subtitle: e.toString(),
        isError: true,
      );
      setState(() => _loading = false);
    }
  }

  // --- Helper Methods ---

  String _ipToCode(String ip, {int port = 8080}) {
    final parts = ip.split('.').map(int.parse).toList();
    if (parts.length != 4) return '';
    int ipNum =
        (parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3];
    String ipCode = ipNum.toRadixString(36).toUpperCase().padLeft(8, '0');
    String portCode = port.toRadixString(36).toUpperCase().padLeft(3, '0');
    return ipCode + portCode;
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return "$bytes B";
    if (bytes < 1024 * 1024) return "${(bytes / 1024).toStringAsFixed(1)} KB";
    if (bytes < 1024 * 1024 * 1024)
      return "${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB";
    return "${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB";
  }

  IconData _getFileIcon(String fileName) {
    final ext = fileName.split('.').last.toLowerCase();
    switch (ext) {
      case 'jpg':
      case 'jpeg':
      case 'png':
      case 'gif':
        return Icons.image_rounded;
      case 'mp4':
      case 'mov':
      case 'avi':
        return Icons.videocam_rounded;
      case 'mp3':
      case 'wav':
      case 'aac':
        return Icons.audiotrack_rounded;
      case 'pdf':
        return Icons.picture_as_pdf_rounded;
      case 'doc':
      case 'docx':
      case 'txt':
        return Icons.description_rounded;
      case 'zip':
      case 'rar':
        return Icons.folder_zip_rounded;
      case 'apk':
        return Icons.android_rounded;
      case 'exe':
      case 'msi':
        return Icons.window_rounded;
      default:
        return Icons.insert_drive_file_rounded;
    }
  }

  IconData _getPlatformIcon(String platform) {
    switch (platform.toLowerCase()) {
      case 'android':
        return Icons.android;
      case 'ios':
        return Icons.phone_iphone;
      case 'windows':
        return Icons.desktop_windows;
      case 'macos':
        return Icons.laptop_mac;
      case 'linux':
        return Icons.computer;
      default:
        return Icons.devices;
    }
  }

  void _showStatus({
    required String message,
    String? subtitle,
    IconData icon = Icons.info_rounded,
    bool isSuccess = false,
    bool isError = false,
    Duration? autoDismiss,
  }) {
    _statusDismissTimer?.cancel();
    setState(() {
      _statusMessage = message;
      _statusSubtitle = subtitle;
      _statusIcon = icon;
      _statusIsSuccess = isSuccess;
      _statusIsError = isError;
    });
    if (autoDismiss != null) {
      _statusDismissTimer = Timer(autoDismiss, () {
        if (mounted) setState(() => _statusMessage = null);
      });
    }
  }

  // --- UI Build ---

  @override
  Widget build(BuildContext context) {
    final displayCode = _localIp != null ? _ipToCode(_localIp!) : "...";

    return Hero(
      tag: 'send_card_container',
      createRectTween: (begin, end) {
        return MaterialRectCenterArcTween(begin: begin, end: end);
      },
      child: Scaffold(
        backgroundColor: Colors.black, // Base color
        resizeToAvoidBottomInset: false, // Prevent resize issues
        body: Container(
          width: double.infinity,
          height: double.infinity,
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Color(0xFFFFD84D),
                Color(0xFFF5C400),
              ], // Android Yellow Gradient
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch, // FILL HEIGHT
            children: [
              // LEFT PANEL: Devices & Connection (Radar View)
              Expanded(flex: 5, child: _buildRadarPanel(displayCode)),

              // RIGHT PANEL: Files (Black Panel)
              Expanded(
                flex: 4,
                child: Container(
                  height: double.infinity,
                  decoration: BoxDecoration(
                    color: Colors.black,
                    border: Border(
                      left: BorderSide(
                        color: Colors.white.withValues(alpha: 0.1),
                      ),
                    ),
                  ),
                  child: SafeArea(child: _buildFilesPanel()),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRadarPanel(String displayCode) {
    // Generate QR Data
    final qrData = _localIp != null ? "http://$_localIp:$_port" : "zapshare";

    return LayoutBuilder(
      builder: (context, constraints) {
        final bool isSmall =
            constraints.maxHeight < 400 || constraints.maxWidth < 600;

        final Widget content = Stack(
          children: [
            // 1. Centered Ripple Background (Restricted to this panel)
            Positioned.fill(
              child: RippleBackground(
                color:
                    Colors
                        .white, // White ripple on yellow background looks better (or darker yellow)
                child: Container(), // Empty child, we use Stack for devices
              ),
            ),

            // Back Button (Top-Left)
            Positioned(
              top: 24,
              left: 24,
              child: Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.9),
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.2),
                      blurRadius: 15,
                      offset: const Offset(0, 5),
                    ),
                  ],
                ),
                child: IconButton(
                  icon: const Icon(
                    Icons.arrow_back_ios_new_rounded,
                    color: Color(0xFFFFD600),
                    size: 18,
                  ),
                  onPressed: () => Navigator.pop(context),
                  tooltip: 'Back',
                ),
              ),
            ),

            // 2. Header / QR Code (Centered Top)
            Align(
              alignment: Alignment.topCenter,
              child: Padding(
                padding: const EdgeInsets.only(top: 32),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.9),
                    borderRadius: BorderRadius.circular(40),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.2),
                        blurRadius: 15,
                        offset: const Offset(0, 5),
                      ),
                    ],
                  ),
                  // FIX: Use FittedBox to prevent overflow during Hero transition
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: const Color(
                              0xFFFFD600,
                            ).withValues(alpha: 0.2),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.wifi_tethering,
                            color: Color(0xFFFFD600),
                            size: 18,
                          ),
                        ),
                        const SizedBox(width: 16),
                        Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              "CONNECTION CODE",
                              style: GoogleFonts.outfit(
                                color: Colors.grey[400],
                                fontSize: 10,
                                letterSpacing: 1.2,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              displayCode,
                              style: GoogleFonts.robotoMono(
                                color: Colors.white,
                                fontSize: 20,
                                fontWeight: FontWeight.bold,
                                letterSpacing: 1.5,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(width: 16),
                        Container(width: 1, height: 32, color: Colors.white12),
                        const SizedBox(width: 8),
                        // QR Scan Button
                        Tooltip(
                          message: "Show QR Code",
                          child: InkWell(
                            borderRadius: BorderRadius.circular(20),
                            onTap: () {
                              showDialog(
                                context: context,
                                builder:
                                    (c) => Center(
                                      child: Container(
                                        width: 300,
                                        padding: const EdgeInsets.all(32),
                                        decoration: BoxDecoration(
                                          color: Colors.white,
                                          borderRadius: BorderRadius.circular(
                                            32,
                                          ),
                                          boxShadow: const [
                                            BoxShadow(
                                              color: Colors.black45,
                                              blurRadius: 40,
                                            ),
                                          ],
                                        ),
                                        child: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Text(
                                              "Scan to Connect",
                                              style: GoogleFonts.outfit(
                                                color: Colors.black,
                                                fontSize: 20,
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                            const SizedBox(height: 24),
                                            QrImageView(
                                              data: qrData,
                                              size: 200,
                                              padding: EdgeInsets.zero,
                                              backgroundColor: Colors.white,
                                            ),
                                            const SizedBox(height: 24),
                                            Text(
                                              "Scan successfully to connect",
                                              textAlign: TextAlign.center,
                                              style: GoogleFonts.outfit(
                                                color: Colors.grey[600],
                                                fontSize: 14,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                              );
                            },
                            child: Container(
                              padding: const EdgeInsets.all(8),
                              child: const Icon(
                                Icons.qr_code_rounded,
                                color: Colors.white,
                                size: 28,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),

            // 3. Center Icon (Me) - With Pulse/Shimmer
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 80,
                    height: 80,
                    decoration: BoxDecoration(
                      color: Colors.black,
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black26,
                          blurRadius: 20,
                          spreadRadius: 5,
                        ),
                      ],
                      border: Border.all(color: Colors.white, width: 2),
                    ),
                    child: Icon(
                      Icons.desktop_windows_rounded,
                      color: const Color(0xFFFFD600),
                      size: 40,
                    ),
                  ),
                  const SizedBox(height: 12),
                  ShimmerLoading(
                    child: Text(
                      "Scanning...",
                      style: GoogleFonts.outfit(
                        color: Colors.black,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        shadows: [
                          Shadow(color: Colors.white30, blurRadius: 10),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // 4. Orbiting Devices
            ..._buildOrbitingDevices(),

            // Status Capsule (moved to bottom center of this panel)
            if (_statusMessage != null)
              Positioned(
                bottom: 32,
                left: 0,
                right: 0,
                child: Center(
                  child: _StatusCapsule(
                    message: _statusMessage!,
                    subtitle: _statusSubtitle,
                    icon: _statusIcon,
                    isSuccess: _statusIsSuccess,
                    isError: _statusIsError,
                    onDismiss: () => setState(() => _statusMessage = null),
                  ),
                ),
              ),
          ],
        );

        if (isSmall) {
          return FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.center,
            child: SizedBox(width: 600, height: 700, child: content),
          );
        }
        return content;
      },
    );
  }

  List<Widget> _buildOrbitingDevices() {
    final devices = _nearbyDevices; // Already filtered for online
    final widgets = <Widget>[];

    if (devices.isEmpty) return widgets;

    // Center offset downwards to avoid collision with top code capsule
    final double verticalOffset = 50.0;
    final double orbitRadius = 240.0; // Increased radius
    final int count = devices.length;

    for (int i = 0; i < count; i++) {
      final device = devices[i];
      // Angle: Start from top (-pi/2) and distribute evenly
      final double angle = (-pi / 2) + (2 * pi * i / count);

      widgets.add(
        Center(
          child: Transform.translate(
            offset: Offset(
              orbitRadius * cos(angle),
              (orbitRadius * sin(angle)) +
                  verticalOffset, // Add vertical offset here
            ),
            child: _buildDeviceNode(device),
          ),
        ),
      );
    }
    return widgets;
  }

  Widget _buildDeviceNode(DiscoveredDevice device) {
    String displayName = device.userName ?? device.deviceName;

    return GestureDetector(
      onTap: () => _sendConnectionRequest(device),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 60,
            height: 60,
            decoration: BoxDecoration(
              color: const Color(0xFF1C1C1E),
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 2),
              boxShadow: [
                BoxShadow(
                  color: Colors.black26,
                  blurRadius: 10,
                  offset: Offset(0, 4),
                ),
              ],
            ),
            child:
                device.avatarUrl != null
                    ? Builder(
                      builder: (context) {
                        final avatarUrl = device.avatarUrl!;
                        bool isUrl =
                            avatarUrl.startsWith('http') ||
                            avatarUrl.startsWith('https');
                        // Check for Custom Avatar ID
                        bool isCustom = CustomAvatarWidget.avatars.any(
                          (a) => a['id'] == avatarUrl,
                        );

                        if (isUrl) {
                          return ClipOval(
                            child: Image.network(
                              avatarUrl,
                              width: 60,
                              height: 60,
                              fit: BoxFit.cover,
                              errorBuilder:
                                  (c, e, s) => Icon(
                                    _getPlatformIcon(device.platform),
                                    color: Colors.white,
                                    size: 28,
                                  ),
                            ),
                          );
                        } else if (isCustom) {
                          return CustomAvatarWidget(
                            avatarId: avatarUrl,
                            size: 60,
                            useBackground: true,
                          );
                        }
                        // Fallback to text (e.g. raw emoji)
                        return Center(
                          child: Text(
                            avatarUrl,
                            style: const TextStyle(
                              fontSize: 28,
                              color: Colors.white,
                              fontFamily: 'Segoe UI Emoji',
                            ),
                          ),
                        );
                      },
                    )
                    : Icon(
                      _getPlatformIcon(device.platform),
                      color: Colors.white,
                      size: 28,
                    ),
          ),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              displayName,
              style: GoogleFonts.outfit(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilesPanel() {
    // FIX: Wrap in LayoutBuilder to handle small sizes during Hero transition
    return LayoutBuilder(
      builder: (context, constraints) {
        // If constrained space is too small (during animation), scale down the UI
        final bool isSmall =
            constraints.maxHeight < 300 || constraints.maxWidth < 600;

        Widget content = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.all(24),
              child: Row(
                children: [
                  Text(
                    "Files to Share",
                    style: GoogleFonts.outfit(
                      color: Colors.white,
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Spacer(),
                  if (_files.isNotEmpty)
                    TextButton.icon(
                      onPressed: () {
                        setState(() {
                          _files.clear();
                          _progressList.clear();
                          _isPausedList.clear();
                          _downloadCounts.clear();
                          _stopServer();
                        });
                      },
                      icon: const Icon(
                        Icons.clear_all_rounded,
                        size: 18,
                        color: Colors.white54,
                      ),
                      label: Text(
                        "Clear All",
                        style: GoogleFonts.outfit(color: Colors.white54),
                      ),
                    ),
                ],
              ),
            ),

            // Action Buttons
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Row(
                children: [
                  Expanded(
                    child: _buildActionButton(
                      icon: Icons.add_rounded,
                      label: "Add Files",
                      onTap: _pickFiles,
                      isPrimary: true,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: _buildActionButton(
                      icon: Icons.create_new_folder_rounded,
                      label: "Add Folder",
                      onTap: _pickFolder,
                      isPrimary: false,
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 24),

            // Loading Indicator
            if (_loading)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 8,
                ),
                child: LinearProgressIndicator(
                  backgroundColor: Colors.white10,
                  color: const Color(0xFFFFD600),
                  minHeight: 2,
                ),
              ),

            // File List
            Expanded(
              child:
                  _files.isEmpty
                      ? _buildEmptyState()
                      : ListView.builder(
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        itemCount: _files.length,
                        itemBuilder: (ctx, i) => _buildVerticalFileCard(i),
                      ),
            ),
          ],
        );

        if (isSmall) {
          // Force layout into a box that is large enough, then scale it down to fit the constraints
          // This creates the "zoom in" effect during Hero
          return FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 500, // Safe assumes width
              height: 700, // Safe assumes height
              child: content,
            ),
          );
        }

        return content;
      },
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Material(
            color: const Color(0xFF1C1C1E).withValues(alpha: 0.8),
            shape: CircleBorder(
              side: BorderSide(
                color: Colors.white.withValues(alpha: 0.1),
                width: 1,
              ),
            ),
            child: InkWell(
              onTap: _pickFiles,
              borderRadius: BorderRadius.circular(50),
              child: Container(
                width: 100,
                height: 100,
                alignment: Alignment.center,
                child: const Icon(
                  Icons.file_upload_outlined,
                  color: Colors.white54,
                  size: 48,
                ),
              ),
            ),
          ),
          const SizedBox(height: 24),
          Text(
            _isDragOver ? "Drop files here" : "No files selected",
            style: GoogleFonts.outfit(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            "Add files to start sharing",
            style: GoogleFonts.inter(
              color: const Color(0xFFAAAAAA), // Opaque grey for sharper text
              fontSize: 14,
              fontWeight: FontWeight.w500,
              letterSpacing: 0.2,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildVerticalFileCard(int index) {
    // Android Style File Card
    final file = _files[index];
    final progress = _progressList.length > index ? _progressList[index] : 0.0;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1C1C1E).withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color:
              _isSharing && progress > 0
                  ? const Color(0xFFFFD600).withValues(alpha: 0.3)
                  : Colors.white.withValues(alpha: 0.05),
          width: 1.5,
        ),
      ),
      child: Row(
        children: [
          // Icon Container with Fill Progress Effect
          SizedBox(
            width: 50,
            height: 50,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Stack(
                children: [
                  // Background
                  Container(width: 50, height: 50, color: Colors.grey[800]),
                  // Progress Fill
                  if (progress > 0)
                    Align(
                      alignment: Alignment.bottomCenter,
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 100),
                        curve: Curves.linear,
                        width: 50,
                        height: 50 * progress,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.bottomCenter,
                            end: Alignment.topCenter,
                            colors: [
                              const Color(0xFFFFD600),
                              const Color(0xFFFFEE58),
                            ],
                          ),
                        ),
                      ),
                    ),
                  // Icon
                  Center(
                    child: Icon(
                      _getFileIcon(file.name),
                      color: progress > 0.5 ? Colors.black : Colors.white,
                      size: 28,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 16),

          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  file.name,
                  style: GoogleFonts.outfit(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Text(
                      _formatBytes(file.size),
                      style: GoogleFonts.outfit(
                        color: Colors.grey[400],
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    if (progress > 0) ...[
                      const SizedBox(width: 8),
                      Text(
                        "${(progress * 100).toInt()}%",
                        style: GoogleFonts.outfit(
                          color: const Color(0xFFFFD600),
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),

          if (_isSharing)
            IconButton(
              icon: Icon(
                Icons.close_rounded,
                color: Colors.grey[500],
                size: 20,
              ),
              onPressed: () {
                // Todo: implement remove specific file
              },
            ),
        ],
      ),
    );
  }

  Widget _buildActionButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    required bool isPrimary,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 16),
          decoration: BoxDecoration(
            color:
                isPrimary
                    ? const Color(0xFFFFD600)
                    : Colors.white.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(16),
            border:
                isPrimary
                    ? null
                    : Border.all(color: Colors.white.withValues(alpha: 0.1)),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                color: isPrimary ? Colors.black : Colors.white,
                size: 20,
              ),
              const SizedBox(width: 8),
              Text(
                label,
                style: GoogleFonts.outfit(
                  color: isPrimary ? Colors.black : Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildConnectionPanel(String displayCode) {
    // Generate QR Data: HTTP Link for universal access
    final qrData = _localIp != null ? "http://$_localIp:$_port" : "zapshare";

    return Container(
      padding: const EdgeInsets.all(32),
      // Use semi-transparent background to let global pulse show through gently if this is devices panel
      color: Colors.transparent,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 1. Connection INFO Card (QR + Code)
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: const Color(
                0xFF1C1C1E,
              ).withValues(alpha: 0.95), // Solid card
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black45,
                  blurRadius: 20,
                  offset: const Offset(0, 10),
                ),
              ],
            ),
            child: Row(
              children: [
                // QR Code (BIGGER - 120)
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFD600),
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFFFFD600).withOpacity(0.3),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: QrImageView(
                    data: qrData,
                    version: QrVersions.auto,
                    size: 120,
                    backgroundColor: const Color(0xFFFFD600),
                    foregroundColor: Colors.black,
                    padding: EdgeInsets.zero,
                  ),
                ),
                const SizedBox(width: 24),
                // Code Text
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        "Connection Code",
                        style: GoogleFonts.outfit(
                          color: Colors.grey[400],
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 4),
                      SelectableText(
                        displayCode,
                        style: GoogleFonts.robotoMono(
                          color: const Color(0xFFFFD600),
                          fontSize: 18, // Reduced font size to 18
                          fontWeight: FontWeight.bold,
                          letterSpacing: 2,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          const Spacer(),

          // 2. Nearby Devices (Visual "Scanning" Area)
          Padding(
            padding: const EdgeInsets.only(left: 8.0, bottom: 16.0),
            child: Text(
              "Scanning for devices...",
              style: GoogleFonts.outfit(
                color: Colors.white70,
                fontSize: 16,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.5,
              ),
            ),
          ),

          Expanded(
            flex: 2,
            child:
                _nearbyDevices.isEmpty
                    ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.radar_rounded,
                            color: Colors.white24,
                            size: 48,
                          ),
                          SizedBox(height: 16),
                          Text(
                            "No devices found nearby",
                            style: GoogleFonts.outfit(
                              color: Colors.white24,
                              fontSize: 14,
                            ),
                          ),
                        ],
                      ),
                    )
                    : ListView.builder(
                      itemCount: _nearbyDevices.length,
                      itemBuilder: (context, index) {
                        final device = _nearbyDevices[index];
                        return Container(
                          margin: const EdgeInsets.only(bottom: 12),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: Colors.white.withValues(alpha: 0.05),
                            ),
                          ),
                          child: ListTile(
                            leading: Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: Colors.black26,
                                shape: BoxShape.circle,
                              ),
                              child: Icon(
                                _getPlatformIcon(device.platform),
                                color: const Color(0xFFFFD600),
                                size: 20,
                              ),
                            ),
                            title: Text(
                              device.deviceName,
                              style: GoogleFonts.outfit(
                                color: Colors.white,
                                fontSize: 16,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            subtitle: Text(
                              device.ipAddress,
                              style: GoogleFonts.outfit(
                                color: Colors.grey[500],
                                fontSize: 12,
                              ),
                            ),
                            trailing: const Icon(
                              Icons.arrow_forward_ios_rounded,
                              color: Colors.white24,
                              size: 16,
                            ),
                            onTap: () {
                              _sendConnectionRequest(device);
                            },
                          ),
                        );
                      },
                    ),
          ),
        ],
      ),
    );
  }
}

// Helper Shimmer Widget
class ShimmerLoading extends StatefulWidget {
  final Widget child;
  const ShimmerLoading({super.key, required this.child});

  @override
  State<ShimmerLoading> createState() => _ShimmerLoadingState();
}

class _ShimmerLoadingState extends State<ShimmerLoading>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat();
    _animation = Tween<double>(begin: -2.0, end: 2.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOutSine),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _animation,
      builder: (context, child) {
        return ShaderMask(
          blendMode: BlendMode.srcIn,
          shaderCallback: (bounds) {
            return LinearGradient(
              begin: Alignment(-1.0, -0.0),
              end: Alignment(1.0, 0.0),
              transform: _SlidingGradientTransform(percent: _animation.value),
              colors: const [
                Color(0xFF000000),
                Color(0xFF666666),
                Color(0xFF000000),
              ],
              stops: const [0.4, 0.5, 0.6],
            ).createShader(bounds);
          },
          child: widget.child,
        );
      },
    );
  }
}

class _SlidingGradientTransform extends GradientTransform {
  final double percent;
  const _SlidingGradientTransform({required this.percent});

  @override
  Matrix4? transform(Rect bounds, {TextDirection? textDirection}) {
    return Matrix4.translationValues(bounds.width * percent, 0.0, 0.0);
  }
}
