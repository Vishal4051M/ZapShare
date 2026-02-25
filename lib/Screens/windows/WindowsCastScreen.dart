import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'dart:async';
import '../../services/device_discovery_service.dart';
import '../../widgets/cast_remote_control.dart';
import 'LocalPlayerDebugScreen.dart';

class WindowsCastScreen extends StatefulWidget {
  final File? initialFile;
  const WindowsCastScreen({super.key, this.initialFile});

  @override
  State<WindowsCastScreen> createState() => _WindowsCastScreenState();
}

class _WindowsCastScreenState extends State<WindowsCastScreen>
    with SingleTickerProviderStateMixin {
  final DeviceDiscoveryService _discoveryService = DeviceDiscoveryService();
  final NetworkInfo _networkInfo = NetworkInfo();

  List<DiscoveredDevice> _devices = [];
  bool _isScanning = false;
  File? _selectedFile;
  File? _selectedSubtitle;
  HttpServer? _server;
  String? _serverUrl;

  late AnimationController _scanController;

  // Cast session state
  String? _castTargetIp;
  String? _castTargetName;
  StreamSubscription<CastAck>? _castAckSubscription;

  // Status Capsule state
  String? _statusMessage;
  IconData _statusIcon = Icons.info_rounded;
  bool _statusIsSuccess = false;
  bool _statusIsError = false;
  Timer? _statusDismissTimer;

  @override
  void initState() {
    super.initState();
    _scanController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();

    // Handle initial file
    if (widget.initialFile != null) {
      _selectedFile = widget.initialFile;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _startServer(widget.initialFile!);
      });
    }

    _initDiscovery();
  }

  Future<void> _initDiscovery() async {
    await _discoveryService.initialize();
    _discoveryService.devicesStream.listen((devices) {
      if (mounted) {
        setState(() {
          _devices = devices;
        });
      }
    });

    // Listen for cast acknowledgements from the receiver
    _castAckSubscription = _discoveryService.castAckStream.listen((ack) {
      if (!mounted) return;
      if (ack.accepted) {
        _showStatus(
          message: "${ack.deviceName} accepted cast",
          isSuccess: true,
          autoDismiss: Duration(seconds: 3),
        );
      } else {
        _showStatus(
          message: "${ack.deviceName} declined cast",
          isError: true,
          autoDismiss: Duration(seconds: 3),
        );
        // Clear cast target since receiver declined
        setState(() {
          _castTargetIp = null;
          _castTargetName = null;
        });
      }
    });

    _startScanning();
  }

  Future<void> _startScanning() async {
    setState(() => _isScanning = true);
    await _discoveryService.start();
  }

  Future<void> _stopScanning() async {
    setState(() => _isScanning = false);
    await _discoveryService.stop();
  }

  Future<void> _pickVideo() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.video,
        allowMultiple: false,
      );

      if (result != null && result.files.single.path != null) {
        final file = File(result.files.single.path!);
        setState(() {
          _selectedFile = file;
          // Reset subtitle when new video is picked (optional)
          _selectedSubtitle = null;
        });
        await _startServer(file);
      }
    } catch (e) {
      print('Error picking file: $e');
      _showStatus(
        message: "Error picking file",
        isError: true,
        autoDismiss: Duration(seconds: 3),
      );
    }
  }

  Future<void> _pickSubtitle() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['srt', 'vtt', 'ass', 'ssa'],
        allowMultiple: false,
      );

      if (result != null && result.files.single.path != null) {
        final file = File(result.files.single.path!);
        setState(() {
          _selectedSubtitle = file;
        });
        if (_selectedFile != null) {
          // Restart server to include subtitle serving logic updates if needed
          // Or just ensure the listener handles it dynamically (which it will)
          await _startServer(_selectedFile!);
        }
        _showStatus(
          message:
              "Subtitle added: ${file.path.split(Platform.pathSeparator).last}",
          isSuccess: true,
          autoDismiss: Duration(seconds: 2),
        );
      }
    } catch (e) {
      print('Error picking subtitle: $e');
    }
  }

  Future<void> _startServer(File file) async {
    await _server?.close(force: true);

    try {
      // Get local IP
      String? ip;
      // Windows specific IP retrieval
      final interfaces = await NetworkInterface.list();
      for (var interface in interfaces) {
        if (interface.name.toLowerCase().contains('pseudo') ||
            interface.name.toLowerCase().contains('loopback'))
          continue;

        for (var addr in interface.addresses) {
          if (addr.type == InternetAddressType.IPv4 && !addr.isLoopback) {
            ip = addr.address;
            break;
          }
        }
        if (ip != null) break;
      }

      if (ip == null)
        throw Exception(
          'Could not determine local IP. Check your network connection.',
        );

      // Try binding with retry on port conflicts
      HttpServer? server;
      int retries = 3;
      while (retries > 0) {
        try {
          server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
          break;
        } catch (e) {
          retries--;
          if (retries == 0) rethrow;
          await Future.delayed(const Duration(milliseconds: 500));
        }
      }

      _server = server!;
      final port = _server!.port;
      _serverUrl = 'http://$ip:$port/video';

      // Detect content type from file extension
      final ext = file.path.split('.').last.toLowerCase();
      final contentType = _getVideoContentType(ext);

      _server!.listen((HttpRequest request) async {
        try {
          request.response.headers.add('Access-Control-Allow-Origin', '*');
          request.response.headers.add('Access-Control-Allow-Headers', 'Range');
          request.response.headers.add(
            'Access-Control-Expose-Headers',
            'Content-Range, Content-Length, Accept-Ranges',
          );

          // Handle preflight
          if (request.method == 'OPTIONS') {
            request.response.statusCode = HttpStatus.ok;
            await request.response.close();
            return;
          }

          // Route: /subtitle
          if (request.uri.path == '/subtitle' && _selectedSubtitle != null) {
            final subFile = _selectedSubtitle!;
            if (await subFile.exists()) {
              request.response.headers.contentType = ContentType.text;
              // Basic logic for now (might need specific mime types)
              await subFile.openRead().pipe(request.response);
            } else {
              request.response.statusCode = HttpStatus.notFound;
              await request.response.close();
            }
            return;
          }

          // Route: /video (default)
          final fileSize = await file.length();
          request.response.headers.contentType = ContentType.parse(contentType);
          request.response.headers.add('Accept-Ranges', 'bytes');
          request.response.headers.add('Cache-Control', 'no-cache');

          final range = request.headers.value('range');
          if (range != null) {
            final parts = range.replaceFirst('bytes=', '').split('-');
            final start = int.parse(parts[0]);
            final end =
                parts.length > 1 && parts[1].isNotEmpty
                    ? int.parse(parts[1])
                    : fileSize - 1;

            // Validate range
            if (start >= fileSize || end >= fileSize || start > end) {
              request.response.statusCode =
                  HttpStatus.requestedRangeNotSatisfiable;
              request.response.headers.set(
                'Content-Range',
                'bytes */$fileSize',
              );
              await request.response.close();
              return;
            }

            request.response.statusCode = HttpStatus.partialContent;
            request.response.headers.set(
              'Content-Range',
              'bytes $start-$end/$fileSize',
            );
            request.response.headers.contentLength = end - start + 1;

            await file.openRead(start, end + 1).pipe(request.response);
          } else {
            request.response.headers.contentLength = fileSize;
            await file.openRead().pipe(request.response);
          }
        } catch (e) {
          print('Error serving file: $e');
          try {
            request.response.statusCode = HttpStatus.internalServerError;
            await request.response.close();
          } catch (_) {}
        }
      });

      print('Server started at $_serverUrl');
      if (mounted) setState(() {});
      _showStatus(
        message: "Ready to Cast",
        isSuccess: true,
        autoDismiss: Duration(seconds: 2),
      );
    } catch (e) {
      print('Error starting server: $e');
      setState(() {
        _selectedFile = null;
      });
      _showStatus(
        message:
            "Server failed: ${e.toString().length > 60 ? '${e.toString().substring(0, 60)}...' : e}",
        isError: true,
        autoDismiss: Duration(seconds: 5),
      );
    }
  }

  /// Get proper MIME type for video file extension
  static String _getVideoContentType(String ext) {
    const mimeMap = {
      'mp4': 'video/mp4',
      'm4v': 'video/mp4',
      'mkv': 'video/x-matroska',
      'webm': 'video/webm',
      'avi': 'video/x-msvideo',
      'mov': 'video/quicktime',
      'wmv': 'video/x-ms-wmv',
      'flv': 'video/x-flv',
      'ts': 'video/mp2t',
      'mts': 'video/mp2t',
      'm2ts': 'video/mp2t',
      'mpg': 'video/mpeg',
      'mpeg': 'video/mpeg',
      '3gp': 'video/3gpp',
      'ogv': 'video/ogg',
      'asf': 'video/x-ms-asf',
      'vob': 'video/dvd',
      'divx': 'video/x-divx',
      'rm': 'application/vnd.rn-realmedia',
      'rmvb': 'application/vnd.rn-realmedia-vbr',
    };
    return mimeMap[ext] ?? 'application/octet-stream';
  }

  Future<void> _castToDevice(DiscoveredDevice device) async {
    if (_selectedFile == null || _serverUrl == null) {
      _showStatus(
        message: "Select a video first",
        isError: true,
        autoDismiss: Duration(seconds: 2),
      );
      return;
    }

    try {
      final fileName = _selectedFile?.path.split(Platform.pathSeparator).last;

      String? subtitleUrl;
      if (_selectedSubtitle != null && _serverUrl != null) {
        subtitleUrl = _serverUrl!.replaceFirst('/video', '/subtitle');
      }

      await _discoveryService.sendCastUrl(
        device.ipAddress,
        _serverUrl!,
        fileName: fileName,
        subtitleUrl: subtitleUrl,
      );

      if (!mounted) return;
      setState(() {
        _castTargetIp = device.ipAddress;
        _castTargetName = device.deviceName;
      });
      _showStatus(
        message: "Casting to ${device.deviceName}",
        isSuccess: true,
        autoDismiss: Duration(seconds: 3),
      );
    } catch (e) {
      _showStatus(
        message: "Failed to cast: $e",
        isError: true,
        autoDismiss: Duration(seconds: 3),
      );
    }
  }

  void _showStatus({
    required String message,
    IconData icon = Icons.info_rounded,
    bool isSuccess = false,
    bool isError = false,
    Duration? autoDismiss,
  }) {
    _statusDismissTimer?.cancel();
    setState(() {
      _statusMessage = message;
      _statusIcon = icon;
      _statusIsSuccess = isSuccess;
      _statusIsError = isError;
    });

    if (autoDismiss != null) {
      _statusDismissTimer = Timer(autoDismiss, _hideStatus);
    }
  }

  void _hideStatus() {
    _statusDismissTimer?.cancel();
    if (mounted) {
      setState(() {
        _statusMessage = null;
      });
    }
  }

  @override
  void dispose() {
    _server?.close(force: true);
    _scanController.dispose();
    _castAckSubscription?.cancel();
    _statusDismissTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Hero(
      tag: 'cast_card_container',
      createRectTween: (begin, end) {
        return MaterialRectCenterArcTween(begin: begin, end: end);
      },
      child: Scaffold(
        backgroundColor: const Color(0xFFFAFAFA),
        body: Stack(
          children: [
            // Background
            Positioned(
              top: -100,
              right: -100,
              child: Container(
                width: 300,
                height: 300,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.blueAccent.withOpacity(0.05),
                      blurRadius: 100,
                      spreadRadius: 20,
                    ),
                  ],
                ),
              ),
            ),

            SafeArea(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final bool isSmall =
                      constraints.maxWidth < 800 || constraints.maxHeight < 500;

                  Widget content = Row(
                    children: [
                      // Left Side - Video Selection
                      Expanded(
                        flex: 4,
                        child: Container(
                          decoration: BoxDecoration(
                            border: Border(
                              right: BorderSide(
                                color: Colors.grey.withOpacity(0.2),
                              ),
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // Header
                              Padding(
                                padding: const EdgeInsets.all(24),
                                child: Row(
                                  children: [
                                    Container(
                                      width: 40,
                                      height: 40,
                                      decoration: BoxDecoration(
                                        color: const Color(0xFFF5F5F7),
                                        shape: BoxShape.circle,
                                      ),
                                      child: IconButton(
                                        padding: EdgeInsets.zero,
                                        icon: const Icon(
                                          Icons.arrow_back_ios_new_rounded,
                                          color: Colors.black,
                                          size: 18,
                                        ),
                                        onPressed: () => Navigator.pop(context),
                                      ),
                                    ),
                                    const SizedBox(width: 16),
                                    Text(
                                      'App Cast',
                                      style: GoogleFonts.outfit(
                                        color: Colors.black,
                                        fontSize: 24,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ],
                                ),
                              ),

                              // Content
                              Padding(
                                padding: EdgeInsets.symmetric(horizontal: 24),
                                child: Text(
                                  'SELECT CONTENT',
                                  style: GoogleFonts.outfit(
                                    color: Colors.black54,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: 1.2,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 24),

                              Expanded(
                                child: SingleChildScrollView(
                                  padding: EdgeInsets.symmetric(horizontal: 24),
                                  child: Column(
                                    children: [
                                      GestureDetector(
                                        onTap: _pickVideo,
                                        child: Container(
                                          height: 240,
                                          width: double.infinity,
                                          decoration: BoxDecoration(
                                            color: const Color(0xFFF5F5F7),
                                            borderRadius: BorderRadius.circular(
                                              24,
                                            ),
                                            border: Border.all(
                                              color:
                                                  _selectedFile != null
                                                      ? const Color(0xFFFFD600)
                                                      : Colors.grey.withOpacity(
                                                        0.2,
                                                      ),
                                              width: 2,
                                            ),
                                          ),
                                          child: Column(
                                            mainAxisAlignment:
                                                MainAxisAlignment.center,
                                            children: [
                                              Container(
                                                padding: const EdgeInsets.all(
                                                  24,
                                                ),
                                                decoration: BoxDecoration(
                                                  color: (_selectedFile != null
                                                          ? const Color(
                                                            0xFFFFD600,
                                                          )
                                                          : Colors.black)
                                                      .withOpacity(0.05),
                                                  shape: BoxShape.circle,
                                                ),
                                                child: Icon(
                                                  _selectedFile != null
                                                      ? Icons
                                                          .movie_creation_rounded
                                                      : Icons.add_rounded,
                                                  size: 48,
                                                  color:
                                                      _selectedFile != null
                                                          ? const Color(
                                                            0xFFFFD600,
                                                          )
                                                          : Colors.black,
                                                ),
                                              ),
                                              const SizedBox(height: 24),
                                              Padding(
                                                padding: EdgeInsets.symmetric(
                                                  horizontal: 24,
                                                ),
                                                child: Text(
                                                  _selectedFile?.path
                                                          .split(
                                                            Platform
                                                                .pathSeparator,
                                                          )
                                                          .last ??
                                                      'Select Video File',
                                                  style: GoogleFonts.outfit(
                                                    color: Colors.black,
                                                    fontSize: 18,
                                                    fontWeight:
                                                        _selectedFile != null
                                                            ? FontWeight.w600
                                                            : FontWeight.w500,
                                                  ),
                                                  textAlign: TextAlign.center,
                                                  maxLines: 2,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                ),
                                              ),
                                              const SizedBox(height: 8),
                                              if (_selectedFile == null)
                                                Text(
                                                  'Supports MP4, MKV, AVI',
                                                  style: GoogleFonts.outfit(
                                                    color: Colors.grey[600],
                                                    fontSize: 14,
                                                  ),
                                                ),
                                            ],
                                          ),
                                        ),
                                      ),

                                      // Subtitle Picker
                                      const SizedBox(height: 16),
                                      Container(
                                        decoration: BoxDecoration(
                                          color: const Color(0xFFF5F5F7),
                                          borderRadius: BorderRadius.circular(
                                            16,
                                          ),
                                          border: Border.all(
                                            color:
                                                _selectedSubtitle != null
                                                    ? const Color(0xFFFFD600)
                                                    : Colors.grey.withOpacity(
                                                      0.2,
                                                    ),
                                          ),
                                        ),
                                        child: Row(
                                          children: [
                                            Expanded(
                                              child: InkWell(
                                                onTap: _pickSubtitle,
                                                borderRadius: BorderRadius.only(
                                                  topLeft: Radius.circular(16),
                                                  bottomLeft: Radius.circular(
                                                    16,
                                                  ),
                                                  topRight:
                                                      _selectedSubtitle != null
                                                          ? Radius.zero
                                                          : Radius.circular(16),
                                                  bottomRight:
                                                      _selectedSubtitle != null
                                                          ? Radius.zero
                                                          : Radius.circular(16),
                                                ),
                                                child: Padding(
                                                  padding:
                                                      const EdgeInsets.symmetric(
                                                        vertical: 16,
                                                        horizontal: 24,
                                                      ),
                                                  child: Row(
                                                    children: [
                                                      Icon(
                                                        Icons.subtitles_rounded,
                                                        color:
                                                            _selectedSubtitle !=
                                                                    null
                                                                ? const Color(
                                                                  0xFFF57F17,
                                                                ) // Darker yellow for visibility
                                                                : Colors.grey,
                                                      ),
                                                      const SizedBox(width: 16),
                                                      Expanded(
                                                        child: Text(
                                                          _selectedSubtitle
                                                                  ?.path
                                                                  .split(
                                                                    Platform
                                                                        .pathSeparator,
                                                                  )
                                                                  .last ??
                                                              'Add Subtitle (Optional)',
                                                          style:
                                                              GoogleFonts.outfit(
                                                                color:
                                                                    Colors
                                                                        .black87,
                                                                fontSize: 16,
                                                                fontWeight:
                                                                    FontWeight
                                                                        .w500,
                                                              ),
                                                          overflow:
                                                              TextOverflow
                                                                  .ellipsis,
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                              ),
                                            ),
                                            if (_selectedSubtitle != null)
                                              IconButton(
                                                icon: const Icon(
                                                  Icons.close_rounded,
                                                  size: 20,
                                                  color: Colors.grey,
                                                ),
                                                onPressed: () {
                                                  setState(
                                                    () =>
                                                        _selectedSubtitle =
                                                            null,
                                                  );
                                                },
                                              ),
                                          ],
                                        ),
                                      ),

                                      if (_serverUrl != null) ...[
                                        SizedBox(height: 24),
                                        Container(
                                          padding: const EdgeInsets.all(16),
                                          decoration: BoxDecoration(
                                            color: Colors.grey.withOpacity(0.1),
                                            borderRadius: BorderRadius.circular(
                                              12,
                                            ),
                                          ),
                                          child: Row(
                                            children: [
                                              const Icon(
                                                Icons.link_rounded,
                                                color: Color(0xFFFFD600),
                                                size: 20,
                                              ),
                                              const SizedBox(width: 12),
                                              Expanded(
                                                child: SelectableText(
                                                  _serverUrl!,
                                                  style: GoogleFonts.outfit(
                                                    color: Colors.black,
                                                    fontSize: 13,
                                                  ),
                                                ),
                                              ),
                                              IconButton(
                                                icon: const Icon(
                                                  Icons.copy_rounded,
                                                  color: Colors.grey,
                                                  size: 20,
                                                ),
                                                onPressed: () {
                                                  Clipboard.setData(
                                                    ClipboardData(
                                                      text: _serverUrl!,
                                                    ),
                                                  );
                                                  _showStatus(
                                                    message: "URL copied",
                                                    isSuccess: true,
                                                    autoDismiss: Duration(
                                                      seconds: 1,
                                                    ),
                                                  );
                                                },
                                              ),
                                            ],
                                          ),
                                        ),
                                      ],
                                      if (_selectedFile != null) ...[
                                        const SizedBox(height: 16),
                                        Container(
                                          width: double.infinity,
                                          decoration: BoxDecoration(
                                            color: Colors.red.withOpacity(0.05),
                                            borderRadius: BorderRadius.circular(
                                              12,
                                            ),
                                            border: Border.all(
                                              color: Colors.red.withOpacity(
                                                0.2,
                                              ),
                                            ),
                                          ),
                                          child: TextButton.icon(
                                            onPressed: () {
                                              if (_selectedFile != null) {
                                                Navigator.push(
                                                  context,
                                                  MaterialPageRoute(
                                                    builder:
                                                        (
                                                          context,
                                                        ) => LocalPlayerDebugScreen(
                                                          file: _selectedFile!,
                                                          subtitleFile:
                                                              _selectedSubtitle,
                                                        ),
                                                  ),
                                                );
                                              }
                                            },
                                            icon: const Icon(
                                              Icons.bug_report_rounded,
                                              color: Colors.red,
                                              size: 20,
                                            ),
                                            label: Text(
                                              "Debug: Play Locally (Check Duration)",
                                              style: GoogleFonts.outfit(
                                                color: Colors.red,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                              ),

                              // Remote control (shown after casting)
                              if (_castTargetIp != null)
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    24,
                                    0,
                                    24,
                                    12,
                                  ),
                                  child: CastRemoteControlWidget(
                                    targetDeviceIp: _castTargetIp!,
                                    targetDeviceName:
                                        _castTargetName ?? 'Device',
                                    fileName:
                                        _selectedFile?.path
                                            .split(Platform.pathSeparator)
                                            .last ??
                                        'Unknown',
                                    onDisconnect: () {
                                      setState(() {
                                        _castTargetIp = null;
                                        _castTargetName = null;
                                      });
                                    },
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),

                      // Right Side - Device List
                      Expanded(
                        flex: 3,
                        child: Container(
                          color: const Color(0xFFFAFAFA),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Padding(
                                padding: const EdgeInsets.all(24),
                                child: Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                  children: [
                                    Row(
                                      children: [
                                        if (_isScanning)
                                          Padding(
                                            padding: const EdgeInsets.only(
                                              right: 12,
                                            ),
                                            child: RotationTransition(
                                              turns: _scanController,
                                              child: const Icon(
                                                Icons.sync,
                                                color: Color(0xFFFFD600),
                                                size: 16,
                                              ),
                                            ),
                                          ),
                                        Text(
                                          'AVAILABLE DEVICES',
                                          style: GoogleFonts.outfit(
                                            color: Colors.black54,
                                            fontSize: 12,
                                            fontWeight: FontWeight.w700,
                                            letterSpacing: 1.2,
                                          ),
                                        ),
                                      ],
                                    ),
                                    IconButton(
                                      icon: Icon(
                                        _isScanning
                                            ? Icons.stop_circle_outlined
                                            : Icons.refresh_rounded,
                                        color: Colors.black54,
                                      ),
                                      onPressed:
                                          _isScanning
                                              ? _stopScanning
                                              : _startScanning,
                                    ),
                                  ],
                                ),
                              ),
                              Expanded(
                                child:
                                    _devices.isEmpty
                                        ? Center(
                                          child: Column(
                                            mainAxisAlignment:
                                                MainAxisAlignment.center,
                                            children: [
                                              Icon(
                                                Icons.computer_rounded,
                                                size: 64,
                                                color: Colors.grey[300],
                                              ),
                                              const SizedBox(height: 16),
                                              Text(
                                                _isScanning
                                                    ? 'Scanning network...'
                                                    : 'No devices found',
                                                style: GoogleFonts.outfit(
                                                  color: Colors.grey[600],
                                                  fontSize: 16,
                                                ),
                                              ),
                                            ],
                                          ),
                                        )
                                        : ListView.builder(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 24,
                                          ),
                                          itemCount: _devices.length,
                                          itemBuilder: (context, index) {
                                            final device = _devices[index];
                                            return Container(
                                              margin: const EdgeInsets.only(
                                                bottom: 12,
                                              ),
                                              decoration: BoxDecoration(
                                                color: const Color(0xFFF5F5F7),
                                                borderRadius:
                                                    BorderRadius.circular(16),
                                                border: Border.all(
                                                  color: Colors.grey
                                                      .withOpacity(0.2),
                                                ),
                                              ),
                                              child: Padding(
                                                padding: const EdgeInsets.all(
                                                  16,
                                                ),
                                                child: Row(
                                                  children: [
                                                    Container(
                                                      width: 48,
                                                      height: 48,
                                                      decoration: BoxDecoration(
                                                        color: Colors.white,
                                                        borderRadius:
                                                            BorderRadius.circular(
                                                              12,
                                                            ),
                                                      ),
                                                      child: Icon(
                                                        Icons.devices,
                                                        color: Colors.black54,
                                                      ),
                                                    ),
                                                    const SizedBox(width: 16),
                                                    Expanded(
                                                      child: Column(
                                                        crossAxisAlignment:
                                                            CrossAxisAlignment
                                                                .start,
                                                        children: [
                                                          Text(
                                                            device.deviceName,
                                                            style:
                                                                GoogleFonts.outfit(
                                                                  color:
                                                                      Colors
                                                                          .black,
                                                                  fontWeight:
                                                                      FontWeight
                                                                          .w600,
                                                                ),
                                                          ),
                                                          const SizedBox(
                                                            height: 4,
                                                          ),
                                                          Text(
                                                            device.ipAddress,
                                                            style: GoogleFonts.outfit(
                                                              color:
                                                                  Colors
                                                                      .grey[800],
                                                              fontSize: 13,
                                                            ),
                                                          ),
                                                        ],
                                                      ),
                                                    ),
                                                    const SizedBox(width: 16),
                                                    ElevatedButton(
                                                      onPressed:
                                                          () => _castToDevice(
                                                            device,
                                                          ),
                                                      style:
                                                          ElevatedButton.styleFrom(
                                                            backgroundColor:
                                                                const Color(
                                                                  0xFFFFD600,
                                                                ),
                                                            foregroundColor:
                                                                Colors.black,
                                                          ),
                                                      child: Text(
                                                        'CAST',
                                                        style:
                                                            GoogleFonts.outfit(
                                                              fontWeight:
                                                                  FontWeight
                                                                      .bold,
                                                            ),
                                                      ),
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
                      ),
                    ],
                  );

                  if (isSmall) {
                    return FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.center,
                      child: SizedBox(width: 1000, height: 700, child: content),
                    );
                  }

                  return content;
                },
              ),
            ),

            // Status Capsule Positioned
            if (_statusMessage != null)
              Positioned(
                bottom: 32,
                left: 0,
                right: 0,
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    decoration: BoxDecoration(
                      color:
                          _statusIsError
                              ? const Color(0xFFB71C1C)
                              : (_statusIsSuccess
                                  ? const Color(0xFF1B5E20)
                                  : const Color(0xFF1C1C1E)),
                      borderRadius: BorderRadius.circular(30),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.3),
                          blurRadius: 12,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(_statusIcon, color: Colors.white70, size: 20),
                        const SizedBox(width: 12),
                        Text(
                          _statusMessage!,
                          style: GoogleFonts.outfit(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
