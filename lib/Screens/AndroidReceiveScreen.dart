import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;
import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:open_file/open_file.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'ImagePreviewDialog.dart';


const Color kAndroidAccentYellow = Colors.yellow; // lighter yellow for Android

enum FileType {
  image,
  video,
  audio,
  pdf,
  document,
  spreadsheet,
  presentation,
  archive,
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
  });
}

class AndroidReceiveScreen extends StatefulWidget {
  final String? autoConnectCode;
  
  const AndroidReceiveScreen({super.key, this.autoConnectCode});
  
  @override
  State<AndroidReceiveScreen> createState() => _AndroidReceiveScreenState();
}

class _AndroidReceiveScreenState extends State<AndroidReceiveScreen> {
  final TextEditingController _codeController = TextEditingController();
  final FocusNode _codeFocusNode = FocusNode();
  String? _saveFolder;
  List<DownloadTask> _tasks = [];
  List<DownloadTask> _downloadedFiles = []; // Separate list for downloaded files
  bool _downloading = false;
  int _activeDownloads = 0;
  final int _maxParallel = 2;
  String? _serverIp;
  int _currentTab = 0; // 0 = Available Files, 1 = Downloaded Files
  List<Map<String, dynamic>> _fileList = [];
  bool _loading = false;
  final PageController _pageController = PageController();

  List<String> _recentCodes = [];
  final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();

