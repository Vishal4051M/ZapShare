import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:saf_stream/saf_stream.dart';
import 'package:saf_util/saf_util.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'dart:convert';
import 'dart:math';
import '../services/device_discovery_service.dart';
import '../widgets/connection_request_dialog.dart';

const Color kAndroidAccentYellow = Colors.yellow; // lighter yellow for Android

// Class to track download status for each client
class DownloadStatus {
  final String clientIP;
  final int fileIndex;
  final String fileName;
  final int fileSize;
  double progress;
  int bytesSent;
  bool isCompleted;
  DateTime startTime;
  DateTime? completionTime;
  double speedMbps;

  DownloadStatus({
    required this.clientIP,
    required this.fileIndex,
    required this.fileName,
    required this.fileSize,
    this.progress = 0.0,
    this.bytesSent = 0,
    this.isCompleted = false,
    required this.startTime,
    this.completionTime,
    this.speedMbps = 0.0,
  });
}

class HttpFileShareScreen extends StatefulWidget {
  const HttpFileShareScreen({super.key});

  @override
  _HttpFileShareScreenState createState() => _HttpFileShareScreenState();
}

class _HttpFileShareScreenState extends State<HttpFileShareScreen> {
  final _pageController = PageController();
  final _safUtil = SafUtil();
  List<String> _fileUris = [];
  List<String> _fileNames = [];

  String? _localIp;
  HttpServer? _server;
  bool _isSharing = false;
  final safStream = SafStream();
  bool _loading = false;
  String? initialUri;
  List<String>? mimeTypes;
  final bool _multipleFiles = true;

  // Per-file progress and pause state for parallel transfers
  List<ValueNotifier<double>> _progressList = [];
  List<ValueNotifier<bool>> _isPausedList = [];
  List<int> _bytesSentList = [];
  List<int> _fileSizeList = [];
  List<bool> _completedFiles = []; // Added for tracking completion
  
  // Track downloads per client for multiple simultaneous downloads
  Map<String, Map<int, DownloadStatus>> _clientDownloads = {}; // clientIP -> {fileIndex -> DownloadStatus}
  List<String> _connectedClients = []; // List of connected client IPs
  Map<String, String> _clientDeviceNames = {}; // clientIP -> deviceName mapping

  final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();

  // Device Discovery
  final DeviceDiscoveryService _discoveryService = DeviceDiscoveryService();
  List<DiscoveredDevice> _nearbyDevices = [];
  StreamSubscription? _devicesSubscription;
  StreamSubscription? _connectionRequestSubscription;
  StreamSubscription? _connectionResponseSubscription;
  bool _showNearbyDevices = true;
  String? _pendingRequestDeviceIp;
  Timer? _requestTimeoutTimer;
  DiscoveredDevice? _pendingDevice;


  String _ipToCode(String ip) {
    final parts = ip.split('.').map(int.parse).toList();
    if (parts.length != 4) return '';
    int n = (parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3];
    String code = n.toRadixString(36).toUpperCase();
    return code.padLeft(8, '0');
  }

 

  String _getFileExtension(String fileName) {
    final lastDotIndex = fileName.lastIndexOf('.');
    if (lastDotIndex == -1 || lastDotIndex == fileName.length - 1) {
      return ''; // No extension or ends with dot
    }
    return fileName.substring(lastDotIndex + 1);
  }

  String _getMimeTypeFromExtension(String ext) {
    switch (ext.toLowerCase()) {
      // Images
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'png':
        return 'image/png';
      case 'gif':
        return 'image/gif';
      case 'bmp':
        return 'image/bmp';
      case 'webp':
        return 'image/webp';
      case 'svg':
        return 'image/svg+xml';
      case 'ico':
        return 'image/x-icon';
      case 'tiff':
      case 'tif':
        return 'image/tiff';
      case 'heic':
        return 'image/heic';
      case 'heif':
        return 'image/heif';
      case 'avif':
        return 'image/avif';
      case 'jxl':
        return 'image/jxl';

      // Videos
      case 'mp4':
        return 'video/mp4';
      case 'avi':
        return 'video/x-msvideo';
      case 'mov':
        return 'video/quicktime';
      case 'wmv':
        return 'video/x-ms-wmv';
      case 'flv':
        return 'video/x-flv';
      case 'webm':
        return 'video/webm';
      case 'mkv':
        return 'video/x-matroska';
      case 'm4v':
        return 'video/x-m4v';
      case '3gp':
        return 'video/3gpp';
      case 'ogv':
        return 'video/ogg';
      case 'ts':
        return 'video/mp2t';
      case 'mts':
        return 'video/mp2t';
      case 'm2ts':
        return 'video/mp2t';
      case 'divx':
        return 'video/divx';
      case 'xvid':
        return 'video/xvid';

      // Audio
      case 'mp3':
        return 'audio/mpeg';
      case 'wav':
        return 'audio/wav';
      case 'flac':
        return 'audio/flac';
      case 'aac':
        return 'audio/aac';
      case 'ogg':
        return 'audio/ogg';
      case 'opus':
        return 'audio/opus';
      case 'wma':
        return 'audio/x-ms-wma';
      case 'm4a':
        return 'audio/mp4';
      case 'aiff':
        return 'audio/aiff';
      case 'au':
        return 'audio/basic';
      case 'mid':
      case 'midi':
        return 'audio/midi';
      case 'amr':
        return 'audio/amr';
      case '3ga':
        return 'audio/3gpp';

      // Documents
      case 'pdf':
        return 'application/pdf';
      case 'doc':
        return 'application/msword';
      case 'docx':
        return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
      case 'xls':
        return 'application/vnd.ms-excel';
      case 'xlsx':
        return 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
      case 'ppt':
        return 'application/vnd.ms-powerpoint';
      case 'pptx':
        return 'application/vnd.openxmlformats-officedocument.presentationml.presentation';
      case 'odt':
        return 'application/vnd.oasis.opendocument.text';
      case 'ods':
        return 'application/vnd.oasis.opendocument.spreadsheet';
      case 'odp':
        return 'application/vnd.oasis.opendocument.presentation';
      case 'rtf':
        return 'application/rtf';
      case 'txt':
        return 'text/plain';
      case 'csv':
        return 'text/csv';
      case 'html':
      case 'htm':
        return 'text/html';
      case 'xml':
        return 'application/xml';
      case 'json':
        return 'application/json';
      case 'yaml':
      case 'yml':
        return 'application/x-yaml';

      // Archives
      case 'zip':
        return 'application/zip';
      case 'rar':
        return 'application/vnd.rar';
      case '7z':
        return 'application/x-7z-compressed';
      case 'tar':
        return 'application/x-tar';
      case 'gz':
        return 'application/gzip';
      case 'bz2':
        return 'application/x-bzip2';
      case 'xz':
        return 'application/x-xz';
      case 'lzma':
        return 'application/x-lzma';
      case 'cab':
        return 'application/vnd.ms-cab-compressed';
      case 'iso':
        return 'application/x-iso9660-image';

      // Executables and Packages
      case 'exe':
        return 'application/x-msdownload';
      case 'msi':
        return 'application/x-msi';
      case 'deb':
        return 'application/vnd.debian.binary-package';
      case 'rpm':
        return 'application/x-rpm';
      case 'apk':
        return 'application/vnd.android.package-archive';
      case 'ipa':
        return 'application/octet-stream';
      case 'dmg':
        return 'application/x-apple-diskimage';
      case 'pkg':
        return 'application/vnd.apple.installer+xml';
      case 'app':
        return 'application/x-executable';

      // Programming and Development
      case 'java':
        return 'text/x-java-source';
      case 'class':
        return 'application/java-vm';
      case 'jar':
        return 'application/java-archive';
      case 'py':
        return 'text/x-python';
      case 'pyc':
        return 'application/x-python-code';
      case 'js':
        return 'application/javascript';
      case 'ts':
        return 'application/typescript';
      case 'php':
        return 'application/x-httpd-php';
      case 'rb':
        return 'application/x-ruby';
      case 'cpp':
      case 'cc':
        return 'text/x-c++src';
      case 'c':
        return 'text/x-csrc';
      case 'h':
        return 'text/x-chdr';
      case 'cs':
        return 'text/x-csharp';
      case 'swift':
        return 'text/x-swift';
      case 'kt':
        return 'text/x-kotlin';
      case 'go':
        return 'text/x-go';
      case 'rs':
        return 'text/x-rust';
      case 'scala':
        return 'text/x-scala';
      case 'pl':
        return 'text/x-perl';
      case 'sh':
        return 'application/x-sh';
      case 'bat':
        return 'application/x-msdos-program';
      case 'ps1':
        return 'application/x-powershell';

      // Web and Markup
      case 'css':
        return 'text/css';
      case 'scss':
        return 'text/x-scss';
      case 'sass':
        return 'text/x-sass';
      case 'less':
        return 'text/x-less';
      case 'md':
      case 'markdown':
        return 'text/markdown';
      case 'tex':
        return 'application/x-tex';
      case 'latex':
        return 'application/x-latex';

      // Database
      case 'sql':
        return 'application/sql';
      case 'db':
        return 'application/x-sqlite3';
      case 'sqlite':
        return 'application/x-sqlite3';

      // Fonts
      case 'ttf':
        return 'font/ttf';
      case 'otf':
        return 'font/otf';
      case 'woff':
        return 'font/woff';
      case 'woff2':
        return 'font/woff2';
      case 'eot':
        return 'application/vnd.ms-fontobject';

      // CAD and 3D
      case 'dwg':
        return 'application/acad';
      case 'dxf':
        return 'application/dxf';
      case 'obj':
        return 'text/plain';
      case 'stl':
        return 'application/sla';
      case 'fbx':
        return 'application/octet-stream';
      case 'blend':
        return 'application/x-blender';

      // E-books
      case 'epub':
        return 'application/epub+zip';
      case 'mobi':
        return 'application/x-mobipocket-ebook';
      case 'azw':
        return 'application/vnd.amazon.ebook';
      case 'azw3':
        return 'application/vnd.amazon.ebook';

      // Virtual Machines
      case 'vmdk':
        return 'application/x-vmdk';
      case 'vdi':
        return 'application/x-vdi';
      case 'vhd':
        return 'application/x-vhd';
      case 'ova':
        return 'application/x-ovf';
      case 'ovf':
        return 'application/x-ovf';

      // Configuration and Settings
      case 'ini':
        return 'text/plain';
      case 'conf':
        return 'text/plain';
      case 'cfg':
        return 'text/plain';
      case 'config':
        return 'text/plain';
      case 'env':
        return 'text/plain';
      case 'properties':
        return 'text/plain';

      // Logs
      case 'log':
        return 'text/plain';

      // Certificates and Keys
      case 'pem':
        return 'application/x-pem-file';
      case 'crt':
        return 'application/x-x509-ca-cert';
      case 'key':
        return 'application/x-pkcs8';
      case 'p12':
        return 'application/x-pkcs12';
      case 'pfx':
        return 'application/x-pkcs12';

      // Other Common Types
      case 'torrent':
        return 'application/x-bittorrent';
      case 'ics':
        return 'text/calendar';
      case 'vcf':
        return 'text/vcard';
      case 'ics':
        return 'text/calendar';
      case 'eml':
        return 'message/rfc822';
      case 'msg':
        return 'application/vnd.ms-outlook';

      default:
        return 'application/octet-stream'; // fallback for unknown types
    }
  }

  String formatBytes(int bytes) {
    if (bytes < 1024) return "$bytes B";
    if (bytes < 1024 * 1024) return "${(bytes / 1024).toStringAsFixed(1)} KB";
    if (bytes < 1024 * 1024 * 1024) return "${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB";
    return "${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB";
  }

  static const MethodChannel _platform = MethodChannel('zapshare.saf');

  @override
  void initState() {
    super.initState();
    _init();
    _initLocalNotifications();
    _listenForSharedFiles();
    
    // Initialize device discovery
    _initDeviceDiscovery();
    
    // Periodically cleanup disconnected clients
    Timer.periodic(Duration(minutes: 2), (timer) {
      if (mounted) {
        _cleanupDisconnectedClients();
      }
    });
  }

  void _listenForSharedFiles() {
    _platform.setMethodCallHandler((call) async {
      if (call.method == 'sharedFiles') {
        final List<dynamic> files = call.arguments as List<dynamic>;
        if (files.isNotEmpty) {
          await _handleSharedFiles(files.cast<Map>());
        }
      }
      return null;
    });
  }

  
  Future<String> getConnectedIps() async {
    try {
      print("Attempting to get hotspot IP...");
      final String result = await _platform.invokeMethod('getGatewayIp');
      print("Hotspot IP obtained: $result");
      if (result.isNotEmpty && result != "0.0.0.0") {
        return result;
      } else {
        print("Empty or invalid hotspot IP received, using fallback");
        return '192.168.8.1';
      }
    } catch (e) {
      print("Failed to get hotspot IP: $e");
      return '192.168.8.1';
    }
  }
  Future<void> _handleSharedFiles(List<Map> files) async {
    setState(() => _loading = true);
    List<String> uris = [];
    List<String> names = [];
    List<int> sizes = [];
    for (final file in files) {
      final uri = file['uri'] as String;
      final name = file['name'] as String? ?? uri.split('/').last;
      int size = 0;
      try {
        size = await getFileSizeFromUri(uri);
      } catch (_) {}
      uris.add(uri);
      names.add(name);
      sizes.add(size);
    }
    setState(() {
      _fileUris = uris;
      _fileNames = names;
      _progressList = List.generate(uris.length, (_) => ValueNotifier(0.0));
      _isPausedList = List.generate(uris.length, (_) => ValueNotifier(false));
      _bytesSentList = List.generate(uris.length, (_) => 0);
      _fileSizeList = sizes;
      _completedFiles = List.generate(uris.length, (_) => false); // Initialize completedFiles
      _loading = false;
    });
  }

