import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'dart:math'; // Added for min
import 'package:path_provider/path_provider.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/services.dart';
import 'package:open_file/open_file.dart';

class DownloadTask {
  final String url;
  final String fileName;
  final int fileSize;
  String savePath;
  double progress;
  String status;
  bool isSelected;
  bool isPaused;
  int bytesReceived;
  double speedMbps;

  DownloadTask({
    required this.url,
    required this.fileName,
    required this.fileSize,
    required this.savePath,
    this.progress = 0.0,
    this.status = 'Waiting',
    this.isSelected = true,
    this.isPaused = false,
    this.bytesReceived = 0,
    this.speedMbps = 0.0,
  });
}

class WindowsReceiveScreen extends StatefulWidget {
  final String? autoConnectCode;

  const WindowsReceiveScreen({super.key, this.autoConnectCode});

  @override
  State<WindowsReceiveScreen> createState() => _WindowsReceiveScreenState();
}

class UpperCaseTextFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final upper = newValue.text.toUpperCase();
    return TextEditingValue(
      text: upper,
      selection: newValue.selection,
      composing: TextRange.empty,
    );
  }
}

class _WindowsReceiveScreenState extends State<WindowsReceiveScreen> {
  final TextEditingController _codeController = TextEditingController();
  final FocusNode _codeFocusNode = FocusNode();
  String? _saveFolder;
  List<DownloadTask> _tasks = [];
  List<DownloadTask> _downloadedFiles = [];
  bool _downloading = false;
  int _activeDownloads = 0;
  final int _maxParallel = 3;
  String? _serverIp;
  int _serverPort = 8080;
  bool _loading = false;
  List<String> _recentCodes = [];

  // Status capsule state
  String? _statusMessage;
  String? _statusSubtitle;
  IconData _statusIcon = Icons.sync_rounded;
  bool _statusIsSuccess = false;
  bool _statusIsError = false;
  Timer? _statusDismissTimer;