  @override
  void initState() {
    super.initState();
    _loadRecentCodes();
    _initLocalNotifications();
    _codeFocusNode.addListener(() {
      setState(() {});
    });
    
    // Auto-connect if code provided
    if (widget.autoConnectCode != null && widget.autoConnectCode!.isNotEmpty) {
      print('🚀 [Receive Screen] Auto-connecting with code: ${widget.autoConnectCode}');
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _codeController.text = widget.autoConnectCode!;
        _fetchFileList(widget.autoConnectCode!);
      });
    }
  }

  Future<void> _initLocalNotifications() async {
    const AndroidInitializationSettings initializationSettingsAndroid =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    final InitializationSettings initializationSettings = InitializationSettings(
      android: initializationSettingsAndroid,
    );
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

  Future<void> showProgressNotification(int fileIndex, double progress, String fileName, {double speedMbps = 0.0, bool paused = false}) async {
    final percent = (progress * 100).toStringAsFixed(1);
    final body = '$fileName\nProgress: $percent%\nSpeed: ${speedMbps.toStringAsFixed(2)} Mbps';
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
    );
    final platformChannelSpecifics = NotificationDetails(android: androidPlatformChannelSpecifics);
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

  Future<void> _loadRecentCodes() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _recentCodes = prefs.getStringList('recent_codes') ?? [];
    });
  }

  Future<void> _saveRecentCode(String code) async {
    final prefs = await SharedPreferences.getInstance();
    List<String> codes = prefs.getStringList('recent_codes') ?? [];
    codes.remove(code);
    codes.insert(0, code);
    if (codes.length > 2) codes.sublist(0, 2);
    await prefs.setStringList('recent_codes', codes);
    setState(() {
      _recentCodes = codes;
    });
  }

    Future<void> _pickSaveFolder() async {
    String? result = await FilePicker.platform.getDirectoryPath(dialogTitle: 'Select Folder to Save');
    setState(() => _saveFolder = result);
    
    if (result != null) {
      // Folder selected successfully
    }
  }

  Future<String> _getDefaultDownloadFolder() async {
    try {
      // Request storage permissions first
      await _requestStoragePermissions();
      
      // Try to get the public Downloads directory
      final downloadsDir = await getDownloadsDirectory();
      if (downloadsDir != null) {
        // Check if this is the public Downloads directory
        final downloadsPath = downloadsDir.path;
        if (downloadsPath.contains('/Download') || downloadsPath.contains('/Downloads')) {
          final zapShareDir = Directory('$downloadsPath/ZapShare');
          if (!await zapShareDir.exists()) {
            await zapShareDir.create(recursive: true);
          }
          return zapShareDir.path;
        }
      }
      
      // Fallback to direct public Downloads path
      final publicDownloadsPath = '/storage/emulated/0/Download/ZapShare';
      final zapShareDir = Directory(publicDownloadsPath);
      
      if (!await zapShareDir.exists()) {
        await zapShareDir.create(recursive: true);
      }
      
      return publicDownloadsPath;
    } catch (e) {
      print('Error getting default download folder: $e');
      
      // Try alternative paths
      final alternativePaths = [
        '/storage/emulated/0/Download/ZapShare',
        '/sdcard/Download/ZapShare',
        '/storage/sdcard0/Download/ZapShare',
      ];
      
      for (final path in alternativePaths) {
        try {
          final dir = Directory(path);
          if (!await dir.exists()) {
            await dir.create(recursive: true);
          }
          return path;
        } catch (_) {
          continue;
        }
      }
    }
    
    // Final fallback
    return '/storage/emulated/0/Download/ZapShare';
  }

  Future<void> _requestStoragePermissions() async {
    try {
      // Request storage permissions
      if (await Permission.storage.isDenied) {
        await Permission.storage.request();
      }
      
      // For Android 11+ (API 30+), also request manage external storage
      if (await Permission.manageExternalStorage.isDenied) {
        await Permission.manageExternalStorage.request();
      }
    } catch (e) {
      print('Error requesting storage permissions: $e');
    }
  }

  bool _decodeCode(String code) {
    try {
      print('Decoding code: $code');
      if (!RegExp(r'^[A-Z0-9]{8}$').hasMatch(code)) {
        print('Code format invalid: must be 8 characters, A-Z or 0-9');
        return false;
      }
      int n = int.parse(code, radix: 36);
      print('Parsed code to number: $n');
      final ip = '${(n >> 24) & 0xFF}.${(n >> 16) & 0xFF}.${(n >> 8) & 0xFF}.${n & 0xFF}';
      print('Decoded IP: $ip');
      final parts = ip.split('.').map(int.parse).toList();
      if (parts.length != 4 || parts.any((p) => p < 0 || p > 255)) {
        print('Invalid IP address: $ip');
        return false;
      }
      _serverIp = ip;
      print('Server IP set to: $_serverIp');
      return true;
    } catch (e) {
      print('Error decoding code: $e');
      return false;
    }
  }

  String formatBytes(int bytes) {
    if (bytes < 1024) return "$bytes B";
    if (bytes < 1024 * 1024) return "${(bytes / 1024).toStringAsFixed(1)} KB";
    if (bytes < 1024 * 1024 * 1024) return "${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB";
    return "${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB";
  }

  Future<void> _fetchFileList(String code) async {
    if (!_decodeCode(code)) {
      return;
    }
    await _saveRecentCode(code);
    setState(() { _loading = true; });
    
    try {
      final url = 'http://$_serverIp:8080/list';
      print('Fetching file list from: $url');
      
      // Add timeout to the request - increased for release builds
      final resp = await http.get(Uri.parse(url)).timeout(
        Duration(seconds: 30),
        onTimeout: () {
          throw TimeoutException('Request timed out after 30 seconds');
        },
      );
      
      print('Response status: ${resp.statusCode}');
      print('Response body: ${resp.body}');
      
      if (resp.statusCode == 200) {
        final List files = jsonDecode(resp.body);
        print('Parsed files: $files');
        _fileList = files.cast<Map<String, dynamic>>();
        _tasks = _fileList.map((f) => DownloadTask(
          url: 'http://$_serverIp:8080/file/${f['index']}',
          fileName: f['name'] ?? 'Unknown File',
          fileSize: f['size'] ?? 0,
          savePath: '',
          progress: 0.0,
          status: 'Waiting',
          isSelected: true,
          isPaused: false,
          bytesReceived: 0,
        )).toList();
        print('Created ${_tasks.length} download tasks');
        setState(() { _loading = false; });
        
        if (_tasks.isEmpty) {
          // No files found on server
        } else {
          // Files found successfully
        }
      } else {
        setState(() { _loading = false; });
        // Server error occurred
      }
          } catch (e) {
        print('Error fetching file list: $e');
        setState(() { _loading = false; });
        // Error occurred while fetching file list
      }
  }

  Future<void> _startDownloads() async {
    // Use default folder if none is selected
    if (_saveFolder == null) {
      _saveFolder = await _getDefaultDownloadFolder();
      setState(() {}); // Update UI to show the default folder
      
      // Files will be saved to default location
    }
    
    final selectedTasks = _tasks.where((task) => task.isSelected).toList();
    if (selectedTasks.isEmpty) {
      return;
    }

    await FlutterForegroundTask.startService(
      notificationTitle: "⚡ ZapShare Download",
      notificationText: "Pikachu is downloading your files! 🏃",
    );

    setState(() { 
      _downloading = true; 
      _activeDownloads = 0; 
    });
    
    _startQueuedDownloads();
  }

  void _startQueuedDownloads() {
    while (_activeDownloads < _maxParallel) {
      final next = _tasks.indexWhere((t) => t.isSelected && t.status == 'Waiting' && !t.isPaused);
      if (next == -1) break;
      setState(() { _activeDownloads++; });
      _downloadFile(_tasks[next]);
    }
  }

  Future<void> _downloadFile(DownloadTask task) async {
    setState(() { task.status = 'Downloading'; });
    
    try {
      // Create HTTP client with increased timeout for release builds
      final client = http.Client();
      final request = http.Request('GET', Uri.parse(task.url));
      request.headers['Connection'] = 'keep-alive';
      request.headers['Cache-Control'] = 'no-cache';
      
      final response = await client.send(request).timeout(
        Duration(minutes: 10), // Increased timeout for large files
        onTimeout: () {
          throw TimeoutException('Download timed out after 10 minutes');
        },
      );
      final contentDisposition = response.headers['content-disposition'];
      String fileName = task.fileName;
      if (contentDisposition != null) {
        final match = RegExp(r'filename=\"?([^\";]+)\"?').firstMatch(contentDisposition);
        if (match != null) fileName = match.group(1)!;
      }
      
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
      final file = File(savePath);
      final sink = file.openWrite();
      int received = 0;
      final contentLength = response.contentLength ?? task.fileSize;
      
      DateTime lastUpdate = DateTime.now();
      double lastProgress = 0.0;
      int lastBytes = 0;
      DateTime lastSpeedTime = DateTime.now();
      double speedMbps = 0.0;

      await for (var chunk in response.stream) {
        // Pause logic
        while (task.isPaused) {
          await Future.delayed(Duration(milliseconds: 200));
        }
        
        sink.add(chunk);
        received += chunk.length;
        task.bytesReceived = received;
        
        // Force flush sink periodically to ensure data is written
        if (received % (256 * 1024) == 0) { // Flush every 256KB
          await sink.flush();
        }
        
        // Debug logging for release builds
        if (received % (1024 * 1024) == 0) { // Log every MB
          print('Download progress: ${task.fileName} - ${received}/${contentLength} bytes');
        }
        
        double progress = received / contentLength;
        task.progress = progress;

        // Speed calculation
        final now = DateTime.now();
        final elapsed = now.difference(lastSpeedTime).inMilliseconds;
        if (elapsed > 0) {
          final bytesDelta = received - lastBytes;
          speedMbps = (bytesDelta * 8) / (elapsed * 1000); // Mbps
          lastBytes = received;
          lastSpeedTime = now;
        }

        // Throttle updates: only update if 100ms passed or progress increased by 1%
        if (now.difference(lastUpdate).inMilliseconds > 100 ||
            (progress - lastProgress) > 0.01) {
          setState(() {});
          await showProgressNotification(
            _tasks.indexOf(task),
            progress,
            fileName,
            speedMbps: speedMbps,
            paused: task.isPaused,
          );
          lastUpdate = now;
          lastProgress = progress;
        }
      }
      
      // Final flush before closing
      await sink.flush();
      await sink.close();
      
      // Close the HTTP client
      client.close();
      
      // Cancel notification before removing task from list
      await cancelProgressNotification(_tasks.indexOf(task));
      
      setState(() { 
        task.status = 'Complete'; 
        _activeDownloads--; 
        // Move completed file to downloaded files list
        _downloadedFiles.add(task);
        _tasks.remove(task);
      });
      
      // Record transfer history
      try {
        final prefs = await SharedPreferences.getInstance();
        final history = prefs.getStringList('transfer_history') ?? [];
        final entry = {
          'fileName': fileName,
          'fileSize': contentLength,
          'direction': 'Received',
          'peer': _serverIp ?? '',
          'peerDeviceName': null, // Could be enhanced to lookup device name
          'dateTime': DateTime.now().toIso8601String(),
          'fileLocation': savePath, // Save the actual file path
        };
        history.insert(0, jsonEncode(entry));
        if (history.length > 100) history.removeLast();
        await prefs.setStringList('transfer_history', history);
        
        // Download completed successfully
      } catch (_) {}
      
      _startQueuedDownloads();
      
      // Check if all downloads are complete
      if (_tasks.every((task) => task.status == 'Complete' || !task.isSelected)) {
        await FlutterForegroundTask.stopService();
        setState(() { _downloading = false; });
      }
      
    } catch (e) {
      setState(() { 
        task.status = 'Error: $e'; 
        _activeDownloads--; 
      });
      await cancelProgressNotification(_tasks.indexOf(task));
      _startQueuedDownloads();
    }
  }

  void _toggleFileSelection(int index) {
    setState(() {
      _tasks[index].isSelected = !_tasks[index].isSelected;
    });
    
    // File selection toggled
  }


  void _showImagePreview(DownloadTask task) {
    // Get all image files from available tasks
    final imageTasks = _tasks.where((t) => _getFileType(t.fileName) == FileType.image).toList();
    final currentIndex = imageTasks.indexOf(task);
    
    if (currentIndex == -1) return;
    
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (context) => ImagePreviewDialog(
        imageTasks: imageTasks,
        initialIndex: currentIndex,
        onSelectionChanged: (index, isSelected) {
          // Find the corresponding task in the main list and update its selection
          final previewTask = imageTasks[index];
          final mainIndex = _tasks.indexOf(previewTask);
          if (mainIndex != -1) {
            setState(() {
              _tasks[mainIndex].isSelected = isSelected;
            });
          }
        },
      ),
    );
  }



  String _formatBytes(int bytes) {
    if (bytes < 1024) return "$bytes B";
    if (bytes < 1024 * 1024) return "${(bytes / 1024).toStringAsFixed(1)} KB";
    if (bytes < 1024 * 1024 * 1024) return "${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB";
    return "${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB";
  }


  // Get file type category
  FileType _getFileType(String fileName) {
    final ext = fileName.split('.').last.toLowerCase();
    
    if (['jpg', 'jpeg', 'png', 'gif', 'bmp', 'webp', 'svg', 'ico', 'tiff', 'tif', 'heic', 'heif', 'avif', 'jxl'].contains(ext)) {
      return FileType.image;
    } else if (['mp4', 'mov', 'avi', 'mkv', 'wmv', 'flv', 'webm', 'm4v', '3gp'].contains(ext)) {
      return FileType.video;
    } else if (['mp3', 'wav', 'flac', 'aac', 'ogg', 'm4a', 'wma'].contains(ext)) {
      return FileType.audio;
    } else if (['pdf'].contains(ext)) {
      return FileType.pdf;
    } else if (['doc', 'docx'].contains(ext)) {
      return FileType.document;
    } else if (['xls', 'xlsx'].contains(ext)) {
      return FileType.spreadsheet;
    } else if (['ppt', 'pptx'].contains(ext)) {
      return FileType.presentation;
    } else if (['zip', 'rar', '7z', 'tar', 'gz'].contains(ext)) {
      return FileType.archive;
    } else if (['txt', 'rtf', 'md'].contains(ext)) {
      return FileType.text;
    } else {
      return FileType.other;
    }
  }

  // Open file based on type
  Future<void> _openFileByType(String filePath, String fileName) async {
    final fileType = _getFileType(fileName);
    
    try {
      switch (fileType) {
        case FileType.image:
          await _openImageFile(filePath, fileName);
          break;
        case FileType.video:
          await _openVideoFile(filePath, fileName);
          break;
        case FileType.audio:
          await _openAudioFile(filePath, fileName);
          break;
        case FileType.pdf:
          await _openPdfFile(filePath, fileName);
          break;
        case FileType.document:
        case FileType.spreadsheet:
        case FileType.presentation:
          await _openDocumentFile(filePath, fileName);
          break;
        case FileType.text:
          await _openTextFile(filePath, fileName);
          break;
        case FileType.archive:
          await _openArchiveFile(filePath, fileName);
          break;
        case FileType.other:
          await _openGenericFile(filePath, fileName);
          break;
      }
    } catch (e) {
      _showSnackBar('Unable to open file: $e');
    }
  }

  Future<void> _openImageFile(String filePath, String fileName) async {
    // Try to open with image viewer
    final result = await OpenFile.open(filePath, type: 'image/*');
    if (result.type != ResultType.done) {
      _showSnackBar('No image viewer found. File saved to: $filePath');
    }
  }

  Future<void> _openVideoFile(String filePath, String fileName) async {
    final result = await OpenFile.open(filePath, type: 'video/*');
    if (result.type != ResultType.done) {
      _showSnackBar('No video player found. File saved to: $filePath');
    }
  }

  Future<void> _openAudioFile(String filePath, String fileName) async {
    final result = await OpenFile.open(filePath, type: 'audio/*');
    if (result.type != ResultType.done) {
      _showSnackBar('No audio player found. File saved to: $filePath');
    }
  }

  Future<void> _openPdfFile(String filePath, String fileName) async {
    final result = await OpenFile.open(filePath, type: 'application/pdf');
    if (result.type != ResultType.done) {
      _showSnackBar('No PDF viewer found. File saved to: $filePath');
    }
  }

  Future<void> _openDocumentFile(String filePath, String fileName) async {
    final result = await OpenFile.open(filePath);
    if (result.type != ResultType.done) {
      _showSnackBar('No document viewer found. File saved to: $filePath');
    }
  }

  Future<void> _openTextFile(String filePath, String fileName) async {
    final result = await OpenFile.open(filePath, type: 'text/*');
    if (result.type != ResultType.done) {
      _showSnackBar('No text editor found. File saved to: $filePath');
    }
  }

  Future<void> _openArchiveFile(String filePath, String fileName) async {
    final result = await OpenFile.open(filePath);
    if (result.type != ResultType.done) {
      _showSnackBar('No archive extractor found. File saved to: $filePath');
    }
  }

  Future<void> _openGenericFile(String filePath, String fileName) async {
    final result = await OpenFile.open(filePath);
    if (result.type != ResultType.done) {
      _showSnackBar('File saved to: $filePath');
    }
  }


  // Get file type icon
  IconData _getFileTypeIcon(FileType fileType) {
    switch (fileType) {
      case FileType.image:
        return Icons.image_outlined;
      case FileType.video:
        return Icons.videocam_outlined;
      case FileType.audio:
        return Icons.audiotrack_outlined;
      case FileType.pdf:
        return Icons.picture_as_pdf_outlined;
      case FileType.document:
        return Icons.description_outlined;
      case FileType.spreadsheet:
        return Icons.table_chart_outlined;
      case FileType.presentation:
        return Icons.slideshow_outlined;
      case FileType.archive:
        return Icons.archive_outlined;
      case FileType.text:
        return Icons.text_snippet_outlined;
      case FileType.other:
        return Icons.insert_drive_file_outlined;
    }
  }




  // Show snackbar message
  void _showSnackBar(String message) {
    // Snackbars removed as requested
    print(message);
  }






  @override
  void dispose() {
    FlutterForegroundTask.stopService();
    _pageController.dispose();
    _codeFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      resizeToAvoidBottomInset: false,
      body: Stack(
        children: [
          Positioned.fill(
            child: SafeArea(
              child: Stack(
                children: [
                  // Header - completely static
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: _buildZapShareHeader(),
                  ),
                  
                  // Main content - positioned below header
                  Positioned(
                    top: 100, // Adjust based on header height
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: Column(
                        children: [
                          const SizedBox(height: 8),
                          
                          // Compact connection section
                          _buildConnectionSection(),
                          
                          const SizedBox(height: 12),
                          
                          // Swipe tabs for files - always show
                          _buildSwipeTabs(),
                          const SizedBox(height: 12),
                          
                          // Content area with swipe - takes most space
                          Expanded(
                            child: Stack(
                              children: [
                                Positioned.fill(
                                  child: PageView(
                                    controller: _pageController,
                                    onPageChanged: (index) {
                                      setState(() {
                                        _currentTab = index;
                                      });
                                    },
                                    children: [
                                      _buildAvailableFilesContent(),
                                      _buildDownloadedFilesContent(),
                                    ],
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
          ),
        ],
      ),
    );
  }

  // ZapShare-style header
  Widget _buildZapShareHeader() {
    return Container(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
              child: Row(
                children: [
                  IconButton(
                    icon: Icon(Icons.arrow_back_ios_rounded, color: Colors.white, size: 20),
                    onPressed: () => Navigator.pop(context),
                  ),
                  Expanded(
                    child: Text(
                      'Receive Files',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 28,
                        fontWeight: FontWeight.w300,
                        letterSpacing: -0.5,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                  const SizedBox(width: 48), // Balance the back button
                ],
              ),
    );
  }

  // Swipe tabs
  Widget _buildSwipeTabs() {
    final screenWidth = MediaQuery.of(context).size.width;
    final isCompact = screenWidth < 400;
    
    return Container(
      height: isCompact ? 44 : 48,
      decoration: BoxDecoration(
        color: Colors.grey[900],
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.grey[800]!, width: 1),
      ),
      child: Stack(
                  children: [
          // Animated background
          AnimatedPositioned(
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOut,
            left: _currentTab == 0 ? 4 : MediaQuery.of(context).size.width / 2 - 20,
            top: 4,
            bottom: 4,
            child: Container(
              width: MediaQuery.of(context).size.width / 2 - 24,
              decoration: BoxDecoration(
                color: Colors.yellow[300],
                borderRadius: BorderRadius.circular(8),
                boxShadow: [
                  BoxShadow(
                    color: Colors.yellow[300]!.withOpacity(0.3),
                    blurRadius: 4,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
            ),
          ),
          // Tab content
          Row(
            children: [
          // Available Files Tab
                      Expanded(
            child: GestureDetector(
              onTap: () {
                _pageController.animateToPage(0, 
                  duration: const Duration(milliseconds: 300), 
                  curve: Curves.easeInOut);
              },
              child: Container(
                child: Center(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.cloud_download_outlined,
                        color: _currentTab == 0 ? Colors.black : Colors.grey[400],
                        size: 18,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        isCompact 
                            ? 'Available (${_tasks.where((t) => t.isSelected).length}/${_tasks.length})'
                            : 'Available (${_tasks.where((t) => t.isSelected).length}/${_tasks.length})',
                        style: TextStyle(
                          color: _currentTab == 0 ? Colors.black : Colors.grey[400],
                          fontSize: isCompact ? 13 : 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          // Downloaded Files Tab
                      Expanded(
            child: GestureDetector(
              onTap: () {
                _pageController.animateToPage(1, 
                  duration: const Duration(milliseconds: 300), 
                  curve: Curves.easeInOut);
              },
              child: Container(
                child: Center(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.check_circle_outline,
                        color: _currentTab == 1 ? Colors.black : Colors.grey[400],
                        size: 18,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        isCompact 
                            ? 'Downloaded (${_downloadedFiles.length})'
                            : 'Downloaded (${_downloadedFiles.length})',
                        style: TextStyle(
                          color: _currentTab == 1 ? Colors.black : Colors.grey[400],
                          fontSize: isCompact ? 13 : 14,
                          fontWeight: FontWeight.w600,
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
        ],
      ),
    );
  }


  // Available files content
  Widget _buildAvailableFilesContent() {
    if (_loading) {
      return _buildLoadingState();
    }
    
    if (_codeController.text.isNotEmpty && !_loading && _tasks.isEmpty) {
      return _buildEmptyState();
    }
    
    if (_tasks.isEmpty) {
      return Container(
        margin: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: Colors.grey[900],
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.grey[800]!, width: 1),
        ),
      );
    }

    return Column(
        children: [
        // Files list
        Expanded(
          child: Container(
            margin: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.grey[900],
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.grey[800]!, width: 1),
                ),
            child: ListView.builder(
              padding: const EdgeInsets.all(8),
              itemCount: _tasks.length,
              itemBuilder: (context, index) {
                final task = _tasks[index];
                return _buildAvailableFileItem(task, index);
              },
            ),
          ),
        ),
        
        // Download button
        if (_tasks.isNotEmpty) ...[
          const SizedBox(height: 16),
          _buildDownloadButton(),
        ],
      ],
    );
  }

  // Downloaded files content
  Widget _buildDownloadedFilesContent() {
    if (_downloadedFiles.isEmpty) {
      return Container(
        margin: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: Colors.grey[900],
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.grey[800]!, width: 1),
        ),
      );
    }

    return Container(
      margin: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.grey[900],
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey[800]!, width: 1),
      ),
          child: ListView.builder(
        padding: const EdgeInsets.all(8),
        itemCount: _downloadedFiles.length,
            itemBuilder: (context, index) {
          final task = _downloadedFiles[index];
          return _buildDownloadedFileItem(task);
        },
      ),
    );
  }

  // Connection section - compact design
  Widget _buildConnectionSection() {
    final screenWidth = MediaQuery.of(context).size.width;
    final isCompact = screenWidth < 400;
    
    return Container(
      decoration: BoxDecoration(
        color: Colors.grey[900],
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey[800]!, width: 1),
      ),
      child: Column(
        children: [
          // Compact code input and folder selection in one row
          Container(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                // Code input - takes more space
                Expanded(
                  flex: 3,
                  child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
                        'Connection Code',
          style: TextStyle(
                          color: Colors.white,
                          fontSize: isCompact ? 14 : 15,
            fontWeight: FontWeight.w600,
          ),
        ),
                      const SizedBox(height: 6),
        Container(
          height: 40,
      decoration: BoxDecoration(
                          color: Colors.grey[800],
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: _codeFocusNode.hasFocus ? Colors.yellow[300]! : Colors.grey[700]!, 
                            width: _codeFocusNode.hasFocus ? 2 : 1
                          ),
      ),
      child: TextField(
        controller: _codeController,
        focusNode: _codeFocusNode,
        cursorColor: Colors.yellow,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w500,
                            fontFamily: 'monospace',
                            letterSpacing: 1.0,
                          ),
                          textAlign: TextAlign.center,
                          decoration: InputDecoration(
          hintText: 'Enter 8-character code',
                            hintStyle: const TextStyle(
                              color: Colors.grey,
                              fontSize: 14,
                            ),
          border: InputBorder.none,
          focusedBorder: InputBorder.none,
          enabledBorder: InputBorder.none,
          errorBorder: InputBorder.none,
          disabledBorder: InputBorder.none,
          focusedErrorBorder: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          fillColor: Colors.transparent,
          filled: true,
          isDense: true,
                          ),
                          onSubmitted: (val) => _fetchFileList(val.trim()),
                          onChanged: (val) {
                            // Auto-submit when 8 characters are entered
                            if (val.length == 8) {
                              _fetchFileList(val.trim());
                }
              },
            ),
          ),
                    ],
                  ),
                ),
                
                const SizedBox(width: 12),
                
                // Folder selection - compact
                Expanded(
                  flex: 2,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Save Location',
        style: TextStyle(
          color: Colors.white,
                          fontSize: isCompact ? 14 : 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 6),
                      GestureDetector(
                        onTap: _pickSaveFolder,
                        child: Container(
                          height: 40,
                          padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
                            color: Colors.grey[800],
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: Colors.grey[700]!, width: 1),
      ),
      child: Row(
        children: [
          Icon(
            Icons.folder_rounded,
            color: Colors.yellow[300],
                                size: 16,
          ),
                              const SizedBox(width: 6),
          Expanded(
            child: Text(
                                  _saveFolder != null 
                                      ? (_saveFolder!.contains('/Download') 
                                          ? 'Downloads/ZapShare' 
                                          : _saveFolder!.split('/').last)
                                      : 'Downloads/ZapShare (default)',
              style: TextStyle(
                                    color: _saveFolder != null 
                                        ? Colors.white 
                                        : Colors.grey[400],
                                    fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
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
            ),
          ),
          
          // Recent codes - compact horizontal
          if (_recentCodes.isNotEmpty) ...[
            Container(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: _buildCompactRecentCodes(),
            ),
          ],
          
          // Connection status - compact
          if (_serverIp != null) ...[
            Container(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      child: Row(
        children: [
          Container(
            width: 6,
            height: 6,
                    decoration: const BoxDecoration(
              color: Colors.green,
              shape: BoxShape.circle,
            ),
          ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Connected to $_serverIp',
                      style: const TextStyle(
                        color: Colors.green,
                        fontSize: 12,
              fontWeight: FontWeight.w500,
              fontFamily: 'monospace',
            ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }


  // Compact recent codes for smaller space
  Widget _buildCompactRecentCodes() {
    final screenWidth = MediaQuery.of(context).size.width;
    final isCompact = screenWidth < 400;
    
    return SizedBox(
      height: 32,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: _recentCodes.length,
        itemBuilder: (context, index) {
          final code = _recentCodes[index];
    return Container(
            margin: const EdgeInsets.only(right: 8),
            child: GestureDetector(
              onTap: () {
                _codeController.text = code;
                _fetchFileList(code);
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
                  color: Colors.yellow[300],
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.yellow[300]!.withOpacity(0.3),
                      blurRadius: 4,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                  child: Text(
                  code,
                    style: TextStyle(
                    color: Colors.black,
                    fontSize: isCompact ? 13 : 14,
                      fontWeight: FontWeight.w600,
                    fontFamily: 'monospace',
                    letterSpacing: 0.5,
                    ),
                  ),
                ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildLoadingState() {
    return Container(
      padding: const EdgeInsets.all(40),
      child: Column(
        children: [
          CircularProgressIndicator(
            color: Colors.yellow[300],
            strokeWidth: 3,
          ),
          const SizedBox(height: 20),
          const Text(
            'Connecting...',
            style: TextStyle(
              color: Colors.white,
              fontSize: 17,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Please wait while we connect to the server',
              style: TextStyle(
              color: Colors.grey,
              fontSize: 15,
              fontWeight: FontWeight.w400,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }


  // Downloaded file item
  Widget _buildDownloadedFileItem(DownloadTask task) {
    final fileType = _getFileType(task.fileName);
    final screenWidth = MediaQuery.of(context).size.width;
    final isCompact = screenWidth < 400;
    
        return Container(
      margin: const EdgeInsets.symmetric(vertical: 3),
      padding: EdgeInsets.all(isCompact ? 10 : 12),
          decoration: BoxDecoration(
            color: Colors.grey[800],
            borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey[700]!, width: 1),
      ),
                child: Row(
                  children: [
                    // File icon
                    Container(
            width: isCompact ? 32 : 36,
            height: isCompact ? 32 : 36,
                      decoration: BoxDecoration(
              color: Colors.yellow[300],
              borderRadius: BorderRadius.circular(8),
                      ),
                            child: Icon(
              _getFileTypeIcon(fileType),
              color: Colors.black,
              size: isCompact ? 18 : 20,
            ),
          ),
          SizedBox(width: isCompact ? 10 : 12),
                    
                    // File info
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            task.fileName,
                            style: TextStyle(
                              color: Colors.white,
                    fontSize: isCompact ? 15 : 16,
                              fontWeight: FontWeight.w600,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                const SizedBox(height: 2),
                          Text(
                            _formatBytes(task.fileSize),
                            style: TextStyle(
                    color: Colors.grey,
                    fontSize: isCompact ? 12 : 13,
                    fontWeight: FontWeight.w400,
                            ),
                          ),
                        ],
                      ),
                    ),
                    
                    // Open button
          GestureDetector(
            onTap: () => _openFileByType(task.savePath, task.fileName),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                color: Colors.yellow[300],
                borderRadius: BorderRadius.circular(6),
              ),
              child: const Text(
                            'Open',
                            style: TextStyle(
                  color: Colors.black,
                  fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                      ),
                    ),
                  ],
      ),
    );
  }


  // Available file item
  Widget _buildAvailableFileItem(DownloadTask task, int index) {
    final fileType = _getFileType(task.fileName);
    final isSelected = task.isSelected;
    final isDownloading = task.status == 'Downloading';
    
    final screenWidth = MediaQuery.of(context).size.width;
    final isCompact = screenWidth < 400;
    
    return GestureDetector(
      onTap: () => _toggleFileSelection(index),
      onLongPress: () {
        if (fileType == FileType.image) {
          _showImagePreview(task);
        }
      },
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 3),
        padding: EdgeInsets.all(isCompact ? 10 : 12),
          decoration: BoxDecoration(
            color: Colors.grey[800],
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
            color: isSelected ? Colors.yellow[300]! : Colors.grey[700]!,
            width: isSelected ? 2 : 1,
          ),
        ),
                child: Row(
                  children: [
                    // Selection checkbox
                    Container(
                      width: 20,
                      height: 20,
                      decoration: BoxDecoration(
                color: isSelected ? Colors.yellow[300] : Colors.transparent,
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(
                  color: isSelected ? Colors.yellow[300]! : Colors.grey[600]!,
                          width: 2,
                        ),
                      ),
              child: isSelected
                  ? const Icon(
                      Icons.check,
                              color: Colors.black,
                      size: 12,
                            )
                          : null,
                    ),
          SizedBox(width: isCompact ? 10 : 12),
                    
                    // File icon
                    Container(
            width: isCompact ? 32 : 36,
            height: isCompact ? 32 : 36,
                      decoration: BoxDecoration(
                        color: Colors.yellow[300],
              borderRadius: BorderRadius.circular(8),
                      ),
                            child: Icon(
              _getFileTypeIcon(fileType),
                              color: Colors.black,
              size: isCompact ? 18 : 20,
            ),
          ),
          SizedBox(width: isCompact ? 10 : 12),
                    
                    // File info
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            task.fileName,
                            style: TextStyle(
                              color: Colors.white,
                    fontSize: isCompact ? 15 : 16,
                              fontWeight: FontWeight.w600,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                const SizedBox(height: 2),
                Row(
                  children: [
                          Text(
                            _formatBytes(task.fileSize),
                            style: TextStyle(
                        color: Colors.grey,
                        fontSize: isCompact ? 12 : 13,
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                    if (isDownloading) ...[
                      const SizedBox(width: 8),
                      Text(
                        '${(task.progress * 100).toStringAsFixed(0)}%',
                                style: TextStyle(
                          color: Colors.yellow[300],
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ],
                            ),
                        ],
                      ),
                    ),
                    
            // Action buttons
            if (isDownloading) ...[
              // Progress indicator
                      Container(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                              value: task.progress,
                  backgroundColor: Colors.grey[600]!,
                              color: Colors.yellow[300],
                              strokeWidth: 2,
                            ),
              ),
            ] else if (task.status == 'Completed') ...[
              // Completed indicator
                            Container(
                padding: const EdgeInsets.all(6),
                              decoration: BoxDecoration(
                  color: Colors.green,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Icon(
                  Icons.check,
                                      color: Colors.white,
                  size: 16,
                        ),
                      ),
                    ],
                  ],
            ),
          ),
    );
  }

  // Download button
  Widget _buildDownloadButton() {
    final selectedCount = _tasks.where((t) => t.isSelected).length;
    final isEnabled = selectedCount > 0 && !_downloading;
    
    return Container(
      width: double.infinity,
      height: 48,
      decoration: BoxDecoration(
        color: isEnabled ? Colors.yellow[300] : Colors.grey[700],
        borderRadius: BorderRadius.circular(12),
        boxShadow: isEnabled ? [
          BoxShadow(
            color: Colors.yellow[300]!.withOpacity(0.3),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ] : null,
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: isEnabled ? _startDownloads : null,
          borderRadius: BorderRadius.circular(12),
          child: Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.download_rounded,
                  color: isEnabled ? Colors.black : Colors.grey[400],
                  size: 18,
                ),
                const SizedBox(width: 6),
                Text(
                  selectedCount > 0 
                      ? 'Download $selectedCount File${selectedCount > 1 ? 's' : ''}'
                      : 'Select Files to Download',
                  style: TextStyle(
                    color: isEnabled ? Colors.black : Colors.grey[400],
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Container(
      padding: const EdgeInsets.all(40),
      child: Column(
        children: [
          Container(
            width: 80,
            height: 80,
        decoration: BoxDecoration(
          color: Colors.grey[900],
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.grey[800]!, width: 1),
        ),
            child: Icon(
              Icons.folder_open_rounded,
              color: Colors.grey[600],
              size: 40,
            ),
          ),
          const SizedBox(height: 24),
          const Text(
            'No Files Found',
            style: TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Make sure the sender is sharing files\nand both devices are on the same network',
            style: TextStyle(
              color: Colors.grey,
              fontSize: 15,
              fontWeight: FontWeight.w400,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 32),
          GestureDetector(
            onTap: () => _fetchFileList(_codeController.text.trim()),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              decoration: BoxDecoration(
                color: Colors.yellow[300],
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text(
                'Try Again',
                style: TextStyle(
                  color: Colors.black,
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

} 