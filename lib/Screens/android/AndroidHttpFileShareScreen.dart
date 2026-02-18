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
import '../../services/device_discovery_service.dart';
import '../../services/range_request_handler.dart';

import 'package:http/http.dart' as http; // Add http package for handshake
import '../../services/wifi_direct_service.dart';
import '../../widgets/connection_request_dialog.dart';
import 'AndroidReceiveScreen.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:screen_brightness/screen_brightness.dart';

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

class AndroidHttpFileShareScreen extends StatefulWidget {
  final List<Map<dynamic, dynamic>>? initialSharedFiles;

  const AndroidHttpFileShareScreen({super.key, this.initialSharedFiles});

  @override
  _AndroidHttpFileShareScreenState createState() =>
      _AndroidHttpFileShareScreenState();
}

class _AndroidHttpFileShareScreenState
    extends State<AndroidHttpFileShareScreen> {
  final _pageController = PageController();
  final _safUtil = SafUtil();
  List<String> _fileUris = [];
  List<String> _fileNames = [];

  String? _localIp;
  HttpServer? _server;
  bool _isSharing = false;
  bool _useHttps = false;
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

  // Track total bytes sent across all parallel range requests per file
  Map<int, int> _totalBytesSentPerFile = {}; // fileIndex -> totalBytesSent
  Map<int, Set<String>> _activeRangeRequests =
      {}; // fileIndex -> Set of range strings
  Map<int, Map<String, int>> _rangeBytesSentPerRequest =
      {}; // fileIndex -> (rangeKey -> bytesSent)

  // Track downloads per client for multiple simultaneous downloads
  Map<String, Map<int, DownloadStatus>> _clientDownloads =
      {}; // clientIP -> {fileIndex -> DownloadStatus}
  List<String> _connectedClients = []; // List of connected client IPs
  Map<String, String> _clientDeviceNames = {}; // clientIP -> deviceName mapping

  final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
      FlutterLocalNotificationsPlugin();

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
  Set<String> _processedRequests =
      {}; // Track processed request IPs to prevent duplicates
  Map<String, DateTime> _lastRequestTime = {}; // Track last request time per IP
  bool _isShowingConnectionDialog = false; // Prevent multiple dialogs

  // WiFi Direct Mode

  final WiFiDirectService _wifiDirectService = WiFiDirectService();
  bool _isWifiDirectMode = false;
  List<WiFiDirectPeer> _wifiDirectPeers = [];
  StreamSubscription? _wifiDirectModeSubscription;
  StreamSubscription? _wifiDirectPeersSubscription;
  StreamSubscription? _wifiDirectConnectionSubscription;
  StreamSubscription? _wifiDirectDirectPeersSubscription;
  StreamSubscription? _wifiDirectDirectConnectionSubscription;
  WiFiDirectConnectionInfo? _wifiDirectConnectionInfo;
  bool _isConnectingWifiDirect = false;
  String? _connectingPeerAddress;
  bool _waitingForWifiDirectPeer =
      false; // Flag to track if we are waiting to auto-connect

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
    if (bytes < 1024 * 1024 * 1024)
      return "${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB";
    return "${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB";
  }

  static const MethodChannel _platform = MethodChannel('zapshare.saf');

  @override
  void initState() {
    super.initState();

    // Handle initial shared files FIRST - set them synchronously before any async operations
    if (widget.initialSharedFiles != null &&
        widget.initialSharedFiles!.isNotEmpty) {
      print(
        '📁 [HttpFileShareScreen] Processing ${widget.initialSharedFiles!.length} initial shared files IMMEDIATELY',
      );
      print('📁 [HttpFileShareScreen] Files: ${widget.initialSharedFiles}');
      _processInitialFiles(widget.initialSharedFiles!);
    }

    _init();
    _initLocalNotifications();

    // Initialize device discovery
    _initDeviceDiscovery();

    // Initialize WiFi Direct service for peer discovery
    _initWifiDirect();

    // Set up listener for future shared files (after initial processing)
    _listenForSharedFiles();

    // Periodically cleanup disconnected clients
    Timer.periodic(Duration(minutes: 2), (timer) {
      if (mounted) {
        _cleanupDisconnectedClients();
      }
    });
  }

  void _initWifiDirect() async {
    // Initialize WiFi Direct service
    print('🔧 Initializing WiFi Direct service...');
    final initialized = await _wifiDirectService.initialize();

    if (!initialized) {
      print('⚠️ WiFi Direct service initialization failed');
      return;
    }

    // Start peer discovery
    print('🔍 Starting WiFi Direct peer discovery...');
    await _wifiDirectService.startPeerDiscovery();

    // Listen to discovered peers from WiFi Direct service
    _wifiDirectDirectPeersSubscription = _wifiDirectService.peersStream.listen((
      peers,
    ) {
      if (mounted) {
        setState(() {
          _wifiDirectPeers = peers;
        });
        print('📱 WiFi Direct peers updated: ${peers.length} peers');
      }
    });

    // Listen to WiFi Direct connection info
    _wifiDirectDirectConnectionSubscription = _wifiDirectService
        .connectionInfoStream
        .listen((info) {
          if (mounted) {
            setState(() {
              _wifiDirectConnectionInfo = info;
              _isConnectingWifiDirect = false;
            });

            if (info.groupFormed) {
              print('✅ WiFi Direct group formed via direct service!');
              _handleWifiDirectConnected(info);
            }
          }
        });

    print('✅ WiFi Direct service initialized and discovering');
  }

  Future<void> _handleWifiDirectConnected(WiFiDirectConnectionInfo info) async {
    print(
      '🔗 WiFi Direct Connected! Group Owner: ${info.isGroupOwner}, Owner Address: ${info.groupOwnerAddress}',
    );
    print('   ⚠️  NOTE: Wi-Fi Direct role does NOT determine sender/receiver!');
    print('   Both devices will start HTTP server and use UDP discovery.');

    // Wait for IP assignment loop (max 10 seconds)
    // We need to make sure we have the 192.168.49.x IP before we start the server or discovery
    print('⏳ Waiting for Wi-Fi Direct IP assignment (192.168.49.x)...');
    int ipAttempts = 0;
    while (ipAttempts < 10) {
      await Future.delayed(Duration(seconds: 1));
      await _fetchLocalIp();
      if (_localIp != null && _localIp!.startsWith('192.168.49.')) {
        print('✅ Wi-Fi Direct IP assigned: $_localIp');
        break;
      }
      ipAttempts++;
      if (ipAttempts % 2 == 0)
        print(
          '   ... still waiting for IP (Attempt $ipAttempts/10) - Current: $_localIp',
        );
    }

    if (_localIp == null || !_localIp!.startsWith('192.168.49.')) {
      print(
        '⚠️ Warning: Could not get 192.168.49.x IP. Proceeding with Best Effort: $_localIp',
      );
    }

    // Refresh local IP one last time to be sure
    // await _fetchLocalIp(); // Already done in loop

    // BOTH devices start HTTP server (regardless of role)
    print('🚀 Starting HTTP server on WiFi Direct network...');
    print('   My IP: $_localIp');
    print('   Role: ${info.isGroupOwner ? "Group Owner" : "Client"}');
    await _startServer();

    // Restart UDP Discovery on the new interface
    // Crucial: The discovery service needs to bind to the new interface
    print('🔄 Restarting Device Discovery Service on new interface...');
    try {
      await _discoveryService.stop();
      // Give it a moment to release ports
      await Future.delayed(Duration(milliseconds: 500));
      await _discoveryService.start();
    } catch (e) {
      print('Error restarting discovery service: $e');
    }

    // BOTH devices continue UDP discovery to find peer's IP
    print('📡 UDP discovery active - waiting to discover peer device...');
    print('   Peer will be discovered automatically via UDP broadcast');

    // If we have files to share, wait for peer discovery then send request
    if (_fileUris.isNotEmpty) {
      print(
        '📤 Files selected - will send connection request once peer is discovered',
      );
      print('   Files: ${_fileNames.length} files');

      // Calculate total size
      final totalSize = _fileSizeList.fold<int>(0, (sum, size) => sum + size);

      DiscoveredDevice? peerDevice;
      int attempts = 0;
      const maxAttempts = 30; // Wait up to 30 seconds

      print('⏳ Starting peer IP discovery loop ($maxAttempts attempts)...');

      // Set flag so stream listener can also catch it immediately
      _waitingForWifiDirectPeer = true;

      while (attempts < maxAttempts && _waitingForWifiDirectPeer) {
        final discoveredDevices = _discoveryService.discoveredDevices;

        // Look for devices on Wi-Fi Direct subnet (192.168.49.x)
        final wifiDirectPeers =
            discoveredDevices.where((device) {
              // Check for standard Wi-Fi Direct subnet OR if we are on the same subnet
              return (device.ipAddress.startsWith('192.168.49.') ||
                      (_localIp != null &&
                          device.ipAddress.split('.').take(3).join('.') ==
                              _localIp!.split('.').take(3).join('.'))) &&
                  device.ipAddress != _localIp &&
                  device.ipAddress != '0.0.0.0';
            }).toList();

        if (wifiDirectPeers.isNotEmpty) {
          peerDevice = wifiDirectPeers.first;
          print(
            '✅ Found Wi-Fi Direct peer via UDP discovery: ${peerDevice.deviceName} (${peerDevice.ipAddress})',
          );
          _waitingForWifiDirectPeer = false; // Stop waiting
          break;
        }

        attempts++;
        await Future.delayed(Duration(seconds: 1));
        if (attempts % 5 == 0)
          print('   ... searching for peer (attempt $attempts/$maxAttempts)');
      }

      // If loop finished and we found a device (or stream found it and set flag false, but here 'peerDevice' might be null if stream handled it)
      // wait, if stream handled it, _waitingForWifiDirectPeer is false. peerDevice is null.
      // We should check if stream handled it.
      if (!_waitingForWifiDirectPeer && peerDevice == null) {
        print('✨ Wi-Fi Direct peer handled by stream listener.');
        return;
      }

      if (peerDevice != null) {
        // Peer found! Send HTTP Handshake
        await _sendHttpConnectionRequest(
          peerDevice.ipAddress,
          _fileNames,
          totalSize,
        );
      } else {
        // Fallback: Try common Wi-Fi Direct IPs blindly
        print(
          '⚠️  No peer discovered via UDP after timeout, trying common Wi-Fi Direct IPs...',
        );
        final targetIps =
            info.isGroupOwner
                ? [
                  '192.168.49.2',
                  '192.168.49.3',
                  '192.168.49.4',
                ] // Try multiple client IPs
                : [
                  info.groupOwnerAddress.isNotEmpty
                      ? info.groupOwnerAddress
                      : '192.168.49.1',
                ];

        bool sent = false;
        for (final targetIp in targetIps) {
          if (targetIp == _localIp) continue;

          print('📡 Attempting HTTP handshake to: $targetIp');
          if (await _sendHttpConnectionRequest(
            targetIp,
            _fileNames,
            totalSize,
          )) {
            sent = true;
            break;
          }
        }

        if (!sent && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Could not find peer. Make sure app is open on other device.',
              ),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    } else {
      print('📱 No files selected - ready to receive');
      print('   Role: ${info.isGroupOwner ? "Group Owner" : "Client"}');
      print('   HTTP server running at: http://$_localIp:8080');
      print('   Waiting for peer to send connection request...');
    }
  }

  // New method for reliable HTTP handshake
  Future<bool> _sendHttpConnectionRequest(
    String targetIp,
    List<String> fileNames,
    int totalSize,
  ) async {
    try {
      final url = Uri.parse('http://$targetIp:8080/connection-request');
      print('📤 Sending HTTP Connection Request to $url');

      final body = jsonEncode({
        'deviceId': _discoveryService.myDeviceId ?? 'unknown',
        'deviceName': _discoveryService.myDeviceName ?? 'Unknown Device',
        'platform': 'android', // Assuming android screen
        'fileCount': fileNames.length,
        'fileNames': fileNames,
        'totalSize': totalSize,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      });

      final response = await http
          .post(url, headers: {'Content-Type': 'application/json'}, body: body)
          .timeout(Duration(seconds: 5));

      if (response.statusCode == 200) {
        final respData = jsonDecode(response.body);
        if (respData['accepted'] == true) {
          print('✅ Connection Accepted by Peer (HTTP response)');
          // _startSharingToDevice(targetIp); // Server already started before handshake
          return true;
        } else {
          print('❌ Connection Declined by Peer (HTTP response)');
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Connection declined by peer'),
                backgroundColor: Colors.red,
              ),
            );
          }
          return true; // Communication worked, but declined
        }
      } else {
        print('⚠️ HTTP Request failed with status: ${response.statusCode}');
      }
    } catch (e) {
      print('❌ HTTP Connection Request failed: $e');
    }
    return false;
  }

  void _processInitialFiles(List<Map> files) {
    print(
      '📁 [_processInitialFiles] Starting synchronous file processing for ${files.length} files',
    );
    List<String> uris = [];
    List<String> names = [];
    List<int> sizes = [];

    for (final file in files) {
      final uri = file['uri'] as String;
      final name = file['name'] as String? ?? uri.split('/').last;
      print('📁 [_processInitialFiles] Adding file: $name (URI: $uri)');
      uris.add(uri);
      names.add(name);
      sizes.add(0); // Will get actual size asynchronously later
    }

    // Set state SYNCHRONOUSLY in initState (before first build)
    _fileUris = uris;
    _fileNames = names;
    _progressList = List.generate(uris.length, (_) => ValueNotifier(0.0));
    _isPausedList = List.generate(uris.length, (_) => ValueNotifier(false));
    _bytesSentList = List.generate(uris.length, (_) => 0);
    _fileSizeList = sizes;
    _completedFiles = List.generate(uris.length, (_) => false);
    _loading = false;

    print('✅ [_processInitialFiles] Files set synchronously: $_fileNames');

    // Get file sizes asynchronously after initialization
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      print('📁 [_processInitialFiles] Getting file sizes asynchronously...');
      for (int i = 0; i < uris.length; i++) {
        try {
          final size = await getFileSizeFromUri(uris[i]);
          if (mounted) {
            setState(() {
              _fileSizeList[i] = size;
            });
            print(
              '📁 [_processInitialFiles] File ${names[i]} size: $size bytes',
            );
          }
        } catch (e) {
          print(
            '⚠️ [_processInitialFiles] Could not get size for ${names[i]}: $e',
          );
        }
      }
    });
  }

  void _listenForSharedFiles() {
    _platform.setMethodCallHandler((call) async {
      if (call.method == 'sharedFiles') {
        final List<dynamic> files = call.arguments as List<dynamic>;
        if (files.isNotEmpty) {
          print(
            '📁 [MethodChannel] Received shared files: ${files.length} files',
          );
          print('📁 [MethodChannel] Files data: $files');

          // Check if we're already on this screen
          if (mounted) {
            print(
              '📁 [MethodChannel] Screen is mounted, processing files directly',
            );
            await _handleSharedFiles(files.cast<Map>());
          } else {
            print(
              '📁 [MethodChannel] Screen not mounted, navigation should happen from MainActivity',
            );
            // The files will be passed via initialSharedFiles from main.dart navigation
          }
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
    print('📁 [_handleSharedFiles] Starting to process ${files.length} files');
    setState(() => _loading = true);
    List<String> uris = [];
    List<String> names = [];
    List<int> sizes = [];
    for (final file in files) {
      final uri = file['uri'] as String;
      final name = file['name'] as String? ?? uri.split('/').last;
      print('📁 [_handleSharedFiles] Processing file: $name (URI: $uri)');
      int size = 0;
      try {
        size = await getFileSizeFromUri(uri);
        print('📁 [_handleSharedFiles] File size: $size bytes');
      } catch (e) {
        print('⚠️ [_handleSharedFiles] Could not get file size: $e');
      }
      uris.add(uri);
      names.add(name);
      sizes.add(size);
    }
    print('📁 [_handleSharedFiles] Setting state with ${uris.length} files');
    setState(() {
      _fileUris = uris;
      _fileNames = names;
      _progressList = List.generate(uris.length, (_) => ValueNotifier(0.0));
      _isPausedList = List.generate(uris.length, (_) => ValueNotifier(false));
      _bytesSentList = List.generate(uris.length, (_) => 0);
      _fileSizeList = sizes;
      _completedFiles = List.generate(
        uris.length,
        (_) => false,
      ); // Initialize completedFiles
      _loading = false;
    });
    print('✅ [_handleSharedFiles] Files processed successfully');
    print('📁 [_handleSharedFiles] _fileNames: $_fileNames');
    print('📁 [_handleSharedFiles] _fileUris: $_fileUris');
  }

  Future<void> _init() async {
    await _clearCache();
    await _fetchLocalIp();

    _showConnectionTip();
  }

  Future<void> _initLocalNotifications() async {
    const AndroidInitializationSettings initializationSettingsAndroid =
        AndroidInitializationSettings('@mipmap/launcher_icon');
    final InitializationSettings initializationSettings =
        InitializationSettings(android: initializationSettingsAndroid);
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

  Future<void> showProgressNotification(
    int fileIndex,
    double progress,
    String fileName, {
    double speedMbps = 0.0,
    bool paused = false,
  }) async {
    final percent = (progress * 100).toInt();

    // Calculate estimated time remaining
    String timeRemaining = 'Calculating...';
    if (speedMbps > 0 && progress > 0 && progress < 1.0) {
      final fileSize =
          _fileSizeList.length > fileIndex ? _fileSizeList[fileIndex] : 0;
      final remainingBytes = fileSize * (1.0 - progress);
      final remainingMB = remainingBytes / (1024 * 1024);
      final remainingSeconds = (remainingMB / speedMbps).round();

      if (remainingSeconds < 60) {
        timeRemaining = '${remainingSeconds}s';
      } else if (remainingSeconds < 3600) {
        final minutes = (remainingSeconds / 60).floor();
        final seconds = remainingSeconds % 60;
        timeRemaining = '${minutes}m ${seconds}s';
      } else {
        final hours = (remainingSeconds / 3600).floor();
        final minutes = ((remainingSeconds % 3600) / 60).floor();
        timeRemaining = '${hours}h ${minutes}m';
      }
    }

    final status = paused ? 'Paused' : 'Sending';
    final speedText =
        speedMbps > 0 ? '${speedMbps.toStringAsFixed(2)} Mbps' : '--';

    final androidPlatformChannelSpecifics = AndroidNotificationDetails(
      'file_transfer_channel',
      'File Transfer',
      channelDescription: 'File sharing progress notifications',
      importance: Importance.low,
      priority: Priority.low,
      showProgress: true,
      maxProgress: 100,
      progress: percent,
      onlyAlertOnce: true,
      ongoing: !paused,
      autoCancel: false,
    );

    final platformChannelSpecifics = NotificationDetails(
      android: androidPlatformChannelSpecifics,
    );
    await flutterLocalNotificationsPlugin.show(
      1000 + fileIndex,
      paused ? '⏸ Transfer Paused' : '📤 Sending File',
      '$fileName • $percent% • $speedText${!paused && speedMbps > 0 ? ' • $timeRemaining' : ''}',
      platformChannelSpecifics,
      payload: 'progress',
    );
  }

  Future<void> cancelProgressNotification(int fileIndex) async {
    await flutterLocalNotificationsPlugin.cancel(1000 + fileIndex);
  }

  final MethodChannel _channel = const MethodChannel('zapshare.saf');

  Future<void> serveSafFile(
    HttpRequest request, {
    required int fileIndex,
    required String uri,
    required String fileName,
    required int fileSize,
    int chunkSize = 262144, // 256KB - optimized for release builds
  }) async {
    final response = request.response;

    // Get client IP for tracking individual downloads
    final clientIP = request.connectionInfo?.remoteAddress.address ?? 'unknown';
    
    // Attempt to get device name from headers (if provided by peer)
    final clientNameHeader = request.headers.value('x-device-name');
    if (clientNameHeader != null && clientNameHeader.isNotEmpty) {
      _clientDeviceNames[clientIP] = clientNameHeader;
    }
    print(
      'Client $clientIP started downloading file: $fileName (File size: $fileSize bytes)',
    );

    // Check if this is a Range request (for parallel streaming)
    final rangeHeader = request.headers.value('range');

    if (rangeHeader != null) {
      // Handle parallel streaming with Range request
      print(
        '🚀 Range request detected: $rangeHeader - Using parallel streaming!',
      );

      // Initialize tracking for this file if needed
      if (!_totalBytesSentPerFile.containsKey(fileIndex)) {
        _totalBytesSentPerFile[fileIndex] = 0;
        _activeRangeRequests[fileIndex] = {};
      }

      // Track this range request
      final rangeKey = rangeHeader;
      _activeRangeRequests[fileIndex]!.add(rangeKey);
      _rangeBytesSentPerRequest[fileIndex] ??= {};
      _rangeBytesSentPerRequest[fileIndex]![rangeKey] = 0;

      DateTime lastUpdate = DateTime.now();
      double lastProgress = 0.0;

      try {
        await RangeRequestHandler.handleRangeRequest(
          request: request,
          uri: uri,
          fileName: fileName,
          fileSize: fileSize,
          onProgress: (bytesForRange, progress) {
            // bytesForRange is the total bytes sent so far for this range
            final prev = _rangeBytesSentPerRequest[fileIndex]?[rangeKey] ?? 0;
            final delta = bytesForRange - prev;
            if (delta > 0) {
              _rangeBytesSentPerRequest[fileIndex]![rangeKey] = bytesForRange;
              _totalBytesSentPerFile[fileIndex] =
                  (_totalBytesSentPerFile[fileIndex] ?? 0) + delta;
              _bytesSentList[fileIndex] = _totalBytesSentPerFile[fileIndex]!;
            }

            // Calculate overall progress
            final overallProgress =
                (_totalBytesSentPerFile[fileIndex]! / fileSize).clamp(0.0, 1.0);
            _progressList[fileIndex].value = overallProgress;

            // Throttle UI updates
            final now = DateTime.now();
            if (now.difference(lastUpdate).inMilliseconds > 200 ||
                (overallProgress - lastProgress) > 0.01) {
              showProgressNotification(
                fileIndex,
                overallProgress,
                fileName,
                speedMbps: 0,
                paused: false,
              );
              lastUpdate = now;
              lastProgress = overallProgress;
            }
          },
        );
      } finally {
        // Remove this range from active set
        _activeRangeRequests[fileIndex]?.remove(rangeKey);
        _rangeBytesSentPerRequest[fileIndex]?.remove(rangeKey);

        // If no more active ranges, mark as complete
        if (_activeRangeRequests[fileIndex]?.isEmpty ?? true) {
          _progressList[fileIndex].value = 1.0;
          _completedFiles[fileIndex] = true;
          print('✅ All ranges complete for file $fileIndex: $fileName');
        }
      }
      return;
    }

    // Regular single-stream download (fallback for older clients)
    print('📥 Regular download request - Using single stream');

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

    dynamic streamId; // Stream ID for cleanup

    try {
      // Set headers (including Accept-Ranges for parallel streaming support)
      response.statusCode = HttpStatus.ok;
      response.headers.set('Content-Length', fileSize.toString());
      response.headers.set('Content-Type', 'application/octet-stream');
      response.headers.set(
        'Content-Disposition',
        'attachment; filename="$fileName"',
      );
      response.headers.set(
        'Accept-Ranges',
        'bytes',
      ); // Enable parallel streaming!

      // Open stream
      print('Opening stream for file $fileIndex: $fileName');
      streamId = await MethodChannel(
        'zapshare.saf',
      ).invokeMethod('openReadStream', {'uri': uri});
      if (streamId == null) {
        print('Failed to open stream for file $fileIndex: $fileName');
        response.statusCode = HttpStatus.internalServerError;
        response.write('Could not open SAF stream.');
        await response.close();
        return;
      }
      print(
        'Successfully opened stream $streamId for file $fileIndex: $fileName',
      );

      // Stream file in chunks
      bool done = false;
      while (!done) {
        // Pause logic
        while (_isPausedList[fileIndex].value) {
          await Future.delayed(Duration(milliseconds: 200));
        }
        try {
          final chunk = await MethodChannel(
            'zapshare.saf',
          ).invokeMethod<Uint8List>('readChunk', {
            'uri': uri,
            'streamId': streamId,
            'size': chunkSize,
          });

          if (chunk == null || chunk.isEmpty) {
            print(
              'File $fileIndex: End of stream reached. Total bytes sent: $bytesSent',
            );
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
            if (bytesSent % (1024 * 1024) == 0) {
              // Log every MB
              print(
                'File $fileIndex: Sent ${bytesSent}/${fileSize} bytes (${(progress * 100).toStringAsFixed(1)}%)',
              );
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
                print(
                  'File $fileName reached 100% progress for client $clientIP',
                );
                // Mark as completed immediately
                if (_clientDownloads.containsKey(clientIP) &&
                    _clientDownloads[clientIP]!.containsKey(fileIndex)) {
                  _clientDownloads[clientIP]![fileIndex]!.isCompleted = true;
                  _clientDownloads[clientIP]![fileIndex]!.completionTime =
                      DateTime.now();
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
      await MethodChannel(
        'zapshare.saf',
      ).invokeMethod('closeStream', {'uri': uri, 'streamId': streamId});
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
          'peerDeviceName':
              _clientDeviceNames[clientIP], // Record device name if available
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
      // First try to get wifi IP from NetworkInfo
      ip = await info.getWifiIP();
      print("WiFi IP obtained: $ip");

      // Check for Wi-Fi Direct standard subnet
      if (ip != null && ip.startsWith('192.168.49.')) {
        print("✅ Confirmed Wi-Fi Direct IP: $ip");
      }
    } catch (e) {
      print("Failed to get WiFi IP: $e");
    }

    // Comprehensive Interface Check
    // If NetworkInfo failed or returned a non-direct IP while we expect one,
    // lets manually iterate interfaces to find the true Wi-Fi Direct IP.
    if (_wifiDirectConnectionInfo?.groupFormed == true &&
        (ip == null || !ip.startsWith('192.168.49.'))) {
      print(
        '⚠️ Wi-Fi Direct active but NetworkInfo returned $ip. Scanning interfaces...',
      );
      try {
        final interfaces = await NetworkInterface.list();
        for (var interface in interfaces) {
          print('   Interface: ${interface.name}');
          for (var addr in interface.addresses) {
            print('     Address: ${addr.address}');
            // Look for 192.168.49.x
            if (addr.type == InternetAddressType.IPv4 &&
                addr.address.startsWith('192.168.49.')) {
              ip = addr.address;
              print(
                '   => Found Wi-Fi Direct IP on interface ${interface.name}: $ip',
              );
              break; // Found it
            }
          }
          if (ip != null && ip.startsWith('192.168.49.')) break;
        }
      } catch (e) {
        print('Error listing interfaces: $e');
      }
    }

    String finalIp;
    if (ip != null && ip.isNotEmpty && ip != "0.0.0.0") {
      finalIp = ip;
      print("Using IP: $finalIp");
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

    // Restart discovery service
    print('🔄 Refreshing: Restarting discovery service...');
    await _discoveryService.stop();
    await _discoveryService.start();

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
      builder:
          (_) => StatefulBuilder(
            builder:
                (context, setState) => AlertDialog(
                  backgroundColor: Colors.yellow.shade50,
                  title: Text(
                    "Connection Tip",
                    style: TextStyle(color: Colors.black),
                  ),
                  content: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        "Ensure devices are on the same network or hotspot.",
                        style: TextStyle(color: Colors.black),
                      ),
                      Row(
                        children: [
                          Checkbox(
                            value: dontShowAgain,
                            activeColor: Colors.white,
                            checkColor: Colors.black,
                            onChanged:
                                (val) => setState(
                                  () => dontShowAgain = val ?? false,
                                ),
                          ),
                          Text(
                            "Don't show again",
                            style: TextStyle(color: Colors.black),
                          ),
                        ],
                      ),
                    ],
                  ),
                  actions: [
                    TextButton(
                      onPressed: () {
                        if (dontShowAgain)
                          prefs.setBool('showConnectionTip', false);
                        Navigator.of(context).pop();
                      },
                      child: Text(
                        "Got it!",
                        style: TextStyle(color: Colors.black),
                      ),
                    ),
                  ],
                ),
          ),
    );
  }

  Future<int> getFileSizeFromUri(String uri) async {
    final size = await const MethodChannel(
      'zapshare.saf',
    ).invokeMethod<int>('getFileSize', {'uri': uri});
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
        _progressList.addAll(
          List.generate(uris.length, (_) => ValueNotifier(0.0)),
        );
        _isPausedList.addAll(
          List.generate(uris.length, (_) => ValueNotifier(false)),
        );
        _bytesSentList.addAll(List.generate(uris.length, (_) => 0));
        _fileSizeList.addAll(sizes);
        _completedFiles.addAll(
          List.generate(uris.length, (_) => false),
        ); // Initialize completedFiles
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
    // Attempt TLS bind using cert/key if available
    SecurityContext? sc;
    try {
      final certFile = File('temp-server/certs/server.crt');
      final keyFile = File('temp-server/certs/server.key');
      if (await certFile.exists() && await keyFile.exists()) {
        sc = SecurityContext();
        sc.useCertificateChain(certFile.path);
        sc.usePrivateKey(keyFile.path);
      } else {
        final certData = await rootBundle.load('assets/certs/server.crt');
        final keyData = await rootBundle.load('assets/certs/server.key');
        sc = SecurityContext();
        sc.useCertificateChainBytes(certData.buffer.asUint8List());
        sc.usePrivateKeyBytes(keyData.buffer.asUint8List());
      }
    } catch (e) {
      sc = null;
    }

    if (sc != null) {
      _server = await HttpServer.bindSecure(InternetAddress.anyIPv4, 8080, sc);
      _useHttps = true;
    } else {
      _server = await HttpServer.bind(InternetAddress.anyIPv4, 8080);
      _useHttps = false;
    }
    // Generate 8-char code for sharing (just IP)
    final codeForUser = _ipToCode(_localIp ?? '');
    setState(() {
      _displayCode = codeForUser;
    });
    _server!.listen((HttpRequest request) async {
      final path = request.uri.path;

      // Add CORS headers for all requests
      request.response.headers.add('Access-Control-Allow-Origin', '*');
      request.response.headers.add(
        'Access-Control-Allow-Methods',
        'GET, POST, OPTIONS',
      );
      request.response.headers.add('Access-Control-Allow-Headers', '*');

      // Handle preflight OPTIONS request
      if (request.method == 'OPTIONS') {
        request.response.statusCode = HttpStatus.ok;
        await request.response.close();
        return;
      }

      // Serve web interface at root
      if (path == '/' || path == '/index.html') {
        await _serveWebInterface(request);
        return;
      }

      if (path == '/list') {
        // Serve file list as JSON
        final list = List.generate(
          _fileNames.length,
          (i) => {
            'index': i,
            'name': _fileNames[i],
            'size': _fileSizeList.length > i ? _fileSizeList[i] : 0,
          },
        );
        request.response.headers.contentType = ContentType.json;
        // Send my device name
        request.response.headers.set('X-Device-Name', _discoveryService.myDeviceName ?? 'ZapShare Android');
        request.response.write(jsonEncode(list));
        await request.response.close();
        return;
      }

      // Handle connection request (HTTP Handshake)
      if (path == '/connection-request' && request.method == 'POST') {
        try {
          final content = await utf8.decoder.bind(request).join();
          final data = jsonDecode(content);

          print(
            '📩 Received HTTP Connection Request from ${data['deviceName']}',
          );

          final connectionRequest = ConnectionRequest(
            deviceId: data['deviceId'],
            deviceName: data['deviceName'],
            platform: data['platform'] ?? 'unknown',
            ipAddress:
                request
                    .connectionInfo!
                    .remoteAddress
                    .address, // Correct IP from connection
            fileCount: data['fileCount'],
            fileNames: List<String>.from(data['fileNames']),
            totalSize: data['totalSize'],
            timestamp: DateTime.now(),
          );
          
          // Store device name mapping
          _clientDeviceNames[connectionRequest.ipAddress] = connectionRequest.deviceName;

          // Use a Completer to bridge the UI dialog callback to this HTTP response
          final completer = Completer<bool>();

          if (mounted) {
            if (_isShowingConnectionDialog) {
              request.response.statusCode = HttpStatus.conflict;
              request.response.write(
                jsonEncode({'error': 'Busy conversation'}),
              );
              await request.response.close();
              return;
            }

            _isShowingConnectionDialog = true;

            await showDialog(
              context: context,
              barrierDismissible: false,
              builder: (dialogContext) {
                return ConnectionRequestDialog(
                  request: connectionRequest,
                  onAccept: (files, path) {
                    Navigator.of(dialogContext).pop();
                    _isShowingConnectionDialog = false;
                    completer.complete(true);

                    if (mounted) {
                      final code = _ipToCode(connectionRequest.ipAddress);

                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder:
                              (context) =>
                                  AndroidReceiveScreen(autoConnectCode: code),
                        ),
                      );
                    }
                  },
                  onDecline: () {
                    Navigator.of(dialogContext).pop();
                    _isShowingConnectionDialog = false;
                    completer.complete(false);
                  },
                );
              },
            );
          } else {
            completer.complete(false);
          }

          final accepted = await completer.future;

          request.response.headers.contentType = ContentType.json;
          request.response.statusCode = HttpStatus.ok;
          request.response.write(jsonEncode({'accepted': accepted}));
          await request.response.close();
        } catch (e) {
          print('Error handling connection request: $e');
          request.response.statusCode = HttpStatus.badRequest;
          await request.response.close();
        }
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
        final fileSize =
            _fileSizeList.length > index ? _fileSizeList[index] : 0;
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

  Future<List<Map<String, String>>> listFilesInFolderSAF(
    String folderUri,
  ) async {
    final jsonString = await _channel.invokeMethod<String>(
      'listFilesInFolder',
      {'folderUri': folderUri},
    );
    if (jsonString == null) return [];
    final List<dynamic> decoded = jsonDecode(jsonString);
    return decoded
        .cast<Map<String, dynamic>>()
        .map((e) => {'uri': e['uri'] as String, 'name': e['name'] as String})
        .toList();
  }

  Future<String?> zipFilesToCache(
    List<String> uris,
    List<String> names,
    String zipName,
  ) async {
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
          _progressList.addAll(
            List.generate(uris.length, (_) => ValueNotifier(0.0)),
          );
          _isPausedList.addAll(
            List.generate(uris.length, (_) => ValueNotifier(false)),
          );
          _bytesSentList.addAll(List.generate(uris.length, (_) => 0));
          _fileSizeList.addAll(sizes);
          _completedFiles.addAll(
            List.generate(uris.length, (_) => false),
          ); // Initialize completedFiles
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
            font-family: -apple-system, BlinkMacSystemFont, 'SF Pro Display', 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif;
            background: #000000;
            color: #ffffff;
            min-height: 100vh;
            display: flex;
            overflow-x: hidden;
        }

        .main-content {
            flex: 1;
            padding: 120px 40px 40px;
            display: flex;
            align-items: center;
            justify-content: center;
            position: relative;
            z-index: 10;
            width: 100%;
        }
        
        .container {
            max-width: 700px;
            width: 100%;
        }

        @media (max-width: 1024px) {
            .main-content {
                padding: 80px 20px 30px;
            }
        }

        @media (max-width: 768px) {
            .container {
                max-width: 100%;
            }
        }

        @media (max-width: 480px) {
            .main-content {
                padding: 30px 16px;
            }
        }
        
        .card {
            background: rgba(26, 26, 26, 0.8);
            border: 1px solid rgba(255, 255, 255, 0.1);
            border-radius: 16px;
            padding: 36px 44px;
            box-shadow: 0 20px 60px rgba(0, 0, 0, 0.6);
            backdrop-filter: blur(40px);
            animation: fadeInUp 0.6s ease-out 0.3s both;
        }

        @media (max-width: 768px) {
            .card {
                padding: 24px 18px;
            }
        }

        @media (max-width: 480px) {
            .card {
                padding: 24px 20px;
            }
        }

        @keyframes fadeInUp {
            from { opacity: 0; transform: translateY(20px); }
            to { opacity: 1; transform: translateY(0); }
        }
        
        .header {
            text-align: center;
            margin-bottom: 28px;
        }
        
        .title {
            font-size: 20px;
            font-weight: 600;
            color: #ffffff;
            margin-bottom: 6px;
            letter-spacing: -0.3px;
        }
        
        .subtitle {
            font-size: 13px;
            color: rgba(255, 255, 255, 0.6);
            font-weight: 400;
            line-height: 1.5;
        }
        
        .content {
            margin-top: 20px;
        }
        
        .file-list {
            margin-top: 20px;
            max-height: 500px;
            overflow-y: auto;
        }

        .file-list::-webkit-scrollbar {
            width: 6px;
        }

        .file-list::-webkit-scrollbar-track {
            background: rgba(255, 255, 255, 0.05);
            border-radius: 10px;
        }

        .file-list::-webkit-scrollbar-thumb {
            background: rgba(255, 235, 59, 0.3);
            border-radius: 10px;
        }
        
        .file-item {
            display: flex;
            align-items: center;
            padding: 12px;
            margin-bottom: 12px;
            background: rgba(0, 0, 0, 0.3);
            border-radius: 12px;
            border: 1px solid rgba(255, 255, 255, 0.08);
            transition: all 0.3s cubic-bezier(0.4, 0, 0.2, 1);
            position: relative;
        }
        
        .file-item:hover {
            border-color: rgba(255, 235, 59, 0.5);
            background: rgba(255, 235, 59, 0.05);
            transform: translateY(-2px);
        }
        
        .file-item.selected {
            border-color: #FFEB3B;
            background: rgba(255, 235, 59, 0.1);
            box-shadow: 0 4px 12px rgba(255, 235, 59, 0.2);
        }
        
        .pagination {
            display: flex;
            justify-content: center;
            align-items: center;
            margin: 20px 0;
            gap: 10px;
        }
        
        .pagination button {
            background: linear-gradient(135deg, #FFEB3B 0%, #FFF176 100%);
            color: #000;
            border: none;
            padding: 10px 15px;
            border-radius: 12px;
            font-weight: 600;
            cursor: pointer;
            transition: all 0.3s cubic-bezier(0.4, 0, 0.2, 1);
            box-shadow: 0 4px 16px rgba(255, 235, 59, 0.3);
        }
        
        .pagination button:hover {
            transform: translateY(-2px);
            box-shadow: 0 8px 24px rgba(255, 235, 59, 0.4);
        }
        
        .pagination button:disabled {
            background: rgba(255, 255, 255, 0.1);
            color: rgba(255, 255, 255, 0.3);
            cursor: not-allowed;
            transform: none;
            box-shadow: none;
        }
        
        .pagination-info {
            color: #FFEB3B;
            font-weight: 600;
            margin: 0 15px;
            font-size: 13px;
        }
        
        .file-checkbox {
            margin-right: 12px;
            transform: scale(1.1);
            accent-color: #FFEB3B;
        }
        
        .file-icon {
            width: 36px;
            height: 36px;
            background: #FFEB3B;
            border-radius: 8px;
            display: flex;
            align-items: center;
            justify-content: center;
            margin-right: 12px;
            font-size: 10px;
            font-weight: 700;
            color: #000;
            letter-spacing: -0.5px;
        }
        
        .file-info {
            flex: 1;
        }
        
        .file-name {
            font-size: 14px;
            font-weight: 600;
            color: #fff;
            margin-bottom: 4px;
        }
        
        .file-size {
            font-size: 12px;
            color: rgba(255, 255, 255, 0.5);
            font-weight: 500;
        }
        
        .download-btn {
            background: linear-gradient(135deg, #FFEB3B 0%, #FFF176 100%);
            color: #000;
            border: none;
            padding: 10px 20px;
            border-radius: 12px;
            font-size: 14px;
            font-weight: 600;
            cursor: pointer;
            transition: all 0.3s cubic-bezier(0.4, 0, 0.2, 1);
            text-decoration: none;
            display: inline-block;
            box-shadow: 0 4px 16px rgba(255, 235, 59, 0.3);
        }
        
        .download-btn:hover {
            transform: translateY(-2px);
            box-shadow: 0 8px 24px rgba(255, 235, 59, 0.4);
        }
        
        .download-btn:active {
            transform: translateY(0);
        }
        
        .bulk-actions {
            background: rgba(0, 0, 0, 0.3);
            padding: 16px;
            margin-bottom: 16px;
            border-radius: 12px;
            border: 1px solid rgba(255, 255, 255, 0.08);
            display: flex;
            justify-content: space-between;
            align-items: center;
            flex-wrap: wrap;
            gap: 12px;
        }
        
        .bulk-actions h3 {
            color: #FFEB3B;
            margin: 0;
            font-size: 13px;
            font-weight: 600;
            text-transform: uppercase;
            letter-spacing: 0.5px;
        }
        
        .bulk-btn {
            background: linear-gradient(135deg, #FFEB3B 0%, #FFF176 100%);
            color: #000;
            border: none;
            padding: 10px 20px;
            border-radius: 12px;
            font-weight: 600;
            font-size: 13px;
            cursor: pointer;
            transition: all 0.3s cubic-bezier(0.4, 0, 0.2, 1);
            box-shadow: 0 4px 16px rgba(255, 235, 59, 0.3);
        }
        
        .bulk-btn:hover {
            transform: translateY(-2px);
            box-shadow: 0 8px 24px rgba(255, 235, 59, 0.4);
        }
        
        .bulk-btn.secondary {
            background: rgba(255, 255, 255, 0.1);
            color: #FFEB3B;
            box-shadow: none;
        }
        
        .bulk-btn.secondary:hover {
            background: rgba(255, 235, 59, 0.1);
        }
        
        .no-files {
            text-align: center;
            padding: 60px 20px;
        }
        
        .no-files h3 {
            font-size: 16px;
            font-weight: 500;
            margin-bottom: 8px;
            color: rgba(255, 255, 255, 0.4);
        }

        .no-files p {
            font-size: 14px;
            color: rgba(255, 255, 255, 0.6);
        }
        
        .loading {
            text-align: center;
            padding: 60px 20px;
        }
        
        .spinner {
            border: 4px solid rgba(255, 255, 255, 0.1);
            border-top: 4px solid #FFEB3B;
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
        
        .loading h3 {
            color: rgba(255, 255, 255, 0.6);
            font-size: 15px;
            font-weight: 500;
        }
        
        .progress-container {
            background: rgba(255, 255, 255, 0.1);
            border-radius: 2px;
            height: 4px;
            margin: 8px 0;
            overflow: hidden;
        }
        
        .progress-bar {
            background: linear-gradient(90deg, #FFEB3B 0%, #FFF176 100%);
            height: 100%;
            transition: width 0.3s ease;
        }
        
        .preview-btn {
            background: rgba(255, 255, 255, 0.1);
            color: #FFEB3B;
            border: none;
            padding: 8px 12px;
            border-radius: 8px;
            font-size: 12px;
            font-weight: 600;
            cursor: pointer;
            margin-left: 10px;
            transition: all 0.3s cubic-bezier(0.4, 0, 0.2, 1);
        }
        
        .preview-btn:hover {
            background: rgba(255, 235, 59, 0.1);
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
            color: #FFEB3B;
            font-size: 40px;
            font-weight: bold;
            cursor: pointer;
        }
        
        .close:hover {
            color: #FFF176;
        }
        
        @media (max-width: 600px) {
            .file-item {
                flex-wrap: wrap;
            }
            
            .file-icon {
                margin: 0 12px 0 0;
            }
            
            .download-btn {
                margin-top: 12px;
                width: 100%;
            }
        }
    </style>
</head>
<body>
    <div class="main-content">
        <div class="container">
            <div class="card">
                <div class="header">
                    <h2 class="title">Available Files</h2>
                    <p class="subtitle">Download files shared from this device</p>
                </div>
                
                <div class="content">
                    <div id="bulkActions" class="bulk-actions" style="display: none;">
                        <h3>Bulk Actions</h3>
                        <div style="display: flex; gap: 10px;">
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
                            <div class="spinner"></div>
                            <h3>Loading files...</h3>
                        </div>
                    </div>
                </div>
            </div>
        </div>
    </div>

    <!-- Image Preview Modal -->
    <div id="imageModal" class="modal">
        <span class="close" onclick="closeModal()">&times;</span>
        <img class="modal-content" id="modalImage">
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
                            <a href="/file/\${file.index}" class="download-btn" download onclick="startDownload(this, \${file.index})">
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
        
        function startDownload(button, fileIndex) {
            const fileItem = button.closest('.file-item');
            const progressContainer = fileItem.querySelector('.progress-container');
            const progressBar = fileItem.querySelector('.progress-bar');
            const downloadBtn = button;
            
            // Show progress bar
            progressContainer.style.display = 'block';
            
            // Change button state
            downloadBtn.textContent = 'Downloading...';
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
                        downloadBtn.textContent = 'Download';
                        downloadBtn.style.pointerEvents = 'auto';
                        progressContainer.style.display = 'none';
                        progressBar.style.width = '0%';
                    }, 1000);
                }
                progressBar.style.width = progress + '%';
            }, 200);
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
                'pdf': 'PDF', 'doc': 'DOC', 'docx': 'DOC', 'txt': 'TXT',
                'jpg': 'IMG', 'jpeg': 'IMG', 'png': 'IMG', 'gif': 'IMG',
                'mp4': 'VID', 'avi': 'VID', 'mov': 'VID', 'mp3': 'AUD',
                'zip': 'ZIP', 'rar': 'ZIP', '7z': 'ZIP', 'exe': 'EXE'
            };
            return iconMap[ext] || 'FILE';
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

          // Auto-connect to Wi-Fi Direct peer if waiting
          if (_waitingForWifiDirectPeer) {
            final wifiDirectPeers =
                devices.where((device) {
                  // STRICTLY check for Wi-Fi Direct subnet.
                  // Do NOT allow "same subnet" fallback here, as it might pick up the old network interface
                  // before the device has fully switched, causing connection issues.
                  return device.ipAddress.startsWith('192.168.49.') &&
                      device.ipAddress != _localIp &&
                      device.ipAddress != '0.0.0.0';
                }).toList();

            if (wifiDirectPeers.isNotEmpty) {
              final peer = wifiDirectPeers.first;
              print(
                '🚀 Auto-connecting to confirmed Wi-Fi Direct peer: ${peer.deviceName} (${peer.ipAddress})',
              );
              _waitingForWifiDirectPeer = false;
              _sendConnectionRequest(peer);
            }
          }
        });
      }
    });

    // Listen for incoming connection requests
    _connectionRequestSubscription = _discoveryService.connectionRequestStream.listen(
      (request) {
        if (mounted) {
          // Prevent multiple dialogs from showing at once
          if (_isShowingConnectionDialog) {
            print(
              '⏭️  Dialog already showing, ignoring request from ${request.ipAddress}',
            );
            return;
          }

          // Check if we already have a dialog open for this IP
          final now = DateTime.now();
          final lastTime = _lastRequestTime[request.ipAddress];

          // Ignore duplicate requests within 30 seconds (or if already processed)
          if (lastTime != null && now.difference(lastTime).inSeconds < 30) {
            print(
              '⏭️  Ignoring duplicate request from ${request.ipAddress} (last: ${now.difference(lastTime).inSeconds}s ago)',
            );
            return;
          }

          print(
            '📩 Stream listener received connection request from ${request.deviceName} (${request.ipAddress})',
          );
          _lastRequestTime[request.ipAddress] = now;
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
    _connectionResponseSubscription = _discoveryService.connectionResponseStream
        .listen((response) {
          print(
            '📨 Connection response received: accepted=${response.accepted}, ip=${response.ipAddress}',
          );
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

    // Set flag to prevent multiple dialogs
    _isShowingConnectionDialog = true;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        print('📱 Building ConnectionRequestDialog...');
        return ConnectionRequestDialog(
          request: request,
          onAccept: (files, path) async {
            print('✅ User accepted connection request');
            // Close the dialog using the dialog context
            Navigator.of(dialogContext).pop();

            // Reset flag
            _isShowingConnectionDialog = false;

            // Mark this request as processed to prevent duplicates
            _processedRequests.add(request.ipAddress);

            // Send acceptance response
            await _discoveryService.sendConnectionResponse(
              request.ipAddress,
              true,
            );

            // Navigate to receive screen to download files
            if (mounted) {
              final code = request.ipAddress
                  .split('.')
                  .map((p) => int.parse(p).toRadixString(36).toUpperCase())
                  .join('');

              Navigator.push(
                context,
                MaterialPageRoute(
                  builder:
                      (context) => AndroidReceiveScreen(autoConnectCode: code),
                ),
              );

              // Show snackbar with instructions
              Future.delayed(Duration(milliseconds: 500), () {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        'Enter code: ${_ipToCode(request.ipAddress)}',
                      ),
                      backgroundColor: Colors.green,
                      duration: Duration(seconds: 5),
                      action: SnackBarAction(
                        label: 'Copy',
                        textColor: Colors.yellow[300],
                        onPressed: () {
                          final code = _ipToCode(request.ipAddress);
                          Clipboard.setData(ClipboardData(text: code));
                        },
                      ),
                    ),
                  );
                }
              });
            }

            // Clear the processed request after 60 seconds to allow future requests
            Future.delayed(Duration(seconds: 60), () {
              _processedRequests.remove(request.ipAddress);
            });
          },
          onDecline: () async {
            print('❌ User declined connection request');
            // Close the dialog using the dialog context
            Navigator.of(dialogContext).pop();

            // Reset flag
            _isShowingConnectionDialog = false;

            // Mark as processed temporarily
            _processedRequests.add(request.ipAddress);

            // Send decline response
            await _discoveryService.sendConnectionResponse(
              request.ipAddress,
              false,
            );

            // Allow new requests after 30 seconds
            Future.delayed(Duration(seconds: 30), () {
              _processedRequests.remove(request.ipAddress);
            });
          },
        );
      },
    ).then((_) {
      // Also reset flag when dialog is dismissed by other means
      _isShowingConnectionDialog = false;
    });
    print('✅ Dialog shown');
  }

  Future<void> _sendConnectionRequest(DiscoveredDevice device) async {
    // ALWAYS require files to be selected first (consistent with HTTP flow)
    if (_fileUris.isEmpty) {
      print('⚠️ No files selected');

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              Icon(Icons.info_outline, color: Colors.black),
              SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Please select files first before sending',
                  style: TextStyle(fontSize: 14, color: Colors.black),
                ),
              ),
            ],
          ),
          backgroundColor: Colors.yellow[300],
          duration: Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      );
      return;
    }

    // Wi-Fi Direct Handling
    if (device.discoveryMethod == DiscoveryMethod.wifiDirect &&
        device.wifiDirectAddress != null) {
      print('🔗 Initiating Wi-Fi Direct connection to: ${device.deviceName}');
      print('   Device Address: ${device.wifiDirectAddress}');

      // Set state to show connecting UI
      setState(() {
        _isConnectingWifiDirect = true;
        _connectingPeerAddress = device.wifiDirectAddress;
      });

      // Show connecting feedback with yellow theme dialog
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) {
          return Dialog(
            backgroundColor: Colors.yellow[100],
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            child: Padding(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.yellow[300],
                    ),
                    child: CircularProgressIndicator(
                      valueColor: AlwaysStoppedAnimation<Color>(Colors.black),
                    ),
                  ),
                  SizedBox(height: 24),
                  Text(
                    'Connecting to device...',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Colors.black,
                    ),
                  ),
                  SizedBox(height: 8),
                  Text(
                    'Establishing secure Wi-Fi Direct connection to ${device.deviceName}',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 14, color: Colors.grey[800]),
                  ),
                ],
              ),
            ),
          );
        },
      );

      // Connect to Wi-Fi Direct peer using WiFiDirectService
      print('📡 Calling WiFiDirectService.connectToPeer()...');
      final success = await _wifiDirectService.connectToPeer(
        device.wifiDirectAddress!,
        isGroupOwner: true, // Sender is group owner
      );

      // Dismiss the dialog
      if (mounted && Navigator.canPop(context)) {
        Navigator.pop(context);
      }

      if (!success) {
        print('❌ Wi-Fi Direct connection initiation failed');
        setState(() {
          _isConnectingWifiDirect = false;
          _connectingPeerAddress = null;
        });

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Row(
                children: [
                  Icon(Icons.error_outline, color: Colors.white),
                  SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Failed to connect to ${device.deviceName}',
                      style: TextStyle(fontSize: 14, color: Colors.white),
                    ),
                  ),
                ],
              ),
              backgroundColor: Colors.red,
              duration: Duration(seconds: 2),
            ),
          );
        }
      } else {
        print('✅ Wi-Fi Direct connection initiated successfully');
        print('   Waiting for connection to form...');
        // Connection will complete via _handleWifiDirectConnected callback
      }
      return;
    }

    // HTTP/UDP Device Handling (existing flow)
    setState(() {
      _pendingRequestDeviceIp = device.ipAddress;
      _pendingDevice = device;
    });

    // Start HTTP server immediately (needed for both HTTP and UDP flows)
    print('🚀 Starting HTTP server...');
    await _startServer();

    // Show connecting feedback dialog
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return Dialog(
          backgroundColor: Colors.yellow[100],
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.yellow[300],
                  ),
                  child: CircularProgressIndicator(
                    valueColor: AlwaysStoppedAnimation<Color>(Colors.black),
                  ),
                ),
                SizedBox(height: 24),
                Text(
                  'Sending Request...',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Colors.black,
                    fontFamily: "Outfit",
                  ),
                ),
                SizedBox(height: 8),
                Text(
                  'Asking ${device.deviceName} to accept connection...',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.grey[800],
                    fontFamily: "Outfit",
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );

    // Calculate total size
    final totalSize = _fileSizeList.fold<int>(0, (sum, size) => sum + size);

    // Use the robust HTTP handshake immediately
    print('🚀 Initiating HTTP Handshake to ${device.ipAddress}...');
    final success = await _sendHttpConnectionRequest(
      device.ipAddress,
      _fileNames,
      totalSize,
    );

    if (success) {
      // Handshake successful, server is running.
      // Dismiss dialog
      if (mounted && Navigator.canPop(context)) {
        Navigator.pop(context);
      }
      return;
    }

    // Fallback to UDP if HTTP fails (legacy support or firewall issue)
    print('⚠️ HTTP Handshake failed, falling back to UDP request...');

    // Send connection request (UDP)
    print(
      '📤 Sending connection request to ${device.deviceName} (${device.ipAddress})',
    );
    await _discoveryService.sendConnectionRequest(
      device.ipAddress,
      _fileNames,
      totalSize,
    );

    // Dismiss dialog regardless after sending UDP (user waits for response dialog or timeout)
    // Actually, for UDP we should probably keep it open?
    // Existing logic has a 10s timeout timer.
    // Let's keep the dialog open until timeout or response?
    // But _requestTimeoutTimer calls _showRetryDialog in 10s.
    // If we leave this dialog open, _showRetryDialog will stack on top.
    // Better to close this "Sending..." dialog now, and let the 10s timer handle the "Wait" or "Retry".
    // Alternatively, we can let the user cancel.
    // For consistency with Wi-Fi Direct flow, lets close it now.
    if (mounted && Navigator.canPop(context)) {
      Navigator.pop(context);
    }

    print('✅ Connection request sent successfully (UDP)');

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
                    border: Border.all(color: Colors.yellow[600]!, width: 3),
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
                    border: Border.all(color: Colors.grey[700]!, width: 1),
                  ),
                  child: Column(
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.info_outline_rounded,
                            color: Colors.yellow[400],
                            size: 18,
                          ),
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

  Future<void> _showQrDialog() async {
    if (_localIp == null) return;

    final scheme = _useHttps ? 'https' : 'http';
    final url = '$scheme://${_localIp}:8080';

    try {
      // Set high brightness
      double originalBrightness = 0.5;
      try {
        originalBrightness = await ScreenBrightness().current;
        await ScreenBrightness().setScreenBrightness(1.0);
      } catch (e) {
        print('Error setting brightness: $e');
      }

      if (!mounted) return;

      await showDialog(
        context: context,
        builder:
            (context) => Dialog(
              backgroundColor: Colors.grey[900],
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
                side: BorderSide(color: Colors.yellow[300]!, width: 2),
              ),
              child: Padding(
                padding: const EdgeInsets.all(24.0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Scan to Connect',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 24),
                    Container(
                      padding: EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.yellow[300],
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: QrImageView(
                        data: url,
                        version: QrVersions.auto,
                        size: 240.0,
                        backgroundColor: Colors.transparent,
                        eyeStyle: QrEyeStyle(
                          eyeShape: QrEyeShape.square,
                          color: Colors.black,
                        ),
                        dataModuleStyle: QrDataModuleStyle(
                          dataModuleShape: QrDataModuleShape.square,
                          color: Colors.black,
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),
                    Text(
                      url,
                      style: TextStyle(
                        color: Colors.grey[400],
                        fontSize: 14,
                        fontFamily: 'monospace',
                      ),
                    ),
                    const SizedBox(height: 24),
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: Text(
                        'Close',
                        style: TextStyle(
                          color: Colors.yellow[300],
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
      );

      // Restore brightness
      try {
        await ScreenBrightness().setScreenBrightness(originalBrightness);
      } catch (e) {
        print('Error restoring brightness: $e');
      }
    } catch (e) {
      print('Error showing QR dialog: $e');
    }
  }

  @override
  void dispose() {
    _server?.close(force: true);
    _pageController.dispose();
    _devicesSubscription?.cancel();
    _connectionRequestSubscription?.cancel();
    _connectionResponseSubscription?.cancel();
    _requestTimeoutTimer?.cancel();
    // Cancel WiFi Direct subscriptions
    _wifiDirectModeSubscription?.cancel();
    _wifiDirectPeersSubscription?.cancel();
    _wifiDirectConnectionSubscription?.cancel();
    _wifiDirectDirectPeersSubscription?.cancel();
    _wifiDirectDirectConnectionSubscription?.cancel();
    // Stop WiFi Direct peer discovery
    _wifiDirectService.stopPeerDiscovery();
    print('🛑 WiFi Direct service stopped');
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
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // Centered Title
                  Text(
                    'Share Files',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 28,
                      fontWeight: FontWeight.w300,
                      letterSpacing: -0.5,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  // Left and Right Buttons
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      IconButton(
                        icon: Icon(
                          Icons.arrow_back_ios_rounded,
                          color: Colors.white,
                          size: 20,
                        ),
                        onPressed: () => Navigator.pop(context),
                      ),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: Icon(
                              Icons.refresh_rounded,
                              color: Colors.grey[400],
                              size: 20,
                            ),
                            onPressed: _refreshIp,
                          ),
                          IconButton(
                            icon: Icon(
                              Icons.qr_code_rounded,
                              color: Colors.white,
                              size: 20,
                            ),
                            onPressed: _showQrDialog,
                          ),
                        ],
                      ),
                    ],
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
                      _buildFileList(isCompact),
                    ],

                    // Empty state
                    if (_fileNames.isEmpty && !_loading) ...[
                      Expanded(child: _buildEmptyState()),
                    ],

                    // Loading state
                    if (_loading) ...[Expanded(child: _buildLoadingState())],
                  ],
                ),
              ),
            ),

            // Action buttons - reorganized for better UX
            if (_fileNames.isNotEmpty) ...[
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 36,
                ),
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
                      icon:
                          _isSharing
                              ? Icons.stop_circle_rounded
                              : Icons.send_rounded,
                      onTap:
                          (_fileUris.isEmpty || _loading)
                              ? null
                              : _isSharing
                              ? _stopServer
                              : _startServer,
                      color:
                          _fileUris.isEmpty
                              ? Colors.grey[700]!
                              : _isSharing
                              ? Colors.red[600]!
                              : Colors.yellow[300]!,
                      textColor:
                          _fileUris.isEmpty
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
                Icon(Icons.people_rounded, color: Colors.yellow[300], size: 16),
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
    // Show WiFi Direct peers when WiFi Direct mode is enabled
    if (_isWifiDirectMode) {
      return _buildWifiDirectDevicesSection();
    }

    // Regular nearby devices section (multicast/UDP discovery)
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
          color:
              _showNearbyDevices
                  ? Colors.grey[900]
                  : Colors.grey[900]!.withOpacity(0.5),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color:
                _nearbyDevices.isNotEmpty
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

  Widget _buildWifiDirectDevicesSection() {
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
          color:
              _showNearbyDevices
                  ? Colors.blue[900]!.withOpacity(0.3)
                  : Colors.blue[900]!.withOpacity(0.15),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color:
                _wifiDirectPeers.isNotEmpty
                    ? Colors.blue[400]!.withOpacity(0.6)
                    : Colors.blue[400]!.withOpacity(0.3),
            width: _wifiDirectPeers.isNotEmpty ? 2 : 1,
          ),
        ),
        child: Column(
          children: [
            // Header with WiFi Direct indicator
            Row(
              children: [
                Container(
                  width: 20,
                  height: 20,
                  decoration: BoxDecoration(
                    color: Colors.blue[400],
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.wifi_tethering_rounded,
                    color: Colors.white,
                    size: 12,
                  ),
                ),
                SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'WiFi Direct Mode',
                        style: TextStyle(
                          color: Colors.blue[300],
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      Text(
                        _wifiDirectPeers.isEmpty
                            ? 'Scanning for peers...'
                            : '${_wifiDirectPeers.length} peer${_wifiDirectPeers.length == 1 ? '' : 's'} found',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
                if (_wifiDirectConnectionInfo?.groupFormed == true)
                  Container(
                    padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.green[700],
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.check_circle, color: Colors.white, size: 12),
                        SizedBox(width: 4),
                        Text(
                          'Connected',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                SizedBox(width: 8),
                Icon(
                  _showNearbyDevices
                      ? Icons.keyboard_arrow_up_rounded
                      : Icons.keyboard_arrow_down_rounded,
                  color: Colors.blue[300],
                  size: 20,
                ),
              ],
            ),

            // Expandable content
            if (_showNearbyDevices) ...[
              SizedBox(height: 12),
              if (_wifiDirectPeers.isEmpty)
                _buildWifiDirectEmptyState()
              else
                _buildWifiDirectPeerList(),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildWifiDirectEmptyState() {
    return Container(
      padding: EdgeInsets.symmetric(vertical: 16),
      child: Column(
        children: [
          SizedBox(
            width: 40,
            height: 40,
            child: CircularProgressIndicator(
              color: Colors.blue[400],
              strokeWidth: 3,
            ),
          ),
          SizedBox(height: 12),
          Text(
            'Scanning for WiFi Direct peers...',
            style: TextStyle(
              color: Colors.blue[200],
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
          SizedBox(height: 4),
          Text(
            'Make sure nearby devices have WiFi Direct enabled',
            style: TextStyle(color: Colors.grey[500], fontSize: 11),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _buildWifiDirectPeerList() {
    return Container(
      height: 85,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: _wifiDirectPeers.length,
        itemBuilder: (context, index) {
          return _buildWifiDirectPeerItem(_wifiDirectPeers[index]);
        },
      ),
    );
  }

  Widget _buildWifiDirectPeerItem(WiFiDirectPeer peer) {
    final isConnecting =
        _isConnectingWifiDirect && _connectingPeerAddress == peer.deviceAddress;
    final isConnected = _wifiDirectConnectionInfo?.groupFormed == true;

    return GestureDetector(
      onTap:
          isConnecting || isConnected
              ? null
              : () {
                // Convert WiFiDirectPeer to DiscoveredDevice and use unified flow
                final device = DiscoveredDevice(
                  deviceId: 'wd_${peer.deviceAddress.replaceAll(':', '')}',
                  deviceName: peer.deviceName,
                  ipAddress: '0.0.0.0',
                  port: 0,
                  platform: 'android',
                  lastSeen: DateTime.now(),
                  discoveryMethod: DiscoveryMethod.wifiDirect,
                  wifiDirectAddress: peer.deviceAddress,
                );
                _sendConnectionRequest(device);
              },
      child: Container(
        width: 70,
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
                gradient:
                    isConnecting
                        ? LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [Colors.blue[300]!, Colors.blue[400]!],
                        )
                        : LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [Colors.grey[800]!, Colors.grey[850]!],
                        ),
                border: Border.all(
                  color: isConnecting ? Colors.blue[300]! : Colors.blue[700]!,
                  width: 2,
                ),
                boxShadow: [
                  if (isConnecting)
                    BoxShadow(
                      color: Colors.blue[300]!.withOpacity(0.3),
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
                  Icon(
                    Icons.android,
                    color: isConnecting ? Colors.white : Colors.blue[200],
                    size: 24,
                  ),
                  if (isConnecting)
                    Positioned.fill(
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(
                          Colors.white.withOpacity(0.5),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            SizedBox(height: 6),
            // Device name
            Text(
              peer.deviceName.length > 10
                  ? '${peer.deviceName.substring(0, 10)}...'
                  : peer.deviceName,
              style: TextStyle(
                color: isConnecting ? Colors.blue[300] : Colors.white,
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
            style: TextStyle(color: Colors.grey[600], fontSize: 12),
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
    final isPending =
        _pendingRequestDeviceIp == device.ipAddress ||
        _pendingRequestDeviceIp == device.deviceId;

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
                gradient:
                    isPending
                        ? LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [Colors.yellow[300]!, Colors.yellow[400]!],
                        )
                        : LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [Colors.grey[800]!, Colors.grey[850]!],
                        ),
                border: Border.all(
                  color: isPending ? Colors.yellow[600]! : Colors.grey[700]!,
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
      builder:
          (context) => Dialog(
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
                      border: Border.all(color: Colors.yellow[600]!, width: 3),
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
                  _buildDetailRow(
                    Icons.computer_rounded,
                    'Platform',
                    device.platform,
                  ),
                  SizedBox(height: 12),
                  _buildDetailRow(
                    Icons.wifi_rounded,
                    'IP Address',
                    device.ipAddress,
                  ),
                  SizedBox(height: 12),
                  _buildDetailRow(
                    Icons.share_rounded,
                    'Share Code',
                    device.shareCode,
                  ),
                  SizedBox(height: 12),
                  _buildDetailRow(
                    device.isOnline
                        ? Icons.check_circle_rounded
                        : Icons.cancel_rounded,
                    'Status',
                    device.isOnline ? 'Online' : 'Offline',
                    statusColor:
                        device.isOnline ? Colors.green[400] : Colors.red[400],
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

  Widget _buildDetailRow(
    IconData icon,
    String label,
    String value, {
    Color? statusColor,
  }) {
    return Row(
      children: [
        Container(
          padding: EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Colors.grey[850],
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.grey[700]!, width: 1),
          ),
          child: Icon(icon, color: statusColor ?? Colors.yellow[300], size: 20),
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
    final isPending =
        _pendingRequestDeviceIp == device.ipAddress ||
        _pendingRequestDeviceIp == device.deviceId;

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
            colors:
                isPending
                    ? [
                      Colors.yellow[300]!.withOpacity(0.2),
                      Colors.yellow[400]!.withOpacity(0.1),
                    ]
                    : [Colors.grey[850]!, Colors.grey[900]!],
          ),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isPending ? Colors.yellow[300]! : Colors.grey[700]!,
            width: isPending ? 2 : 1,
          ),
          boxShadow: [
            BoxShadow(
              color:
                  isPending
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
                color:
                    isPending
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
    final isPending =
        _pendingRequestDeviceIp == device.ipAddress ||
        _pendingRequestDeviceIp == device.deviceId;

    return Tooltip(
      message: '${device.deviceName}\n${device.platform}\n${device.ipAddress}',
      preferBelow: false,
      verticalOffset: 10,
      decoration: BoxDecoration(
        color: Colors.grey[900],
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.yellow[300]!, width: 1),
      ),
      textStyle: TextStyle(color: Colors.white, fontSize: 12),
      child: GestureDetector(
        onTap: isPending ? null : () => _sendConnectionRequest(device),
        child: AnimatedContainer(
          duration: Duration(milliseconds: 200),
          padding: EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color:
                isPending
                    ? Colors.yellow[300]!.withOpacity(0.2)
                    : Colors.grey[800],
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
                child:
                    _displayCode != null
                        ? StatefulBuilder(
                          builder: (context, setState) {
                            bool isPressed = false;

                            return GestureDetector(
                              onTap: () {
                                HapticFeedback.lightImpact();
                                Clipboard.setData(
                                  ClipboardData(text: _displayCode!),
                                );
                              },
                              onTapDown:
                                  (_) => setState(() => isPressed = true),
                              onTapUp: (_) => setState(() => isPressed = false),
                              onTapCancel:
                                  () => setState(() => isPressed = false),
                              child: AnimatedContainer(
                                duration: Duration(milliseconds: 150),
                                padding: EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 8,
                                ),
                                transform:
                                    Matrix4.identity()
                                      ..scale(isPressed ? 0.98 : 1.0),
                                decoration: BoxDecoration(
                                  color: Colors.yellow[300]!.withOpacity(
                                    isPressed ? 0.15 : 0.1,
                                  ),
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(
                                    color: Colors.yellow[300]!.withOpacity(
                                      isPressed ? 0.5 : 0.3,
                                    ),
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
                                      color: Colors.yellow[300]!.withOpacity(
                                        0.7,
                                      ),
                                      size: 16,
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        )
                        : Container(
                          padding: EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
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
                        padding: EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        transform:
                            Matrix4.identity()..scale(isPressed ? 0.98 : 1.0),
                        decoration: BoxDecoration(
                          color: Colors.grey[400]!.withOpacity(
                            isPressed ? 0.15 : 0.1,
                          ),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: Colors.grey[400]!.withOpacity(
                              isPressed ? 0.5 : 0.3,
                            ),
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
        if (_fileNames.isNotEmpty) _buildSmallClearButton(),
      ],
    );
  }

  Widget _buildFileList(bool isCompact) {
    return SizedBox(
      height: 160, // Fixed height for horizontal list (increased for padding)
      child: ListView.builder(
        scrollDirection: Axis.horizontal, // Changed to horizontal
        itemCount: _fileNames.length,
        itemBuilder: (context, index) {
          final fileName = _fileNames[index];
          final fileSize =
              _fileSizeList.length > index ? _fileSizeList[index] : 0;
          final progress =
              _progressList.length > index
                  ? _progressList[index]
                  : ValueNotifier(0.0);
          final isPaused =
              _isPausedList.length > index
                  ? _isPausedList[index]
                  : ValueNotifier(false);
          final isCompleted =
              _completedFiles.length > index
                  ? _completedFiles[index]
                  : false; // Check completion

          // Get client download statuses for this file
          final clientStatuses =
              <String, DownloadStatus>{}; // clientIP -> DownloadStatus
          for (final clientIP in _connectedClients) {
            if (_clientDownloads.containsKey(clientIP) &&
                _clientDownloads[clientIP]!.containsKey(index)) {
              clientStatuses[clientIP] = _clientDownloads[clientIP]![index]!;
            }
          }

          // Check if any client has completed this file
          final hasAnyClientCompleted = clientStatuses.values.any(
            (status) => status.isCompleted,
          );
          final completedClients =
              clientStatuses.values
                  .where((status) => status.isCompleted)
                  .toList();

          return _buildHorizontalFileCard(
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
      ),
    );
  }

  // New horizontal file card with long press functionality
  Widget _buildHorizontalFileCard({
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
    return GestureDetector(
      onLongPress:
          () => _showFileDetailsDialog(
            index: index,
            fileName: fileName,
            fileSize: fileSize,
            progress: progress,
            isPaused: isPaused,
            isCompleted: isCompleted,
            hasAnyClientCompleted: hasAnyClientCompleted,
            completedClients: completedClients,
            clientStatuses: clientStatuses,
          ),
      child: SizedBox(
        width: 160,
        height: 160,
        child: Container(
          margin: EdgeInsets.only(right: 12),
          decoration: BoxDecoration(
            color: Colors.grey[900],
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.grey[800]!, width: 1),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.3),
                blurRadius: 6,
                offset: Offset(0, 3),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: EdgeInsets.all(12),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // File Icon with circular progress
                  if (_isSharing && !hasAnyClientCompleted)
                    // Show circular progress when sharing
                    ValueListenableBuilder<double>(
                      valueListenable: progress,
                      builder:
                          (context, value, _) => ValueListenableBuilder<bool>(
                            valueListenable: isPaused,
                            builder:
                                (context, paused, _) => Stack(
                                  clipBehavior: Clip.none,
                                  children: [
                                    // Circular progress and pause button in center
                                    Stack(
                                      alignment: Alignment.center,
                                      children: [
                                        SizedBox(
                                          width: 70,
                                          height: 70,
                                          child: CircularProgressIndicator(
                                            value: value,
                                            backgroundColor: Colors.grey[800]!
                                                .withOpacity(0.3),
                                            color: Colors.yellow[300],
                                            strokeWidth: 5,
                                            strokeCap: StrokeCap.round,
                                          ),
                                        ),
                                        // Pause/Resume button in center of circle
                                        GestureDetector(
                                          onTap: () {
                                            _togglePause(index);
                                          },
                                          child: Container(
                                            width: 32,
                                            height: 32,
                                            decoration: BoxDecoration(
                                              color:
                                                  paused
                                                      ? Colors.orange[400]
                                                      : Colors.yellow[300],
                                              shape: BoxShape.circle,
                                              boxShadow: [
                                                BoxShadow(
                                                  color: Colors.black
                                                      .withOpacity(0.3),
                                                  blurRadius: 4,
                                                  offset: Offset(0, 2),
                                                ),
                                              ],
                                            ),
                                            child: Icon(
                                              paused
                                                  ? Icons.play_arrow
                                                  : Icons.pause,
                                              color: Colors.black,
                                              size: 20,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                    // Percentage badge at top-right
                                    Positioned(
                                      top: -8,
                                      right: -8,
                                      child: Container(
                                        padding: EdgeInsets.symmetric(
                                          horizontal: 6,
                                          vertical: 3,
                                        ),
                                        decoration: BoxDecoration(
                                          color: Colors.yellow[300],
                                          borderRadius: BorderRadius.circular(
                                            10,
                                          ),
                                          boxShadow: [
                                            BoxShadow(
                                              color: Colors.black.withOpacity(
                                                0.3,
                                              ),
                                              blurRadius: 4,
                                              offset: Offset(0, 2),
                                            ),
                                          ],
                                        ),
                                        child: Text(
                                          '${(value * 100).toStringAsFixed(0)}%',
                                          style: TextStyle(
                                            color: Colors.black,
                                            fontSize: 11,
                                            fontWeight: FontWeight.bold,
                                            height: 1.0,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                          ),
                    )
                  else
                    // Show file icon when not sharing or completed
                    Container(
                      width: 60,
                      height: 60,
                      decoration: BoxDecoration(
                        color:
                            hasAnyClientCompleted
                                ? Colors.green[400]
                                : Colors.yellow[300],
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(
                        hasAnyClientCompleted
                            ? Icons.check_rounded
                            : _getFileIcon(fileName),
                        color: Colors.black,
                        size: 30,
                      ),
                    ),
                  SizedBox(height: 10),
                  // File Name - constrained to prevent overflow
                  Flexible(
                    child: Text(
                      fileName,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        height: 1.2,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                    ),
                  ),
                  SizedBox(height: 6),
                  // File size (progress is now shown inside circle)
                  Text(
                    isCompleted ? 'Sent' : formatBytes(fileSize),
                    style: TextStyle(
                      color: isCompleted ? Colors.green[400] : Colors.grey[400],
                      fontSize: 10,
                      fontWeight: FontWeight.w500,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // File details dialog with pause/resume functionality
  void _showFileDetailsDialog({
    required int index,
    required String fileName,
    required int fileSize,
    required ValueNotifier<double> progress,
    required ValueNotifier<bool> isPaused,
    required bool isCompleted,
    required bool hasAnyClientCompleted,
    required List<DownloadStatus> completedClients,
    required Map<String, DownloadStatus> clientStatuses,
  }) {
    HapticFeedback.mediumImpact();

    showDialog(
      context: context,
      builder:
          (context) => Dialog(
            backgroundColor: Colors.transparent,
            child: Container(
              padding: EdgeInsets.all(24),
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
                  // File Icon
                  Container(
                    width: 80,
                    height: 80,
                    decoration: BoxDecoration(
                      color:
                          hasAnyClientCompleted
                              ? Colors.green[400]
                              : Colors.yellow[300],
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Icon(
                      hasAnyClientCompleted
                          ? Icons.check_rounded
                          : _getFileIcon(fileName),
                      color: Colors.black87,
                      size: 40,
                    ),
                  ),
                  SizedBox(height: 20),

                  // File Name
                  Text(
                    fileName,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                    textAlign: TextAlign.center,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                  SizedBox(height: 12),

                  // File Size
                  Text(
                    formatBytes(fileSize),
                    style: TextStyle(
                      color: Colors.grey[400],
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  SizedBox(height: 24),

                  // Action Buttons
                  Row(
                    children: [
                      // Delete Button
                      Expanded(
                        child: GestureDetector(
                          onTap: () async {
                            Navigator.of(context).pop();
                            final shouldDelete = await _showDeleteConfirmation(
                              fileName,
                            );
                            if (shouldDelete) {
                              _deleteFile(index);
                            }
                          },
                          child: Container(
                            padding: EdgeInsets.symmetric(vertical: 14),
                            decoration: BoxDecoration(
                              color: Colors.red[600],
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  Icons.delete_rounded,
                                  color: Colors.white,
                                  size: 18,
                                ),
                                SizedBox(width: 8),
                                Text(
                                  'Delete',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      SizedBox(width: 12),

                      // Close Button
                      Expanded(
                        child: GestureDetector(
                          onTap: () => Navigator.of(context).pop(),
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
                              'Close',
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
                    ],
                  ),
                ],
              ),
            ),
          ),
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
      direction:
          DismissDirection.endToStart, // Swipe right to left (like Gmail)
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
            Icon(Icons.delete_rounded, color: Colors.white, size: 28),
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
                            color:
                                isCompleted
                                    ? Colors.green[400]
                                    : Colors.grey[400],
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
                              completedClients
                                  .map((c) => c.clientIP)
                                  .join(', '),
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
                        builder:
                            (context, value, _) => Container(
                              width: 32,
                              height: 32,
                              child: Stack(
                                alignment: Alignment.center,
                                children: [
                                  CircularProgressIndicator(
                                    value: value,
                                    backgroundColor: Colors.grey[800]!
                                        .withOpacity(0.3),
                                    color: Colors.yellow[300],
                                    strokeWidth: 3,
                                    strokeCap: StrokeCap.round,
                                  ),
                                  // Pause/Resume button overlay
                                  ValueListenableBuilder<bool>(
                                    valueListenable: isPaused,
                                    builder:
                                        (context, paused, _) => Transform.scale(
                                          scale:
                                              0.625, // Scale down from 32x32 to 20x20
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
                        builder:
                            (context, value, _) => ValueListenableBuilder<bool>(
                              valueListenable: isPaused,
                              builder:
                                  (context, paused, _) => Text(
                                    paused
                                        ? 'Paused'
                                        : '${(value * 100).toStringAsFixed(0)}%',
                                    style: TextStyle(
                                      color:
                                          paused
                                              ? Colors.yellow[600]
                                              : Colors.yellow[300],
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
                style: TextStyle(color: Colors.grey[300]),
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
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            );
          },
        ) ??
        false;
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
                  border: Border.all(color: Colors.grey[800]!, width: 2),
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
            style: TextStyle(color: Colors.grey[500], fontSize: 14),
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
              color:
                  isEnabled
                      ? (isPrimary ? Colors.yellow[300] : color)
                      : Colors.grey[700],
              shape: BoxShape.circle,
              boxShadow:
                  isEnabled
                      ? [
                        BoxShadow(
                          color: (isPrimary ? Colors.yellow[400]! : color)
                              .withOpacity(isPressed ? 0.2 : 0.3),
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
                      ]
                      : [
                        BoxShadow(
                          color: Colors.grey[800]!.withOpacity(0.3),
                          blurRadius: 8,
                          offset: Offset(0, 4),
                          spreadRadius: 0,
                        ),
                      ],
              border:
                  isEnabled && isPrimary
                      ? Border.all(color: Colors.yellow[600]!, width: 2)
                      : null,
            ),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: isEnabled ? onTap : null,
                borderRadius: BorderRadius.circular(44),
                splashColor:
                    isEnabled
                        ? Colors.white.withOpacity(0.2)
                        : Colors.transparent,
                highlightColor:
                    isEnabled
                        ? Colors.white.withOpacity(0.1)
                        : Colors.transparent,
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
                  color: (isPrimary ? Colors.yellow[400]! : color).withOpacity(
                    isPressed ? 0.2 : 0.3,
                  ),
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
              border:
                  isPrimary
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
                child: Center(child: Icon(icon, color: textColor, size: 26)),
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
                        color: backgroundColor.withOpacity(
                          isPressed ? 0.2 : 0.3,
                        ),
                        blurRadius: isPressed ? 8 : 12,
                        offset: Offset(0, isPressed ? 3 : 6),
                        spreadRadius: 0,
                      ),
                    ],
                    border: Border.all(
                      color:
                          backgroundColor == Colors.yellow[300]!
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
                  color: (isPaused ? Colors.green[400] : Colors.yellow[400])!
                      .withOpacity(isPressed ? 0.3 : 0.4),
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
                      color: Colors.red[400]!.withOpacity(
                        isPressed ? 0.9 : 0.7,
                      ),
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
                    color:
                        isEnabled
                            ? (isPrimary ? Colors.yellow[300] : color)
                            : Colors.grey[700],
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: [
                      BoxShadow(
                        color: (isPrimary ? Colors.yellow[400]! : color)
                            .withOpacity(isPressed ? 0.2 : 0.3),
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
                    border:
                        isEnabled && isPrimary
                            ? Border.all(color: Colors.yellow[600]!, width: 2)
                            : Border.all(
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
    final paint =
        Paint()
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
      final borderPaint =
          Paint()
            ..color = Colors.yellow[600]!
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2;
      canvas.drawPath(path, borderPaint);
    }

    // Add shadow effect
    if (!isPressed) {
      final shadowPaint =
          Paint()
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

class _AnimatedRadarState extends State<_AnimatedRadar>
    with SingleTickerProviderStateMixin {
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
  State<_PulsingSearchIndicator> createState() =>
      _PulsingSearchIndicatorState();
}

class _PulsingSearchIndicatorState extends State<_PulsingSearchIndicator>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: 1500),
    )..repeat(reverse: true);

    _scaleAnimation = Tween<double>(
      begin: 0.8,
      end: 1.2,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));
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
          child: Icon(Icons.search, color: Colors.grey[600], size: 30),
        ),
      ],
    );
  }
}