  Future<void> _init() async {
    await _clearCache();
    await _fetchLocalIp();
    _showConnectionTip();
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
          if (idx != null && idx < _isPausedList.length) {
            _isPausedList[idx].value = true;
          }
        } else if (actionId.startsWith('resume_')) {
          final idx = int.tryParse(actionId.substring(7));
          if (idx != null && idx < _isPausedList.length) {
            _isPausedList[idx].value = false;
          }
        }
      },
    );
  }

  Future<void> showProgressNotification(int fileIndex, double progress, String fileName, {double speedMbps = 0.0, bool paused = false}) async {
    final percent = (progress * 100).toStringAsFixed(1);
    final body = '$fileName\nProgress: $percent%\nSpeed: ${speedMbps.toStringAsFixed(2)} Mbps';
    final androidPlatformChannelSpecifics = AndroidNotificationDetails(
      'progress_channel_$fileIndex',
      'File Transfer Progress $fileIndex',
      channelDescription: 'Shows the progress of file transfer $fileIndex',
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
      1000 + fileIndex,
      'ZapShare Transfer',
      body,
      platformChannelSpecifics,
      payload: 'progress',
    );
  }

  Future<void> cancelProgressNotification(int fileIndex) async {
    await flutterLocalNotificationsPlugin.cancel(1000 + fileIndex);
  }

  final MethodChannel _channel = const MethodChannel('zapshare.saf');

  Future<void> serveSafFile(HttpRequest request, {
    required int fileIndex,
    required String uri,
    required String fileName,
    required int fileSize,
    int chunkSize = 262144, // 256KB - optimized for release builds
  }) async {
    final response = request.response;
    
    // Get client IP for tracking individual downloads
    final clientIP = request.connectionInfo?.remoteAddress.address ?? 'unknown';
    print('Client $clientIP started downloading file: $fileName (File size: $fileSize bytes)');
    
    // Initialize client download tracking
    if (!_clientDownloads.containsKey(clientIP)) {
      _clientDownloads[clientIP] = {};
      if (!_connectedClients.contains(clientIP)) {
        _connectedClients.add(clientIP);
      }
    }
    
    // Create or update download status for this client
    final downloadStatus = DownloadStatus(
      clientIP: clientIP,
      fileIndex: fileIndex,
      fileName: fileName,
      fileSize: fileSize,
      startTime: DateTime.now(),
    );
    _clientDownloads[clientIP]![fileIndex] = downloadStatus;
    
    int bytesSent = 0;
    _progressList[fileIndex].value = 0.0;
    _fileSizeList[fileIndex] = fileSize;
    _bytesSentList[fileIndex] = 0;

    DateTime lastUpdate = DateTime.now();
    double lastProgress = 0.0;
    int lastBytes = 0;
    DateTime lastSpeedTime = DateTime.now();
    double speedMbps = 0.0;

    try {
      // Set headers
      response.statusCode = HttpStatus.ok;
      response.headers.set('Content-Length', fileSize.toString());
      response.headers.set('Content-Type', 'application/octet-stream');
      response.headers.set('Content-Disposition', 'attachment; filename="$fileName"');

      // Open stream
      print('Opening stream for file $fileIndex: $fileName');
      final opened = await MethodChannel('zapshare.saf')
          .invokeMethod<bool>('openReadStream', {
            'uri': uri,
          });
      if (opened != true) {
        print('Failed to open stream for file $fileIndex: $fileName');
        response.statusCode = HttpStatus.internalServerError;
        response.write('Could not open SAF stream.');
        await response.close();
        return;
      }
      print('Successfully opened stream for file $fileIndex: $fileName');

      // Stream file in chunks
      bool done = false;
      while (!done) {
        // Pause logic
        while (_isPausedList[fileIndex].value) {
          await Future.delayed(Duration(milliseconds: 200));
        }
        try {
          final chunk = await MethodChannel('zapshare.saf')
              .invokeMethod<Uint8List>('readChunk', {
                'uri': uri, 
                'size': chunkSize,
              });

          if (chunk == null || chunk.isEmpty) {
            print('File $fileIndex: End of stream reached. Total bytes sent: $bytesSent');
            done = true;
          } else {
            response.add(chunk);
            bytesSent += chunk.length;
            _bytesSentList[fileIndex] = bytesSent;
            double progress = bytesSent / fileSize;
            
            // Force flush response in release builds to ensure data is sent
            // Use more aggressive flushing for release builds
            if (bytesSent % (chunkSize * 2) == 0) {
              await response.flush();
            }
            
            // Debug logging for release builds
            if (bytesSent % (1024 * 1024) == 0) { // Log every MB
              print('File $fileIndex: Sent ${bytesSent}/${fileSize} bytes (${(progress * 100).toStringAsFixed(1)}%)');
            }
            
            // Update client-specific download status
            if (_clientDownloads.containsKey(clientIP) && 
                _clientDownloads[clientIP]!.containsKey(fileIndex)) {
              _clientDownloads[clientIP]![fileIndex]!.bytesSent = bytesSent;
              _clientDownloads[clientIP]![fileIndex]!.progress = progress;
            }

            // Speed calculation
            final now = DateTime.now();
            final elapsed = now.difference(lastSpeedTime).inMilliseconds;
            if (elapsed > 0) {
              final bytesDelta = bytesSent - lastBytes;
              speedMbps = (bytesDelta * 8) / (elapsed * 1000); // Mbps
              lastBytes = bytesSent;
              lastSpeedTime = now;
              
              // Update speed in client download status
              if (_clientDownloads.containsKey(clientIP) && 
                  _clientDownloads[clientIP]!.containsKey(fileIndex)) {
                _clientDownloads[clientIP]![fileIndex]!.speedMbps = speedMbps;
              }
            }

            // Throttle updates: only update if 100ms passed or progress increased by 100%
            if (now.difference(lastUpdate).inMilliseconds > 100 ||
                (progress - lastProgress) > 0.01) {
              _progressList[fileIndex].value = progress;
              await showProgressNotification(
                fileIndex,
                progress,
                fileName,
                speedMbps: speedMbps,
                paused: _isPausedList[fileIndex].value,
              );
              lastUpdate = now;
              lastProgress = progress;
              
              // Check if progress reached 100% for this file
              if (progress >= 1.0) {
                print('File $fileName reached 100% progress for client $clientIP');
                // Mark as completed immediately
                if (_clientDownloads.containsKey(clientIP) && 
                    _clientDownloads[clientIP]!.containsKey(fileIndex)) {
                  _clientDownloads[clientIP]![fileIndex]!.isCompleted = true;
                  _clientDownloads[clientIP]![fileIndex]!.completionTime = DateTime.now();
                  _clientDownloads[clientIP]![fileIndex]!.progress = 1.0;
                }
                if (_completedFiles.length > fileIndex) {
                  _completedFiles[fileIndex] = true;
                }
                break; // Exit the streaming loop since file is complete
              }
            }
            // Final flush to ensure all data is sent
            await response.flush();
          }
        } catch (e) {
          print('Stream error: $e');
          response.statusCode = HttpStatus.internalServerError;
          break;
        }
      }
    } catch (e) {
      print('Serve file error: $e');
      response.statusCode = HttpStatus.internalServerError;
    } finally {
      await MethodChannel('zapshare.saf')
          .invokeMethod('closeStream', {
            'uri': uri,
          });
      await response.close();
      
      // Mark file as completed for this specific client
      if (_clientDownloads.containsKey(clientIP) && 
          _clientDownloads[clientIP]!.containsKey(fileIndex)) {
        _clientDownloads[clientIP]![fileIndex]!.isCompleted = true;
        _clientDownloads[clientIP]![fileIndex]!.completionTime = DateTime.now();
        _clientDownloads[clientIP]![fileIndex]!.progress = 1.0;
        print('File $fileName completed for client $clientIP');
      }
      
      // Mark file as completed globally (for backward compatibility)
      if (_completedFiles.length > fileIndex) {
        _completedFiles[fileIndex] = true;
      }
      
      // Reset progress
      _progressList[fileIndex].value = 0.0;
      _bytesSentList[fileIndex] = 0;
      _fileSizeList[fileIndex] = 0;
      await cancelProgressNotification(fileIndex);
      
      // Record transfer history
      try {
        final prefs = await SharedPreferences.getInstance();
        final history = prefs.getStringList('transfer_history') ?? [];
        final entry = {
          'fileName': fileName,
          'fileSize': fileSize,
          'direction': 'Sent',
          'peer': clientIP, // Record the actual client IP
          'peerDeviceName': _clientDeviceNames[clientIP], // Record device name if available
          'dateTime': DateTime.now().toIso8601String(),
        };
        history.insert(0, jsonEncode(entry));
        if (history.length > 100) history.removeLast();
        await prefs.setStringList('transfer_history', history);
      } catch (_) {}
      
      // Check if all files are completed and auto-stop sharing
      _checkAndAutoStopSharing();
    }
  }

  Future<void> _clearCache() async {
    final dir = await getTemporaryDirectory();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  }

  Future<void> _fetchLocalIp() async {
    final info = NetworkInfo();
    String? ip;
    
    try {
      ip = await info.getWifiIP();
      print("WiFi IP obtained: $ip");
    } catch (e) {
      print("Failed to get WiFi IP: $e");
    }
    
    String finalIp;
    if (ip != null && ip.isNotEmpty && ip != "0.0.0.0") {
      finalIp = ip;
      print("Using WiFi IP: $finalIp");
    } else {
      try {
        finalIp = await getConnectedIps();
        print("Using hotspot/gateway IP: $finalIp");
      } catch (e) {
        print("Failed to get hotspot IP: $e");
        finalIp = '192.168.8.1'; // Default hotspot IP
        print("Using fallback IP: $finalIp");
      }
    }
    
    setState(() => _localIp = finalIp);
  }

  Future<void> _refreshIp() async {
    setState(() => _loading = true);
    await _fetchLocalIp();
    setState(() => _loading = false);
  }

  Future<void> _showConnectionTip() async {
    final prefs = await SharedPreferences.getInstance();
    final showTip = prefs.getBool('showConnectionTip') ?? true;
    if (!showTip) return;

    bool dontShowAgain = false;
    await Future.delayed(Duration(milliseconds: 500));
    showDialog(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          backgroundColor: Colors.yellow.shade50,
          title: Text("Connection Tip", style: TextStyle(color: Colors.black)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text("Ensure devices are on the same network or hotspot.",
                  style: TextStyle(color: Colors.black)),
              Row(
                children: [
                  Checkbox(
                    value: dontShowAgain,
                    activeColor: Colors.white,
                    checkColor: Colors.black,
                    onChanged: (val) =>
                        setState(() => dontShowAgain = val ?? false),
                  ),
                  Text("Don't show again", style: TextStyle(color: Colors.black)),
                ],
              )
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                if (dontShowAgain) prefs.setBool('showConnectionTip', false);
                Navigator.of(context).pop();
              },
              child: Text("Got it!", style: TextStyle(color: Colors.black)),
            )
          ],
        ),
      ),
    );
  }

  Future<int> getFileSizeFromUri(String uri) async {
    final size = await const MethodChannel('zapshare.saf')
        .invokeMethod<int>('getFileSize', {'uri': uri});
    if (size == null) throw Exception('Could not get file size for $uri');
    return size;
  }

  Future<void> _selectFiles() async {
    HapticFeedback.mediumImpact();
    setState(() => _loading = true);

    final result = await _safUtil.pickFiles(
      multiple: _multipleFiles,
      mimeTypes: mimeTypes,
      initialUri: initialUri,
    );

    if (result != null) {
      List<String> uris = [];
      List<String> names = [];
      List<int> sizes = [];
      for (final docFile in result) {
        uris.add(docFile.uri);
        names.add(docFile.name);
        try {
          final size = await getFileSizeFromUri(docFile.uri);
          sizes.add(size);
        } catch (_) {
          sizes.add(0);
        }
      }
      setState(() {
        // Append to existing lists instead of replacing
        _fileUris.addAll(uris);
        _fileNames.addAll(names);
        _progressList.addAll(List.generate(uris.length, (_) => ValueNotifier(0.0)));
        _isPausedList.addAll(List.generate(uris.length, (_) => ValueNotifier(false)));
        _bytesSentList.addAll(List.generate(uris.length, (_) => 0));
        _fileSizeList.addAll(sizes);
        _completedFiles.addAll(List.generate(uris.length, (_) => false)); // Initialize completedFiles
        _loading = false;
      });
    } else {
      setState(() => _loading = false);
    }
  }

  String? _displayCode;

  Future<void> _startServer() async {
    if (_fileUris.isEmpty) return;
    HapticFeedback.mediumImpact();
    await FlutterForegroundTask.startService(
      notificationTitle: "ZapShare Transfer",
      notificationText: "Sharing file(s)...",
    );
    await _server?.close(force: true);
    _server = await HttpServer.bind(InternetAddress.anyIPv4, 8080);
    // Generate 8-char code for sharing (just IP)
    final codeForUser = _ipToCode(_localIp ?? '');
    setState(() {
      _displayCode = codeForUser;
    });
    _server!.listen((HttpRequest request) async {
      final path = request.uri.path;
      
      // Serve web interface at root
      if (path == '/' || path == '/index.html') {
        await _serveWebInterface(request);
        return;
      }
      
      if (path == '/list') {
        // Serve file list as JSON
        final list = List.generate(_fileNames.length, (i) => {
          'index': i,
          'name': _fileNames[i],
          'size': _fileSizeList.length > i ? _fileSizeList[i] : 0,
        });
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(list));
        await request.response.close();
        return;
      }
      
      final segments = request.uri.pathSegments;
      if (segments.length == 2 && segments[0] == 'file') {
        final index = int.tryParse(segments[1]);
        if (index == null || index >= _fileUris.length) {
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
          return;
        }
        final uri = _fileUris[index];
        final name = _fileNames[index];
        final fileSize = _fileSizeList.length > index ? _fileSizeList[index] : 0;
        final ext = _getFileExtension(name).toLowerCase();
        final mimeType = _getMimeTypeFromExtension(ext);
        try {
          request.response.headers.contentType = ContentType.parse(mimeType);
          request.response.headers.set(
            'Content-Disposition',
            'attachment; filename="$name"',
          );
          await serveSafFile(
            request,
            fileIndex: index,
            uri: uri,
            fileName: name,
            fileSize: fileSize,
          );
        } catch (e) {
          print('Error streaming file: $e');
          request.response.statusCode = HttpStatus.internalServerError;
          await request.response.close();
        }
        return;
      }
      
      // 404 for other paths
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
    });
    setState(() => _isSharing = true);
  }

  Future<void> _stopServer() async {
    HapticFeedback.mediumImpact();
    setState(() => _loading = true);
    await _server?.close(force: true);
    await FlutterForegroundTask.stopService();
    setState(() {
      _isSharing = false;
      _loading = false;
    });
  }

  void _clearAllFiles() {
    HapticFeedback.heavyImpact();
    setState(() {
      _fileUris.clear();
      _fileNames.clear();
      _progressList.clear();
      _isPausedList.clear();
      _bytesSentList.clear();
      _fileSizeList.clear();
      _completedFiles.clear(); // Clear completed files
      _clientDownloads.clear(); // Clear client downloads
      _connectedClients.clear(); // Clear connected clients
    });
  }

  void _deleteFile(int index) {
    if (index < 0 || index >= _fileUris.length) return;
    
    HapticFeedback.mediumImpact();
    
    setState(() {
      // Remove from all lists
      _fileUris.removeAt(index);
      _fileNames.removeAt(index);
      _progressList.removeAt(index);
      _isPausedList.removeAt(index);
      _bytesSentList.removeAt(index);
      _fileSizeList.removeAt(index);
      _completedFiles.removeAt(index);
      
      // Clean up client downloads for this file index
      for (final clientIP in _clientDownloads.keys) {
        _clientDownloads[clientIP]?.remove(index);
      }
    });
  }

  void _togglePause(int index) {
    if (index < _isPausedList.length) {
      _isPausedList[index].value = !_isPausedList[index].value;
      // Add haptic feedback
      HapticFeedback.lightImpact();
    }
  }

  // Clean up disconnected clients
  void _cleanupDisconnectedClients() {
    final now = DateTime.now();
    final disconnectedClients = <String>[];
    
    for (final clientIP in _connectedClients) {
      bool hasActiveDownloads = false;
      
      if (_clientDownloads.containsKey(clientIP)) {
        for (final download in _clientDownloads[clientIP]!.values) {
          // Consider client active if they have downloads in progress or completed recently (within 5 minutes)
          if (!download.isCompleted || 
              (download.completionTime != null && 
               now.difference(download.completionTime!).inMinutes < 5)) {
            hasActiveDownloads = true;
            break;
          }
        }
      }
      
      if (!hasActiveDownloads) {
        disconnectedClients.add(clientIP);
      }
    }
    
    // Remove disconnected clients
    for (final clientIP in disconnectedClients) {
      _connectedClients.remove(clientIP);
      _clientDownloads.remove(clientIP);
      print('Cleaned up disconnected client: $clientIP');
    }
  }

  // Check if all files are completed and auto-stop sharing
  void _checkAndAutoStopSharing() {
    if (!_isSharing || _fileNames.isEmpty) return;
    
    // Check if all files have been completed by at least one client
    bool allFilesCompleted = true;
    for (int i = 0; i < _fileNames.length; i++) {
      bool fileCompleted = false;
      
      // Check if any client has completed this file
      for (final clientIP in _connectedClients) {
        if (_clientDownloads.containsKey(clientIP) && 
            _clientDownloads[clientIP]!.containsKey(i) &&
            _clientDownloads[clientIP]![i]!.isCompleted) {
          fileCompleted = true;
          break;
        }
      }
      
      if (!fileCompleted) {
        allFilesCompleted = false;
        break;
      }
    }
    
    // If all files are completed, auto-stop sharing
    if (allFilesCompleted) {
      print('All files completed! Auto-stopping file sharing...');
      _autoStopSharing();
    }
  }

  // Auto-stop sharing when all files are completed
  Future<void> _autoStopSharing() async {
    if (!_isSharing) return;
    
    setState(() {
      _isSharing = false;
      _loading = true;
    });
    
    try {
      await _server?.close(force: true);
      await FlutterForegroundTask.stopService();
      
      setState(() {
        _loading = false;
        _displayCode = null; // Clear the share code
      });
      
      // SnackBar removed as requested
      
      print('File sharing auto-stopped successfully');
    } catch (e) {
      print('Error auto-stopping file sharing: $e');
      setState(() {
        _loading = false;
      });
    }
  }

  Future<String?> pickFolderSAF() async {
    final uri = await _channel.invokeMethod<String>('pickFolder');
    return uri;
  }

  Future<List<Map<String, String>>> listFilesInFolderSAF(String folderUri) async {
    final jsonString = await _channel.invokeMethod<String>('listFilesInFolder', {'folderUri': folderUri});
    if (jsonString == null) return [];
    final List<dynamic> decoded = jsonDecode(jsonString);
    return decoded.cast<Map<String, dynamic>>().map((e) => {
      'uri': e['uri'] as String,
      'name': e['name'] as String,
    }).toList();
  }

  Future<String?> zipFilesToCache(List<String> uris, List<String> names, String zipName) async {
    const channel = MethodChannel('zapshare.saf');
    return await channel.invokeMethod<String>('zipFilesToCache', {
      'uris': uris,
      'names': names,
      'zipName': zipName,
    });
  }

  Future<void> _pickFolder() async {
    HapticFeedback.mediumImpact();
    final folderUri = await pickFolderSAF();
    if (folderUri != null) {
      final files = await listFilesInFolderSAF(folderUri);
      if (files.isNotEmpty) {
        List<String> uris = [];
        List<String> names = [];
        List<int> sizes = [];
        for (final f in files) {
          uris.add(f['uri']!);
          names.add(f['name']!);
          try {
            final size = await getFileSizeFromUri(f['uri']!);
            sizes.add(size);
          } catch (_) {
            sizes.add(0);
          }
        }
        setState(() {
          // Append to existing lists instead of replacing
          _fileUris.addAll(uris);
          _fileNames.addAll(names);
          _progressList.addAll(List.generate(uris.length, (_) => ValueNotifier(0.0)));
          _isPausedList.addAll(List.generate(uris.length, (_) => ValueNotifier(false)));
          _bytesSentList.addAll(List.generate(uris.length, (_) => 0));
          _fileSizeList.addAll(sizes);
          _completedFiles.addAll(List.generate(uris.length, (_) => false)); // Initialize completedFiles
        });
      }
    }
  }

  Future<void> _serveWebInterface(HttpRequest request) async {
    final response = request.response;
    response.statusCode = HttpStatus.ok;
    response.headers.contentType = ContentType.html;
    
    final html = '''
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>ZapShare - File Download</title>
    <style>
        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }
        
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            background: #000000;
            min-height: 100vh;
            padding: 20px;
        }
        
        .container {
            max-width: 900px;
            margin: 0 auto;
            background: #1a1a1a;
            border-radius: 20px;
            box-shadow: 0 20px 40px rgba(0,0,0,0.5);
            overflow: hidden;
            border: 2px solid #FFD600;
        }
        
        .header {
            background: #1a1a1a;
            padding: 30px;
            text-align: center;
            color: #FFD600;
            position: relative;
            overflow: hidden;
            border-bottom: 2px solid #FFD600;
        }
        
        .header::before {
            content: '⚡';
            position: absolute;
            top: 10px;
            left: 20px;
            font-size: 2rem;
            animation: sparkle 2s infinite;
        }
        
        .header::after {
            content: '⚡';
            position: absolute;
            top: 10px;
            right: 20px;
            font-size: 2rem;
            animation: sparkle 2s infinite reverse;
        }
        
        @keyframes sparkle {
            0%, 100% { opacity: 0.3; transform: scale(1); }
            50% { opacity: 1; transform: scale(1.2); }
        }
        
        .header h1 {
            font-size: 2.5rem;
            font-weight: 800;
            margin-bottom: 10px;
            text-shadow: 0 2px 4px rgba(0,0,0,0.3);
        }
        
        .header p {
            font-size: 1.1rem;
            opacity: 0.9;
            color: #ffffff;
        }
        
        .content {
            padding: 30px;
            background: #1a1a1a;
        }
        
        .file-list {
            margin-top: 20px;
        }
        
        .file-item {
            display: flex;
            align-items: center;
            padding: 20px;
            margin-bottom: 15px;
            background: #2a2a2a;
            border-radius: 12px;
            border: 2px solid #FFD600;
            transition: all 0.3s ease;
            position: relative;
        }
        
        .file-item:hover {
            border-color: #FF6B35;
            transform: translateY(-3px);
            box-shadow: 0 12px 30px rgba(255, 107, 53, 0.3);
            background: #333;
        }
        
        .file-item.selected {
            border-color: #FF6B35;
            background: #333;
            box-shadow: 0 8px 25px rgba(255, 107, 53, 0.2);
        }
        
        .pagination {
            display: flex;
            justify-content: center;
            align-items: center;
            margin: 20px 0;
            gap: 10px;
        }
        
        .pagination button {
            background: #FFD600;
            color: #1a1a1a;
            border: none;
            padding: 10px 15px;
            border-radius: 8px;
            font-weight: 600;
            cursor: pointer;
            transition: all 0.3s ease;
        }
        
        .pagination button:hover {
            background: #FF6B35;
            color: white;
            transform: translateY(-2px);
        }
        
        .pagination button:disabled {
            background: #666;
            color: #999;
            cursor: not-allowed;
            transform: none;
        }
        
        .pagination-info {
            color: #FFD600;
            font-weight: 600;
            margin: 0 15px;
        }
        
        .file-checkbox {
            margin-right: 15px;
            transform: scale(1.2);
            accent-color: #FFD600;
        }
        
        .file-icon {
            width: 50px;
            height: 50px;
            background: linear-gradient(135deg, #FFD600 0%, #FF6B35 100%);
            border-radius: 12px;
            display: flex;
            align-items: center;
            justify-content: center;
            margin-right: 20px;
            font-size: 24px;
            color: #1a1a1a;
            border: 2px solid #FFD600;
        }
        
        .file-info {
            flex: 1;
        }
        
        .file-name {
            font-size: 1.1rem;
            font-weight: 600;
            color: #FFD600;
            margin-bottom: 5px;
        }
        
        .file-size {
            font-size: 0.9rem;
            color: #ccc;
        }
        
        .download-btn {
            background: linear-gradient(135deg, #FFD600 0%, #FF6B35 100%);
            color: #1a1a1a;
            border: none;
            padding: 12px 24px;
            border-radius: 25px;
            font-size: 1rem;
            font-weight: 600;
            cursor: pointer;
            transition: all 0.3s ease;
            text-decoration: none;
            display: inline-block;
            border: 2px solid #FFD600;
        }
        
        .download-btn:hover {
            transform: translateY(-2px);
            box-shadow: 0 8px 25px rgba(255, 214, 0, 0.4);
            background: linear-gradient(135deg, #FF6B35 0%, #FFD600 100%);
        }
        
        .download-btn:active {
            transform: translateY(0);
        }
        
        .bulk-actions {
            background: #2a2a2a;
            padding: 20px;
            margin-bottom: 20px;
            border-radius: 12px;
            border: 2px solid #FFD600;
            display: flex;
            justify-content: space-between;
            align-items: center;
            flex-wrap: wrap;
            gap: 15px;
        }
        
        .bulk-actions h3 {
            color: #FFD600;
            margin: 0;
        }
        
        .bulk-btn {
            background: #FF6B35;
            color: white;
            border: none;
            padding: 10px 20px;
            border-radius: 20px;
            font-weight: 600;
            cursor: pointer;
            transition: all 0.3s ease;
        }
        
        .bulk-btn:hover {
            background: #FF8C42;
            transform: translateY(-2px);
        }
        
        .bulk-btn.secondary {
            background: #333;
            color: #FFD600;
            border: 2px solid #FFD600;
        }
        
        .bulk-btn.secondary:hover {
            background: #FFD600;
            color: #1a1a1a;
        }
        
        .no-files {
            text-align: center;
            padding: 60px 20px;
            color: #ccc;
        }
        
        .no-files h3 {
            font-size: 1.5rem;
            margin-bottom: 10px;
            color: #FFD600;
        }
        
        .loading {
            text-align: center;
            padding: 60px 20px;
            color: #ccc;
        }
        
        .spinner {
            border: 4px solid #333;
            border-top: 4px solid #FFD600;
            border-radius: 50%;
            width: 40px;
            height: 40px;
            animation: spin 1s linear infinite;
            margin: 0 auto 20px;
        }
        
        @keyframes spin {
            0% { transform: rotate(0deg); }
            100% { transform: rotate(360deg); }
        }
        
        .pikachu-runner {
            width: 80px;
            height: 80px;
            margin: 0 auto 20px;
            position: relative;
            animation: run 1s infinite;
        }
        
        .pikachu-runner::before {
            content: '⚡';
            position: absolute;
            top: -10px;
            right: -15px;
            font-size: 24px;
            animation: spark 0.5s infinite alternate;
        }
        
        .pikachu-runner::after {
            content: '⚡';
            position: absolute;
            top: -10px;
            left: -15px;
            font-size: 24px;
            animation: spark 0.5s infinite alternate-reverse;
        }
        
        @keyframes run {
            0%, 100% { transform: translateY(0) rotate(0deg); }
            25% { transform: translateY(-5px) rotate(5deg); }
            50% { transform: translateY(-10px) rotate(0deg); }
            75% { transform: translateY(-5px) rotate(-5deg); }
        }
        
        @keyframes spark {
            0% { opacity: 0.3; transform: scale(0.8); }
            100% { opacity: 1; transform: scale(1.2); }
        }
        
        .progress-container {
            background: #333;
            border-radius: 25px;
            padding: 3px;
            margin: 20px 0;
            border: 2px solid #FFD600;
        }
        
        .progress-bar {
            background: linear-gradient(90deg, #FFD600 0%, #FF6B35 100%);
            height: 20px;
            border-radius: 20px;
            transition: width 0.3s ease;
            position: relative;
            overflow: hidden;
        }
        
        .progress-bar::after {
            content: '';
            position: absolute;
            top: 0;
            left: 0;
            right: 0;
            bottom: 0;
            background: linear-gradient(90deg, transparent 0%, rgba(255,255,255,0.3) 50%, transparent 100%);
            animation: shimmer 2s infinite;
        }
        
        @keyframes shimmer {
            0% { transform: translateX(-100%); }
            100% { transform: translateX(100%); }
        }
        
        .footer {
            text-align: center;
            padding: 20px;
            color: #ccc;
            font-size: 0.9rem;
            border-top: 1px solid #333;
            background: #2a2a2a;
        }
        
        .preview-btn {
            background: #FF6B35;
            color: white;
            border: none;
            padding: 8px 12px;
            border-radius: 6px;
            font-size: 12px;
            font-weight: 600;
            cursor: pointer;
            margin-left: 10px;
            transition: all 0.3s ease;
        }
        
        .preview-btn:hover {
            background: #FF8C42;
            transform: translateY(-1px);
        }
        
        .modal {
            display: none;
            position: fixed;
            z-index: 1000;
            left: 0;
            top: 0;
            width: 100%;
            height: 100%;
            background-color: rgba(0,0,0,0.9);
        }
        
        .modal-content {
            margin: auto;
            display: block;
            max-width: 90%;
            max-height: 90%;
            margin-top: 5%;
        }
        
        .close {
            position: absolute;
            top: 15px;
            right: 35px;
            color: #FFD600;
            font-size: 40px;
            font-weight: bold;
            cursor: pointer;
        }
        
        .close:hover {
            color: #FF6B35;
        }
        
        @media (max-width: 600px) {
            .container {
                margin: 10px;
                border-radius: 15px;
            }
            
            .header {
                padding: 20px;
            }
            
            .header h1 {
                font-size: 2rem;
            }
            
            .content {
                padding: 20px;
            }
            
            .file-item {
                flex-direction: column;
                text-align: center;
            }
            
            .file-icon {
                margin: 0 0 15px 0;
            }
            
            .download-btn {
                margin-top: 15px;
            }
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>📁 ZapShare</h1>
            <p>Download your shared files</p>
        </div>
        
        <div class="content">
            <div id="bulkActions" class="bulk-actions" style="display: none;">
                <h3>📦 Bulk Actions</h3>
                <div>
                    <button class="bulk-btn secondary" onclick="selectAll()">Select All</button>
                    <button class="bulk-btn secondary" onclick="deselectAll()">Deselect All</button>
                    <button class="bulk-btn" onclick="downloadSelected()">Download Selected</button>
                </div>
            </div>
            <div id="pagination" class="pagination" style="display: none;">
                <button id="prevBtn" onclick="changePage(-1)">Previous</button>
                <span id="paginationInfo" class="pagination-info"></span>
                <button id="nextBtn" onclick="changePage(1)">Next</button>
            </div>
            <div id="fileList" class="file-list">
                <div class="loading">
                    <div class="pikachu-runner">🏃</div>
                    <h3>Pikachu is running to fetch your files! ⚡</h3>
                </div>
            </div>
        </div>
        
        <!-- Image Preview Modal -->
        <div id="imageModal" class="modal">
            <span class="close" onclick="closeModal()">&times;</span>
            <img class="modal-content" id="modalImage">
        </div>
        
        <div class="footer">
            <p>Powered by ZapShare • Fast & Secure File Sharing</p>
        </div>
    </div>

    <script>
        let selectedFiles = new Set();
        let allFiles = [];
        let currentPage = 0;
        const filesPerPage = 10;
        
        async function loadFiles() {
            try {
                const response = await fetch('/list');
                if (!response.ok) {
                    throw new Error('Failed to fetch files');
                }
                
                allFiles = await response.json();
                currentPage = 0;
                displayFiles();
            } catch (error) {
                console.error('Error loading files:', error);
                document.getElementById('fileList').innerHTML = 
                    '<div class="no-files"><h3>Error loading files</h3><p>Please try again later</p></div>';
            }
        }
        
        function displayFiles() {
            const fileList = document.getElementById('fileList');
            const bulkActions = document.getElementById('bulkActions');
            const pagination = document.getElementById('pagination');
            
            if (allFiles.length === 0) {
                fileList.innerHTML = 
                    '<div class="no-files"><h3>No files available</h3><p>No files have been shared yet</p></div>';
                bulkActions.style.display = 'none';
                pagination.style.display = 'none';
                return;
            }
            
            // Calculate pagination
            const startIndex = currentPage * filesPerPage;
            const endIndex = Math.min(startIndex + filesPerPage, allFiles.length);
            const currentFiles = allFiles.slice(startIndex, endIndex);
            
            // Update pagination controls
            updatePaginationControls();
            
            const filesHtml = currentFiles.map((file, index) => {
                const size = formatFileSize(file.size);
                const icon = getFileIcon(file.name);
                const isSelected = selectedFiles.has(file.index);
                const isImage = isImageFile(file.name);
                
                return \`
                    <div class="file-item \${isSelected ? 'selected' : ''}" data-index="\${file.index}">
                        <input type="checkbox" class="file-checkbox" 
                               \${isSelected ? 'checked' : ''} 
                               onchange="toggleFileSelection(\${file.index}, this.checked)">
                        <div class="file-icon">\${icon}</div>
                        <div class="file-info">
                            <div class="file-name">\${file.name}</div>
                            <div class="file-size">\${size}</div>
                            <div class="progress-container" style="display: none;">
                                <div class="progress-bar" style="width: 0%"></div>
                            </div>
                        </div>
                        <div style="display: flex; gap: 10px; align-items: center;">
                            \${isImage ? \`<button class="preview-btn" onclick="previewImage(\${file.index})">Preview</button>\` : ''}
                            <a href="/file/\${file.index}" class="download-btn" download onclick="startPikachuRun(this, \${file.index})">
                                Download
                            </a>
                        </div>
                    </div>
                \`;
            }).join('');
            
            fileList.innerHTML = filesHtml;
            updateBulkActions();
        }
        
        function toggleFileSelection(fileIndex, isSelected) {
            if (isSelected) {
                selectedFiles.add(fileIndex);
            } else {
                selectedFiles.delete(fileIndex);
            }
            
            const fileItem = document.querySelector(\`[data-index="\${fileIndex}"]\`);
            if (fileItem) {
                fileItem.classList.toggle('selected', isSelected);
            }
            
            updateBulkActions();
        }
        
        function updateBulkActions() {
            const bulkActions = document.getElementById('bulkActions');
            if (selectedFiles.size > 0) {
                bulkActions.style.display = 'flex';
                const downloadBtn = bulkActions.querySelector('.bulk-btn:not(.secondary)');
                downloadBtn.textContent = \`Download Selected (\${selectedFiles.size})\`;
            } else {
                bulkActions.style.display = 'none';
            }
        }
        
        function selectAll() {
            const startIndex = currentPage * filesPerPage;
            const endIndex = Math.min(startIndex + filesPerPage, allFiles.length);
            const currentFiles = allFiles.slice(startIndex, endIndex);
            
            currentFiles.forEach(file => {
                selectedFiles.add(file.index);
            });
            displayFiles();
        }
        
        function deselectAll() {
            const startIndex = currentPage * filesPerPage;
            const endIndex = Math.min(startIndex + filesPerPage, allFiles.length);
            const currentFiles = allFiles.slice(startIndex, endIndex);
            
            currentFiles.forEach(file => {
                selectedFiles.delete(file.index);
            });
            displayFiles();
        }
        
        function changePage(direction) {
            const totalPages = Math.ceil(allFiles.length / filesPerPage);
            const newPage = currentPage + direction;
            
            if (newPage >= 0 && newPage < totalPages) {
                currentPage = newPage;
                displayFiles();
            }
        }
        
        function updatePaginationControls() {
            const pagination = document.getElementById('pagination');
            const paginationInfo = document.getElementById('paginationInfo');
            const prevBtn = document.getElementById('prevBtn');
            const nextBtn = document.getElementById('nextBtn');
            
            const totalPages = Math.ceil(allFiles.length / filesPerPage);
            const startIndex = currentPage * filesPerPage + 1;
            const endIndex = Math.min((currentPage + 1) * filesPerPage, allFiles.length);
            
            if (totalPages > 1) {
                pagination.style.display = 'flex';
                paginationInfo.textContent = \`Page \${currentPage + 1} of \${totalPages} (\${startIndex}-\${endIndex} of \${allFiles.length} files)\`;
                prevBtn.disabled = currentPage === 0;
                nextBtn.disabled = currentPage === totalPages - 1;
            } else {
                pagination.style.display = 'none';
            }
        }
        
        function previewImage(fileIndex) {
            const modal = document.getElementById('imageModal');
            const modalImg = document.getElementById('modalImage');
            
            modalImg.src = \`/file/\${fileIndex}\`;
            modal.style.display = 'block';
        }
        
        function closeModal() {
            const modal = document.getElementById('imageModal');
            modal.style.display = 'none';
        }
        
        function isImageFile(filename) {
            const imageExtensions = ['jpg', 'jpeg', 'png', 'gif', 'bmp', 'webp', 'svg', 'ico', 'tiff', 'tif', 'heic', 'heif', 'avif', 'jxl'];
            const ext = filename.split('.').pop().toLowerCase();
            return imageExtensions.includes(ext);
        }
        
        function downloadSelected() {
            if (selectedFiles.size === 0) return;
            
            // Show Pikachu running for bulk download
            showNotification('Pikachu is running to download your files! ⚡', 'success');
            
            // Download files one by one
            selectedFiles.forEach(fileIndex => {
                const link = document.createElement('a');
                link.href = \`/file/\${fileIndex}\`;
                link.download = '';
                link.style.display = 'none';
                document.body.appendChild(link);
                link.click();
                document.body.removeChild(link);
            });
        }
        
        function startPikachuRun(button, fileIndex) {
            const fileItem = button.closest('.file-item');
            const progressContainer = fileItem.querySelector('.progress-container');
            const progressBar = fileItem.querySelector('.progress-bar');
            const downloadBtn = button;
            
            // Show progress bar
            progressContainer.style.display = 'block';
            
            // Change button to show Pikachu running
            downloadBtn.innerHTML = '<div class="pikachu-runner" style="width: 20px; height: 20px; margin: 0;">🏃</div>';
            downloadBtn.style.pointerEvents = 'none';
            
            // Simulate progress (since we can't track actual download progress)
            let progress = 0;
            const interval = setInterval(() => {
                progress += Math.random() * 15;
                if (progress >= 100) {
                    progress = 100;
                    clearInterval(interval);
                    
                    // Reset button and hide progress
                    setTimeout(() => {
                        downloadBtn.innerHTML = 'Download';
                        downloadBtn.style.pointerEvents = 'auto';
                        progressContainer.style.display = 'none';
                        progressBar.style.width = '0%';
                    }, 1000);
                }
                progressBar.style.width = progress + '%';
            }, 200);
            
            // Show notification
            showNotification('Pikachu is running to download your file! ⚡', 'success');
        }
        
        function showNotification(message, type = 'info') {
            const notification = document.createElement('div');
            notification.className = \`notification \${type}\`;
            notification.textContent = message;
            notification.style.cssText = \`
                position: fixed;
                top: 20px;
                right: 20px;
                padding: 15px 20px;
                border-radius: 8px;
                color: white;
                font-weight: 600;
                z-index: 1000;
                animation: slideIn 0.3s ease;
                background: \${type === 'success' ? '#FF6B35' : '#FFD600'};
                color: \${type === 'success' ? 'white' : '#1a1a1a'};
            \`;
            
            document.body.appendChild(notification);
            
            setTimeout(() => {
                notification.style.animation = 'slideOut 0.3s ease';
                setTimeout(() => {
                    if (notification.parentNode) {
                        notification.parentNode.removeChild(notification);
                    }
                }, 300);
            }, 3000);
        }
        
        function formatFileSize(bytes) {
            if (bytes === 0) return '0 B';
            const k = 1024;
            const sizes = ['B', 'KB', 'MB', 'GB'];
            const i = Math.floor(Math.log(bytes) / Math.log(k));
            return parseFloat((bytes / Math.pow(k, i)).toFixed(2)) + ' ' + sizes[i];
        }
        
        function getFileIcon(filename) {
            const ext = filename.split('.').pop().toLowerCase();
            const iconMap = {
                'pdf': '📄', 'doc': '📝', 'docx': '📝', 'txt': '📄',
                'jpg': '🖼️', 'jpeg': '🖼️', 'png': '🖼️', 'gif': '🖼️',
                'mp4': '🎥', 'avi': '🎥', 'mov': '🎥', 'mp3': '🎵',
                'zip': '📦', 'rar': '📦', '7z': '📦', 'exe': '⚙️'
            };
            return iconMap[ext] || '📁';
        }
        
        // Load files when page loads
        document.addEventListener('DOMContentLoaded', loadFiles);
        
        // Close modal when clicking outside
        window.onclick = function(event) {
            const modal = document.getElementById('imageModal');
            if (event.target == modal) {
                closeModal();
            }
        }
        
        // Auto-refresh every 5 seconds
        setInterval(loadFiles, 5000);
        
        // Add CSS animations
        const style = document.createElement('style');
        style.textContent = \`
            @keyframes slideIn {
                from { transform: translateX(100%); opacity: 0; }
                to { transform: translateX(0); opacity: 1; }
            }
            @keyframes slideOut {
                from { transform: translateX(0); opacity: 1; }
                to { transform: translateX(100%); opacity: 0; }
            }
        \`;
        document.head.appendChild(style);
    </script>
</body>
</html>
    ''';
    
    response.write(html);
    await response.close();
  }

  void _initDeviceDiscovery() async {
    print('🔍 Initializing device discovery...');
    
    // Initialize device info first
    await _discoveryService.initialize();
    
    // Start discovery
    await _discoveryService.start();
    
    print('✅ Device discovery started');
    
    // Listen for nearby devices
    _devicesSubscription = _discoveryService.devicesStream.listen((devices) {
      if (mounted) {
        print('📱 Nearby devices updated: ${devices.length} devices');
        setState(() {
          _nearbyDevices = devices.where((d) => d.isOnline).toList();
          // Update device name mapping
          for (var device in devices) {
            _clientDeviceNames[device.ipAddress] = device.deviceName;
          }
        });
      }
    });
    
    // Listen for incoming connection requests
    _connectionRequestSubscription = _discoveryService.connectionRequestStream.listen(
      (request) {
        if (mounted) {
          print('📩 Stream listener received connection request from ${request.deviceName} (${request.ipAddress})');
          _showConnectionRequestDialog(request);
        } else {
          print('⚠️  Widget not mounted, ignoring connection request');
        }
      },
      onError: (error) {
        print('❌ Error in connection request stream: $error');
      },
      onDone: () {
        print('⚠️  Connection request stream closed');
      },
    );
    print('✅ Connection request listener active');
    
    // Listen for connection responses
    _connectionResponseSubscription = _discoveryService.connectionResponseStream.listen((response) {
      print('📨 Connection response received: accepted=${response.accepted}, ip=${response.ipAddress}');
      if (mounted && _pendingRequestDeviceIp != null) {
        // Cancel the timeout timer since we got a response
        _requestTimeoutTimer?.cancel();
        _requestTimeoutTimer = null;
        
        if (response.accepted) {
          // Connection accepted! Start sharing
          print('✅ Connection accepted! Starting server...');
          _startSharingToDevice(_pendingRequestDeviceIp!);
        } else {
          // Connection declined
          print('❌ Connection declined');
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Connection request was declined'),
              backgroundColor: Colors.red,
              duration: Duration(seconds: 3),
            ),
          );
        }
        _pendingRequestDeviceIp = null;
        _pendingDevice = null;
      }
    });
    
    print('✅ All stream listeners set up');
  }

  void _showConnectionRequestDialog(ConnectionRequest request) {
    print('🚀 _showConnectionRequestDialog called');
    print('   Device: ${request.deviceName}');
    print('   IP: ${request.ipAddress}');
    print('   Files: ${request.fileNames.length}');
    print('   Context valid: ${context != null}');
    
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        print('📱 Building ConnectionRequestDialog...');
        return ConnectionRequestDialog(
          request: request,
          onAccept: () async {
            print('✅ User accepted connection request');
            Navigator.of(context).pop();
            await _discoveryService.sendConnectionResponse(request.ipAddress, true);
          },
          onDecline: () async {
            print('❌ User declined connection request');
            Navigator.of(context).pop();
            await _discoveryService.sendConnectionResponse(request.ipAddress, false);
          },
        );
      },
    );
    print('✅ Dialog shown');
  }

  Future<void> _sendConnectionRequest(DiscoveredDevice device) async {
    if (_fileUris.isEmpty) {
      print('⚠️ No files selected');
      return;
    }

    setState(() {
      _pendingRequestDeviceIp = device.ipAddress;
      _pendingDevice = device;
    });
    
    // Start server FIRST before sending request
    print('🚀 Starting server before sending connection request...');
    await _startServer();
    
    // Calculate total size
    final totalSize = _fileSizeList.fold<int>(0, (sum, size) => sum + size);
    
    // Send connection request
    print('📤 Sending connection request to ${device.deviceName} (${device.ipAddress})');
    await _discoveryService.sendConnectionRequest(
      device.ipAddress,
      _fileNames,
      totalSize,
    );

    print('✅ Connection request sent successfully');
    
    // Start 10-second timeout timer
    _requestTimeoutTimer?.cancel();
    _requestTimeoutTimer = Timer(Duration(seconds: 10), () {
      if (mounted && _pendingRequestDeviceIp != null) {
        print('⏰ Connection request timeout - no response after 10 seconds');
        _showRetryDialog();
      }
    });
  }

  void _showRetryDialog() {
    if (!mounted) return;
    
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return Dialog(
          backgroundColor: Colors.transparent,
          child: Container(
            decoration: BoxDecoration(
              color: Colors.grey[900],
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: Colors.yellow[300]!.withOpacity(0.5),
                width: 2,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.5),
                  blurRadius: 20,
                  offset: Offset(0, 10),
                ),
              ],
            ),
            padding: EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Icon
                Container(
                  width: 70,
                  height: 70,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.yellow[300],
                    border: Border.all(
                      color: Colors.yellow[600]!,
                      width: 3,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.yellow[300]!.withOpacity(0.4),
                        blurRadius: 15,
                        offset: Offset(0, 5),
                      ),
                    ],
                  ),
                  child: Icon(
                    Icons.timer_off_rounded,
                    size: 35,
                    color: Colors.black87,
                  ),
                ),
                SizedBox(height: 16),
                
                // Title
                Text(
                  'No Response',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: Colors.yellow[300],
                  ),
                ),
                SizedBox(height: 8),
                
                // Device name
                if (_pendingDevice != null)
                  Text(
                    _pendingDevice!.deviceName,
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                    textAlign: TextAlign.center,
                  ),
                SizedBox(height: 16),
                
                // Message
                Container(
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    color: Colors.grey[850],
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: Colors.grey[700]!,
                      width: 1,
                    ),
                  ),
                  child: Column(
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.info_outline_rounded, color: Colors.yellow[400], size: 18),
                          SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'hasn\'t responded to your request',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 14,
                                color: Colors.grey[400],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                SizedBox(height: 8),
                Text(
                  'Would you like to try again?',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.white,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                SizedBox(height: 24),
                
                // Buttons
                Row(
                  children: [
                    // Cancel button
                    Expanded(
                      child: GestureDetector(
                        onTap: () {
                          _requestTimeoutTimer?.cancel();
                          _requestTimeoutTimer = null;
                          setState(() {
                            _pendingRequestDeviceIp = null;
                            _pendingDevice = null;
                          });
                          Navigator.of(context).pop();
                        },
                        child: Container(
                          padding: EdgeInsets.symmetric(vertical: 14),
                          decoration: BoxDecoration(
                            color: Colors.grey[800],
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: Colors.grey[700]!,
                              width: 1,
                            ),
                          ),
                          child: Text(
                            'Cancel',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Colors.grey[400],
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    ),
                    SizedBox(width: 12),
                    
                    // Retry button
                    Expanded(
                      child: GestureDetector(
                        onTap: () async {
                          Navigator.of(context).pop();
                          if (_pendingDevice != null) {
                            await _sendConnectionRequest(_pendingDevice!);
                          }
                        },
                        child: Container(
                          padding: EdgeInsets.symmetric(vertical: 14),
                          decoration: BoxDecoration(
                            color: Colors.yellow[300],
                            borderRadius: BorderRadius.circular(12),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.yellow[300]!.withOpacity(0.3),
                                blurRadius: 8,
                                offset: Offset(0, 4),
                              ),
                            ],
                          ),
                          child: Text(
                            'Retry',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Colors.black,
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _startSharingToDevice(String deviceIp) async {
    // Start the HTTP server
    await _startServer();
    
    print('✅ Server started successfully');
  }

  @override
  void dispose() {
    _server?.close(force: true);
    _pageController.dispose();
    _devicesSubscription?.cancel();
    _connectionRequestSubscription?.cancel();
    _connectionResponseSubscription?.cancel();
    _requestTimeoutTimer?.cancel();
    // Don't stop the singleton discovery service - it runs globally
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final isCompact = screenWidth < 600;
    
    // Check for auto-stop when building UI
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_isSharing) {
        _checkAndAutoStopSharing();
      }
    });
    
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            // Header
            Container(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
              child: Row(
                children: [
                  IconButton(
                    icon: Icon(Icons.arrow_back_ios_rounded, color: Colors.white, size: 20),
                    onPressed: () => Navigator.pop(context),
                  ),
                  Expanded(
                    child: Text(
                      'Share Files',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 28,
                        fontWeight: FontWeight.w300,
                        letterSpacing: -0.5,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                  IconButton(
                    icon: Icon(Icons.refresh_rounded, color: Colors.grey[400], size: 20),
                    onPressed: _refreshIp,
                  ),
                ],
              ),
            ),
            
            // Main content
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Column(
                  children: [
                    // Connection status - compact
                    if (_localIp != null) ...[
                      _buildCompactConnectionStatus(),
                      const SizedBox(height: 24),
                    ],
                    
                    // Share code section - always visible for consistent design
                    _buildCompactShareCode(),
                    const SizedBox(height: 24),
                    
                    // Nearby devices section
                    _buildNearbyDevicesSection(),
                    
                    // File list section - prominent
                    if (_fileNames.isNotEmpty) ...[
                      _buildFileListHeader(),
                      const SizedBox(height: 16),
                      Expanded(child: _buildFileList(isCompact)),
                    ],
                    
                    // Empty state
                    if (_fileNames.isEmpty && !_loading) ...[
                      Expanded(
                        child: _buildEmptyState(),
                      ),
                    ],
                    
                    // Loading state
                    if (_loading) ...[
                      Expanded(
                        child: _buildLoadingState(),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            
            // Action buttons - reorganized for better UX
            if (_fileNames.isNotEmpty) ...[
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 36),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _buildRectangularButton(
                      icon: Icons.attach_file_rounded,
                      onTap: _selectFiles,
                      color: Colors.grey[900]!,
                      textColor: Colors.white,
                      label: 'Add Files',
                    ),
                    _buildRectangularButton(
                      icon: Icons.folder_rounded,
                      onTap: _pickFolder,
                      color: Colors.grey[900]!,
                      textColor: Colors.white,
                      label: 'Folder',
                    ),
                    _buildRectangularButton(
                      icon: _isSharing ? Icons.stop_circle_rounded : Icons.send_rounded,
                      onTap: (_fileUris.isEmpty || _loading)
                          ? null
                          : _isSharing
                              ? _stopServer
                              : _startServer,
                      color: _fileUris.isEmpty
                          ? Colors.grey[700]!
                          : _isSharing
                              ? Colors.red[600]!
                              : Colors.yellow[300]!,
                      textColor: _fileUris.isEmpty
                          ? Colors.grey[400]!
                          : _isSharing
                              ? Colors.white
                              : Colors.black,
                      label: _isSharing ? 'Stop' : 'Send',
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildCompactConnectionStatus() {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.grey[900],
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey[800]!, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  color: Colors.green,
                  shape: BoxShape.circle,
                ),
              ),
              SizedBox(width: 12),
              Text(
                'Connected • $_localIp',
                style: TextStyle(
                  color: Colors.grey[300],
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  fontFamily: 'monospace',
                ),
              ),
            ],
          ),
          if (_connectedClients.isNotEmpty) ...[
            SizedBox(height: 8),
            Row(
              children: [
                Icon(
                  Icons.people_rounded,
                  color: Colors.yellow[300],
                  size: 16,
                ),
                SizedBox(width: 8),
                Text(
                  '${_connectedClients.length} client${_connectedClients.length == 1 ? '' : 's'} connected',
                  style: TextStyle(
                    color: Colors.yellow[300],
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildNearbyDevicesSection() {
    // Compact header-only view when collapsed
    return GestureDetector(
      onTap: () {
        setState(() => _showNearbyDevices = !_showNearbyDevices);
        HapticFeedback.lightImpact();
      },
      child: AnimatedContainer(
        duration: Duration(milliseconds: 300),
        margin: EdgeInsets.only(bottom: 12),
        padding: EdgeInsets.symmetric(
          horizontal: 14,
          vertical: _showNearbyDevices ? 14 : 10,
        ),
        decoration: BoxDecoration(
          color: _showNearbyDevices 
            ? Colors.grey[900] 
            : Colors.grey[900]!.withOpacity(0.5),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: _nearbyDevices.isNotEmpty 
              ? Colors.yellow[300]!.withOpacity(0.4) 
              : Colors.grey[700]!.withOpacity(0.3),
            width: 1,
          ),
        ),
        child: Column(
          children: [
            // Compact header
            Row(
              children: [
                SizedBox(
                  width: 16,
                  height: 16,
                  child: _AnimatedRadar(isActive: true),
                ),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _nearbyDevices.isEmpty 
                      ? 'Discovering...' 
                      : '${_nearbyDevices.length} device${_nearbyDevices.length == 1 ? '' : 's'} nearby',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Icon(
                  _showNearbyDevices 
                    ? Icons.keyboard_arrow_up_rounded 
                    : Icons.keyboard_arrow_down_rounded,
                  color: Colors.grey[500],
                  size: 20,
                ),
              ],
            ),
            
            // Expandable content
            if (_showNearbyDevices && _nearbyDevices.isNotEmpty) ...[
              SizedBox(height: 12),
              _buildCompactDeviceList(),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyDevicesState() {
    return Container(
      padding: EdgeInsets.symmetric(vertical: 24),
      child: Column(
        children: [
          // Animated scanning indicator
          _PulsingSearchIndicator(),
          SizedBox(height: 16),
          Text(
            'Searching for nearby devices...',
            style: TextStyle(
              color: Colors.grey[400],
              fontSize: 14,
              fontWeight: FontWeight.w500,
            ),
          ),
          SizedBox(height: 8),
          Text(
            'Make sure devices are on the same network',
            style: TextStyle(
              color: Colors.grey[600],
              fontSize: 12,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _buildCompactDeviceList() {
    return Container(
      height: 85,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: _nearbyDevices.length,
        itemBuilder: (context, index) {
          return _buildCircularDeviceItem(_nearbyDevices[index]);
        },
      ),
    );
  }

  Widget _buildCircularDeviceItem(DiscoveredDevice device) {
    final isPending = _pendingRequestDeviceIp == device.ipAddress;
    
    return GestureDetector(
      onTap: isPending ? null : () => _sendConnectionRequest(device),
      onLongPress: () => _showDeviceDetailsDialog(device),
      child: Container(
        width: 65,
        margin: EdgeInsets.only(right: 10),
        child: Column(
          children: [
            // Circular device icon
            AnimatedContainer(
              duration: Duration(milliseconds: 200),
              width: 55,
              height: 55,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: isPending
                  ? LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        Colors.yellow[300]!,
                        Colors.yellow[400]!,
                      ],
                    )
                  : LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        Colors.grey[800]!,
                        Colors.grey[850]!,
                      ],
                    ),
                border: Border.all(
                  color: isPending 
                    ? Colors.yellow[600]! 
                    : Colors.grey[700]!,
                  width: 2,
                ),
                boxShadow: [
                  if (isPending)
                    BoxShadow(
                      color: Colors.yellow[300]!.withOpacity(0.3),
                      blurRadius: 8,
                      offset: Offset(0, 3),
                    ),
                  BoxShadow(
                    color: Colors.black.withOpacity(0.2),
                    blurRadius: 6,
                    offset: Offset(0, 3),
                  ),
                ],
              ),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // Platform icon
                  Icon(
                    _getPlatformIcon(device.platform),
                    color: isPending ? Colors.black87 : Colors.white70,
                    size: 24,
                  ),
                  // Pending spinner
                  if (isPending)
                    Positioned.fill(
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(
                          Colors.black.withOpacity(0.3),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            SizedBox(height: 6),
            // Device name
            Text(
              device.deviceName.length > 8 
                ? '${device.deviceName.substring(0, 8)}...' 
                : device.deviceName,
              style: TextStyle(
                color: isPending ? Colors.yellow[300] : Colors.white,
                fontSize: 10,
                fontWeight: FontWeight.w600,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  void _showDeviceDetailsDialog(DiscoveredDevice device) {
    HapticFeedback.mediumImpact();
    
    showDialog(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: Colors.transparent,
        child: Container(
          padding: EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: Colors.grey[900],
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: Colors.yellow[300]!.withOpacity(0.5),
              width: 2,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.5),
                blurRadius: 20,
                offset: Offset(0, 10),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Device Icon
              Container(
                width: 80,
                height: 80,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.yellow[300],
                  border: Border.all(
                    color: Colors.yellow[600]!,
                    width: 3,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.yellow[300]!.withOpacity(0.4),
                      blurRadius: 15,
                      offset: Offset(0, 5),
                    ),
                  ],
                ),
                child: Icon(
                  _getPlatformIcon(device.platform),
                  color: Colors.black87,
                  size: 40,
                ),
              ),
              SizedBox(height: 16),
              
              // Device Name
              Text(
                device.deviceName,
                style: TextStyle(
                  color: Colors.yellow[300],
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
              ),
              SizedBox(height: 20),
              
              // Device Details
              _buildDetailRow(Icons.computer_rounded, 'Platform', device.platform),
              SizedBox(height: 12),
              _buildDetailRow(Icons.wifi_rounded, 'IP Address', device.ipAddress),
              SizedBox(height: 12),
              _buildDetailRow(Icons.share_rounded, 'Share Code', device.shareCode),
              SizedBox(height: 12),
              _buildDetailRow(
                device.isOnline ? Icons.check_circle_rounded : Icons.cancel_rounded,
                'Status',
                device.isOnline ? 'Online' : 'Offline',
                statusColor: device.isOnline ? Colors.green[400] : Colors.red[400],
              ),
              
              SizedBox(height: 24),
              
              // Close Button
              GestureDetector(
                onTap: () => Navigator.of(context).pop(),
                child: Container(
                  width: double.infinity,
                  padding: EdgeInsets.symmetric(vertical: 14),
                  decoration: BoxDecoration(
                    color: Colors.yellow[300],
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.yellow[300]!.withOpacity(0.3),
                        blurRadius: 8,
                        offset: Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Text(
                    'Close',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.black,
                      fontSize: 16,
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

  Widget _buildDetailRow(IconData icon, String label, String value, {Color? statusColor}) {
    return Row(
      children: [
        Container(
          padding: EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Colors.grey[850],
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: Colors.grey[700]!,
              width: 1,
            ),
          ),
          child: Icon(
            icon,
            color: statusColor ?? Colors.yellow[300],
            size: 20,
          ),
        ),
        SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(
                  color: Colors.grey[500],
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
              SizedBox(height: 2),
              Text(
                value,
                style: TextStyle(
                  color: statusColor ?? Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildBeautifulDeviceCard(DiscoveredDevice device) {
    final isPending = _pendingRequestDeviceIp == device.ipAddress;
    
    return GestureDetector(
      onTap: isPending ? null : () => _sendConnectionRequest(device),
      child: AnimatedContainer(
        duration: Duration(milliseconds: 300),
        width: 160,
        padding: EdgeInsets.all(14),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: isPending
                ? [
                    Colors.yellow[300]!.withOpacity(0.2),
                    Colors.yellow[400]!.withOpacity(0.1),
                  ]
                : [
                    Colors.grey[850]!,
                    Colors.grey[900]!,
                  ],
          ),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isPending ? Colors.yellow[300]! : Colors.grey[700]!,
            width: isPending ? 2 : 1,
          ),
          boxShadow: [
            BoxShadow(
              color: isPending 
                ? Colors.yellow[300]!.withOpacity(0.2)
                : Colors.black.withOpacity(0.2),
              blurRadius: isPending ? 12 : 8,
              offset: Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Platform icon with background
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: isPending 
                  ? Colors.yellow[300]!.withOpacity(0.2)
                  : Colors.grey[800],
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: isPending ? Colors.yellow[300]! : Colors.transparent,
                  width: 1,
                ),
              ),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Icon(
                    _getPlatformIcon(device.platform),
                    color: isPending ? Colors.yellow[300] : Colors.white,
                    size: 30,
                  ),
                  if (isPending)
                    Positioned.fill(
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation(Colors.yellow[300]),
                      ),
                    ),
                ],
              ),
            ),
            SizedBox(height: 12),
            // Device name
            Text(
              device.deviceName,
              style: TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
            ),
            SizedBox(height: 4),
            // Platform name
            Text(
              device.platform,
              style: TextStyle(
                color: Colors.grey[500],
                fontSize: 11,
                fontWeight: FontWeight.w500,
              ),
            ),
            if (isPending) ...[
              SizedBox(height: 8),
              Text(
                'Connecting...',
                style: TextStyle(
                  color: Colors.yellow[300],
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildCompactDeviceChip(DiscoveredDevice device) {
    final isPending = _pendingRequestDeviceIp == device.ipAddress;
    
    return Tooltip(
      message: '${device.deviceName}\n${device.platform}\n${device.ipAddress}',
      preferBelow: false,
      verticalOffset: 10,
      decoration: BoxDecoration(
        color: Colors.grey[900],
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.yellow[300]!, width: 1),
      ),
      textStyle: TextStyle(
        color: Colors.white,
        fontSize: 12,
      ),
      child: GestureDetector(
        onTap: isPending ? null : () => _sendConnectionRequest(device),
        child: AnimatedContainer(
          duration: Duration(milliseconds: 200),
          padding: EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: isPending ? Colors.yellow[300]!.withOpacity(0.2) : Colors.grey[800],
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: isPending ? Colors.yellow[300]! : Colors.grey[700]!,
              width: isPending ? 2 : 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                _getPlatformIcon(device.platform),
                color: isPending ? Colors.yellow[300] : Colors.white70,
                size: 16,
              ),
              SizedBox(width: 6),
              Flexible(
                child: Text(
                  device.deviceName,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (isPending) ...[
                SizedBox(width: 6),
                SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation(Colors.yellow[300]),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildNearbyDeviceCard(DiscoveredDevice device) {
    final isPending = _pendingRequestDeviceIp == device.ipAddress;
    
    return GestureDetector(
      onTap: isPending ? null : () => _sendConnectionRequest(device),
      child: Container(
        width: 140,
        margin: EdgeInsets.only(right: 12),
        padding: EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isPending ? Colors.yellow[300]!.withOpacity(0.1) : Colors.grey[900],
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isPending ? Colors.yellow[300]! : Colors.grey[800]!,
            width: isPending ? 2 : 1,
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              _getPlatformIcon(device.platform),
              color: isPending ? Colors.yellow[300] : Colors.white,
              size: 28,
            ),
            SizedBox(height: 8),
            Text(
              device.deviceName,
              style: TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
            ),
            if (isPending) ...[
              SizedBox(height: 4),
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation(Colors.yellow[300]),
                ),
              ),
            ],
          ],
        ),
      ),
    );
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

  Widget _buildCompactShareCode() {
    final shareUrl = 'http://$_localIp:8080';
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.grey[900],
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.yellow[300]!, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: _displayCode != null
                    ? StatefulBuilder(
                        builder: (context, setState) {
                          bool isPressed = false;
                          
                          return GestureDetector(
                            onTap: () {
                              HapticFeedback.lightImpact();
                              Clipboard.setData(ClipboardData(text: _displayCode!));
                            },
                            onTapDown: (_) => setState(() => isPressed = true),
                            onTapUp: (_) => setState(() => isPressed = false),
                            onTapCancel: () => setState(() => isPressed = false),
                            child: AnimatedContainer(
                              duration: Duration(milliseconds: 150),
                              padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                              transform: Matrix4.identity()..scale(isPressed ? 0.98 : 1.0),
                              decoration: BoxDecoration(
                                color: Colors.yellow[300]!.withOpacity(isPressed ? 0.15 : 0.1),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: Colors.yellow[300]!.withOpacity(isPressed ? 0.5 : 0.3),
                                  width: isPressed ? 1.5 : 1,
                                ),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    _displayCode!,
                                    style: TextStyle(
                                      fontSize: 18,
                                      color: Colors.yellow[300],
                                      fontWeight: FontWeight.w600,
                                      letterSpacing: 1,
                                      fontFamily: 'monospace',
                                    ),
                                  ),
                                  SizedBox(width: 8),
                                  Icon(
                                    Icons.copy_rounded,
                                    color: Colors.yellow[300]!.withOpacity(0.7),
                                    size: 16,
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      )
                    : Container(
                        padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                          color: Colors.grey[800]!.withOpacity(0.3),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: Colors.grey[600]!.withOpacity(0.3),
                            width: 1,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.info_outline_rounded,
                              color: Colors.grey[500],
                              size: 16,
                            ),
                            SizedBox(width: 8),
                            Text(
                              'Start sharing to see code',
                              style: TextStyle(
                                fontSize: 14,
                                color: Colors.grey[500],
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      ),
              ),
            ],
          ),
          SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: StatefulBuilder(
                  builder: (context, setState) {
                    bool isPressed = false;
                    
                    return GestureDetector(
                      onTap: () {
                        HapticFeedback.lightImpact();
                        Clipboard.setData(ClipboardData(text: shareUrl));
                      },
                      onTapDown: (_) => setState(() => isPressed = true),
                      onTapUp: (_) => setState(() => isPressed = false),
                      onTapCancel: () => setState(() => isPressed = false),
                      child: AnimatedContainer(
                        duration: Duration(milliseconds: 150),
                        padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        transform: Matrix4.identity()..scale(isPressed ? 0.98 : 1.0),
                        decoration: BoxDecoration(
                          color: Colors.grey[400]!.withOpacity(isPressed ? 0.15 : 0.1),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: Colors.grey[400]!.withOpacity(isPressed ? 0.5 : 0.3),
                            width: isPressed ? 0.5 : 1,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              shareUrl,
                              style: TextStyle(
                                fontSize: 14,
                                color: Colors.grey[400],
                                fontWeight: FontWeight.w500,
                                fontFamily: 'monospace',
                              ),
                            ),
                            SizedBox(width: 8),
                            Icon(
                              Icons.link_rounded,
                              color: Colors.grey[400]!.withOpacity(0.7),
                              size: 16,
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
        ],
      ),
    );
  }

  Widget _buildFileListHeader() {
    return Row(
      children: [
        Text(
          'Files to Share',
          style: TextStyle(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.w600,
          ),
        ),
        Spacer(),
        Text(
          '${_fileNames.length} file${_fileNames.length == 1 ? '' : 's'}',
          style: TextStyle(
            color: Colors.grey[400],
            fontSize: 14,
            fontWeight: FontWeight.w500,
          ),
        ),
        SizedBox(width: 16),
        if (_fileNames.isNotEmpty)
          _buildSmallClearButton(),
      ],
    );
  }

  Widget _buildFileList(bool isCompact) {
    return ListView.builder(
      itemCount: _fileNames.length,
      itemBuilder: (context, index) {
        final fileName = _fileNames[index];
        final fileSize = _fileSizeList.length > index ? _fileSizeList[index] : 0;
        final progress = _progressList.length > index ? _progressList[index] : ValueNotifier(0.0);
        final isPaused = _isPausedList.length > index ? _isPausedList[index] : ValueNotifier(false);
        final isCompleted = _completedFiles.length > index ? _completedFiles[index] : false; // Check completion
        
        // Get client download statuses for this file
        final clientStatuses = <String, DownloadStatus>{}; // clientIP -> DownloadStatus
        for (final clientIP in _connectedClients) {
          if (_clientDownloads.containsKey(clientIP) && 
              _clientDownloads[clientIP]!.containsKey(index)) {
            clientStatuses[clientIP] = _clientDownloads[clientIP]![index]!;
          }
        }
        
        // Check if any client has completed this file
        final hasAnyClientCompleted = clientStatuses.values.any((status) => status.isCompleted);
        final completedClients = clientStatuses.values.where((status) => status.isCompleted).toList();
        
        return _buildSwipeToDeleteFile(
          index: index,
          fileName: fileName,
          fileSize: fileSize,
          progress: progress,
          isPaused: isPaused,
          isCompleted: isCompleted,
          hasAnyClientCompleted: hasAnyClientCompleted,
          completedClients: completedClients,
          clientStatuses: clientStatuses,
          isCompact: isCompact,
        );
      },
    );
  }

  Widget _buildSwipeToDeleteFile({
    required int index,
    required String fileName,
    required int fileSize,
    required ValueNotifier<double> progress,
    required ValueNotifier<bool> isPaused,
    required bool isCompleted,
    required bool hasAnyClientCompleted,
    required List<DownloadStatus> completedClients,
    required Map<String, DownloadStatus> clientStatuses,
    required bool isCompact,
  }) {
    // Use a more stable key based on file URI and name to avoid conflicts
    final fileKey = '${_fileUris[index]}_$fileName';
    
    return Dismissible(
      key: Key(fileKey),
      direction: DismissDirection.endToStart, // Swipe right to left (like Gmail)
      background: Container(
        margin: EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(
          color: Colors.red[600],
          borderRadius: BorderRadius.circular(12),
        ),
        alignment: Alignment.centerRight,
        padding: EdgeInsets.only(right: 20),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.delete_rounded,
              color: Colors.white,
              size: 28,
            ),
            SizedBox(height: 4),
            Text(
              'Delete',
              style: TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
      confirmDismiss: (direction) async {
        // Show confirmation dialog
        final shouldDelete = await _showDeleteConfirmation(fileName);
        if (shouldDelete) {
          // Delete immediately if confirmed
          _deleteFile(index);
        }
        return false; // Always return false to prevent automatic dismissal
      },
      // Add a resize duration to prevent conflicts
      resizeDuration: Duration(milliseconds: 200),
      child: Container(
        margin: EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(
          color: Colors.grey[900],
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.grey[800]!, width: 1),
        ),
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: Colors.yellow[300],
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(
                      _getFileIcon(fileName),
                      color: Colors.black,
                      size: 20,
                    ),
                  ),
                  SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          fileName,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        SizedBox(height: 2),
                        Text(
                          isCompleted ? 'Sent' : formatBytes(fileSize),
                          style: TextStyle(
                            color: isCompleted ? Colors.green[400] : Colors.grey[400],
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (_isSharing) ...[
                    SizedBox(width: 12),
                    if (hasAnyClientCompleted) ...[
                      // Completion indicator with client info
                      Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(
                          color: Colors.green[400],
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: Colors.green[400]!.withOpacity(0.4),
                              blurRadius: 6,
                              offset: Offset(0, 2),
                            ),
                          ],
                        ),
                        child: Icon(
                          Icons.check_rounded,
                          color: Colors.white,
                          size: 20,
                        ),
                      ),
                      SizedBox(width: 8),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Sent to ${completedClients.length} client${completedClients.length == 1 ? '' : 's'}',
                            style: TextStyle(
                              color: Colors.green[400],
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          if (completedClients.isNotEmpty) ...[
                            SizedBox(height: 2),
                            Text(
                              completedClients.map((c) => c.clientIP).join(', '),
                              style: TextStyle(
                                color: Colors.grey[500],
                                fontSize: 10,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ] else ...[
                      // Show percentage and pause/resume button when sharing
                      ValueListenableBuilder<double>(
                        valueListenable: progress,
                        builder: (context, value, _) => Container(
                          width: 32,
                          height: 32,
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              CircularProgressIndicator(
                                value: value,
                                backgroundColor: Colors.grey[800]!.withOpacity(0.3),
                                color: Colors.yellow[300],
                                strokeWidth: 3,
                                strokeCap: StrokeCap.round,
                              ),
                              // Pause/Resume button overlay
                              ValueListenableBuilder<bool>(
                                valueListenable: isPaused,
                                builder: (context, paused, _) => Transform.scale(
                                  scale: 0.625, // Scale down from 32x32 to 20x20
                                  child: _buildPauseResumeButton(
                                    isPaused: paused,
                                    onTap: () => _togglePause(index),
                                    progress: progress.value,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      SizedBox(width: 8),
                      // Progress percentage inline
                      ValueListenableBuilder<double>(
                        valueListenable: progress,
                        builder: (context, value, _) => ValueListenableBuilder<bool>(
                          valueListenable: isPaused,
                          builder: (context, paused, _) => Text(
                            paused ? 'Paused' : '${(value * 100).toStringAsFixed(0)}%',
                            style: TextStyle(
                              color: paused ? Colors.yellow[600] : Colors.yellow[300],
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<bool> _showDeleteConfirmation(String fileName) async {
    return await showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          backgroundColor: Colors.grey[900],
          title: Text(
            'Delete File',
            style: TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w600,
            ),
          ),
          content: Text(
            'Are you sure you want to remove "$fileName" from the sharing list?',
            style: TextStyle(
              color: Colors.grey[300],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(
                'Cancel',
                style: TextStyle(
                  color: Colors.grey[400],
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              style: TextButton.styleFrom(
                backgroundColor: Colors.red[600],
                foregroundColor: Colors.white,
              ),
              child: Text(
                'Delete',
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        );
      },
    ) ?? false;
  }

  Widget _buildEmptyState() {
    return Column(
      children: [
        // Main content area - fills available space
        Expanded(
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  'No Files Selected',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'Select files to start sharing',
                  style: TextStyle(
                    color: Colors.grey[400],
                    fontSize: 16,
                    fontWeight: FontWeight.w400,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
        
        // Action buttons - exactly same position as non-empty state
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 36),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _buildRectangularButton(
                icon: Icons.attach_file_rounded,
                onTap: _selectFiles,
                color: Colors.grey[900]!,
                textColor: Colors.white,
                label: 'Add Files',
              ),
              _buildRectangularButton(
                icon: Icons.folder_rounded,
                onTap: _pickFolder,
                color: Colors.grey[900]!,
                textColor: Colors.white,
                label: 'Folder',
              ),
              _buildRectangularButton(
                icon: Icons.send_rounded,
                onTap: null, // Disabled
                color: Colors.grey[700]!,
                textColor: Colors.grey[400]!,
                label: 'Send',
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildLoadingState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Stack(
            alignment: Alignment.center,
            children: [
              // Outer rotating ring
              SizedBox(
                width: 90,
                height: 90,
                child: CircularProgressIndicator(
                  color: Colors.yellow[300],
                  strokeWidth: 3,
                ),
              ),
              // Inner pulsing circle
              Container(
                width: 60,
                height: 60,
                decoration: BoxDecoration(
                  color: Colors.grey[900],
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: Colors.grey[800]!,
                    width: 2,
                  ),
                ),
                child: Icon(
                  Icons.hourglass_empty_rounded,
                  color: Colors.yellow[300],
                  size: 28,
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          Text(
            'Loading...',
            style: TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Please wait',
            style: TextStyle(
              color: Colors.grey[500],
              fontSize: 14,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActionButton({
    required IconData icon,
    required VoidCallback? onTap,
    required Color color,
    required Color textColor,
    required String label,
  }) {
    final isEnabled = onTap != null;
    final isPrimary = color == Colors.yellow[300];
    
    return StatefulBuilder(
      builder: (context, setState) {
        bool isPressed = false;
        
        return GestureDetector(
          onTapDown: (_) => setState(() => isPressed = true),
          onTapUp: (_) => setState(() => isPressed = false),
          onTapCancel: () => setState(() => isPressed = false),
          child: AnimatedContainer(
            duration: Duration(milliseconds: 150),
            width: 88,
            height: 88,
            transform: Matrix4.identity()..scale(isPressed ? 0.95 : 1.0),
            decoration: BoxDecoration(
              color: isEnabled 
                ? (isPrimary ? Colors.yellow[300] : color)
                : Colors.grey[700],
              shape: BoxShape.circle,
              boxShadow: isEnabled ? [
                BoxShadow(
                  color: (isPrimary ? Colors.yellow[400]! : color).withOpacity(isPressed ? 0.2 : 0.3),
                  blurRadius: isPressed ? 12 : 16,
                  offset: Offset(0, isPressed ? 4 : 8),
                  spreadRadius: 0,
                ),
                BoxShadow(
                  color: Colors.black.withOpacity(0.1),
                  blurRadius: 4,
                  offset: Offset(0, 2),
                  spreadRadius: 0,
                ),
              ] : [
                BoxShadow(
                  color: Colors.grey[800]!.withOpacity(0.3),
                  blurRadius: 8,
                  offset: Offset(0, 4),
                  spreadRadius: 0,
                ),
              ],
              border: isEnabled && isPrimary 
                ? Border.all(color: Colors.yellow[600]!, width: 2)
                : null,
            ),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: isEnabled ? onTap : null,
                borderRadius: BorderRadius.circular(44),
                splashColor: isEnabled ? Colors.white.withOpacity(0.2) : Colors.transparent,
                highlightColor: isEnabled ? Colors.white.withOpacity(0.1) : Colors.transparent,
                child: Center(
                  child: AnimatedScale(
                    duration: Duration(milliseconds: 150),
                    scale: isEnabled ? 1.0 : 0.8,
                    child: Icon(
                      icon, 
                      color: isEnabled ? textColor : Colors.grey[500], 
                      size: 28,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildRoundActionButton({
    required IconData icon,
    required VoidCallback? onTap,
    required Color color,
    required Color textColor,
  }) {
    final isPrimary = color == Colors.yellow[300];
    
    return StatefulBuilder(
      builder: (context, setState) {
        bool isPressed = false;
        
        return GestureDetector(
          onTapDown: (_) => setState(() => isPressed = true),
          onTapUp: (_) => setState(() => isPressed = false),
          onTapCancel: () => setState(() => isPressed = false),
          child: AnimatedContainer(
            duration: Duration(milliseconds: 150),
            width: 88,
            height: 88,
            transform: Matrix4.identity()..scale(isPressed ? 0.95 : 1.0),
            decoration: BoxDecoration(
              color: isPrimary ? Colors.yellow[300] : color,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: (isPrimary ? Colors.yellow[400]! : color).withOpacity(isPressed ? 0.2 : 0.3),
                  blurRadius: isPressed ? 12 : 16,
                  offset: Offset(0, isPressed ? 4 : 8),
                  spreadRadius: 0,
                ),
                BoxShadow(
                  color: Colors.black.withOpacity(0.1),
                  blurRadius: 4,
                  offset: Offset(0, 2),
                  spreadRadius: 0,
                ),
              ],
              border: isPrimary 
                ? Border.all(color: Colors.yellow[600]!, width: 2)
                : null,
            ),
            child: Material(
              color: Colors.transparent,
                        child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(16),
            splashColor: Colors.white.withOpacity(0.2),
            highlightColor: Colors.white.withOpacity(0.1),
                child: Center(
                  child: Icon(icon, color: textColor, size: 26),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  // Enhanced button for the share code copy functionality
  Widget _buildCopyButton({
    required String text,
    required VoidCallback onTap,
    required Color backgroundColor,
    required Color textColor,
    required IconData icon,
    required String label,
  }) {
    return StatefulBuilder(
      builder: (context, setState) {
        bool isPressed = false;
        
        return GestureDetector(
          onTapDown: (_) => setState(() => isPressed = true),
          onTapUp: (_) => setState(() => isPressed = false),
          onTapCancel: () => setState(() => isPressed = false),
          child: AnimatedContainer(
            duration: Duration(milliseconds: 150),
            transform: Matrix4.identity()..scale(isPressed ? 0.95 : 1.0),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: onTap,
                borderRadius: BorderRadius.circular(16),
                splashColor: Colors.white.withOpacity(0.2),
                highlightColor: Colors.white.withOpacity(0.1),
                child: Container(
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    color: backgroundColor,
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: [
                      BoxShadow(
                        color: backgroundColor.withOpacity(isPressed ? 0.2 : 0.3),
                        blurRadius: isPressed ? 8 : 12,
                        offset: Offset(0, isPressed ? 3 : 6),
                        spreadRadius: 0,
                      ),
                    ],
                    border: Border.all(
                      color: backgroundColor == Colors.yellow[300]! 
                        ? Colors.yellow[600]! 
                        : Colors.transparent,
                      width: 1.5,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(icon, color: textColor, size: 18),
                      SizedBox(width: 8),
                      Text(
                        label,
                        style: TextStyle(
                          color: textColor,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  // Enhanced pause/resume button with better visual feedback
  Widget _buildPauseResumeButton({
    required bool isPaused,
    required VoidCallback onTap,
    required double progress,
  }) {
    return StatefulBuilder(
      builder: (context, setState) {
        bool isPressed = false;
        
        return GestureDetector(
          onTapDown: (_) => setState(() => isPressed = true),
          onTapUp: (_) => setState(() => isPressed = false),
          onTapCancel: () => setState(() => isPressed = false),
          child: AnimatedContainer(
            duration: Duration(milliseconds: 150),
            width: 32,
            height: 32,
            transform: Matrix4.identity()..scale(isPressed ? 0.9 : 1.0),
            decoration: BoxDecoration(
              color: isPaused ? Colors.green[400] : Colors.yellow[400],
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: (isPaused ? Colors.green[400] : Colors.yellow[400])!.withOpacity(isPressed ? 0.3 : 0.4),
                  blurRadius: isPressed ? 6 : 8,
                  offset: Offset(0, isPressed ? 2 : 4),
                  spreadRadius: 0,
                ),
              ],
              border: Border.all(
                color: Colors.white.withOpacity(0.3),
                width: 1,
              ),
            ),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: onTap,
                borderRadius: BorderRadius.circular(16),
                splashColor: Colors.white.withOpacity(0.3),
                highlightColor: Colors.white.withOpacity(0.2),
                child: Center(
                  child: AnimatedSwitcher(
                    duration: Duration(milliseconds: 200),
                    child: Icon(
                      isPaused ? Icons.play_arrow_rounded : Icons.pause_rounded,
                      key: ValueKey(isPaused),
                      color: Colors.white,
                      size: 16,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  // Small clear button for the header
  Widget _buildSmallClearButton() {
    return StatefulBuilder(
      builder: (context, setState) {
        bool isPressed = false;
        
        return GestureDetector(
          onTapDown: (_) => setState(() => isPressed = true),
          onTapUp: (_) => setState(() => isPressed = false),
          onTapCancel: () => setState(() => isPressed = false),
          child: AnimatedContainer(
            duration: Duration(milliseconds: 150),
            transform: Matrix4.identity()..scale(isPressed ? 0.95 : 1.0),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: _clearAllFiles,
                borderRadius: BorderRadius.circular(16),
                splashColor: Colors.red.withOpacity(0.2),
                highlightColor: Colors.red.withOpacity(0.1),
                child: Container(
                  padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.red[600]!.withOpacity(isPressed ? 0.8 : 0.6),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: Colors.red[400]!.withOpacity(isPressed ? 0.9 : 0.7),
                      width: 1,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.red.withOpacity(isPressed ? 0.2 : 0.3),
                        blurRadius: isPressed ? 4 : 8,
                        offset: Offset(0, isPressed ? 1 : 3),
                        spreadRadius: 0,
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.clear_all_rounded,
                        color: Colors.white,
                        size: 16,
                      ),
                      SizedBox(width: 6),
                      Text(
                        'Clear All',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  // Pill-shaped action button for file selection
  Widget _buildPillActionButton({
    required IconData icon,
    required VoidCallback? onTap,
    required Color color,
    required Color textColor,
    required String label,
  }) {
    final isEnabled = onTap != null;
    
    return StatefulBuilder(
      builder: (context, setState) {
        bool isPressed = false;
        
        return GestureDetector(
          onTapDown: (_) => setState(() => isPressed = true),
          onTapUp: (_) => setState(() => isPressed = false),
          onTapCancel: () => setState(() => isPressed = false),
          child: AnimatedContainer(
            duration: Duration(milliseconds: 150),
            transform: Matrix4.identity()..scale(isPressed ? 0.95 : 1.0),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: isEnabled ? onTap : null,
                borderRadius: BorderRadius.circular(16),
                splashColor: Colors.white.withOpacity(0.2),
                highlightColor: Colors.white.withOpacity(0.1),
                child: Container(
                  padding: EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                  decoration: BoxDecoration(
                    color: isEnabled ? color : Colors.grey[700],
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: [
                      BoxShadow(
                        color: color.withOpacity(isPressed ? 0.2 : 0.3),
                        blurRadius: isPressed ? 8 : 12,
                        offset: Offset(0, isPressed ? 3 : 6),
                        spreadRadius: 0,
                      ),
                      BoxShadow(
                        color: Colors.black.withOpacity(0.1),
                        blurRadius: 4,
                        offset: Offset(0, 2),
                        spreadRadius: 0,
                      ),
                    ],
                    border: Border.all(
                      color: Colors.white.withOpacity(0.2),
                      width: 1,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        icon,
                        color: isEnabled ? textColor : Colors.grey[500],
                        size: 20,
                      ),
                      SizedBox(width: 8),
                      Text(
                        label,
                        style: TextStyle(
                          color: isEnabled ? textColor : Colors.grey[500],
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  // Rounded square button for folder selection
  Widget _buildRoundedSquareButton({
    required IconData icon,
    required VoidCallback? onTap,
    required Color color,
    required Color textColor,
    required String label,
  }) {
    final isEnabled = onTap != null;
    
    return StatefulBuilder(
      builder: (context, setState) {
        bool isPressed = false;
        
        return GestureDetector(
          onTapDown: (_) => setState(() => isPressed = true),
          onTapUp: (_) => setState(() => isPressed = false),
          onTapCancel: () => setState(() => isPressed = false),
          child: AnimatedContainer(
            duration: Duration(milliseconds: 150),
            transform: Matrix4.identity()..scale(isPressed ? 0.95 : 1.0),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: isEnabled ? onTap : null,
                borderRadius: BorderRadius.circular(16),
                splashColor: Colors.white.withOpacity(0.2),
                highlightColor: Colors.white.withOpacity(0.1),
                child: Container(
                  width: 100,
                  height: 80,
                  decoration: BoxDecoration(
                    color: isEnabled ? color : Colors.grey[700],
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: [
                      BoxShadow(
                        color: color.withOpacity(isPressed ? 0.2 : 0.3),
                        blurRadius: isPressed ? 8 : 12,
                        offset: Offset(0, isPressed ? 3 : 6),
                        spreadRadius: 0,
                      ),
                      BoxShadow(
                        color: Colors.black.withOpacity(0.1),
                        blurRadius: 4,
                        offset: Offset(0, 2),
                        spreadRadius: 0,
                      ),
                    ],
                    border: Border.all(
                      color: Colors.white.withOpacity(0.2),
                      width: 1,
                    ),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        icon,
                        color: isEnabled ? textColor : Colors.grey[500],
                        size: 24,
                      ),
                      SizedBox(height: 6),
                      Text(
                        label,
                        style: TextStyle(
                          color: isEnabled ? textColor : Colors.grey[500],
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  // Rectangular button with consistent corner radius
  Widget _buildRectangularButton({
    required IconData icon,
    required VoidCallback? onTap,
    required Color color,
    required Color textColor,
    required String label,
  }) {
    final isEnabled = onTap != null;
    final isPrimary = color == Colors.yellow[300];
    
    return StatefulBuilder(
      builder: (context, setState) {
        bool isPressed = false;
        
        return GestureDetector(
          onTapDown: (_) => setState(() => isPressed = true),
          onTapUp: (_) => setState(() => isPressed = false),
          onTapCancel: () => setState(() => isPressed = false),
          child: AnimatedContainer(
            duration: Duration(milliseconds: 150),
            transform: Matrix4.identity()..scale(isPressed ? 0.95 : 1.0),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: isEnabled ? onTap : null,
                borderRadius: BorderRadius.circular(16),
                splashColor: Colors.white.withOpacity(0.2),
                highlightColor: Colors.white.withOpacity(0.1),
                                  child: Container(
                    width: 90,
                    height: 80,
                    decoration: BoxDecoration(
                      color: isEnabled 
                        ? (isPrimary ? Colors.yellow[300] : color)
                        : Colors.grey[700],
                      borderRadius: BorderRadius.circular(16),
                    boxShadow: [
                      BoxShadow(
                        color: (isPrimary ? Colors.yellow[400]! : color).withOpacity(isPressed ? 0.2 : 0.3),
                        blurRadius: isPressed ? 8 : 12,
                        offset: Offset(0, isPressed ? 3 : 6),
                        spreadRadius: 0,
                      ),
                      BoxShadow(
                        color: Colors.black.withOpacity(0.1),
                        blurRadius: 4,
                        offset: Offset(0, 2),
                        spreadRadius: 0,
                      ),
                    ],
                    border: isEnabled && isPrimary 
                      ? Border.all(color: Colors.yellow[600]!, width: 2)
                      : Border.all(color: Colors.white.withOpacity(0.2), width: 1),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        icon,
                        color: isEnabled ? textColor : Colors.grey[500],
                        size: 24,
                      ),
                      SizedBox(height: 6),
                                              Text(
                          label,
                          style: TextStyle(
                            color: isEnabled ? textColor : Colors.grey[500],
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                          textAlign: TextAlign.center,
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  // Hexagon-shaped main action button
  Widget _buildHexagonActionButton({
    required IconData icon,
    required VoidCallback? onTap,
    required Color color,
    required Color textColor,
    required String label,
  }) {
    final isEnabled = onTap != null;
    final isPrimary = color == Colors.yellow[300];
    
    return StatefulBuilder(
      builder: (context, setState) {
        bool isPressed = false;
        
        return GestureDetector(
          onTapDown: (_) => setState(() => isPressed = true),
          onTapUp: (_) => setState(() => isPressed = false),
          onTapCancel: () => setState(() => isPressed = false),
          child: AnimatedContainer(
            duration: Duration(milliseconds: 150),
            transform: Matrix4.identity()..scale(isPressed ? 0.95 : 1.0),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: isEnabled ? onTap : null,
                borderRadius: BorderRadius.circular(0),
                splashColor: Colors.white.withOpacity(0.2),
                highlightColor: Colors.white.withOpacity(0.1),
                child: CustomPaint(
                  painter: HexagonPainter(
                    color: isEnabled ? color : Colors.grey[700]!,
                    isPressed: isPressed,
                    isPrimary: isPrimary,
                  ),
                  child: Container(
                    width: 120,
                    height: 100,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          icon,
                          color: isEnabled ? textColor : Colors.grey[500],
                          size: 28,
                        ),
                        SizedBox(height: 8),
                        Text(
                          label,
                          style: TextStyle(
                            color: isEnabled ? textColor : Colors.grey[500],
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  IconData _getFileIcon(String fileName) {
    final ext = _getFileExtension(fileName).toLowerCase();
    switch (ext) {
      case 'pdf':
      case 'doc':
      case 'docx':
      case 'txt':
        return Icons.description_rounded;
      case 'jpg':
      case 'jpeg':
      case 'png':
      case 'gif':
        return Icons.image_rounded;
      case 'mp4':
      case 'avi':
      case 'mov':
        return Icons.video_file_rounded;
      case 'mp3':
      case 'wav':
        return Icons.audio_file_rounded;
      case 'zip':
      case 'rar':
      case '7z':
        return Icons.folder_zip_rounded;
      case 'exe':
        return Icons.settings_rounded;
      default:
        return Icons.insert_drive_file_rounded;
    }
  }
}

// Custom painter for hexagon shape
class HexagonPainter extends CustomPainter {
  final Color color;
  final bool isPressed;
  final bool isPrimary;

  HexagonPainter({
    required this.color,
    required this.isPressed,
    required this.isPrimary,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    
    if (isPrimary) {
      paint.shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Colors.yellow[300]!, Colors.yellow[400]!],
      ).createShader(Rect.fromLTWH(0, 0, size.width, size.height));
    }

    final path = Path();
    final centerX = size.width / 2;
    final centerY = size.height / 2;
    final radius = size.width / 2.5;

    // Create hexagon path
    for (int i = 0; i < 6; i++) {
      final angle = (i * 60 - 30) * (3.14159 / 180);
      final x = centerX + radius * cos(angle);
      final y = centerY + radius * sin(angle);
      
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    path.close();

    // Draw main hexagon
    canvas.drawPath(path, paint);

    // Add border if primary
    if (isPrimary) {
      final borderPaint = Paint()
        ..color = Colors.yellow[600]!
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2;
      canvas.drawPath(path, borderPaint);
    }

    // Add shadow effect
    if (!isPressed) {
      final shadowPaint = Paint()
        ..color = Colors.black.withOpacity(0.2)
        ..style = PaintingStyle.fill;
      
      final shadowPath = Path();
      for (int i = 0; i < 6; i++) {
        final angle = (i * 60 - 30) * (3.14159 / 180);
        final x = centerX + radius * cos(angle) + 3;
        final y = centerY + radius * sin(angle) + 3;
        
        if (i == 0) {
          shadowPath.moveTo(x, y);
        } else {
          shadowPath.lineTo(x, y);
        }
      }
      shadowPath.close();
      canvas.drawPath(shadowPath, shadowPaint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

// Animated Radar Icon Widget
class _AnimatedRadar extends StatefulWidget {
  final bool isActive;
  
  const _AnimatedRadar({Key? key, required this.isActive}) : super(key: key);
  
  @override
  State<_AnimatedRadar> createState() => _AnimatedRadarState();
}

class _AnimatedRadarState extends State<_AnimatedRadar> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  
  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: Duration(seconds: 2),
    )..repeat();
  }
  
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
  
  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Transform.rotate(
          angle: _controller.value * 2 * 3.14159,
          child: Icon(
            Icons.radar,
            color: widget.isActive ? Colors.yellow[300] : Colors.grey[600],
            size: 16,
          ),
        );
      },
    );
  }
}

// Pulsing Search Indicator Widget
class _PulsingSearchIndicator extends StatefulWidget {
  const _PulsingSearchIndicator({Key? key}) : super(key: key);
  
  @override
  State<_PulsingSearchIndicator> createState() => _PulsingSearchIndicatorState();
}

class _PulsingSearchIndicatorState extends State<_PulsingSearchIndicator> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnimation;
  
  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: 1500),
    )..repeat(reverse: true);
    
    _scaleAnimation = Tween<double>(begin: 0.8, end: 1.2).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
  }
  
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
  
  @override
  Widget build(BuildContext context) {
    return Stack(
      alignment: Alignment.center,
      children: [
        // Outer pulse
        AnimatedBuilder(
          animation: _scaleAnimation,
          builder: (context, child) {
            return Transform.scale(
              scale: _scaleAnimation.value,
              child: Container(
                width: 80,
                height: 80,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: Colors.yellow[300]!.withOpacity(0.3),
                    width: 2,
                  ),
                ),
              ),
            );
          },
        ),
        // Inner icon
        Container(
          width: 60,
          height: 60,
          decoration: BoxDecoration(
            color: Colors.grey[800],
            shape: BoxShape.circle,
          ),
          child: Icon(
            Icons.search,
            color: Colors.grey[600],
            size: 30,
          ),
        ),
      ],
    );
  }
}