import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'dart:io';
import 'dart:async';
import 'dart:math';
import 'dart:ui' as ui;
import 'package:path_provider/path_provider.dart';
import 'package:open_file/open_file.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'dart:convert';
import '../../widgets/tv_widgets.dart';
import 'AndroidHomeScreen.dart';

// ─────────────────────────────────────────────────────────
//  Models
// ─────────────────────────────────────────────────────────

class FileItem {
  final String name;
  final int size;
  final String url;
  bool isSelected;
  double progress;
  String status;
  int bytesReceived;
  String? savePath;
  double speedMbps;
  bool isPaused;
  bool isCancelled;

  FileItem({
    required this.name,
    required this.size,
    required this.url,
    this.isSelected = true,
    this.progress = 0.0,
    this.status = 'Waiting',
    this.bytesReceived = 0,
    this.savePath,
    this.speedMbps = 0.0,
    this.isPaused = false,
    this.isCancelled = false,
  });
}

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

// ─────────────────────────────────────────────────────────
//  Main Screen
// ─────────────────────────────────────────────────────────

class AndroidFileListScreen extends StatefulWidget {
  final String serverIp;
  final int serverPort;
  final List<Map<String, dynamic>> files;
  final bool useTcp;

  const AndroidFileListScreen({
    super.key,
    required this.serverIp,
    required this.serverPort,
    required this.files,
    this.useTcp = false,
  });

  @override
  State<AndroidFileListScreen> createState() => _AndroidFileListScreenState();
}

