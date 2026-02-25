import 'package:flutter/material.dart';

import 'package:http/http.dart' as http;
import 'dart:io';
import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:open_file/open_file.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zap_share/blocs/navigation/smooth_page_route.dart';

import 'AndroidFileListScreen.dart';
import 'AndroidHomeScreen.dart';
import 'NearbyDevicesScreen.dart';
import 'package:zap_share/services/wifi_direct_service.dart';

enum FileType {
  image,
  video,
  audio,
  pdf,
  document,
  spreadsheet,
  presentation,
  archive,
  apk,
  text,
  other,
}

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

class AndroidReceiveScreen extends StatefulWidget {
  final String? autoConnectCode;
  final bool useTcp; // Default false (HTTP) for manual entry

  const AndroidReceiveScreen({
    super.key,
    this.autoConnectCode,
    this.useTcp = false,
  });

  @override
  State<AndroidReceiveScreen> createState() => _AndroidReceiveScreenState();
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

class _AndroidReceiveScreenState extends State<AndroidReceiveScreen> {
  final TextEditingController _codeController = TextEditingController();
  final FocusNode _codeFocusNode = FocusNode();
  String? _saveFolder;
  List<DownloadTask> _tasks = [];
  List<DownloadTask> _downloadedFiles = [];
  bool _downloading = false;
  int _activeDownloads = 0;
  final int _maxParallel = 3;
  String? _serverIp;
  int _serverPort = 8080; // Default port
  bool _loading = false;
  List<String> _recentCodes = [];

