import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'dart:io';
import 'dart:async';
import 'package:path_provider/path_provider.dart';
import 'package:open_file/open_file.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'dart:convert';
import '../../widgets/tv_widgets.dart';
import 'AndroidHomeScreen.dart';

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

class AndroidFileListScreen extends StatefulWidget {
  final String serverIp;
  final int serverPort;
  final List<Map<String, dynamic>> files;

  const AndroidFileListScreen({
    super.key,
    required this.serverIp,
    required this.serverPort,
    required this.files,
    this.useTcp = false,
  });

  final bool useTcp;

  @override
  State<AndroidFileListScreen> createState() => _AndroidFileListScreenState();
}

class _AndroidFileListScreenState extends State<AndroidFileListScreen> {
  List<FileItem> _fileItems = [];
  List<FileItem> _downloadQueue = []; // Queue for managing downloads
  String? _saveFolder;
  bool _downloading = false;
  final FlutterLocalNotificationsPlugin _notificationsPlugin =
      FlutterLocalNotificationsPlugin();

  @override
  void initState() {
    super.initState();
    _initializeFiles();
    _initLocalNotifications();
    _loadSaveFolder();
  }

  void _initializeFiles() {
    _fileItems =
        widget.files
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
        setState(() {
          _saveFolder = customFolder;
        });
      } else {
        _saveFolder = await _getDefaultDownloadFolder();
      }
    } catch (e) {
      _saveFolder = await _getDefaultDownloadFolder();
    }
  }

  Future<String> _getDefaultDownloadFolder() async {
    try {
      final downloadsCandidate = Directory(
        '/storage/emulated/0/Download/ZapShare',
      );
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
        if (!await zapDir.exists()) {
          await zapDir.create(recursive: true);
        }
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
        setState(() {
          _saveFolder = selectedDirectory;
        });
        HapticFeedback.mediumImpact();
      }
    } catch (e) {
      print('Error picking folder: $e');
    }
  }

  Future<void> _previewFile(FileItem file) async {
    // Show preview dialog
    showDialog(
      context: context,
      builder:
          (context) => Dialog(
            backgroundColor: Colors.transparent,
            child: Container(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.8,
              ),
              decoration: BoxDecoration(
                color: const Color(0xFF1C1C1E),
                borderRadius: BorderRadius.circular(24),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Header
                  Padding(
                    padding: const EdgeInsets.all(20),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            file.name,
                            style: GoogleFonts.outfit(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close, color: Colors.white),
                          onPressed: () => Navigator.pop(context),
                        ),
                      ],
                    ),
                  ),
                  // Preview content
                  Expanded(child: _buildPreviewContent(file)),
                ],
              ),
            ),
          ),
    );
  }

  Widget _buildPreviewContent(FileItem file) {
    final fileType = _getFileType(file.name);

    if (fileType == FileType.image) {
      return Column(
        children: [
          Expanded(
            child: InteractiveViewer(
              minScale: 0.5,
              maxScale: 4.0,
              child: Image.network(
                file.url,
                fit: BoxFit.contain,
                loadingBuilder: (context, child, loadingProgress) {
                  if (loadingProgress == null) return child;
                  return Center(
                    child: CircularProgressIndicator(
                      color: const Color(0xFFFFD600),
                      value:
                          loadingProgress.expectedTotalBytes != null
                              ? loadingProgress.cumulativeBytesLoaded /
                                  loadingProgress.expectedTotalBytes!
                              : null,
                    ),
                  );
                },
                errorBuilder: (context, error, stackTrace) {
                  return Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(
                          Icons.broken_image_rounded,
                          color: Colors.white54,
                          size: 48,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'Failed to load image',
                          style: GoogleFonts.outfit(
                            color: Colors.white54,
                            fontSize: 14,
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'Pinch to zoom',
              style: GoogleFonts.outfit(color: Colors.grey[600], fontSize: 12),
            ),
          ),
        ],
      );
    }

    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(32),
            decoration: BoxDecoration(
              color: _getFileTypeColor(fileType).withOpacity(0.1),
              shape: BoxShape.circle,
            ),
            child: Icon(
              _getFileTypeIcon(fileType),
              size: 80,
              color: _getFileTypeColor(fileType),
            ),
          ),
          const SizedBox(height: 24),
          Text(
            'Preview not available',
            style: GoogleFonts.outfit(
              color: Colors.grey[500],
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Download to view this file',
            style: GoogleFonts.outfit(color: Colors.grey[600], fontSize: 14),
          ),
        ],
      ),
    );
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

  String _formatBytes(int bytes) {
    if (bytes < 1024) return "$bytes B";
    if (bytes < 1024 * 1024) return "${(bytes / 1024).toStringAsFixed(1)} KB";
    if (bytes < 1024 * 1024 * 1024)
      return "${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB";
    return "${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB";
  }

  Future<void> _startDownloads() async {
    final selectedFiles =
        _fileItems
            .where((f) => f.isSelected && f.status != 'Complete')
            .toList();
    if (selectedFiles.isEmpty) return;

    // Reset states
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

    // Start Foreground Service
    await FlutterForegroundTask.startService(
      notificationTitle: "⚡ ZapShare Download",
      notificationText: "Starting multi-file download...",
      notificationIcon: const NotificationIcon(
        metaDataName: 'com.pravera.flutter_foreground_task.notification_icon',
      ),
    );

    try {
      // Process queue
      while (_downloadQueue.isNotEmpty) {
        // Always take the first item, as priority might have changed the order
        final file = _downloadQueue.first;

        // Skip if already handled or cancelled before start
        if (file.isCancelled) {
          _downloadQueue.remove(file);
          continue;
        }

        // Update notification
        await FlutterForegroundTask.updateService(
          notificationTitle: "Downloading: ${file.name}",
          notificationText:
              "${_downloadQueue.length} files remaining", // Approximate
        );

        // Download
        await _downloadFile(file);

        // Remove from queue after processing (success or error)
        if (mounted) {
          setState(() {
            _downloadQueue.remove(file);
          });
        } else {
          _downloadQueue.remove(file);
        }
      }
    } finally {
      // Stop service when all done
      try {
        await FlutterForegroundTask.stopService();
      } catch (e) {
        print('Note: Foreground service stop: $e');
      }

      if (mounted) {
        setState(() {
          _downloading = false;
        });
      }
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

      if (_saveFolder == null) {
        _saveFolder = await _getDefaultDownloadFolder();
      }

      // Sanitize filename
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
        // TCP Download Logic with Binary Protocol
        // Protocol: Send 4-byte file index → Receive metadata length (4 bytes) + JSON metadata + file data
        const maxRetries = 5;
        for (int retry = 0; retry < maxRetries; retry++) {
          try {
            final uri = Uri.parse(file.url);
            final fileIndex = int.parse(uri.pathSegments.last);

            print(
              '📡 TCP: Connecting to ${widget.serverIp}:${widget.serverPort + 1}',
            );
            tcpSocket = await Socket.connect(
              widget.serverIp,
              widget.serverPort + 1,
              timeout: const Duration(seconds: 10),
            );

            // Send file index as 4-byte big-endian integer
            final indexBytes = [
              (fileIndex >> 24) & 0xFF,
              (fileIndex >> 16) & 0xFF,
              (fileIndex >> 8) & 0xFF,
              fileIndex & 0xFF,
            ];
            tcpSocket.add(indexBytes);
            await tcpSocket.flush();
            print('📤 TCP: Sent file index: $fileIndex');

            // Create a stream controller to handle the TCP data
            final controller = StreamController<List<int>>();
            final metadataBytes = <int>[];
            int? metadataLength;
            bool metadataComplete = false;

            // Listen to socket and parse metadata, then forward file data
            tcpSocket.listen(
              (chunk) {
                if (!metadataComplete) {
                  metadataBytes.addAll(chunk);

                  // Read metadata length (first 4 bytes)
                  if (metadataLength == null && metadataBytes.length >= 4) {
                    metadataLength =
                        (metadataBytes[0] << 24) |
                        (metadataBytes[1] << 16) |
                        (metadataBytes[2] << 8) |
                        metadataBytes[3];
                    print('📥 TCP: Metadata length: $metadataLength bytes');
                  }

                  // Check if we have all metadata
                  if (metadataLength != null &&
                      metadataBytes.length >= 4 + metadataLength!) {
                    // Parse metadata
                    final metadataJson = utf8.decode(
                      metadataBytes.sublist(4, 4 + metadataLength!),
                    );
                    final metadata = jsonDecode(metadataJson);
                    contentLength = metadata['fileSize'] as int;
                    final receivedFileName = metadata['fileName'] as String;

                    print(
                      '✅ TCP: Metadata received - $receivedFileName ($contentLength bytes)',
                    );

                    metadataComplete = true;

                    // Forward any extra bytes (file data) that came with metadata
                    if (metadataBytes.length > 4 + metadataLength!) {
                      final extraBytes = metadataBytes.sublist(
                        4 + metadataLength!,
                      );
                      controller.add(extraBytes);
                    }
                  }
                } else {
                  // Metadata already parsed, forward file data
                  controller.add(chunk);
                }
              },
              onError: (error) {
                controller.addError(error);
              },
              onDone: () {
                controller.close();
              },
              cancelOnError: true,
            );

            contentStream = controller.stream;
            break; // Success, exit retry loop
          } catch (e) {
            tcpSocket?.destroy();
            tcpSocket = null;
            print('⚠️ TCP connect retry ${retry + 1}/$maxRetries failed: $e');
            if (retry < maxRetries - 1) {
              await Future.delayed(Duration(seconds: 2 * (retry + 1)));
            } else {
              rethrow;
            }
          }
        }
      } else {
        // HTTP Download Logic with retry
        const maxRetries = 3;
        for (int retry = 0; retry < maxRetries; retry++) {
          try {
            httpClient = http.Client();
            final request = http.Request('GET', Uri.parse(file.url));
            request.headers['Connection'] = 'close';

            final response = await httpClient
                .send(request)
                .timeout(
                  Duration(minutes: 60),
                  onTimeout: () => throw TimeoutException('Download timed out'),
                );

            if (response.statusCode != 200) {
              throw Exception('Server returned ${response.statusCode}');
            }
            contentLength = response.contentLength ?? file.size;
            contentStream = response.stream;
            break; // Success, exit retry loop
          } catch (e) {
            httpClient?.close();
            httpClient = null;
            print('⚠️ HTTP download retry ${retry + 1}/$maxRetries failed: $e');
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
      DateTime lastDataReceived = DateTime.now();
      bool downloadSuccess = false;

      try {
        await for (var chunk in contentStream) {
          sink.add(chunk);
          received += chunk.length;
          file.bytesReceived = received;
          lastDataReceived = DateTime.now();

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

          // Handle Pause
          while (file.isPaused) {
            if (file.isCancelled) break;
            await Future.delayed(const Duration(milliseconds: 500));
            if (file.speedMbps != 0) {
              setState(() {
                file.speedMbps = 0.0;
              });
            }
          }

          // Handle Cancel
          if (file.isCancelled) {
            throw Exception('Cancelled by user');
          }

          // Strict completion check: Only break if we have the exact amount or more
          if (contentLength > 0 && received >= contentLength) {
            downloadSuccess = true;
            print('✅ Download complete: $received/$contentLength bytes');
            break;
          }
        }

        // Output final status check
        if (!downloadSuccess) {
          if (contentLength > 0 && received >= contentLength) {
            downloadSuccess = true;
          } else {
            // For HTTP sometimes content-length is unknown (-1)
            // But if we have a known length, and mismatch, it's a failure (or partial)
            print(
              '⚠️ Stream finished but incomplete: $received/$contentLength',
            );
          }
        }
      } catch (e) {
        // Recovery: Only accept if we are extremely close (e.g. last few bytes connection close)
        // For TCP we expect exact match. For HTTP loose match might be ok.
        if (contentLength > 0 && received >= contentLength) {
          downloadSuccess = true;
        } else if (contentLength > 0 &&
            received >= (contentLength * 0.99).floor()) {
          downloadSuccess = true;
          print(
            '⚠️ Stream error but recovered (99%): $received/$contentLength bytes - $e',
          );
        } else {
          print('❌ Download failed: $received/$contentLength - $e');
          rethrow;
        }
      } finally {
        // IMMEDIATE cleanup - close file first
        try {
          await sink.flush();
          await sink.close();
        } catch (e) {
          print('Note: File close error (ignored): $e');
        }

        // Send ACK for TCP BEFORE closing socket
        if (downloadSuccess && widget.useTcp && tcpSocket != null) {
          try {
            tcpSocket.write('ACK\n');
            await tcpSocket.flush();
            // Short delay to ensure ACK is sent
            await Future.delayed(const Duration(milliseconds: 50));
          } catch (e) {
            print('Note: ACK send error (ignored): $e');
          }
        }

        // Close network resources
        httpClient?.close();
        tcpSocket?.destroy(); // Use destroy for TCP socket to force close
        await cancelProgressNotification(_fileItems.indexOf(file));
      }

      if (downloadSuccess) {
        // Save to History
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

        // Saved to History - Snackbar removed as per request
      } else {
        throw Exception('Download incomplete');
      }
    } catch (e) {
      setState(() {
        if (e.toString().contains('Cancelled')) {
          file.status = 'Cancelled';
          // Delete partial file
          _deletePartialFile(file.savePath);
        } else {
          file.status = 'Error: $e';
        }
        file.progress = 0.0;
      });
      // ... keep existing error snackbar ...
    }
  }

  Future<void> _deletePartialFile(String? path) async {
    if (path == null) return;
    try {
      final file = File(path);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (e) {
      print("Error deleting partial file: $e");
    }
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
    final platformChannelSpecifics = NotificationDetails(
      android: androidPlatformChannelSpecifics,
    );
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

  @override
  Widget build(BuildContext context) {
    final selectedCount = _fileItems.where((f) => f.isSelected).length;
    final totalSize = _fileItems
        .where((f) => f.isSelected)
        .fold<int>(0, (sum, f) => sum + f.size);

    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;
    final screenWidth = MediaQuery.of(context).size.width;
    final isTV = screenWidth > 1000;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: const Color(0xFF0C0C0E),
        body: SafeArea(
          child: Column(
            children: [
              _buildHeader(),
              Expanded(
                child:
                    (isLandscape || isTV)
                        ? _buildGridView()
                        : SingleChildScrollView(
                          padding: const EdgeInsets.symmetric(horizontal: 24),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const SizedBox(height: 8),
                              _buildSaveLocationCard(),
                              const SizedBox(height: 24),
                              _buildFileList(),
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

  Widget _buildGridView() {
    final width = MediaQuery.of(context).size.width;
    final crossAxisCount = width > 900 ? 3 : 2;
    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: crossAxisCount,
        childAspectRatio: 3.0,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
      ),
      itemCount: _fileItems.length,
      itemBuilder: (context, index) => _buildFileItem(_fileItems[index]),
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
              onPressed: () {
                Navigator.pushAndRemoveUntil(
                  context,
                  MaterialPageRoute(
                    builder: (context) => const AndroidHomeScreen(),
                  ),
                  (route) => false,
                );
              },
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      'Available Files',
                      style: GoogleFonts.outfit(
                        color: Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.5,
                      ),
                    ),
                    const SizedBox(width: 12),
                    // PROTOCOL INDICATOR
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color:
                            widget.useTcp
                                ? Colors.green.withOpacity(0.2)
                                : Colors.blue.withOpacity(0.2),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: widget.useTcp ? Colors.green : Colors.blue,
                          width: 1,
                        ),
                      ),
                      child: Text(
                        widget.useTcp ? 'TCP MODE' : 'HTTP MODE',
                        style: GoogleFonts.outfit(
                          color: widget.useTcp ? Colors.green : Colors.blue,
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
                Text(
                  '${_fileItems.length} files found',
                  style: GoogleFonts.outfit(
                    color: Colors.grey[500],
                    fontSize: 14,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSaveLocationCard() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF1C1C1E),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withOpacity(0.08)),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: const Color(0xFFFFD600).withOpacity(0.15),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(
              Icons.folder_rounded,
              color: Color(0xFFFFD600),
              size: 20,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'SAVE LOCATION',
                  style: GoogleFonts.outfit(
                    color: Colors.grey[500],
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.0,
                  ),
                ),
                Text(
                  _saveFolder ?? 'Default (Downloads/ZapShare)',
                  style: GoogleFonts.outfit(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: _pickCustomFolder,
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              backgroundColor: const Color(0xFFFFD600).withOpacity(0.1),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            child: Text(
              'Change',
              style: GoogleFonts.outfit(
                color: const Color(0xFFFFD600),
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFileList() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'FILES TO DOWNLOAD',
          style: GoogleFonts.outfit(
            color: Colors.grey[500],
            fontSize: 13,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.2,
          ),
        ),
        const SizedBox(height: 16),
        ..._fileItems.map((file) => _buildFileItem(file)),
      ],
    );
  }

  Widget _buildFileItem(FileItem file) {
    final fileType = _getFileType(file.name);
    final isDownloading = file.status == 'Downloading';
    final isComplete = file.status == 'Complete';
    final isError = file.status.startsWith('Error');
    final isWaiting = file.status == 'Waiting';

    // Always use yellow for progress fill
    final progressColor = const Color(0xFFFFD600);
    final iconColor = _getFileTypeColor(fileType);

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TVFocusableButton(
        padding: EdgeInsets.zero,
        borderRadius: BorderRadius.circular(16),
        onPressed:
            isDownloading || isComplete
                ? null
                : () {
                  setState(() {
                    file.isSelected = !file.isSelected;
                  });
                  HapticFeedback.selectionClick();
                },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color:
                isDownloading
                    ? const Color(0xFF2C2C2E)
                    : const Color(0xFF1C1C1E),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color:
                  isDownloading
                      ? Colors.white.withOpacity(0.05)
                      : (file.isSelected
                          ? const Color(0xFFFFD600).withOpacity(0.5)
                          : Colors.white.withOpacity(0.05)),
              width: file.isSelected && !isDownloading ? 1.5 : 1,
            ),
            boxShadow: null,
          ),
          child: Row(
            children: [
              // File Icon with Fill Progress Effect
              if (isDownloading)
                SizedBox(
                  width: 48,
                  height: 48,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Stack(
                      children: [
                        // Background container
                        Container(
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(
                            color: iconColor.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        // Fill from bottom progress
                        Align(
                          alignment: Alignment.bottomCenter,
                          child: Container(
                            width: 48,
                            height: 48 * file.progress,
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.bottomCenter,
                                end: Alignment.topCenter,
                                colors: [
                                  progressColor,
                                  progressColor.withOpacity(0.8),
                                ],
                              ),
                            ),
                          ),
                        ),
                        // File Icon on top
                        Center(
                          child: Icon(
                            _getFileTypeIcon(fileType),
                            color:
                                file.progress > 0.5 ? Colors.black : iconColor,
                            size: 24,
                          ),
                        ),
                      ],
                    ),
                  ),
                )
              else
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color:
                        isComplete
                            ? Colors.green.withOpacity(0.15)
                            : iconColor.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color:
                          isComplete
                              ? Colors.green.withOpacity(0.2)
                              : iconColor.withOpacity(0.2),
                    ),
                  ),
                  child: Icon(
                    isComplete
                        ? Icons.check_rounded
                        : _getFileTypeIcon(fileType),
                    color: isComplete ? Colors.green : iconColor,
                    size: 24,
                  ),
                ),
              const SizedBox(width: 16),

              // File Info
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      file.name,
                      style: GoogleFonts.outfit(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),

                    if (isDownloading) ...[
                      Row(
                        children: [
                          Text(
                            '${(file.progress * 100).toInt()}%',
                            style: GoogleFonts.outfit(
                              color: progressColor,
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            '• ${file.speedMbps.toStringAsFixed(1)} Mbps',
                            style: GoogleFonts.outfit(
                              color: Colors.grey[500],
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ] else if (isComplete) ...[
                      Text(
                        'Download Complete',
                        style: GoogleFonts.outfit(
                          color: Colors.green,
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ] else if (isError) ...[
                      Text(
                        'Failed',
                        style: GoogleFonts.outfit(
                          color: Colors.red,
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ] else ...[
                      // Normal State
                      Text(
                        _formatBytes(file.size),
                        style: GoogleFonts.outfit(
                          color: Colors.grey[500],
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ],
                ),
              ),

              // ACTION BUTTONS
              if (isDownloading ||
                  (file.bytesReceived > 0 && !isComplete && !isError)) ...[
                IconButton(
                  icon: Icon(
                    file.isPaused
                        ? Icons.play_arrow_rounded
                        : Icons.pause_rounded,
                    color: Colors.white,
                    size: 20,
                  ),
                  onPressed: () {
                    setState(() {
                      file.isPaused = !file.isPaused;
                    });
                  },
                ),
                IconButton(
                  icon: const Icon(
                    Icons.close_rounded,
                    color: Colors.white,
                    size: 20,
                  ),
                  onPressed: () {
                    file.isCancelled = true;
                  },
                ),
              ] else if (isWaiting && _downloading) ...[
                TextButton(
                  onPressed: () {
                    setState(() {
                      if (_downloadQueue.contains(file)) {
                        _downloadQueue.remove(file);
                        _downloadQueue.insert(0, file);
                      }
                    });
                  },
                  child: Text(
                    "Prioritize",
                    style: GoogleFonts.outfit(
                      color: const Color(0xFFFFD600),
                      fontSize: 12,
                    ),
                  ),
                ),
              ] else if (!isComplete && !isError) ...[
                // Preview Button
                IconButton(
                  icon: const Icon(
                    Icons.remove_red_eye_rounded,
                    color: Colors.white70,
                    size: 20,
                  ),
                  tooltip: 'Preview',
                  onPressed: () => _previewFile(file),
                ),
                Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    width: 22,
                    height: 22,
                    decoration: BoxDecoration(
                      color:
                          file.isSelected
                              ? const Color(0xFFFFD600)
                              : Colors.transparent,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color:
                            file.isSelected
                                ? const Color(0xFFFFD600)
                                : Colors.grey[700]!,
                        width: 1.5,
                      ),
                    ),
                    child:
                        file.isSelected
                            ? const Icon(
                              Icons.check,
                              size: 14,
                              color: Colors.black,
                            )
                            : null,
                  ),
                ),
              ],

              // Open Button when complete
              if (isComplete)
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: TextButton(
                    onPressed: () => OpenFile.open(file.savePath),
                    style: TextButton.styleFrom(
                      backgroundColor: Colors.green.withOpacity(0.1),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    child: Text(
                      "OPEN",
                      style: GoogleFonts.outfit(
                        color: Colors.green,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBottomAction(int selectedCount, int totalSize) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: const Color(0xFF1C1C1E),
        border: Border(top: BorderSide(color: Colors.white.withOpacity(0.05))),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '$selectedCount files selected',
                  style: GoogleFonts.outfit(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  _formatBytes(totalSize),
                  style: GoogleFonts.outfit(
                    color: const Color(0xFFFFD600),
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            TVFocusableButton(
              autofocus: true,
              onPressed: _downloading ? null : _startDownloads,
              backgroundColor: const Color(0xFFFFD600),
              borderRadius: BorderRadius.circular(16),
              padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 24),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(
                    Icons.download_rounded,
                    size: 22,
                    color: Colors.black,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _downloading ? 'Downloading...' : 'Download Selected',
                    style: GoogleFonts.outfit(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: Colors.black,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