class _AndroidFileListScreenState extends State<AndroidFileListScreen>
    with TickerProviderStateMixin {
  List<FileItem> _fileItems = [];
  List<FileItem> _downloadQueue = [];
  String? _saveFolder;
  bool _downloading = false;
  final FlutterLocalNotificationsPlugin _notificationsPlugin =
      FlutterLocalNotificationsPlugin();

  // Animation controllers
  late AnimationController _pulseController;
  int? _tappedSectorIndex;

  // Sector colors — vibrant, distinct for each sector
  static const List<Color> _sectorColors = [
    Color(0xFFFFD600), // Yellow (primary)
    Color(0xFF00E5FF), // Cyan
    Color(0xFFFF6D00), // Orange
    Color(0xFF76FF03), // Lime
    Color(0xFFE040FB), // Purple
    Color(0xFF00E676), // Green
    Color(0xFFFF4081), // Pink
    Color(0xFFFFAB00), // Amber
    Color(0xFF448AFF), // Blue
    Color(0xFFFF3D00), // Red-Orange
    Color(0xFF18FFFF), // Light Cyan
    Color(0xFFEEFF41), // Lemon
  ];

  @override
  void initState() {
    super.initState();
    _initializeFiles();
    _initLocalNotifications();
    _loadSaveFolder();

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  void _initializeFiles() {
    _fileItems = widget.files
        .map(
          (f) => FileItem(
            name: f['name'] ?? 'Unknown File',
            size: f['size'] ?? 0,
            url:
                'http://${widget.serverIp}:${widget.serverPort}/file/${f['index']}',
          ),
        )
        .toList();
  }

  // ─────────────────────────────────────────────────────────
  //  Utilities
  // ─────────────────────────────────────────────────────────

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

  Color _getSectorColor(int index) {
    return _sectorColors[index % _sectorColors.length];
  }

  // File-type-specific colors for clear visual identification
  static const Map<FileType, Color> _fileTypeColors = {
    FileType.image: Color(0xFFFF6B6B),       // Coral
    FileType.video: Color(0xFFB388FF),       // Light Purple
    FileType.audio: Color(0xFF4DD0E1),       // Teal
    FileType.pdf: Color(0xFFFF5252),         // Red
    FileType.document: Color(0xFF64B5F6),    // Blue
    FileType.spreadsheet: Color(0xFF69F0AE), // Green
    FileType.presentation: Color(0xFFFFB74D),// Orange
    FileType.archive: Color(0xFFFFD740),     // Amber
    FileType.apk: Color(0xFF76FF03),         // Lime
    FileType.text: Color(0xFF80DEEA),        // Cyan
    FileType.other: Color(0xFF90A4AE),       // Blue Grey
  };

  Color _getFileTypeColor(String fileName) {
    final type = _getFileType(fileName);
    return _fileTypeColors[type] ?? const Color(0xFF90A4AE);
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return "$bytes B";
    if (bytes < 1024 * 1024) return "${(bytes / 1024).toStringAsFixed(1)} KB";
    if (bytes < 1024 * 1024 * 1024)
      return "${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB";
    return "${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB";
  }

  // ─────────────────────────────────────────────────────────
  //  Notifications, Permissions, Storage
  // ─────────────────────────────────────────────────────────

  Future<void> _initLocalNotifications() async {
    const AndroidInitializationSettings androidSettings =
        AndroidInitializationSettings('ic_stat_notify');
    final InitializationSettings initSettings = InitializationSettings(
      android: androidSettings,
    );
    await _notificationsPlugin.initialize(initSettings);
  }

  Future<void> _loadSaveFolder() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final customFolder = prefs.getString('custom_save_folder');
      if (customFolder != null && customFolder.isNotEmpty) {
        setState(() => _saveFolder = customFolder);
      } else {
        _saveFolder = await _getDefaultDownloadFolder();
      }
    } catch (e) {
      _saveFolder = await _getDefaultDownloadFolder();
    }
  }

  Future<String> _getDefaultDownloadFolder() async {
    try {
      final downloadsCandidate =
          Directory('/storage/emulated/0/Download/ZapShare');
      if (Platform.isAndroid) {
        try {
          if (!await downloadsCandidate.exists()) {
            await downloadsCandidate.create(recursive: true);
          }
          return downloadsCandidate.path;
        } catch (_) {}
      }
      final downloadsDir = await getDownloadsDirectory();
      if (downloadsDir != null) {
        final zapDir = Directory('${downloadsDir.path}/ZapShare');
        if (!await zapDir.exists()) await zapDir.create(recursive: true);
        return zapDir.path;
      }
      return '/storage/emulated/0/Download/ZapShare';
    } catch (e) {
      return '/storage/emulated/0/Download/ZapShare';
    }
  }

  Future<void> _pickCustomFolder() async {
    try {
      String? selectedDirectory = await FilePicker.platform.getDirectoryPath();
      if (selectedDirectory != null) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('custom_save_folder', selectedDirectory);
        setState(() => _saveFolder = selectedDirectory);
        HapticFeedback.mediumImpact();
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

  Future<void> showProgressNotification(
    int fileIndex,
    double progress,
    String fileName, {
    double speedMbps = 0.0,
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
    final platformChannelSpecifics =
        NotificationDetails(android: androidPlatformChannelSpecifics);
    await _notificationsPlugin.show(
      2000 + fileIndex,
      'ZapShare Download',
      body,
      platformChannelSpecifics,
      payload: 'download_progress',
    );
  }

  Future<void> cancelProgressNotification(int fileIndex) async {
    await _notificationsPlugin.cancel(2000 + fileIndex);
  }

  Future<void> _addToHistory({
    required String fileName,
    required int fileSize,
    required String path,
    required String peerIp,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final historyList = prefs.getStringList('transfer_history') ?? [];
      final entry = {
        'fileName': fileName,
        'fileSize': fileSize,
        'direction': 'Received',
        'peer': peerIp,
        'peerDeviceName': 'Device ($peerIp)',
        'dateTime': DateTime.now().toIso8601String(),
        'fileLocation': path,
      };
      historyList.add(jsonEncode(entry));
      await prefs.setStringList('transfer_history', historyList);
    } catch (e) {
      print('Error saving history: $e');
    }
  }

  Future<void> _deletePartialFile(String? path) async {
    if (path == null) return;
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (e) {
      print("Error deleting partial file: $e");
    }
  }

  // ─────────────────────────────────────────────────────────
  //  Download Engine (HTTP + TCP) — unchanged from original
  // ─────────────────────────────────────────────────────────

  Future<void> _startDownloads() async {
    final selectedFiles = _fileItems
        .where((f) => f.isSelected && f.status != 'Complete')
        .toList();
    if (selectedFiles.isEmpty) return;

    for (var file in selectedFiles) {
      file.status = 'Waiting';
      file.progress = 0.0;
      file.isCancelled = false;
      file.isPaused = false;
    }

    setState(() {
      _downloadQueue = List.from(selectedFiles);
      _downloading = true;
    });

    await FlutterForegroundTask.startService(
      notificationTitle: "ZapShare Download",
      notificationText: "Starting multi-file download...",
      notificationIcon: const NotificationIcon(
        metaDataName: 'com.pravera.flutter_foreground_task.notification_icon',
      ),
    );

    try {
      while (_downloadQueue.isNotEmpty) {
        final file = _downloadQueue.first;
        if (file.isCancelled) {
          _downloadQueue.remove(file);
          continue;
        }
        await FlutterForegroundTask.updateService(
          notificationTitle: "Downloading: ${file.name}",
          notificationText: "${_downloadQueue.length} files remaining",
        );
        await _downloadFile(file);
        if (mounted) {
          setState(() => _downloadQueue.remove(file));
        } else {
          _downloadQueue.remove(file);
        }
      }
    } finally {
      try {
        await FlutterForegroundTask.stopService();
      } catch (e) {
        print('Note: Foreground service stop: $e');
      }
      if (mounted) setState(() => _downloading = false);
    }
  }

  Future<void> _downloadFile(FileItem file) async {
    if (file.isCancelled) return;

    setState(() {
      file.status = 'Downloading';
      file.isPaused = false;
    });

    try {
      await _requestStoragePermissions();
      _saveFolder ??= await _getDefaultDownloadFolder();

      String fileName = file.name.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');
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

      file.savePath = savePath;
      final fileToWrite = File(savePath);
      final sink = fileToWrite.openWrite();

      late Stream<List<int>> contentStream;
      int contentLength = file.size;
      http.Client? httpClient;
      Socket? tcpSocket;

      if (widget.useTcp) {
        const maxRetries = 5;
        for (int retry = 0; retry < maxRetries; retry++) {
          try {
            final uri = Uri.parse(file.url);
            final fileIndex = int.parse(uri.pathSegments.last);
            tcpSocket = await Socket.connect(
              widget.serverIp,
              widget.serverPort + 1,
              timeout: const Duration(seconds: 10),
            );
            final indexBytes = [
              (fileIndex >> 24) & 0xFF,
              (fileIndex >> 16) & 0xFF,
              (fileIndex >> 8) & 0xFF,
              fileIndex & 0xFF,
            ];
            tcpSocket.add(indexBytes);
            await tcpSocket.flush();

            final controller = StreamController<List<int>>();
            final metadataBytes = <int>[];
            int? metadataLength;
            bool metadataComplete = false;

            tcpSocket.listen(
              (chunk) {
                if (!metadataComplete) {
                  metadataBytes.addAll(chunk);
                  if (metadataLength == null && metadataBytes.length >= 4) {
                    metadataLength = (metadataBytes[0] << 24) |
                        (metadataBytes[1] << 16) |
                        (metadataBytes[2] << 8) |
                        metadataBytes[3];
                  }
                  if (metadataLength != null &&
                      metadataBytes.length >= 4 + metadataLength!) {
                    final metadataJson = utf8.decode(
                      metadataBytes.sublist(4, 4 + metadataLength!),
                    );
                    final metadata = jsonDecode(metadataJson);
                    contentLength = metadata['fileSize'] as int;
                    metadataComplete = true;
                    if (metadataBytes.length > 4 + metadataLength!) {
                      controller
                          .add(metadataBytes.sublist(4 + metadataLength!));
                    }
                  }
                } else {
                  controller.add(chunk);
                }
              },
              onError: (error) {
                print('TCP socket error during download: $error');
                // Don't propagate error to stream — just close gracefully
                // Buffered data will still be delivered before the done event
                if (!controller.isClosed) {
                  controller.close();
                }
              },
              onDone: () {
                if (!controller.isClosed) {
                  controller.close();
                }
              },
              cancelOnError: false,
            );
            contentStream = controller.stream;
            break;
          } catch (e) {
            tcpSocket?.destroy();
            tcpSocket = null;
            if (retry < maxRetries - 1) {
              await Future.delayed(Duration(seconds: 2 * (retry + 1)));
            } else {
              rethrow;
            }
          }
        }
      } else {
        const maxRetries = 3;
        for (int retry = 0; retry < maxRetries; retry++) {
          try {
            httpClient = http.Client();
            final request = http.Request('GET', Uri.parse(file.url));
            request.headers['Connection'] = 'close';
            final response = await httpClient.send(request).timeout(
                  Duration(minutes: 60),
                  onTimeout: () =>
                      throw TimeoutException('Download timed out'),
                );
            if (response.statusCode != 200) {
              throw Exception('Server returned ${response.statusCode}');
            }
            contentLength = response.contentLength ?? file.size;
            contentStream = response.stream;
            break;
          } catch (e) {
            httpClient?.close();
            httpClient = null;
            if (retry < maxRetries - 1) {
              await Future.delayed(Duration(seconds: 2 * (retry + 1)));
            } else {
              rethrow;
            }
          }
        }
      }

      int received = 0;
      DateTime lastUpdate = DateTime.now();
      double lastProgress = 0.0;
      int lastBytes = 0;
      DateTime lastSpeedTime = DateTime.now();
      bool downloadSuccess = false;

      try {
        await for (var chunk in contentStream) {
          sink.add(chunk);
          received += chunk.length;
          file.bytesReceived = received;

          double progress = contentLength > 0 ? received / contentLength : 0.0;
          if (progress > 1.0) progress = 1.0;
          file.progress = progress;

          final now = DateTime.now();
          final elapsed = now.difference(lastSpeedTime).inMilliseconds;
          if (elapsed > 0) {
            final bytesDelta = received - lastBytes;
            file.speedMbps = (bytesDelta * 8) / (elapsed * 1000);
            lastBytes = received;
            lastSpeedTime = now;
          }

          if (now.difference(lastUpdate).inMilliseconds > 100 ||
              (progress - lastProgress) > 0.01) {
            setState(() {});
            await showProgressNotification(
              _fileItems.indexOf(file),
              progress,
              fileName,
              speedMbps: file.speedMbps,
            );
            lastUpdate = now;
            lastProgress = progress;
          }

          while (file.isPaused) {
            if (file.isCancelled) break;
            await Future.delayed(const Duration(milliseconds: 500));
            if (file.speedMbps != 0) {
              setState(() => file.speedMbps = 0.0);
            }
          }
          if (file.isCancelled) throw Exception('Cancelled by user');
          if (contentLength > 0 && received >= contentLength) {
            downloadSuccess = true;
            break;
          }
        }
        // Stream ended — check if we received enough data
        if (!downloadSuccess && contentLength > 0) {
          if (received >= contentLength) {
            downloadSuccess = true;
          } else if (received >= (contentLength * 0.98).floor() && received > 0) {
            // TCP may deliver slightly fewer bytes than reported size
            downloadSuccess = true;
            print('Note: Received $received of $contentLength bytes (${(received * 100.0 / contentLength).toStringAsFixed(1)}%) — marking as complete');
          }
        }
      } catch (e) {
        // Even on error, check if we got enough data to consider it complete
        if (contentLength > 0 && received >= contentLength) {
          downloadSuccess = true;
        } else if (contentLength > 0 &&
            received >= (contentLength * 0.95).floor() && received > 0) {
          downloadSuccess = true;
          print('Note: Error during download but received $received of $contentLength bytes — marking as complete');
        } else {
          rethrow;
        }
      } finally {
        try {
          await sink.flush();
          await sink.close();
        } catch (e) {
          print('Note: File close error: $e');
        }
        if (downloadSuccess && widget.useTcp && tcpSocket != null) {
          try {
            tcpSocket.write('ACK\n');
            await tcpSocket.flush();
            await Future.delayed(const Duration(milliseconds: 50));
          } catch (e) {
            print('Note: ACK send error: $e');
          }
        }
        httpClient?.close();
        tcpSocket?.destroy();
        await cancelProgressNotification(_fileItems.indexOf(file));
      }

      if (downloadSuccess) {
        await _addToHistory(
          fileName: file.name,
          fileSize: file.size,
          path: savePath,
          peerIp: widget.serverIp,
        );
        setState(() {
          file.status = 'Complete';
          file.progress = 1.0;
        });
      } else {
        throw Exception('Download incomplete');
      }
    } catch (e) {
      setState(() {
        if (e.toString().contains('Cancelled')) {
          file.status = 'Cancelled';
          _deletePartialFile(file.savePath);
        } else {
          file.status = 'Error: $e';
        }
        file.progress = 0.0;
      });
    }
  }

  // ═══════════════════════════════════════════════════════════
  //   UI
  // ═══════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    final selectedCount = _fileItems.where((f) => f.isSelected).length;
    final totalSize = _fileItems
        .where((f) => f.isSelected)
        .fold<int>(0, (sum, f) => sum + f.size);

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: const Color(0xFF0C0C0E),
        body: SafeArea(
          child: Column(
            children: [
              _buildHeader(),
              Expanded(
                child: SingleChildScrollView(
                  physics: const BouncingScrollPhysics(),
                  child: Column(
                    children: [
                      const SizedBox(height: 12),
                      _buildPieChart(),
                      const SizedBox(height: 20),
                      _buildSaveLocationCard(),
                      const SizedBox(height: 16),
                      _buildFileDetailsList(),
                      const SizedBox(height: 100),
                    ],
                  ),
                ),
              ),
              if (selectedCount > 0)
                _buildBottomAction(selectedCount, totalSize),
            ],
          ),
        ),
      ),
    );
  }

  // ───── Header ─────

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
      child: Row(
        children: [
          GestureDetector(
            onTap: () {
              Navigator.pushAndRemoveUntil(
                context,
                MaterialPageRoute(
                    builder: (context) => const AndroidHomeScreen()),
                (route) => false,
              );
            },
            child: Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: const Color(0xFF1C1C1E),
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white.withOpacity(0.06)),
              ),
              child: const Icon(Icons.arrow_back_ios_new_rounded,
                  color: Colors.white, size: 18),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Incoming Files',
                  style: GoogleFonts.outfit(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.5),
                ),
                const SizedBox(height: 2),
                Text(
                  '${_fileItems.length} files available',
                  style:
                      GoogleFonts.outfit(color: Colors.grey[600], fontSize: 13),
                ),
              ],
            ),
          ),
          // Protocol badge
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: widget.useTcp
                  ? Colors.green.withOpacity(0.15)
                  : Colors.blue.withOpacity(0.15),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                  color: (widget.useTcp ? Colors.green : Colors.blue)
                      .withOpacity(0.4)),
            ),
            child: Text(
              widget.useTcp ? 'TCP' : 'HTTP',
              style: GoogleFonts.outfit(
                  color: widget.useTcp ? Colors.green : Colors.blue,
                  fontSize: 11,
                  fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(width: 8),
          // Select all / deselect
          GestureDetector(
            onTap: () {
              HapticFeedback.selectionClick();
              final allSelected = _fileItems.every((f) => f.isSelected);
              setState(() {
                for (var f in _fileItems) {
                  if (f.status != 'Complete' && f.status != 'Downloading') {
                    f.isSelected = !allSelected;
                  }
                }
              });
            },
            child: Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: const Color(0xFF1C1C1E),
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white.withOpacity(0.06)),
              ),
              child: Icon(
                _fileItems.every((f) => f.isSelected)
                    ? Icons.deselect_rounded
                    : Icons.select_all_rounded,
                color: const Color(0xFFFFD600),
                size: 20,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────────────────
  //  Pie Chart Widget
  // ─────────────────────────────────────────────────────────

  Widget _buildPieChart() {
    final screenWidth = MediaQuery.of(context).size.width;
    final chartSize = (screenWidth * 0.72).clamp(240.0, 360.0);

    // Overall progress for centre display
    final selectedFiles = _fileItems.where((f) => f.isSelected).toList();
    final totalProgress = selectedFiles.isEmpty
        ? 0.0
        : selectedFiles.fold<double>(0.0, (sum, f) => sum + f.progress) /
            selectedFiles.length;
    final completedCount =
        _fileItems.where((f) => f.status == 'Complete').length;

    return GestureDetector(
      onTapUp: (details) => _handleChartTap(details.localPosition, chartSize),
      child: SizedBox(
        width: chartSize,
        height: chartSize,
        child: AnimatedBuilder(
          animation: _pulseController,
          builder: (context, _) {
            return CustomPaint(
              painter: _PieChartPainter(
                files: _fileItems,
                sectorColors: _fileItems.map((f) => _getFileTypeColor(f.name)).toList(),
                tappedIndex: _tappedSectorIndex,
                pulseValue: _pulseController.value,
              ),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Centre number
                    Text(
                      _downloading
                          ? '${(totalProgress * 100).toInt()}%'
                          : '$completedCount/${_fileItems.length}',
                      style: GoogleFonts.outfit(
                        color: Colors.white,
                        fontSize: _downloading ? 38 : 34,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -1.5,
                        height: 1.1,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _downloading
                          ? 'downloading'
                          : (completedCount == _fileItems.length &&
                                  _fileItems.isNotEmpty
                              ? 'complete!'
                              : 'selected'),
                      style: GoogleFonts.outfit(
                        color: _downloading
                            ? const Color(0xFFFFD600)
                            : Colors.grey[500],
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    if (_downloading) ...[
                      const SizedBox(height: 4),
                      // Current file indicator
                      Builder(builder: (_) {
                        final current = _fileItems
                            .where((f) => f.status == 'Downloading')
                            .toList();
                        if (current.isEmpty) return const SizedBox.shrink();
                        return Text(
                          current.first.name.length > 18
                              ? '${current.first.name.substring(0, 15)}...'
                              : current.first.name,
                          style: GoogleFonts.outfit(
                            color: Colors.grey[600],
                            fontSize: 10,
                          ),
                        );
                      }),
                    ],
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  void _handleChartTap(Offset position, double chartSize) {
    if (_downloading) return;

    final center = Offset(chartSize / 2, chartSize / 2);
    final dx = position.dx - center.dx;
    final dy = position.dy - center.dy;
    final distance = sqrt(dx * dx + dy * dy);
    final outerRadius = chartSize / 2;
    final innerRadius = outerRadius * 0.42;

    if (distance < innerRadius || distance > outerRadius) return;

    // Angle from top, clockwise
    double angle = atan2(dx, -dy);
    if (angle < 0) angle += 2 * pi;

    final total = _fileItems.length;
    if (total == 0) return;

    final gapAngle = total > 1 ? 0.04 : 0.0;
    final sectorAngle = (2 * pi - gapAngle * total) / total;

    // Walk through sectors to find which was tapped
    double cumAngle = 0;
    int tappedIndex = -1;
    for (int i = 0; i < total; i++) {
      if (angle >= cumAngle && angle < cumAngle + sectorAngle) {
        tappedIndex = i;
        break;
      }
      cumAngle += sectorAngle + gapAngle;
    }
    if (tappedIndex < 0) tappedIndex = total - 1; // edge case

    HapticFeedback.selectionClick();

    setState(() {
      final file = _fileItems[tappedIndex];
      if (file.status != 'Complete' && file.status != 'Downloading') {
        file.isSelected = !file.isSelected;
      }
      _tappedSectorIndex = tappedIndex;
    });

    Future.delayed(const Duration(milliseconds: 500), () {
      if (mounted) setState(() => _tappedSectorIndex = null);
    });
  }

  // ─────────────────────────────────────────────────────────
  //  File Details List (compact rows below chart)
  // ─────────────────────────────────────────────────────────

  Widget _buildFileDetailsList() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 10),
            child: Text(
              'TAP SECTORS OR ROWS TO SELECT',
              style: GoogleFonts.outfit(
                color: Colors.grey[700],
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.2,
              ),
            ),
          ),
          ...List.generate(_fileItems.length, (i) => _buildFileRow(i)),
        ],
      ),
    );
  }

  Widget _buildFileRow(int index) {
    final file = _fileItems[index];
    final color = _getFileTypeColor(file.name);
    final fileType = _getFileType(file.name);
    final isDownloading = file.status == 'Downloading';
    final isComplete = file.status == 'Complete';
    final isError = file.status.startsWith('Error');

    return GestureDetector(
      onTap: () {
        if (!_downloading && !isComplete) {
          HapticFeedback.selectionClick();
          setState(() => file.isSelected = !file.isSelected);
        }
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: isDownloading
              ? color.withOpacity(0.06)
              : (file.isSelected
                  ? const Color(0xFF1A1A1C)
                  : const Color(0xFF111113)),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isComplete
                ? Colors.green.withOpacity(0.3)
                : (file.isSelected
                    ? color.withOpacity(0.35)
                    : Colors.white.withOpacity(0.04)),
            width: file.isSelected || isComplete ? 1.2 : 0.8,
          ),
        ),
        child: Row(
          children: [
            // ── Colour dot (file type) ──
            Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                color: isComplete ? Colors.green : color,
                shape: BoxShape.circle,
                border: Border.all(
                  color: (isComplete ? Colors.green : color).withOpacity(0.5),
                  width: 1.5,
                ),
                boxShadow: [
                  BoxShadow(
                    color:
                        (isComplete ? Colors.green : color).withOpacity(0.3),
                    blurRadius: 8,
                    spreadRadius: 2,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            // ── File icon (with fill during download) ──
            SizedBox(
              width: 40,
              height: 40,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Stack(
                  children: [
                    Container(
                      decoration: BoxDecoration(
                        color: (isComplete ? Colors.green : color)
                            .withOpacity(0.12),
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    if (isDownloading)
                      Align(
                        alignment: Alignment.bottomCenter,
                        child: Container(
                          width: 40,
                          height: 40 * file.progress,
                          color: color.withOpacity(0.35),
                        ),
                      ),
                    Center(
                      child: Icon(
                        isComplete
                            ? Icons.check_rounded
                            : _getFileTypeIcon(fileType),
                        color: isComplete ? Colors.green : color,
                        size: 20,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 12),
            // ── Name + status ──
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    file.name,
                    style: GoogleFonts.outfit(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 3),
                  if (isDownloading)
                    Row(
                      children: [
                        Text(
                          '${(file.progress * 100).toInt()}%',
                          style: GoogleFonts.outfit(
                              color: color,
                              fontSize: 12,
                              fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          '${file.speedMbps.toStringAsFixed(1)} Mbps',
                          style: GoogleFonts.outfit(
                              color: Colors.grey[500], fontSize: 11),
                        ),
                      ],
                    )
                  else if (isComplete)
                    Text('Complete',
                        style: GoogleFonts.outfit(
                            color: Colors.green,
                            fontSize: 12,
                            fontWeight: FontWeight.w600))
                  else if (isError)
                    Text('Failed',
                        style: GoogleFonts.outfit(
                            color: Colors.red[400],
                            fontSize: 12,
                            fontWeight: FontWeight.w600))
                  else
                    Text(_formatBytes(file.size),
                        style: GoogleFonts.outfit(
                            color: Colors.grey[500], fontSize: 12)),
                ],
              ),
            ),
            // ── Actions ──
            if (isDownloading) ...[
              _miniIconButton(
                file.isPaused
                    ? Icons.play_arrow_rounded
                    : Icons.pause_rounded,
                Colors.white70,
                () => setState(() => file.isPaused = !file.isPaused),
              ),
              _miniIconButton(
                Icons.close_rounded,
                Colors.white54,
                () => file.isCancelled = true,
              ),
            ] else if (isComplete)
              _miniIconButton(
                Icons.open_in_new_rounded,
                Colors.green,
                () => OpenFile.open(file.savePath),
              )
            else
              AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  color: file.isSelected ? color : Colors.transparent,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: file.isSelected ? color : Colors.grey[700]!,
                    width: 1.5,
                  ),
                ),
                child: file.isSelected
                    ? const Icon(Icons.check, size: 14, color: Colors.black)
                    : null,
              ),
          ],
        ),
      ),
    );
  }

  Widget _miniIconButton(IconData icon, Color color, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Icon(icon, color: color, size: 22),
      ),
    );
  }

  // ───── Save Location ─────

  Widget _buildSaveLocationCard() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: const Color(0xFF1A1A1C),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white.withOpacity(0.05)),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(7),
              decoration: BoxDecoration(
                color: const Color(0xFFFFD600).withOpacity(0.12),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.folder_rounded,
                  color: Color(0xFFFFD600), size: 18),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('SAVE TO',
                      style: GoogleFonts.outfit(
                          color: Colors.grey[600],
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1.0)),
                  Text(
                    _saveFolder ?? 'Downloads/ZapShare',
                    style: GoogleFonts.outfit(
                        color: Colors.white70,
                        fontSize: 12,
                        fontWeight: FontWeight.w500),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            GestureDetector(
              onTap: _pickCustomFolder,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFD600).withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text('Change',
                    style: GoogleFonts.outfit(
                        color: const Color(0xFFFFD600),
                        fontSize: 11,
                        fontWeight: FontWeight.w600)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ───── Bottom Action Bar ─────

  Widget _buildBottomAction(int selectedCount, int totalSize) {
    final avgProgress = selectedCount > 0
        ? _fileItems
                .where((f) => f.isSelected)
                .fold<double>(0.0, (sum, f) => sum + f.progress) /
            selectedCount
        : 0.0;

    return Container(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
      decoration: BoxDecoration(
        color: const Color(0xFF141416),
        border:
            Border(top: BorderSide(color: Colors.white.withOpacity(0.05))),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_downloading) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: avgProgress,
                  backgroundColor: Colors.white.withOpacity(0.08),
                  valueColor: const AlwaysStoppedAnimation<Color>(
                      Color(0xFFFFD600)),
                  minHeight: 3,
                ),
              ),
              const SizedBox(height: 10),
            ],
            Row(
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('$selectedCount file${selectedCount == 1 ? '' : 's'}',
                        style: GoogleFonts.outfit(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w600)),
                    Text(_formatBytes(totalSize),
                        style: GoogleFonts.outfit(
                            color: const Color(0xFFFFD600),
                            fontSize: 12,
                            fontWeight: FontWeight.w600)),
                  ],
                ),
                const Spacer(),
                GestureDetector(
                  onTap: _downloading ? null : _startDownloads,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 28, vertical: 14),
                    decoration: BoxDecoration(
                      color: _downloading
                          ? Colors.grey[800]
                          : const Color(0xFFFFD600),
                      borderRadius: BorderRadius.circular(30),
                      boxShadow: _downloading
                          ? null
                          : [
                              BoxShadow(
                                color: const Color(0xFFFFD600)
                                    .withOpacity(0.25),
                                blurRadius: 16,
                                offset: const Offset(0, 4),
                              ),
                            ],
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _downloading
                              ? Icons.hourglass_top_rounded
                              : Icons.download_rounded,
                          size: 20,
                          color:
                              _downloading ? Colors.white54 : Colors.black,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          _downloading ? 'Downloading...' : 'Download',
                          style: GoogleFonts.outfit(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                              color: _downloading
                                  ? Colors.white54
                                  : Colors.black),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ═════════════════════════════════════════════════════════════
//  CUSTOM PIE CHART PAINTER
// ═════════════════════════════════════════════════════════════

class _PieChartPainter extends CustomPainter {
  final List<FileItem> files;
  final List<Color> sectorColors;
  final int? tappedIndex;
  final double pulseValue;

  _PieChartPainter({
    required this.files,
    required this.sectorColors,
    this.tappedIndex,
    required this.pulseValue,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (files.isEmpty) return;

    final center = Offset(size.width / 2, size.height / 2);
    final outerR = size.width / 2;
    final innerR = outerR * 0.44;
    final total = files.length;
    final gapAngle = total > 1 ? 0.04 : 0.0;
    final sectorAngle = (2 * pi - gapAngle * total) / total;

    double startAngle = -pi / 2; // top

    for (int i = 0; i < total; i++) {
      final file = files[i];
      final color = sectorColors[i % sectorColors.length];
      final sel = file.isSelected;
      final tapped = i == tappedIndex;
      final complete = file.status == 'Complete';
      final downloading = file.status == 'Downloading';

      // Pop-out on tap
      final pop = tapped ? 8.0 : 0.0;
      final midA = startAngle + sectorAngle / 2;
      final cx = center.dx + cos(midA) * pop;
      final cy = center.dy + sin(midA) * pop;
      final sc = Offset(cx, cy);

      // ── Background fill ──
      final bgPaint = Paint()
        ..color = sel
            ? color.withOpacity(tapped ? 0.28 : 0.13)
            : Colors.white.withOpacity(0.03)
        ..style = PaintingStyle.fill;
      _sector(canvas, sc, innerR, outerR, startAngle, sectorAngle, bgPaint);

      // ── Progress fill (sweeps clockwise) ──
      if (file.progress > 0 && sel) {
        final progressAngle = sectorAngle * file.progress;
        final pPaint = Paint()
          ..color = complete
              ? Colors.green.withOpacity(0.65)
              : color.withOpacity(0.50 + pulseValue * 0.18)
          ..style = PaintingStyle.fill;
        _sector(canvas, sc, innerR, outerR, startAngle, progressAngle, pPaint);
      }

      // ── Outer arc outline ──
      final arcPaint = Paint()
        ..color = sel
            ? color.withOpacity(tapped ? 0.95 : 0.55)
            : Colors.white.withOpacity(0.08)
        ..style = PaintingStyle.stroke
        ..strokeWidth = tapped ? 3.0 : 1.5
        ..strokeCap = StrokeCap.round;
      _arc(canvas, sc, outerR - 0.5, startAngle, sectorAngle, arcPaint);

      // ── Inner arc outline ──
      final innerArcPaint = Paint()
        ..color = sel
            ? color.withOpacity(0.20)
            : Colors.white.withOpacity(0.04)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.8
        ..strokeCap = StrokeCap.round;
      _arc(canvas, sc, innerR + 0.5, startAngle, sectorAngle, innerArcPaint);

      // ── Glow while downloading ──
      if (downloading && sel) {
        final glow = Paint()
          ..color = color.withOpacity(0.12 + pulseValue * 0.12)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 5
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8);
        _arc(canvas, sc, outerR + 3, startAngle,
            sectorAngle * file.progress, glow);
      }

      // ── Extension label inside sector ──
      final ext = _ext(file.name);
      if (sectorAngle > 0.20 && ext.isNotEmpty) {
        final labelR = (innerR + outerR) / 2;
        final lx = sc.dx + cos(midA) * labelR;
        final ly = sc.dy + sin(midA) * labelR;
        final tp = TextPainter(
          text: TextSpan(
            text: ext,
            style: TextStyle(
              color: sel
                  ? (file.progress > 0.5
                      ? Colors.black.withOpacity(0.8)
                      : color)
                  : Colors.white.withOpacity(0.2),
              fontSize: total <= 4
                  ? 13
                  : (total <= 8 ? 10 : 8),
              fontWeight: FontWeight.w800,
              fontFamily: 'monospace',
            ),
          ),
          textDirection: ui.TextDirection.ltr,
        )..layout();
        tp.paint(canvas, Offset(lx - tp.width / 2, ly - tp.height / 2));
      }

      startAngle += sectorAngle + gapAngle;
    }

    // ── Dark centre circle with subtle gradient ──
    final centerGradient = Paint()
      ..shader = ui.Gradient.radial(
        center,
        innerR,
        [const Color(0xFF161618), const Color(0xFF0C0C0E)],
        [0.0, 1.0],
      );
    canvas.drawCircle(center, innerR, centerGradient);
    // Outer ring
    canvas.drawCircle(
      center,
      innerR,
      Paint()
        ..color = Colors.white.withOpacity(0.09)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
    // Subtle inner ring
    canvas.drawCircle(
      center,
      innerR - 3,
      Paint()
        ..color = Colors.white.withOpacity(0.03)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.5,
    );
  }

  void _sector(Canvas c, Offset ctr, double iR, double oR, double start,
      double sweep, Paint p) {
    final path = Path()
      ..moveTo(ctr.dx + cos(start) * iR, ctr.dy + sin(start) * iR)
      ..lineTo(ctr.dx + cos(start) * oR, ctr.dy + sin(start) * oR)
      ..arcTo(Rect.fromCircle(center: ctr, radius: oR), start, sweep, false)
      ..lineTo(ctr.dx + cos(start + sweep) * iR,
          ctr.dy + sin(start + sweep) * iR)
      ..arcTo(
          Rect.fromCircle(center: ctr, radius: iR), start + sweep, -sweep, false)
      ..close();
    c.drawPath(path, p);
  }

  void _arc(Canvas c, Offset ctr, double r, double start, double sweep,
      Paint p) {
    c.drawArc(Rect.fromCircle(center: ctr, radius: r), start, sweep, false, p);
  }

  String _ext(String name) {
    final p = name.split('.');
    return p.length > 1 ? p.last.toUpperCase() : '';
  }

  @override
  bool shouldRepaint(covariant _PieChartPainter old) => true;
}