  Future<void> _connectToServer({String? code, bool showLoading = true}) async {
    if (showLoading) setState(() => _loading = true);

    // HTTP Connection Flow (Manual Entry default)
    if (!widget.useTcp) {
      try {
        print('Connecting via HTTP to $_serverIp:$_serverPort...');
        final url = Uri.parse('http://$_serverIp:$_serverPort/list');
        final response = await http
            .get(url)
            .timeout(const Duration(seconds: 5));

        if (response.statusCode == 200) {
          final List files = jsonDecode(response.body);
          if (showLoading) setState(() => _loading = false);

          if (files.isNotEmpty) {
            if (code != null) await _saveRecentCode(code);

            HapticFeedback.mediumImpact();
            if (!mounted) return;

            Navigator.push(
              context,
              MaterialPageRoute(
                builder:
                    (context) => AndroidFileListScreen(
                      serverIp: _serverIp!,
                      serverPort: _serverPort,
                      files: files.cast<Map<String, dynamic>>(),
                      useTcp: false, // HTTP mode
                    ),
              ),
            );
          } else {
            _showErrorSnackBar('No files found on this device.');
          }
          return;
        } else {
          throw Exception('Server returned ${response.statusCode}');
        }
      } catch (e) {
        print('HTTP Connection failed: $e');
        if (showLoading) setState(() => _loading = false);
        _showErrorSnackBar('Connection failed: $e');
        return;
      }
    }

    // TCP Connection Flow (Auto Connect / Dialog Accept)
    const maxAttempts = 3;
    for (int attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        print(
          'Connecting via TCP to $_serverIp:${_serverPort + 1} (attempt $attempt/$maxAttempts)...',
        );
        final socket = await Socket.connect(
          _serverIp,
          _serverPort + 1,
          timeout: Duration(seconds: 4),
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
          if (showLoading) setState(() => _loading = false);

          if (files.isNotEmpty) {
            if (code != null) {
              await _saveRecentCode(code);
            }

            HapticFeedback.mediumImpact();
            // Navigate to file list screen with TCP mode enabled
            if (mounted) {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder:
                      (context) => AndroidFileListScreen(
                        serverIp: _serverIp!,
                        serverPort: _serverPort,
                        files: files.cast<Map<String, dynamic>>(),
                        useTcp: true, // Enable TCP for following downloads
                      ),
                ),
              );
            }
          } else {
            _showErrorSnackBar('No files found on this device.');
          }
          socket.close();
          return; // Success — exit the retry loop
        }
        if (!received) throw Exception('No response from device');
        return; // Success
      } catch (e) {
        print('Connection attempt $attempt failed: $e');
        if (attempt < maxAttempts) {
          // Wait before retrying (short delay)
          final delay = attempt;
          print('Retrying in ${delay}s...');
          await Future.delayed(Duration(seconds: delay));
        } else {
          // All attempts failed
          if (showLoading) setState(() => _loading = false);

          if (showLoading) {
            _showErrorSnackBar(
              'Connection failed after $maxAttempts attempts: $e',
            );
            return;
          }
          // Rethrow for silent mode so caller handles it
          throw Exception('Connection failed: $e');
        }
      }
    }
  }

  void _showErrorSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message, style: GoogleFonts.outfit(color: Colors.white)),
        backgroundColor: Colors.red,
      ),
    );
  }

  final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
      FlutterLocalNotificationsPlugin();

  final WiFiDirectService _wifiDirectService = WiFiDirectService();
  StreamSubscription? _connectionInfoSubscription;

  @override
  void initState() {
    super.initState();

    _initLocalNotifications();
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
      // Remove if already exists
      _recentCodes.remove(code);
      // Add to beginning
      _recentCodes.insert(0, code);
      // Keep only last 5
      if (_recentCodes.length > 5) {
        _recentCodes = _recentCodes.sublist(0, 5);
      }
      await prefs.setStringList('recent_codes', _recentCodes);
      setState(() {});
    } catch (e) {
      print('Error saving recent code: $e');
    }
  }

  Future<void> _scanForSenders() async {
    // Navigate to NearbyDevicesScreen as Receiver
    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => const NearbyDevicesScreen(isSender: false),
      ),
    );

    if (result != null && result is NearbyDeviceResult) {
      if (!mounted) return;

      // Show connecting dialog
      showDialog(
        context: context,
        barrierDismissible: false,
        builder:
            (context) => Center(
              child: Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: const Color(0xFF1C1C1E),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: Colors.white.withOpacity(0.05)),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(color: const Color(0xFFFFD600)),
                    const SizedBox(height: 16),
                    Text(
                      'Connecting to ${result.peer.deviceName}...',
                      style: GoogleFonts.outfit(
                        color: Colors.white,
                        fontSize: 16,
                      ),
                    ),
                  ],
                ),
              ),
            ),
      );

      // If the returned peer has an IP address (from auto-connect), use it immediately
      bool usedImmediateIp = false;
      if (result.peer.deviceAddress.contains('.')) {
        // Likely an IP address (MAC addresses use :)
        final ip = result.peer.deviceAddress;
        print('✅ Connected via Wi-Fi Direct (Immediate). Owner IP: $ip');
        if (ip.isNotEmpty) {
          _serverIp = ip;
          _serverPort = 8080;
          usedImmediateIp = true;

          // Close dialog if needed (though we just showed it)
          // Actually we need to keep the dialog until connection to server succeeds

          try {
            // Wait a bit for network
            await Future.delayed(const Duration(seconds: 1));
            await _connectToServer(showLoading: false);

            if (mounted && Navigator.canPop(context)) {
              Navigator.pop(context); // Dismiss "Connecting..." dialog
            }
          } catch (e) {
            // Fallback to listening if immediate connect fails?
            // Or just show error
            if (mounted) {
              if (Navigator.canPop(context)) Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    'Connection failed: $e',
                    style: GoogleFonts.outfit(color: Colors.white),
                  ),
                  backgroundColor: Colors.red,
                ),
              );
            }
          }
        }
      }

      if (!usedImmediateIp) {
        // Listen for connection info to get IP (Normal flow)
        _connectionInfoSubscription?.cancel();
        _connectionInfoSubscription = _wifiDirectService.connectionInfoStream
            .listen((info) async {
              if (info.groupFormed) {
                _connectionInfoSubscription?.cancel();

                if (mounted) {
                  // Get Owner IP
                  final ip = info.groupOwnerAddress;
                  print('✅ Connected via Wi-Fi Direct. Owner IP: $ip');

                  if (ip.isNotEmpty) {
                    setState(() {
                      _serverIp = ip;
                      _serverPort = 8080;
                    });

                    // Proceed to connect without showing another loader
                    try {
                      // Wait a bit for network to stabilize
                      await Future.delayed(const Duration(seconds: 2));

                      await _connectToServer(showLoading: false);

                      if (mounted && Navigator.canPop(context)) {
                        Navigator.pop(context); // Dismiss dialog on success
                      }
                    } catch (e) {
                      if (mounted) {
                        if (Navigator.canPop(context)) Navigator.pop(context);
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              'Connection failed: $e',
                              style: GoogleFonts.outfit(color: Colors.white),
                            ),
                            backgroundColor: Colors.red,
                          ),
                        );
                      }
                    }
                  } else {
                    if (mounted && Navigator.canPop(context))
                      Navigator.pop(context);
                  }
                }
              }
            });
      }

      // Timeout logic
      Future.delayed(const Duration(seconds: 30), () {
        if (_connectionInfoSubscription != null && mounted) {
          // If we are still here, it timed out
          _connectionInfoSubscription?.cancel();
          if (Navigator.canPop(context)) Navigator.pop(context);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Connection timed out',
                style: GoogleFonts.outfit(color: Colors.white),
              ),
              backgroundColor: Colors.red,
            ),
          );
        }
      });
    }
  }

  Future<void> _initLocalNotifications() async {
    const AndroidInitializationSettings initializationSettingsAndroid =
        AndroidInitializationSettings('ic_stat_notify');
    final InitializationSettings initializationSettings =
        InitializationSettings(android: initializationSettingsAndroid);
    await flutterLocalNotificationsPlugin.initialize(
      initializationSettings,
      onDidReceiveNotificationResponse: (NotificationResponse response) {
        final actionId = response.actionId;
        if (actionId == null) return;
        if (actionId.startsWith('pause_')) {
          final idx = int.tryParse(actionId.substring(6));
          if (idx != null && idx < _tasks.length) {
            setState(() {
              _tasks[idx].isPaused = true;
            });
          }
        } else if (actionId.startsWith('resume_')) {
          final idx = int.tryParse(actionId.substring(7));
          if (idx != null && idx < _tasks.length) {
            setState(() {
              _tasks[idx].isPaused = false;
            });
            _startQueuedDownloads();
          }
        }
      },
    );
  }

  Future<void> showProgressNotification(
    int fileIndex,
    double progress,
    String fileName, {
    double speedMbps = 0.0,
    bool paused = false,
  }) async {
    final percent = (progress * 100).toStringAsFixed(1);
    final body =
        '$fileName\nProgress: $percent%\nSpeed: ${speedMbps.toStringAsFixed(2)} Mbps';
    final androidPlatformChannelSpecifics = AndroidNotificationDetails(
      'download_progress_channel_$fileIndex',
      'File Download Progress $fileIndex',
      channelDescription: 'Shows the progress of file download $fileIndex',
      importance: Importance.max,
      priority: Priority.high,
      showProgress: true,
      maxProgress: 100,
      progress: (progress * 100).toInt(),
      onlyAlertOnce: true,
      styleInformation: BigTextStyleInformation(body),
      icon: 'ic_stat_notify',
    );
    final platformChannelSpecifics = NotificationDetails(
      android: androidPlatformChannelSpecifics,
    );
    await flutterLocalNotificationsPlugin.show(
      2000 + fileIndex,
      'ZapShare Download',
      body,
      platformChannelSpecifics,
      payload: 'download_progress',
    );
  }

  Future<void> cancelProgressNotification(int fileIndex) async {
    await flutterLocalNotificationsPlugin.cancel(2000 + fileIndex);
  }

  @override
  void dispose() {
    _codeController.dispose();
    _codeFocusNode.dispose();
    _connectionInfoSubscription?.cancel();
    super.dispose();
  }

  Future<String> _getDefaultDownloadFolder() async {
    try {
      await _requestStoragePermissions();
      final downloadsDir = await getDownloadsDirectory();
      if (downloadsDir != null) {
        final downloadsPath = downloadsDir.path;
        if (downloadsPath.contains('/Download') ||
            downloadsPath.contains('/Downloads')) {
          final zapShareDir = Directory('$downloadsPath/ZapShare');
          if (!await zapShareDir.exists()) {
            await zapShareDir.create(recursive: true);
          }
          return zapShareDir.path;
        }
      }
      final publicDownloadsPath = '/storage/emulated/0/Download/ZapShare';
      final zapShareDir = Directory(publicDownloadsPath);
      if (!await zapShareDir.exists()) {
        await zapShareDir.create(recursive: true);
      }
      return publicDownloadsPath;
    } catch (e) {
      return '/storage/emulated/0/Download/ZapShare';
    }
  }

  Future<void> _pickCustomFolder() async {
    try {
      String? selectedDirectory = await FilePicker.platform.getDirectoryPath();
      if (selectedDirectory != null) {
        setState(() {
          _saveFolder = selectedDirectory;
        });
        HapticFeedback.mediumImpact();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Save location updated',
              style: GoogleFonts.outfit(color: Colors.black),
            ),
            backgroundColor: const Color(0xFFFFD600),
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      print('Error picking folder: $e');
    }
  }

  Future<void> _requestStoragePermissions() async {
    try {
      if (await Permission.storage.isDenied) {
        await Permission.storage.request();
      }
      if (await Permission.manageExternalStorage.isDenied) {
        await Permission.manageExternalStorage.request();
      }
    } catch (e) {
      print('Error requesting storage permissions: $e');
    }
  }

  bool _decodeCode(String code) {
    try {
      // Support both old 8-char format (IP only) and new 11-char format (IP + port)
      if (!RegExp(r'^[A-Z0-9]{8,11}$').hasMatch(code)) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Invalid code format. Must be 8-11 characters.',
              style: GoogleFonts.outfit(color: Colors.white),
            ),
            backgroundColor: Colors.red,
          ),
        );
        return false;
      }

      // Extract IP code (first 8 characters)
      String ipCode = code.substring(0, 8);
      int n = int.parse(ipCode, radix: 36);
      final ip =
          '${(n >> 24) & 0xFF}.${(n >> 16) & 0xFF}.${(n >> 8) & 0xFF}.${n & 0xFF}';
      final parts = ip.split('.').map(int.parse).toList();
      if (parts.length != 4 || parts.any((p) => p < 0 || p > 255)) {
        return false;
      }
      _serverIp = ip;

      // Extract port if available (characters 9-11)
      if (code.length >= 11) {
        String portCode = code.substring(8, 11);
        _serverPort = int.parse(portCode, radix: 36);
      } else {
        // Default to 8080 for backward compatibility
        _serverPort = 8080;
      }

      return true;
    } catch (e) {
      return false;
    }
  }

  Future<void> _fetchFileList(String code) async {
    if (!_decodeCode(code)) return;
    await _connectToServer(code: code);
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

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Added to download queue',
            style: GoogleFonts.outfit(color: Colors.black),
          ),
          backgroundColor: const Color(0xFFFFD600),
        ),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Invalid URL',
            style: GoogleFonts.outfit(color: Colors.white),
          ),
          backgroundColor: Colors.red,
        ),
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
      setState(() {});
    }

    final selectedTasks = _tasks.where((task) => task.isSelected).toList();
    if (selectedTasks.isEmpty) return;

    await FlutterForegroundTask.startService(
      notificationTitle: "⚡ ZapShare Download",
      notificationText: "Downloading files...",
      notificationIcon: const NotificationIcon(
        metaDataName: 'com.pravera.flutter_foreground_task.notification_icon',
      ),
    );

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

    IOSink? sink;
    File? file;

    try {
      final client = http.Client();
      final request = http.Request('GET', Uri.parse(task.url));
      request.headers['Connection'] = 'keep-alive';

      final response = await client
          .send(request)
          .timeout(
            Duration(minutes: 10),
            onTimeout: () => throw TimeoutException('Download timed out'),
          );

      String fileName = task.fileName;

      String savePath = '$_saveFolder/$fileName';
      int count = 1;
      while (await File(savePath).exists()) {
        final parts = fileName.split('.');
        if (parts.length > 1) {
          final base = parts.sublist(0, parts.length - 1).join('.');
          final ext = parts.last;
          savePath = '$_saveFolder/${base}_$count.$ext';
        } else {
          savePath = '$_saveFolder/${fileName}_$count';
        }
        count++;
      }

      task.savePath = savePath;
      file = File(savePath);
      sink = file.openWrite();
      int received = 0;
      final contentLength = response.contentLength ?? task.fileSize;

      DateTime lastUpdate = DateTime.now();
      double lastProgress = 0.0;
      int lastBytes = 0;
      DateTime lastSpeedTime = DateTime.now();

      await for (var chunk in response.stream) {
        while (task.isPaused) {
          await Future.delayed(Duration(milliseconds: 200));
        }

        sink.add(chunk);
        received += chunk.length;
        task.bytesReceived = received;

        // Safety check for empty content length
        final total =
            contentLength > 0 ? contentLength : (received + 1024 * 1024);
        double progress = (received / total).clamp(0.0, 1.0);
        task.progress = progress;

        final now = DateTime.now();
        final elapsed = now.difference(lastSpeedTime).inMilliseconds;
        if (elapsed > 0) {
          final bytesDelta = received - lastBytes;
          task.speedMbps = (bytesDelta * 8) / (elapsed * 1000);
          lastBytes = received;
          lastSpeedTime = now;
        }

        if (now.difference(lastUpdate).inMilliseconds > 100 ||
            (progress - lastProgress) > 0.01) {
          setState(() {});
          await showProgressNotification(
            _tasks.indexOf(task),
            progress,
            fileName,
            speedMbps: task.speedMbps,
            paused: task.isPaused,
          );
          lastUpdate = now;
          lastProgress = progress;
        }
      }

      await sink.flush();
      await sink.close();
      client.close();

      // Get the task index BEFORE removing from list
      final taskIndex = _tasks.indexOf(task);

      setState(() {
        task.status = 'Complete';
        _activeDownloads--;
        _downloadedFiles.add(task);
        _tasks.remove(task);
      });

      // Cancel notification after updating state, using saved index
      if (taskIndex >= 0) {
        await cancelProgressNotification(taskIndex);
      }

      _startQueuedDownloads();

      if (_tasks.every(
        (task) => task.status == 'Complete' || !task.isSelected,
      )) {
        try {
          await FlutterForegroundTask.stopService();
        } catch (e) {
          // Ignore PlatformException when service is already stopped
          print('Note: Foreground service stop: $e');
        }
        setState(() {
          _downloading = false;
        });
      }
    } catch (e) {
      // Clean up incomplete file
      if (sink != null) {
        try {
          await sink.close();
        } catch (_) {}
      }
      if (file != null) {
        try {
          if (await file.exists()) {
            await file.delete();
            print('Deleted incomplete file: ${file.path}');
          }
        } catch (_) {}
      }

      final taskIndex = _tasks.indexOf(task);
      setState(() {
        task.status = 'Error';
        _activeDownloads--;
      });
      if (taskIndex >= 0) {
        await cancelProgressNotification(taskIndex);
      }
      _startQueuedDownloads();
    }
  }

  Future<void> _openFile(DownloadTask task) async {
    try {
      final result = await OpenFile.open(task.savePath);
      if (result.type != ResultType.done) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Could not open file: ${result.message}',
              style: GoogleFonts.outfit(color: Colors.white),
            ),
            backgroundColor: Colors.orange,
          ),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Error opening file: $e',
            style: GoogleFonts.outfit(color: Colors.white),
          ),
          backgroundColor: Colors.red,
        ),
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

  FileType _getFileType(String fileName) {
    final ext = fileName.split('.').last.toLowerCase();
    if (['jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'svg'].contains(ext))
      return FileType.image;
    if (['mp4', 'mov', 'avi', 'mkv', 'flv', 'wmv', 'webm'].contains(ext))
      return FileType.video;
    if (['mp3', 'wav', 'aac', 'flac', 'ogg', 'm4a'].contains(ext))
      return FileType.audio;
    if (ext == 'pdf') return FileType.pdf;
    if (['doc', 'docx', 'txt', 'rtf', 'odt'].contains(ext))
      return FileType.document;
    if (['xls', 'xlsx', 'csv', 'ods'].contains(ext))
      return FileType.spreadsheet;
    if (['ppt', 'pptx', 'odp'].contains(ext)) return FileType.presentation;
    if (['zip', 'rar', '7z', 'tar', 'gz', 'bz2'].contains(ext))
      return FileType.archive;
    if (ext == 'apk') return FileType.apk;
    if (['txt', 'md', 'json', 'xml', 'html', 'css', 'js'].contains(ext))
      return FileType.text;
    return FileType.other;
  }

  @override
  Widget build(BuildContext context) {
    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;
    final screenWidth = MediaQuery.of(context).size.width;
    final isTV = screenWidth > 1000; // Detect TV/large screens

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, result) {
          if (didPop) return;
          if (_codeFocusNode.hasFocus) {
            FocusScope.of(context).unfocus();
          } else {
            if (Navigator.canPop(context)) {
              Navigator.pop(context);
            } else {
              // No previous screen, go to Home
              Navigator.pushReplacement(
                context,
                SmoothPageRoute.fade(page: const AndroidHomeScreen()),
              );
            }
          }
        },
        child: Scaffold(
          backgroundColor: Colors.black,
          body: SafeArea(
            child:
                isLandscape || isTV
                    ? _buildLandscapeLayout()
                    : _buildPortraitLayout(),
          ),
        ),
      ),
    );
  }

  Widget _buildPortraitLayout() {
    return Column(
      children: [
        _buildHeader(),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildCodeInput(),
                const SizedBox(height: 24),
                if (_recentCodes.isNotEmpty) _buildRecentCodes(),
                if (_recentCodes.isNotEmpty) const SizedBox(height: 24),
                _buildSaveLocationCard(),
                const SizedBox(height: 32),
                if (_loading)
                  Center(
                    child: CircularProgressIndicator(color: Color(0xFFFFD600)),
                  ),
                if (_tasks.isNotEmpty) ...[
                  _buildSectionTitle('AVAILABLE FILES'),
                  const SizedBox(height: 16),
                  _buildFileList(_tasks, isDownloadList: true),
                ],
                if (_downloadedFiles.isNotEmpty) ...[
                  const SizedBox(height: 32),
                  _buildSectionTitle('DOWNLOADED'),
                  const SizedBox(height: 16),
                  _buildFileList(_downloadedFiles, isDownloadList: false),
                ],
                const SizedBox(height: 100),
              ],
            ),
          ),
        ),
        if (_tasks.any((t) => t.isSelected && t.status == 'Waiting'))
          _buildBottomAction(),
      ],
    );
  }

  Widget _buildLandscapeLayout() {
    return Row(
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
                // Compact header for landscape
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: const Color(0xFF1C1C1E),
                          shape: BoxShape.circle,
                        ),
                        child: IconButton(
                          padding: EdgeInsets.zero,
                          icon: const Icon(
                            Icons.arrow_back_ios_new_rounded,
                            color: Colors.white,
                            size: 16,
                          ),
                          onPressed: () => Navigator.pop(context),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        'Receive',
                        style: GoogleFonts.outfit(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
                // Scrollable content
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _buildCodeInput(),
                        const SizedBox(height: 16),
                        if (_recentCodes.isNotEmpty) ...[
                          _buildRecentCodes(),
                          const SizedBox(height: 16),
                        ],
                        _buildSaveLocationCard(),
                        const SizedBox(height: 16),
                        if (_loading)
                          Center(
                            child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: CircularProgressIndicator(
                                color: Color(0xFFFFD600),
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
          child: Column(
            children: [
              // Compact file list header
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(
                      color: Colors.white.withOpacity(0.1),
                      width: 1,
                    ),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.folder_rounded,
                      color: const Color(0xFFFFD600),
                      size: 24,
                    ),
                    const SizedBox(width: 12),
                    Text(
                      _tasks.isNotEmpty
                          ? 'Files (${_tasks.length})'
                          : 'No Files',
                      style: GoogleFonts.outfit(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              // Scrollable file list content
              Expanded(
                child:
                    _tasks.isEmpty && _downloadedFiles.isEmpty
                        ? Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.inbox_rounded,
                                size: 48,
                                color: Colors.grey[800],
                              ),
                              const SizedBox(height: 12),
                              Text(
                                'Enter code to view files',
                                style: GoogleFonts.outfit(
                                  color: Colors.grey[600],
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        )
                        : LayoutBuilder(
                          builder: (context, constraints) {
                            return SingleChildScrollView(
                              padding: const EdgeInsets.all(16),
                              child: ConstrainedBox(
                                constraints: BoxConstraints(
                                  minHeight: constraints.maxHeight - 32,
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (_tasks.isNotEmpty) ...[
                                      _buildFileList(
                                        _tasks,
                                        isDownloadList: true,
                                      ),
                                    ],
                                    if (_downloadedFiles.isNotEmpty) ...[
                                      const SizedBox(height: 16),
                                      _buildSectionTitle('DOWNLOADED'),
                                      const SizedBox(height: 8),
                                      _buildFileList(
                                        _downloadedFiles,
                                        isDownloadList: false,
                                      ),
                                    ],
                                    const SizedBox(
                                      height: 80,
                                    ), // Space for button
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
              ),
              // Compact bottom action bar
              if (_tasks.any((t) => t.isSelected && t.status == 'Waiting'))
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1C1C1E),
                    border: Border(
                      top: BorderSide(color: Colors.white.withOpacity(0.05)),
                    ),
                  ),
                  child: SafeArea(
                    top: false,
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                '${_tasks.where((t) => t.isSelected).length} selected',
                                style: GoogleFonts.outfit(
                                  color: Colors.white,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              Text(
                                _formatBytes(
                                  _tasks
                                      .where((t) => t.isSelected)
                                      .fold<int>(
                                        0,
                                        (sum, t) => sum + t.fileSize,
                                      ),
                                ),
                                style: GoogleFonts.outfit(
                                  color: const Color(0xFFFFD600),
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                        ),
                        ElevatedButton(
                          onPressed: _downloading ? null : _startDownloads,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFFFFD600),
                            foregroundColor: Colors.black,
                            padding: const EdgeInsets.symmetric(
                              vertical: 10,
                              horizontal: 20,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                            elevation: 0,
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (_downloading)
                                const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    valueColor: AlwaysStoppedAnimation(
                                      Colors.black,
                                    ),
                                  ),
                                )
                              else
                                const Icon(Icons.download_rounded, size: 16),
                              const SizedBox(width: 6),
                              Text(
                                _downloading ? 'Downloading...' : 'Download',
                                style: GoogleFonts.outfit(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: const Color(0xFF1C1C1E),
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white.withOpacity(0.05)),
            ),
            child: IconButton(
              icon: const Icon(
                Icons.arrow_back_ios_new_rounded,
                color: Colors.white,
                size: 20,
              ),
              onPressed: () => context.navigateBack(),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Text(
              'Receive Files',
              style: GoogleFonts.outfit(
                color: Colors.white,
                fontSize: 28,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.5,
              ),
            ),
          ),
          IconButton(
            onPressed: _showLinkDialog,
            icon: Icon(Icons.link_rounded, color: const Color(0xFFFFD600)),
            tooltip: 'Download from Link',
          ),
        ],
      ),
    );
  }

  Widget _buildCodeInput() {
    final codeLength = _codeController.text.length;
    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;
    final isTV = MediaQuery.of(context).size.width > 1000;
    final isCompact = isLandscape || isTV;

    // Responsive sizing for code boxes
    final boxWidth = isCompact ? 20.0 : 24.0;
    final boxHeight = isCompact ? 40.0 : 48.0;
    final boxGap = isCompact ? 2.0 : 3.0;
    final extraGap = isCompact ? 4.0 : 6.0;
    final fontSize = isCompact ? 18.0 : 22.0;
    final cardPadding = isCompact ? 12.0 : 20.0;

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
        SizedBox(height: isCompact ? 12 : 20),

        // Code Input Card
        Container(
          padding: EdgeInsets.all(cardPadding),
          decoration: BoxDecoration(
            color: const Color(0xFF1C1C1E),
            borderRadius: BorderRadius.circular(isCompact ? 16 : 24),
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
                  Row(
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
                          left:
                              index == 8
                                  ? extraGap
                                  : 0, // Extra space after IP code
                        ),
                        decoration: BoxDecoration(
                          color:
                              hasChar
                                  ? const Color(0xFFFFD600).withOpacity(0.1)
                                  : Colors.black.withOpacity(0.3),
                          borderRadius: BorderRadius.circular(
                            isCompact ? 8 : 12,
                          ),
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
                                    height: isCompact ? 16 : 20,
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
                              HapticFeedback.mediumImpact();
                              FocusScope.of(context).unfocus();
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
                            'Connect',
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

        const SizedBox(height: 24),

        // Scan for Nearby Senders Button
        SizedBox(
          width: double.infinity,
          child: TextButton.icon(
            onPressed: () {
              FocusScope.of(context).unfocus();
              _scanForSenders();
            },
            icon: const Icon(
              Icons.wifi_tethering_rounded,
              color: Colors.white70,
            ),
            label: Text(
              'Scan for Nearby Senders',
              style: GoogleFonts.outfit(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
              backgroundColor: const Color(0xFF1C1C1E),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: BorderSide(color: Colors.white.withOpacity(0.1)),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildRecentCodes() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.history_rounded, color: Colors.grey[600], size: 16),
            const SizedBox(width: 8),
            Text(
              'RECENT CODES',
              style: GoogleFonts.outfit(
                color: Colors.grey[500],
                fontSize: 13,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.2,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children:
              _recentCodes.map((code) {
                return GestureDetector(
                  onTap: () {
                    HapticFeedback.selectionClick();
                    _codeController.text = code;
                    setState(() {});
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1C1C1E),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.white.withOpacity(0.1)),
                    ),
                    child: Text(
                      code,
                      style: GoogleFonts.outfit(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 2,
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
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF1C1C1E),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withOpacity(0.05)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFD600).withOpacity(0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  Icons.folder_rounded,
                  color: const Color(0xFFFFD600),
                  size: 24,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'SAVE LOCATION',
                      style: GoogleFonts.outfit(
                        color: Colors.grey[500],
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.2,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _saveFolder ?? 'Default (Downloads/ZapShare)',
                      style: GoogleFonts.outfit(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _pickCustomFolder,
              icon: Icon(
                Icons.create_new_folder_rounded,
                color: const Color(0xFFFFD600),
                size: 20,
              ),
              label: Text(
                'Change Location',
                style: GoogleFonts.outfit(
                  color: const Color(0xFFFFD600),
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              style: OutlinedButton.styleFrom(
                side: BorderSide(
                  color: const Color(0xFFFFD600).withOpacity(0.3),
                ),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Text(
      title,
      style: GoogleFonts.outfit(
        color: Colors.grey[500],
        fontSize: 12,
        fontWeight: FontWeight.w700,
        letterSpacing: 1.2,
      ),
    );
  }

  Widget _buildFileList(
    List<DownloadTask> files, {
    required bool isDownloadList,
  }) {
    return ListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: files.length,
      itemBuilder: (context, index) {
        final file = files[index];
        final fileType = _getFileType(file.fileName);
        return Container(
          margin: const EdgeInsets.only(bottom: 12),
          decoration: BoxDecoration(
            color: const Color(0xFF1C1C1E),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: Colors.white.withOpacity(0.05)),
          ),
          child: Column(
            children: [
              ListTile(
                contentPadding: const EdgeInsets.all(16),
                leading: Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    color: _getFileTypeColor(fileType).withOpacity(0.1),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Icon(
                    _getFileTypeIcon(fileType),
                    color: _getFileTypeColor(fileType),
                    size: 28,
                  ),
                ),
                title: Text(
                  file.fileName,
                  style: GoogleFonts.outfit(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 6),
                    if (file.status == 'Downloading') ...[
                      Row(
                        children: [
                          Text(
                            '${(file.progress * 100).toInt()}%',
                            style: GoogleFonts.outfit(
                              color: const Color(0xFFFFD600),
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          Text(
                            ' • ${file.speedMbps.toStringAsFixed(2)} Mbps',
                            style: GoogleFonts.outfit(
                              color: Colors.grey[500],
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${_formatBytes(file.bytesReceived)} / ${_formatBytes(file.fileSize)}',
                        style: GoogleFonts.outfit(
                          color: Colors.grey[500],
                          fontSize: 13,
                        ),
                      ),
                    ] else ...[
                      Text(
                        _formatBytes(file.fileSize),
                        style: GoogleFonts.outfit(
                          color: Colors.grey[500],
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ],
                ),
                trailing:
                    isDownloadList
                        ? Container(
                          width: 24,
                          height: 24,
                          decoration: BoxDecoration(
                            color:
                                file.isSelected
                                    ? const Color(0xFFFFD600)
                                    : Colors.transparent,
                            border: Border.all(
                              color:
                                  file.isSelected
                                      ? const Color(0xFFFFD600)
                                      : Colors.grey[600]!,
                              width: 2,
                            ),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child:
                              file.isSelected
                                  ? const Icon(
                                    Icons.check,
                                    color: Colors.black,
                                    size: 16,
                                  )
                                  : null,
                        )
                        : IconButton(
                          icon: Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: const Color(0xFFFFD600).withOpacity(0.1),
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(
                              Icons.open_in_new_rounded,
                              color: Color(0xFFFFD600),
                              size: 20,
                            ),
                          ),
                          onPressed: () => _openFile(file),
                        ),
                onTap:
                    isDownloadList
                        ? () {
                          setState(() {
                            file.isSelected = !file.isSelected;
                          });
                          HapticFeedback.selectionClick();
                        }
                        : null,
              ),
              if (file.status == 'Downloading')
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: LinearProgressIndicator(
                      value: file.progress,
                      backgroundColor: Colors.white.withOpacity(0.05),
                      valueColor: AlwaysStoppedAnimation(
                        const Color(0xFFFFD600),
                      ),
                      minHeight: 8,
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  IconData _getFileTypeIcon(FileType type) {
    switch (type) {
      case FileType.image:
        return Icons.image_rounded;
      case FileType.video:
        return Icons.videocam_rounded;
      case FileType.audio:
        return Icons.audiotrack_rounded;
      case FileType.pdf:
        return Icons.picture_as_pdf_rounded;
      case FileType.document:
        return Icons.description_rounded;
      case FileType.spreadsheet:
        return Icons.table_chart_rounded;
      case FileType.presentation:
        return Icons.slideshow_rounded;
      case FileType.archive:
        return Icons.folder_zip_rounded;
      case FileType.apk:
        return Icons.android_rounded;
      case FileType.text:
        return Icons.text_snippet_rounded;
      default:
        return Icons.insert_drive_file_rounded;
    }
  }

  Color _getFileTypeColor(FileType type) {
    switch (type) {
      case FileType.image:
        return Colors.purple;
      case FileType.video:
        return Colors.red;
      case FileType.audio:
        return Colors.orange;
      case FileType.pdf:
        return Colors.redAccent;
      case FileType.document:
        return Colors.blue;
      case FileType.spreadsheet:
        return Colors.green;
      case FileType.presentation:
        return Colors.deepOrange;
      case FileType.archive:
        return Colors.amber;
      case FileType.apk:
        return Colors.lightGreen;
      case FileType.text:
        return Colors.cyan;
      default:
        return Colors.grey;
    }
  }

  Widget _buildBottomAction() {
    final selectedCount = _tasks.where((t) => t.isSelected).length;
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: const Color(0xFF1C1C1E),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(32)),
        border: Border(top: BorderSide(color: Colors.white.withOpacity(0.05))),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.3),
            blurRadius: 20,
            offset: const Offset(0, -5),
          ),
        ],
      ),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '$selectedCount file${selectedCount != 1 ? 's' : ''} selected',
                  style: GoogleFonts.outfit(
                    color: Colors.grey[400],
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                Text(
                  _formatBytes(
                    _tasks
                        .where((t) => t.isSelected)
                        .fold(0, (sum, t) => sum + t.fileSize),
                  ),
                  style: GoogleFonts.outfit(
                    color: const Color(0xFFFFD600),
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _startDownloads,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFFFD600),
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(vertical: 18),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20),
                  ),
                  elevation: 0,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.download_rounded, size: 22),
                    const SizedBox(width: 8),
                    Text(
                      'Download Selected',
                      style: GoogleFonts.outfit(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