  @override
  void initState() {
    super.initState();
    _loadRecentCodes();
    _codeFocusNode.addListener(() {
      setState(() {});
    });

    if (widget.autoConnectCode != null && widget.autoConnectCode!.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _codeController.text = widget.autoConnectCode!;
        _fetchFileList(widget.autoConnectCode!);
      });
    }

    _initDefaultSaveFolder();
  }

  Future<void> _initDefaultSaveFolder() async {
    _saveFolder = await _getDefaultDownloadFolder();
    if (mounted) setState(() {});
  }

  Future<void> _loadRecentCodes() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final codes = prefs.getStringList('recent_codes') ?? [];
      setState(() {
        _recentCodes = codes;
      });
    } catch (e) {
      print('Error loading recent codes: $e');
    }
  }

  Future<void> _saveRecentCode(String code) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _recentCodes.remove(code);
      _recentCodes.insert(0, code);
      if (_recentCodes.length > 5) {
        _recentCodes = _recentCodes.sublist(0, 5);
      }
      await prefs.setStringList('recent_codes', _recentCodes);
      setState(() {});
    } catch (e) {
      print('Error saving recent code: $e');
    }
  }

  Future<String> _getDefaultDownloadFolder() async {
    try {
      final downloadsDir = await getDownloadsDirectory();
      if (downloadsDir != null) {
        return downloadsDir.path;
      }
      return '${Platform.environment['USERPROFILE'] ?? 'C:\\Users\\User'}\\Downloads';
    } catch (e) {
      return 'C:\\Downloads';
    }
  }

  Future<void> _pickCustomFolder() async {
    try {
      String? selectedDirectory = await FilePicker.platform.getDirectoryPath();
      if (selectedDirectory != null) {
        setState(() {
          _saveFolder = selectedDirectory;
        });
        _showStatus(
          message: 'Save location updated',
          icon: Icons.folder_open_rounded,
          autoDismiss: Duration(seconds: 2),
          isSuccess: true,
        );
      }
    } catch (e) {
      print('Error picking folder: $e');
    }
  }

  bool _decodeCode(String code) {
    try {
      if (!RegExp(r'^[A-Z0-9]{8,11}$').hasMatch(code)) {
        _showStatus(
          message: 'Invalid code format',
          subtitle: 'Must be 8-11 characters',
          icon: Icons.error_outline_rounded,
          isError: true,
          autoDismiss: Duration(seconds: 3),
        );
        return false;
      }

      String ipCode = code.substring(0, 8);
      int n = int.parse(ipCode, radix: 36);
      final ip =
          '${(n >> 24) & 0xFF}.${(n >> 16) & 0xFF}.${(n >> 8) & 0xFF}.${n & 0xFF}';
      final parts = ip.split('.').map(int.parse).toList();
      if (parts.length != 4 || parts.any((p) => p < 0 || p > 255)) {
        return false;
      }
      _serverIp = ip;

      if (code.length >= 11) {
        String portCode = code.substring(8, 11);
        _serverPort = int.parse(portCode, radix: 36);
      } else {
        _serverPort = 8080;
      }

      return true;
    } catch (e) {
      return false;
    }
  }

  Future<void> _fetchFileList(String code) async {
    if (!_decodeCode(code)) return;

    setState(() {
      _loading = true;
      _tasks.clear(); // Clear previous tasks on new connection
      _downloadedFiles.clear();
    });

    _showStatus(message: 'Connecting to device...', subtitle: 'Handshaking...');

    try {
      print('Connecting via TCP to $_serverIp:${_serverPort + 1}...');
      final socket = await Socket.connect(
        _serverIp,
        _serverPort + 1, // Connect to TCP server (port + 1)
        timeout: Duration(seconds: 5),
      );
      socket.writeln('LIST');
      await socket.flush();

      final stream = socket
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter());

      bool received = false;
      await for (var line in stream) {
        final List files = jsonDecode(line);
        received = true;
        setState(() => _loading = false);

        if (files.isNotEmpty) {
          await _saveRecentCode(code);

          setState(() {
            _tasks =
                files.map((f) {
                  final String uri = f['uri'] ?? '';
                  final String name = f['name'] ?? uri.split('/').last;
                  final int size = f['size'] ?? 0;
                  final int index = f['index'] ?? files.indexOf(f);
                  final String url =
                      'http://$_serverIp:$_serverPort/file/$index';

                  return DownloadTask(
                    url: url,
                    fileName: name,
                    fileSize: size,
                    savePath: '',
                  );
                }).toList();
          });

          _startDownloads(); // Auto-start download

          _showStatus(
            message: 'Connected!',
            icon: Icons.check_circle_rounded,
            isSuccess: true,
            autoDismiss: Duration(seconds: 2),
          );
        } else {
          _showStatus(
            message: 'No files found',
            icon: Icons.folder_off_rounded,
            isError: true,
            autoDismiss: Duration(seconds: 3),
          );
        }
        socket.close();
        break;
      }
      if (!received) throw Exception('No response from device');
    } catch (e) {
      setState(() => _loading = false);
      print('Connection failed: $e');

      // Fallback to direct HTTP fetch if TCP fails (legacy support or firewall issue)
      _fetchFileListHttp(code);
    }
  }

  Future<void> _fetchFileListHttp(String code) async {
    try {
      print('Attempting HTTP fallback...');
      final url = 'http://$_serverIp:$_serverPort/list';
      final resp = await http.get(Uri.parse(url)).timeout(Duration(seconds: 3));
      if (resp.statusCode == 200) {
        final List files = jsonDecode(resp.body);
        await _saveRecentCode(code);
        setState(() {
          _loading = false;
          _tasks =
              files.map((f) {
                final String name = f['name'];
                final int size = f['size'];
                final int index = f['index'];
                final String url = 'http://$_serverIp:$_serverPort/file/$index';

                return DownloadTask(
                  url: url,
                  fileName: name,
                  fileSize: size,
                  savePath: '',
                );
              }).toList();
        });
        _showStatus(
          message: 'Connected (HTTP)!',
          icon: Icons.check_circle_rounded,
          isSuccess: true,
          autoDismiss: Duration(seconds: 2),
        );
      } else {
        throw Exception('HTTP Error ${resp.statusCode}');
      }
    } catch (e) {
      print('HTTP Fallback failed: $e');
      _showStatus(
        message: 'Connection failed',
        subtitle: e.toString().substring(0, min(50, e.toString().length)),
        icon: Icons.error_outline_rounded,
        isError: true,
        autoDismiss: Duration(seconds: 4),
      );
    }
  }

  void _addUrlTask(String url) {
    if (url.isEmpty) return;
    try {
      final uri = Uri.parse(url);
      String fileName =
          uri.pathSegments.isNotEmpty
              ? uri.pathSegments.last
              : 'download_${DateTime.now().millisecondsSinceEpoch}';
      if (fileName.isEmpty) fileName = 'file';

      final task = DownloadTask(
        url: url,
        fileName: fileName,
        fileSize: 0,
        savePath: '',
      );

      setState(() {
        _tasks.add(task);
      });
      _startDownloads();

      _showStatus(
        message: 'Added to queue',
        icon: Icons.queue_rounded,
        isSuccess: true,
        autoDismiss: Duration(seconds: 2),
      );
    } catch (e) {
      _showStatus(
        message: 'Invalid URL',
        icon: Icons.error_outline_rounded,
        isError: true,
        autoDismiss: Duration(seconds: 2),
      );
    }
  }

  Future<void> _showLinkDialog() async {
    final controller = TextEditingController();
    await showDialog(
      context: context,
      builder:
          (context) => AlertDialog(
            backgroundColor: const Color(0xFF1C1C1E),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
            title: Text(
              'Download from Link',
              style: GoogleFonts.outfit(
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
            content: TextField(
              controller: controller,
              style: GoogleFonts.outfit(color: Colors.white),
              decoration: InputDecoration(
                hintText: 'https://example.com/file.zip',
                hintStyle: GoogleFonts.outfit(color: Colors.grey),
                filled: true,
                fillColor: Colors.white.withOpacity(0.05),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(
                  'Cancel',
                  style: GoogleFonts.outfit(color: Colors.grey),
                ),
              ),
              ElevatedButton(
                onPressed: () {
                  Navigator.pop(context);
                  _addUrlTask(controller.text);
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFFFD600),
                  foregroundColor: Colors.black,
                ),
                child: Text(
                  'Download',
                  style: GoogleFonts.outfit(fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
    );
  }

  Future<void> _startDownloads() async {
    if (_saveFolder == null) {
      _saveFolder = await _getDefaultDownloadFolder();
      if (mounted) setState(() {});
    }

    final selectedTasks = _tasks.where((task) => task.isSelected).toList();
    if (selectedTasks.isEmpty) return;

    setState(() {
      _downloading = true;
      _activeDownloads = 0;
    });

    _startQueuedDownloads();
  }

  void _startQueuedDownloads() {
    while (_activeDownloads < _maxParallel) {
      final next = _tasks.indexWhere(
        (t) => t.isSelected && t.status == 'Waiting' && !t.isPaused,
      );
      if (next == -1) break;
      setState(() {
        _activeDownloads++;
      });
      _downloadFile(_tasks[next]);
    }
  }

  Future<void> _downloadFile(DownloadTask task) async {
    setState(() {
      task.status = 'Downloading';
    });

    try {
      final client = http.Client();
      final request = http.Request('GET', Uri.parse(task.url));
      request.headers['Connection'] = 'keep-alive';

      final response = await client
          .send(request)
          .timeout(
            Duration(minutes: 60), // Longer timeout for large files on desktop
            onTimeout: () => throw TimeoutException('Download timed out'),
          );

      String fileName = task.fileName;
      // Handle content disposition if needed, but we usually trust the Task's fileName

      String savePath = '$_saveFolder\\$fileName';
      int count = 1;
      while (await File(savePath).exists()) {
        final parts = fileName.split('.');
        if (parts.length > 1) {
          final base = parts.sublist(0, parts.length - 1).join('.');
          final ext = parts.last;
          savePath = '$_saveFolder\\${base}_$count.$ext';
        } else {
          savePath = '$_saveFolder\\${fileName}_$count';
        }
        count++;
      }

      task.savePath = savePath;
      final file = File(savePath);
      final sink = file.openWrite();
      int received = 0;
      final contentLength = response.contentLength ?? task.fileSize;

      DateTime lastSpeedTime = DateTime.now();
      int lastBytes = 0;

      await for (var chunk in response.stream) {
        if (task.isPaused && mounted) {
          // Simple pause logic: wait loop
          while (task.isPaused && mounted) {
            await Future.delayed(Duration(milliseconds: 500));
          }
        }

        sink.add(chunk);
        received += chunk.length;
        task.bytesReceived = received;

        double progress = contentLength > 0 ? received / contentLength : 0.0;
        task.progress = progress;

        final now = DateTime.now();
        final elapsed = now.difference(lastSpeedTime).inMilliseconds;
        if (elapsed > 1000) {
          final bytesDelta = received - lastBytes;
          task.speedMbps = (bytesDelta * 8) / (elapsed * 1000); // Mbps
          lastBytes = received;
          lastSpeedTime = now;
          if (mounted) setState(() {});
        } else if (progress == 1.0 && mounted) {
          setState(() {});
        }
      }

      await sink.flush();
      await sink.close();
      client.close();

      setState(() {
        task.status = 'Complete';
        _activeDownloads--;
        _downloadedFiles.add(task);
        _tasks.remove(task);
      });

      _startQueuedDownloads();

      if (_tasks.every(
        (task) => task.status == 'Complete' || !task.isSelected,
      )) {
        setState(() {
          _downloading = false;
        });
        _showStatus(
          message: 'All downloads complete',
          icon: Icons.done_all_rounded,
          isSuccess: true,
          autoDismiss: Duration(seconds: 3),
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        task.status = 'Error';
        _activeDownloads--;
      });
      _startQueuedDownloads();
    }
  }

  Future<void> _openFile(DownloadTask task) async {
    try {
      final result = await OpenFile.open(task.savePath);
      if (result.type != ResultType.done) {
        _showStatus(
          message: 'Could not open file: ${result.message}',
          isError: true,
          autoDismiss: Duration(seconds: 2),
        );
      }
    } catch (e) {
      _showStatus(
        message: 'Error opening file',
        isError: true,
        autoDismiss: Duration(seconds: 2),
      );
    }
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return "$bytes B";
    if (bytes < 1024 * 1024) return "${(bytes / 1024).toStringAsFixed(1)} KB";
    if (bytes < 1024 * 1024 * 1024)
      return "${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB";
    return "${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB";
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
      _statusDismissTimer = Timer(autoDismiss, _hideStatus);
    }
  }

  void _hideStatus() {
    _statusDismissTimer?.cancel();
    if (mounted) {
      setState(() {
        _statusMessage = null;
        _statusSubtitle = null;
        _statusIsSuccess = false;
        _statusIsError = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Hero(
      tag: 'receive_card_container',
      createRectTween: (begin, end) {
        return MaterialRectCenterArcTween(begin: begin, end: end);
      },
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle.light,
        child: Scaffold(
          backgroundColor: Colors.black,
          body: Stack(
            children: [
              // Background Elements (Optional for visual flair)
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
                        color: const Color(0xFFFFD600).withOpacity(0.05),
                        blurRadius: 100,
                        spreadRadius: 20,
                      ),
                    ],
                  ),
                ),
              ),

              SafeArea(
                child:
                    _buildLandscapeLayout(), // Default to landscape structure for Windows
              ),

              // Status Capsule
              if (_statusMessage != null)
                Positioned(
                  bottom: 32,
                  left: 0,
                  right: 0,
                  child: Center(child: _buildStatusCapsule()),
                ),
            ],
          ),
        ),
      ),
    );
  }

  // Status Capsule Widget
  Widget _buildStatusCapsule() {
    Color bgColor = const Color(0xFF1C1C1E);
    Color iconColor = Colors.white70;

    if (_statusIsSuccess) {
      bgColor = const Color(0xFF1B5E20);
      iconColor = Colors.greenAccent;
    } else if (_statusIsError) {
      bgColor = const Color(0xFFB71C1C);
      iconColor = Colors.redAccent;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: bgColor,
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
          Icon(_statusIcon, color: iconColor, size: 20),
          const SizedBox(width: 12),
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _statusMessage!,
                style: GoogleFonts.outfit(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (_statusSubtitle != null)
                Text(
                  _statusSubtitle!,
                  style: GoogleFonts.outfit(
                    color: Colors.white70,
                    fontSize: 12,
                  ),
                ),
            ],
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: _hideStatus,
            child: const Icon(Icons.close, color: Colors.white30, size: 16),
          ),
        ],
      ),
    );
  }

  Widget _buildLandscapeLayout() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final bool isSmall =
            constraints.maxWidth < 800 || constraints.maxHeight < 500;

        Widget content = Row(
          children: [
            // Left Panel - Code Input and Settings
            Expanded(
              flex: 2,
              child: Container(
                decoration: BoxDecoration(
                  color: const Color(0xFF0A0A0A),
                  border: Border(
                    right: BorderSide(
                      color: Colors.white.withOpacity(0.1),
                      width: 1,
                    ),
                  ),
                ),
                child: Column(
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
                              color: const Color(0xFF1C1C1E),
                              shape: BoxShape.circle,
                            ),
                            child: IconButton(
                              padding: EdgeInsets.zero,
                              icon: const Icon(
                                Icons.arrow_back_ios_new_rounded,
                                color: Colors.white,
                                size: 18,
                              ),
                              onPressed: () => Navigator.pop(context),
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Text(
                              'Receive Files',
                              style: GoogleFonts.outfit(
                                color: Colors.white,
                                fontSize: 24,
                                fontWeight: FontWeight.w700,
                              ),
                              overflow: TextOverflow.visible,
                              softWrap: false,
                            ),
                          ),
                        ],
                      ),
                    ),

                    // Content
                    Expanded(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _buildCodeInput(),
                            const SizedBox(height: 32),
                            if (_recentCodes.isNotEmpty) ...[
                              _buildRecentCodes(),
                              const SizedBox(height: 32),
                            ],
                            _buildSaveLocationCard(),
                            const SizedBox(height: 16),
                            // Link download button
                            Container(
                              width: double.infinity,
                              child: OutlinedButton.icon(
                                onPressed: _showLinkDialog,
                                icon: Icon(
                                  Icons.link_rounded,
                                  color: const Color(0xFFFFD600),
                                ),
                                label: Text(
                                  "Download from URL",
                                  style: GoogleFonts.outfit(
                                    color: Colors.white,
                                  ),
                                ),
                                style: OutlinedButton.styleFrom(
                                  side: BorderSide(
                                    color: Colors.white.withOpacity(0.1),
                                  ),
                                  padding: EdgeInsets.symmetric(vertical: 16),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // Right Panel - File List
            Expanded(
              flex: 3,
              child: Container(
                color: Colors.black, // Explicit black
                child: Column(
                  children: [
                    // Files Header
                    Container(
                      padding: const EdgeInsets.all(24),
                      decoration: BoxDecoration(
                        border: Border(
                          bottom: BorderSide(
                            color: Colors.white.withOpacity(0.1),
                            width: 1,
                          ),
                        ),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Row(
                            children: [
                              Icon(
                                Icons.folder_open_rounded,
                                color: const Color(0xFFFFD600),
                                size: 28,
                              ),
                              const SizedBox(width: 12),
                              Text(
                                _tasks.isNotEmpty
                                    ? 'Available Files (${_tasks.length})'
                                    : 'Waiting for connection...',
                                style: GoogleFonts.outfit(
                                  color: Colors.white,
                                  fontSize: 20,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),

                          if (_tasks.any(
                            (t) => t.isSelected && t.status == 'Waiting',
                          ))
                            ElevatedButton.icon(
                              onPressed: _downloading ? null : _startDownloads,
                              icon:
                                  _downloading
                                      ? SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          color: Colors.black,
                                        ),
                                      )
                                      : Icon(Icons.download_rounded, size: 18),
                              label: Text(
                                _downloading
                                    ? 'Downloading...'
                                    : 'Download All',
                                style: GoogleFonts.outfit(
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFFFFD600),
                                foregroundColor: Colors.black,
                                padding: EdgeInsets.symmetric(
                                  horizontal: 20,
                                  vertical: 16,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),

                    // Content
                    Expanded(
                      child:
                          _loading
                              ? _buildShimmerList()
                              : (_tasks.isEmpty && _downloadedFiles.isEmpty)
                              ? _buildEmptyState()
                              : ListView(
                                padding: const EdgeInsets.all(24),
                                children: [
                                  if (_tasks.isNotEmpty) ...[
                                    Text(
                                      "AVAILABLE",
                                      style: GoogleFonts.outfit(
                                        color: Colors.grey[600],
                                        fontSize: 12,
                                        fontWeight: FontWeight.bold,
                                        letterSpacing: 1.2,
                                      ),
                                    ),
                                    const SizedBox(height: 12),
                                    ..._tasks
                                        .map((task) => _buildFileItem(task))
                                        .toList(),
                                    const SizedBox(height: 32),
                                  ],

                                  if (_downloadedFiles.isNotEmpty) ...[
                                    Text(
                                      "DOWNLOADED",
                                      style: GoogleFonts.outfit(
                                        color: Colors.grey[600],
                                        fontSize: 12,
                                        fontWeight: FontWeight.bold,
                                        letterSpacing: 1.2,
                                      ),
                                    ),
                                    const SizedBox(height: 12),
                                    ..._downloadedFiles
                                        .map((task) => _buildFileItem(task))
                                        .toList(),
                                  ],
                                ],
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
    );
  }

  Widget _buildCodeInput() {
    final codeLength = _codeController.text.length;

    // Desktop sizing
    final boxWidth = 24.0;
    final boxHeight = 44.0;
    final boxGap = 3.0;
    final fontSize = 18.0;
    final cardPadding = 24.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: const Color(0xFFFFD600).withOpacity(0.15),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                Icons.key_rounded,
                color: const Color(0xFFFFD600),
                size: 20,
              ),
            ),
            const SizedBox(width: 12),
            Text(
              'ENTER CODE',
              style: GoogleFonts.outfit(
                color: Colors.grey[500],
                fontSize: 13,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.2,
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),

        // Code Input Card
        Container(
          padding: EdgeInsets.all(cardPadding),
          decoration: BoxDecoration(
            color: const Color(0xFF1C1C1E),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
              color:
                  _codeFocusNode.hasFocus
                      ? const Color(0xFFFFD600)
                      : Colors.white.withOpacity(0.08),
              width: 2,
            ),
            boxShadow: [
              if (_codeFocusNode.hasFocus)
                BoxShadow(
                  color: const Color(0xFFFFD600).withOpacity(0.15),
                  blurRadius: 24,
                  offset: const Offset(0, 8),
                ),
            ],
          ),
          child: Column(
            children: [
              // Individual Code Boxes
              Stack(
                children: [
                  // Visual code boxes
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      mainAxisSize: MainAxisSize.min,
                      children: List.generate(11, (index) {
                        final hasChar = index < codeLength;
                        final isCurrent =
                            index == codeLength && _codeFocusNode.hasFocus;

                        return Container(
                          width: boxWidth,
                          height: boxHeight,
                          margin: EdgeInsets.only(
                            right: index < 10 ? boxGap : 0,
                          ),
                          decoration: BoxDecoration(
                            color:
                                hasChar
                                    ? const Color(0xFFFFD600).withOpacity(0.1)
                                    : Colors.black.withOpacity(0.3),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(
                              color:
                                  isCurrent
                                      ? const Color(0xFFFFD600)
                                      : hasChar
                                      ? const Color(0xFFFFD600).withOpacity(0.3)
                                      : Colors.white.withOpacity(0.1),
                              width: isCurrent ? 2 : 1,
                            ),
                          ),
                          child: Center(
                            child:
                                hasChar
                                    ? Text(
                                      _codeController.text[index],
                                      style: GoogleFonts.outfit(
                                        color: Colors.white,
                                        fontSize: fontSize,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    )
                                    : isCurrent
                                    ? Container(
                                      width: 2,
                                      height: 16,
                                      color: const Color(0xFFFFD600),
                                    )
                                    : Text(
                                      '•',
                                      style: GoogleFonts.outfit(
                                        color: Colors.grey[700],
                                        fontSize: fontSize,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                          ),
                        );
                      }),
                    ),
                  ),

                  // Invisible TextField for input
                  Positioned.fill(
                    child: Opacity(
                      opacity: 0.0,
                      child: TextField(
                        controller: _codeController,
                        focusNode: _codeFocusNode,
                        autofocus: false,
                        keyboardType: TextInputType.text,
                        textCapitalization: TextCapitalization.characters,
                        inputFormatters: [
                          LengthLimitingTextInputFormatter(11),
                          UpperCaseTextFormatter(),
                        ],
                        onChanged: (value) {
                          setState(() {});
                          if (value.length >= 8) {
                            // Auto-submit when code is complete (8-11 chars)
                            if (value.length == 11 || value.length == 8) {
                              _fetchFileList(value);
                            }
                          }
                        },
                        onSubmitted: _fetchFileList,
                      ),
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 20),

              // Helper Text
              Text(
                _codeFocusNode.hasFocus
                    ? 'Enter 11-character code from sender'
                    : 'Tap to enter code',
                textAlign: TextAlign.center,
                style: GoogleFonts.outfit(
                  color: Colors.grey[500],
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),

              const SizedBox(height: 20),

              // Connect Button
              SizedBox(
                width: double.infinity,
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap:
                        codeLength >= 8
                            ? () {
                              _fetchFileList(_codeController.text);
                            }
                            : null,
                    borderRadius: BorderRadius.circular(16),
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      decoration: BoxDecoration(
                        gradient:
                            codeLength >= 8
                                ? const LinearGradient(
                                  begin: Alignment.topLeft,
                                  end: Alignment.bottomRight,
                                  colors: [
                                    Color(0xFFFFD600),
                                    Color(0xFFFFC400),
                                  ],
                                )
                                : null,
                        color:
                            codeLength >= 8
                                ? null
                                : Colors.white.withOpacity(0.05),
                        borderRadius: BorderRadius.circular(16),
                        boxShadow:
                            codeLength >= 8
                                ? [
                                  BoxShadow(
                                    color: const Color(
                                      0xFFFFD600,
                                    ).withOpacity(0.3),
                                    blurRadius: 12,
                                    offset: const Offset(0, 6),
                                  ),
                                ]
                                : null,
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          if (_loading)
                            Padding(
                              padding: const EdgeInsets.only(right: 8.0),
                              child: SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.black,
                                ),
                              ),
                            ),
                          Icon(
                            Icons.arrow_forward_rounded,
                            color:
                                codeLength >= 8
                                    ? Colors.black
                                    : Colors.grey[700],
                            size: 22,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            _loading ? 'CONNECTING...' : 'Connect',
                            style: GoogleFonts.outfit(
                              color:
                                  codeLength >= 8
                                      ? Colors.black
                                      : Colors.grey[700],
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildRecentCodes() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          "RECENT CODES",
          style: GoogleFonts.outfit(
            color: Colors.grey[500],
            fontSize: 12,
            fontWeight: FontWeight.bold,
            letterSpacing: 1.2,
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children:
              _recentCodes.map((code) {
                return InkWell(
                  onTap: () {
                    _codeController.text = code;
                    _fetchFileList(code);
                  },
                  borderRadius: BorderRadius.circular(10),
                  child: Container(
                    padding: EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1C1C1E),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Colors.white.withOpacity(0.1)),
                    ),
                    child: Text(
                      code,
                      style: GoogleFonts.outfit(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 1,
                      ),
                    ),
                  ),
                );
              }).toList(),
        ),
      ],
    );
  }

  Widget _buildSaveLocationCard() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              Icons.folder_special_rounded,
              color: Colors.grey[600],
              size: 18,
            ),
            const SizedBox(width: 8),
            Text(
              "SAVE LOCATION",
              style: GoogleFonts.outfit(
                color: Colors.grey[500],
                fontSize: 12,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.2,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Container(
          decoration: BoxDecoration(
            color: const Color(0xFF1C1C1E),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white.withOpacity(0.05)),
          ),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  padding: EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.grey[900],
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    Icons.folder_open,
                    color: Colors.white70,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _saveFolder ?? 'Downloads',
                        style: GoogleFonts.outfit(
                          color: Colors.white,
                          fontSize: 14,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Files will be saved here',
                        style: GoogleFonts.outfit(
                          color: Colors.grey[500],
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: Icon(
                    Icons.edit_rounded,
                    color: const Color(0xFFFFD600),
                  ),
                  onPressed: _pickCustomFolder,
                  padding: EdgeInsets.zero,
                  constraints: BoxConstraints(),
                  splashRadius: 24,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              color: const Color(0xFF1C1C1E),
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.import_export_rounded,
              size: 40,
              color: Colors.grey[700],
            ),
          ),
          const SizedBox(height: 24),
          Text(
            "No Connection",
            style: GoogleFonts.outfit(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            "Enter the code displayed on the\nsending device to view files.",
            textAlign: TextAlign.center,
            style: GoogleFonts.outfit(color: Colors.grey[500], fontSize: 15),
          ),
        ],
      ),
    );
  }

  Widget _buildFileItem(DownloadTask task) {
    final bool isDownloading = task.status == 'Downloading';
    final bool isComplete = task.status == 'Complete';

    return Container(
      margin: EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF1C1C1E),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withOpacity(0.05)),
      ),
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Row(
          children: [
            // File Icon
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color:
                    isComplete
                        ? const Color(0xFF1B5E20).withOpacity(0.3)
                        : Colors.white.withOpacity(0.05),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                isComplete
                    ? Icons.check_rounded
                    : Icons.insert_drive_file_rounded,
                color: isComplete ? Colors.greenAccent : Colors.white70,
              ),
            ),
            const SizedBox(width: 16),

            // File Info
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    task.fileName,
                    style: GoogleFonts.outfit(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                      fontSize: 16,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        _formatBytes(task.fileSize),
                        style: GoogleFonts.outfit(
                          color: Colors.grey[500],
                          fontSize: 12,
                        ),
                      ),
                      if (isDownloading) ...[
                        Text(" • ", style: TextStyle(color: Colors.grey[700])),
                        Text(
                          "${task.speedMbps.toStringAsFixed(1)} Mbps",
                          style: GoogleFonts.outfit(
                            color: const Color(0xFFFFD600),
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ],
                  ),
                  if (isDownloading) ...[
                    const SizedBox(height: 12),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: task.progress,
                        backgroundColor: Colors.white10,
                        color: const Color(0xFFFFD600),
                        minHeight: 4,
                      ),
                    ),
                  ],
                ],
              ),
            ),

            // Actions
            if (!isComplete && !isDownloading && task.status != 'Waiting')
              IconButton(
                icon: Icon(Icons.refresh_rounded, color: Colors.white70),
                onPressed: () => _downloadFile(task),
              ),

            if (isComplete)
              IconButton(
                icon: Icon(Icons.open_in_new_rounded, color: Colors.white70),
                onPressed: () => _openFile(task),
              ),

            if (task.status == 'Waiting')
              Checkbox(
                value: task.isSelected,
                activeColor: const Color(0xFFFFD600),
                checkColor: Colors.black,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(4),
                ),
                onChanged: (val) {
                  setState(() {
                    task.isSelected = val ?? false;
                  });
                },
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildShimmerList() {
    return ListView.builder(
      padding: const EdgeInsets.all(24),
      itemCount: 6,
      itemBuilder: (context, index) {
        return ShimmerLoading(
          child: Container(
            margin: const EdgeInsets.only(bottom: 12),
            height: 80,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
            ),
          ),
        );
      },
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
              colors: [
                Colors.white.withOpacity(0.3),
                Colors.white,
                Colors.white.withOpacity(0.3),
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
