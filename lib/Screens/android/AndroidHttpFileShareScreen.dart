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
import 'package:zap_share/services/device_discovery_service.dart';
import '../../services/range_request_handler.dart';

import 'package:http/http.dart' as http; // Add http package for handshake
import '../../services/wifi_direct_service.dart';
import '../../widgets/connection_request_dialog.dart';
import 'AndroidReceiveScreen.dart';

import '../../widgets/CustomAvatarWidget.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../blocs/discovery/discovery_bloc.dart';
import '../../blocs/discovery/discovery_event.dart';
import '../../blocs/discovery/discovery_state.dart';

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
  ServerSocket? _tcpServer; // TCP Server for app-to-app transfer
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
  final Map<int, int> _totalBytesSentPerFile =
      {}; // fileIndex -> totalBytesSent
  final Map<int, Set<String>> _activeRangeRequests =
      {}; // fileIndex -> Set of range strings
  final Map<int, Map<String, int>> _rangeBytesSentPerRequest =
      {}; // fileIndex -> (rangeKey -> bytesSent)

  // Track downloads per client for multiple simultaneous downloads
  final Map<String, Map<int, DownloadStatus>> _clientDownloads =
      {}; // clientIP -> {fileIndex -> DownloadStatus}
  final List<String> _connectedClients = []; // List of connected client IPs
  final Map<String, String> _clientDeviceNames =
      {}; // clientIP -> deviceName mapping

  final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
      FlutterLocalNotificationsPlugin();

  // Device Discovery
  // Device Discovery
  final DeviceDiscoveryService _discoveryService = DeviceDiscoveryService();
  // List<DiscoveredDevice> _nearbyDevices = []; // Removed: Managed by DiscoveryBloc
  // StreamSubscription? _devicesSubscription; // Removed: Managed by DiscoveryBloc
  StreamSubscription? _connectionRequestSubscription;
  StreamSubscription? _connectionResponseSubscription;
  String? _pendingRequestDeviceIp;
  Timer? _requestTimeoutTimer;
  Timer? _wifiDirectDiscoveryTimer;
  DiscoveredDevice? _pendingDevice;
  final Set<String> _processedRequests =
      {}; // Track processed request IPs to prevent duplicates
  final Map<String, DateTime> _lastRequestTime =
      {}; // Track last request time per IP
  bool _isShowingConnectionDialog = false; // Prevent multiple dialogs

  // Wi-Fi Direct Service
  final WiFiDirectService _wifiDirectService = WiFiDirectService();
  StreamSubscription? _groupInfoSubscription;
  StreamSubscription?
  _peersSubscription; // Listen for discovered Wi-Fi Direct peers
  List<WiFiDirectPeer> _wifiDirectPeers =
      []; // Store discovered Wi-Fi Direct peers

  // Status capsule state (replaces loading dialogs)
  String? _statusMessage;
  String? _statusSubtitle;
  IconData _statusIcon = Icons.sync_rounded;
  bool _statusIsSuccess = false;
  bool _statusIsError = false;
  Timer? _statusDismissTimer;

  // Loading dialog state tracking - now using status capsule instead
  // final bool _isLoadingDialogShowing = false; // Unused
  // final GlobalKey<_SmoothLoadingDialogState> _loadingDialogKey = GlobalKey(); // Unused
  // NavigatorState? _dialogNavigator; // Unused - status capsule doesn't need navigator

  // Bloc
  late DiscoveryBloc _discoveryBloc;

  // Port configuration
  int _port = 8080; // Default port for HTTP File Share
  String? _displayCode; // Share code for display (generated in _startListening)

  // File size cache to persist sizes across server restarts
  final Map<String, int> _fileSizeCache = {}; // uri -> size

  // Modern toast notification
  void _showModernToast({
    required String message,
    IconData icon = Icons.check_circle_rounded,
    Color backgroundColor = const Color(0xFF1C1C1E),
    Color iconColor = const Color(0xFFFFD600),
    Duration duration = const Duration(seconds: 2),
  }) {
    if (!mounted) return;

    final overlay = Overlay.of(context);
    late OverlayEntry overlayEntry;

    overlayEntry = OverlayEntry(
      builder:
          (context) => _ModernToast(
            message: message,
            icon: icon,
            backgroundColor: backgroundColor,
            iconColor: iconColor,
            onDismiss: () => overlayEntry.remove(),
            duration: duration,
          ),
    );

    overlay.insert(overlayEntry);
  }

  // Status capsule methods (replaces loading dialogs)
  void _showStatus({
    required String message,
    String? subtitle,
    IconData icon = Icons.sync_rounded,
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
    setState(() {
      _statusMessage = null;
      _statusSubtitle = null;
      _statusIsSuccess = false;
      _statusIsError = false;
    });
  }

  // Build the status capsule widget
  Widget _buildStatusCapsule() {
    if (_statusMessage == null) return const SizedBox.shrink();

    Color bgColor = Colors.black.withOpacity(0.85);
    Color iconColor = Colors.white70;

    if (_statusIsSuccess) {
      bgColor = const Color(0xFF1B5E20).withOpacity(0.95);
      iconColor = Colors.greenAccent;
    } else if (_statusIsError) {
      bgColor = const Color(0xFFB71C1C).withOpacity(0.95);
      iconColor = Colors.redAccent;
    }

    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(24),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!_statusIsSuccess && !_statusIsError)
            SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation<Color>(iconColor),
              ),
            )
          else
            Icon(_statusIcon, color: iconColor, size: 18),
          const SizedBox(width: 10),
          Flexible(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _statusMessage!,
                  style: GoogleFonts.outfit(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (_statusSubtitle != null)
                  Text(
                    _statusSubtitle!,
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
            onTap: _hideStatus,
            child: Icon(Icons.close_rounded, color: Colors.white38, size: 16),
          ),
        ],
      ),
    );
  }

  // Modern loading dialog for multi-step processes
  void _showModernLoadingDialog({
    required String title,
    required String subtitle,
    String? step,
    IconData icon = Icons.sync_rounded,
  }) {
    // Use status capsule instead of dialog
    _showStatus(message: title, subtitle: subtitle, icon: icon);
  }

  // Update loading dialog content smoothly
  void _updateLoadingDialog({
    required String title,
    required String subtitle,
    String? step,
    IconData icon = Icons.sync_rounded,
  }) {
    // Use status capsule instead of dialog
    _showStatus(message: title, subtitle: subtitle, icon: icon);
  }

  // Dismiss loading dialog with optional completion animation
  Future<void> _dismissLoadingDialog({bool showSuccess = false}) async {
    if (showSuccess) {
      _showStatus(
        message: 'Connected!',
        icon: Icons.check_circle_rounded,
        isSuccess: true,
        autoDismiss: const Duration(seconds: 2),
      );
    } else {
      _hideStatus();
    }
  }

  String _ipToCode(String ip, {int? port}) {
    final parts = ip.split('.').map(int.parse).toList();
    if (parts.length != 4) return '';
    // Encode IP address (32 bits)
    int ipNum =
        (parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3];
    String ipCode = ipNum.toRadixString(36).toUpperCase().padLeft(8, '0');

    // Encode port (16 bits) - use base 36 for consistency
    int targetPort = port ?? _port;
    String portCode = targetPort
        .toRadixString(36)
        .toUpperCase()
        .padLeft(3, '0');

    // Combine: 8 chars for IP + 3 chars for port = 11 chars total
    return ipCode + portCode;
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
    if (bytes < 1024 * 1024 * 1024) {
      return "${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB";
    }
    return "${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB";
  }

  // Format client IP for display (show last octet for brevity)
  String _formatClientIP(String ip) {
    final parts = ip.split('.');
    if (parts.length == 4) {
      return 'Device .${parts[3]}';
    }
    return ip;
  }

  static const MethodChannel _platform = MethodChannel('zapshare.saf');

  @override
  void initState() {
    super.initState();

    // Initialize Bloc manually to avoid context scope issues with Hero/Overlay
    _discoveryBloc = DiscoveryBloc(discoveryService: _discoveryService)
      ..add(StartDiscovery());

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
    _loadPort();

    // Initialize Wi-Fi Direct service, then start peer discovery (must be sequential)
    _initWiFiDirectService().then((_) => _initWiFiDirectPeerDiscovery());

    // Initialize device discovery
    _initDeviceDiscovery();

    // Set up listener for future shared files (after initial processing)
    _listenForSharedFiles();

    // Periodically cleanup disconnected clients
    Timer.periodic(Duration(minutes: 2), (timer) {
      if (mounted) {
        _cleanupDisconnectedClients();
      }
    });

    // Note: Per-client progress is handled by _ClientProgressSection widget
    // which has its own isolated timer to avoid rebuilding parent widget tree
  }

  Future<void> _initWiFiDirectService() async {
    print('🚀 Initializing Wi-Fi Direct Service...');
    await _wifiDirectService.initialize();
    print('✅ Wi-Fi Direct Service initialized');
  }

  Future<void> _initWiFiDirectPeerDiscovery() async {
    print('🔍 Initializing Wi-Fi Direct Peer Discovery...');

    // Start peer discovery to find nearby devices
    final discoveryStarted = await _wifiDirectService.startPeerDiscovery();

    if (discoveryStarted) {
      print('✅ Wi-Fi Direct Peer Discovery started successfully');

      // Listen for discovered peers
      _peersSubscription = _wifiDirectService.peersStream.listen((peers) {
        if (mounted) {
          setState(() {
            _wifiDirectPeers = peers;
          });
          print('📡 Discovered ${peers.length} Wi-Fi Direct peer(s)');
          for (var peer in peers) {
            print('   - ${peer.deviceName} (${peer.deviceAddress})');
          }
        }
      });

      // WiFi Direct discovery expires after ~30-120 seconds on most Android devices.
      // Periodically restart it so peers remain visible.
      _wifiDirectDiscoveryTimer?.cancel();
      _wifiDirectDiscoveryTimer = Timer.periodic(const Duration(seconds: 30), (
        _,
      ) {
        if (mounted) {
          _wifiDirectService.startPeerDiscovery();
        }
      });

      _showStatus(
        message: 'Scanning for Wi-Fi Direct devices...',
        icon: Icons.wifi_find_rounded,
        autoDismiss: const Duration(seconds: 2),
      );
    } else {
      print('❌ Failed to start Wi-Fi Direct Peer Discovery');
    }
  }

  // New method for reliable HTTP handshake
  Future<bool> _sendHttpConnectionRequest(
    String targetIp,
    List<String> fileNames,
    int totalSize,
  ) async {
    try {
      final url = Uri.parse('http://$targetIp:$_port/connection-request');
      print('📤 Sending HTTP Connection Request to $url');

      final body = jsonEncode({
        'deviceId': _discoveryService.myDeviceId ?? 'unknown',
        'deviceName': _discoveryService.myDeviceName ?? 'Unknown Device',
        'platform': 'android', // Assuming android screen
        'port': _port,
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
            _showModernToast(
              message: 'Connection declined by peer',
              icon: Icons.block_rounded,
              iconColor: Colors.red[400]!,
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
      // Check cache first, otherwise use 0
      sizes.add(_fileSizeCache[uri] ?? 0);
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

    // Get file sizes asynchronously after initialization (only for uncached files)
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      print('📁 [_processInitialFiles] Getting file sizes asynchronously...');
      for (int i = 0; i < uris.length; i++) {
        // Skip if already cached
        if (_fileSizeCache.containsKey(uris[i])) {
          print(
            '📁 [_processInitialFiles] File ${names[i]} size from cache: ${_fileSizeCache[uris[i]]} bytes',
          );
          continue;
        }

        try {
          final size = await getFileSizeFromUri(uris[i]);
          if (mounted) {
            setState(() {
              _fileSizeList[i] = size;
              _fileSizeCache[uris[i]] = size; // Cache the size
            });
            print(
              '📁 [_processInitialFiles] File ${names[i]} size: $size bytes (cached)',
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

      // Check cache first
      int size = _fileSizeCache[uri] ?? 0;
      if (size == 0) {
        try {
          size = await getFileSizeFromUri(uri);
          _fileSizeCache[uri] = size; // Cache the size
          print('📁 [_handleSharedFiles] File size: $size bytes (cached)');
        } catch (e) {
          print('⚠️ [_handleSharedFiles] Could not get file size: $e');
        }
      } else {
        print('📁 [_handleSharedFiles] File size from cache: $size bytes');
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

  Future<void> _loadPort() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      setState(() {
        _port = prefs.getInt('http_file_share_port') ?? 8080;
      });
    } catch (_) {}
  }

  Future<void> _showPortDialog() async {
    final controller = TextEditingController(text: _port.toString());
    final result = await showDialog<int>(
      context: context,
      builder:
          (context) => AlertDialog(
            backgroundColor: const Color(0xFF1C1C1E),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
            title: Text(
              'Change Port',
              style: GoogleFonts.outfit(
                color: Colors.white,
                fontWeight: FontWeight.w700,
              ),
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Enter a port number (1024-65535)',
                  style: GoogleFonts.outfit(
                    color: Colors.grey[400],
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: controller,
                  keyboardType: TextInputType.number,
                  style: GoogleFonts.outfit(color: Colors.white),
                  decoration: InputDecoration(
                    filled: true,
                    fillColor: Colors.white.withOpacity(0.05),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                    hintText: '8080',
                    hintStyle: GoogleFonts.outfit(color: Colors.grey[600]),
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(
                  'Cancel',
                  style: GoogleFonts.outfit(
                    color: Colors.grey,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              ElevatedButton(
                onPressed: () {
                  final port = int.tryParse(controller.text);
                  if (port != null && port >= 1024 && port <= 65535) {
                    Navigator.pop(context, port);
                  } else {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          'Invalid port number',
                          style: GoogleFonts.outfit(color: Colors.white),
                        ),
                        backgroundColor: Colors.red,
                      ),
                    );
                  }
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFFFD600),
                  foregroundColor: Colors.black,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: Text(
                  'Save',
                  style: GoogleFonts.outfit(fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
    );

    if (result != null && result != _port) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('http_file_share_port', result);
      setState(() {
        _port = result;
      });

      if (_isSharing) {
        await _stopServer();
        await _startSharingSession();
      }

      HapticFeedback.mediumImpact();
      _showModernToast(
        message: 'Port updated to $_port',
        icon: Icons.settings_rounded,
        iconColor: const Color(0xFFFFD600),
      );
    }
  }

  Future<void> _init() async {
    await _clearCache();
    await _fetchLocalIp();
    await _loadPort();
    // Start listening on HTTP/TCP immediately so we can receive connection requests instantly
    _startListening();

    _showConnectionTip();
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

    // Notification status text (unused variable but kept for potential future use)
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
      icon: 'ic_stat_notify',
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
                'File $fileIndex: Sent $bytesSent/$fileSize bytes (${(progress * 100).toStringAsFixed(1)}%)',
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

            // Throttle updates: only update if 100ms passed or progress increased by 1%
            if (now.difference(lastUpdate).inMilliseconds > 100 ||
                (progress - lastProgress) > 0.01) {
              _progressList[fileIndex].value = progress;
              // Note: UI updates are handled by _uiUpdateTimer for smooth performance

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

      // Reset progress for next transfer (but keep file size intact for re-sending)
      _progressList[fileIndex].value = 0.0;
      _bytesSentList[fileIndex] = 0;
      // NOTE: Do NOT reset _fileSizeList[fileIndex] = 0 here!
      // The file size must be preserved so the file can be sent to other recipients
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

    // Interface scanning disabled - NetworkInfo is reliable for WiFi Direct
    // Uncomment below if you need manual interface scanning for debugging
    /*
    if (ip == null || !ip.startsWith('192.168.49.')) {
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
    */

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
    // Dialog removed as per user request for cleaner TV experience
    return;
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

        // Check cache first
        int size = _fileSizeCache[docFile.uri] ?? 0;
        if (size == 0) {
          try {
            size = await getFileSizeFromUri(docFile.uri);
            _fileSizeCache[docFile.uri] = size; // Cache the size
          } catch (_) {
            size = 0;
          }
        }
        sizes.add(size);
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

  Future<void> _startSharingSession() async {
    if (_fileUris.isEmpty) return;
    HapticFeedback.mediumImpact();

    // Ensure server is listening
    await _startListening();

    await FlutterForegroundTask.startService(
      notificationTitle: "ZapShare Transfer",
      notificationText: "Sharing file(s)...",
      notificationIcon: const NotificationIcon(
        metaDataName: 'com.pravera.flutter_foreground_task.notification_icon',
      ),
    );
    setState(() => _isSharing = true);
  }

  Future<void> _startListening() async {
    // Start file server (HTTP + TCP)
    await _server?.close(force: true);
    await _tcpServer?.close();
    _tcpServer = null;
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

    try {
      if (sc != null) {
        _server = await HttpServer.bindSecure(
          InternetAddress.anyIPv4,
          _port,
          sc,
        );
        _useHttps = true;
      } else {
        _server = await HttpServer.bind(InternetAddress.anyIPv4, _port);
        _useHttps = false;
      }
    } catch (e) {
      print('❌ Failed to bind HTTP server: $e');
      return;
    }

    // Start TCP Server for App-to-App transfer
    try {
      _tcpServer = await ServerSocket.bind(InternetAddress.anyIPv4, _port + 1);
      _tcpServer!.listen(_handleTcpClient);
      print('🚀 UDP/TCP: Starting TCP server on port ${_port + 1}');
    } catch (e) {
      print('❌ Failed to start TCP server: $e');
    }

    // Generate 11-char code for sharing (IP + port)

    final codeForUser = _ipToCode(_localIp ?? '', port: _port);
    if (mounted) {
      setState(() {
        _displayCode = codeForUser;
      });
    }

    if (_server != null) {
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
              port: (data['port'] as int?) ?? 8080,
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
                    onAccept: () {
                      Navigator.of(dialogContext).pop();
                      _isShowingConnectionDialog = false;
                      completer.complete(true);

                      if (mounted) {
                        final code = _ipToCode(
                          connectionRequest.ipAddress,
                          port: connectionRequest.port,
                        );

                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder:
                                (context) => AndroidReceiveScreen(
                                  autoConnectCode: code,
                                  useTcp:
                                      true, // Use TCP for app-to-app transfers
                                ),
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
    }
    // Server is now listening
    // setState(() => _isSharing = true); // Handled in _startSharingSession
  }

  /// Handle incoming TCP client connections for app-to-app file transfer
  /// Supports two protocols:
  /// 1. Text: "LIST\n" → JSON array of files
  /// 2. Binary: [4 bytes file index] → metadata + file data
  Future<void> _handleTcpClient(Socket client) async {
    final clientAddress = client.remoteAddress.address;
    print('📱 TCP: Client connected from $clientAddress');

    // Define requestProcessed before try block to ensure it's accessible in finally
    bool requestProcessed = false;

    try {
      // Use a subscription to handle potentially fragmented packets
      final buffer = <int>[];

      await for (final chunk in client) {
        if (requestProcessed)
          break; // Should not happen with current protocol logic
        buffer.addAll(chunk);

        // Try to process buffer
        if (buffer.isEmpty) continue;

        // Check if it's a text command (starts with 'L' for LIST)
        if (buffer[0] == 76) {
          // 'L'
          // Wait for newline to ensure full command
          if (buffer.contains(10)) {
            // 10 is '\n'
            final commandBytes = buffer.takeWhile((b) => b != 10).toList();
            final command = utf8.decode(commandBytes).trim();
            print('📥 TCP: Received command: $command');

            if (command == 'LIST') {
              // Send file list as JSON
              final fileList = List.generate(
                _fileNames.length,
                (i) => {
                  'index': i,
                  'name': _fileNames[i],
                  'size': _fileSizeList.length > i ? _fileSizeList[i] : 0,
                },
              );
              final response = jsonEncode(fileList);
              client.writeln(response);
              await client.flush();
              print('✅ TCP: Sent file list (${fileList.length} files)');
            } else {
              print('❌ TCP: Unknown command: $command');
            }
            requestProcessed = true;
            await client.close(); // Close after response (One-Shot Request)
            return;
          }
          // Buffer doesn't have newline yet, wait for more chunks
          continue;
        }

        // Binary protocol for file download (4 bytes index)
        if (buffer.length >= 4) {
          // Parse file index (big-endian int32)
          final fileIndex =
              (buffer[0] << 24) |
              (buffer[1] << 16) |
              (buffer[2] << 8) |
              buffer[3];

          print('📥 TCP: Client requested file index: $fileIndex');

          if (fileIndex < 0 || fileIndex >= _fileUris.length) {
            print('❌ TCP: Invalid file index: $fileIndex');
            await client.close();
            return;
          }
          requestProcessed =
              true; // Mark as processed so we can proceed to send file

          // Break the loop to proceed with file sending OUTSIDE the subscription scope?
          // No, easiest is to call a helper or handle it right here.
          // Since we are inside 'await for', let's handle file sending here and then return.

          await _sendFileOverTcp(client, fileIndex);
          return;
        }
      }
    } catch (e) {
      print('❌ TCP: Error handling client: $e');
    } finally {
      // If requestProcessed is false here, it means the client disconnected
      // without sending a valid request or the request was malformed.
      // In such cases, the client might not have been closed yet.
      if (!requestProcessed) {
        await client.close();
        print('🔌 TCP: Client disconnected (no valid request): $clientAddress');
      }
    }
  }

  Future<void> _sendFileOverTcp(Socket client, int fileIndex) async {
    final fileName = _fileNames[fileIndex];
    final fileSize = _fileSizeList[fileIndex];
    final fileUri = _fileUris[fileIndex];
    final clientAddress = client.remoteAddress.address;

    print('📤 TCP: Sending file: $fileName ($fileSize bytes)');

    try {
      // Send metadata header (JSON)
      final metadata = jsonEncode({
        'fileName': fileName,
        'fileSize': fileSize,
        'fileIndex': fileIndex,
      });
      final metadataBytes = utf8.encode(metadata);
      final metadataLength = metadataBytes.length;

      // Send metadata length (4 bytes) + metadata
      client.add([
        (metadataLength >> 24) & 0xFF,
        (metadataLength >> 16) & 0xFF,
        (metadataLength >> 8) & 0xFF,
        metadataLength & 0xFF,
      ]);
      client.add(metadataBytes);
      await client.flush();

      // Reset progress for this file
      if (mounted) {
        _progressList[fileIndex].value = 0.0;
        _bytesSentList[fileIndex] = 0;
      }

      // Stream file data
      int bytesSent = 0;
      const chunkSize = 65536; // 64KB chunks

      // Speed calculation variables
      DateTime lastUpdate = DateTime.now();
      double lastProgress = 0.0;
      int lastBytes = 0;
      DateTime lastSpeedTime = DateTime.now();
      double speedMbps = 0.0;

      if (fileUri.startsWith('content://')) {
        // SAF URI - use method channel
        dynamic streamId;
        try {
          streamId = await _channel.invokeMethod('openReadStream', {
            'uri': fileUri,
          });
          if (streamId == null) {
            print('❌ TCP: Failed to open SAF stream');
            // Ensure client is closed if an error occurs here
            await client.close();
            return;
          }

          bool done = false;
          while (!done) {
            // Check pause state
            while (_isPausedList.length > fileIndex &&
                _isPausedList[fileIndex].value) {
              await Future.delayed(Duration(milliseconds: 200));
            }

            final chunk = await _channel.invokeMethod<Uint8List>('readChunk', {
              'uri': fileUri,
              'streamId': streamId,
              'size': chunkSize,
            });

            if (chunk == null || chunk.isEmpty) {
              done = true;
            } else {
              client.add(chunk);
              bytesSent += chunk.length;

              // Flush regularly to manage backpressure and ensure smooth progress
              // Flush every 512KB
              if (bytesSent % (512 * 1024) == 0) {
                await client.flush();
              }

              // Update progress logic
              final now = DateTime.now();
              final elapsed = now.difference(lastSpeedTime).inMilliseconds;

              if (elapsed > 0) {
                final bytesDelta = bytesSent - lastBytes;
                speedMbps = (bytesDelta * 8) / (elapsed * 1000); // Mbps
                lastBytes = bytesSent;
                lastSpeedTime = now;
              }

              final progress = (bytesSent / fileSize).clamp(0.0, 1.0);

              // Throttle UI updates (every 200ms)
              if (now.difference(lastUpdate).inMilliseconds > 200 ||
                  (progress - lastProgress) > 0.01) {
                if (mounted) {
                  _progressList[fileIndex].value = progress;
                  _bytesSentList[fileIndex] = bytesSent;
                }

                showProgressNotification(
                  fileIndex,
                  progress,
                  fileName,
                  speedMbps: speedMbps,
                  paused: _isPausedList[fileIndex].value,
                );

                lastUpdate = now;
                lastProgress = progress;

                // Log occasionally
                if (bytesSent % (5 * 1024 * 1024) == 0) {
                  print(
                    '📤 TCP: Sent ${(bytesSent / 1024 / 1024).toStringAsFixed(1)} MB ($speedMbps Mbps)',
                  );
                }
              }
            }
          }

          // Closing stream
          await _channel.invokeMethod('closeReadStream', {
            'uri': fileUri,
            'streamId': streamId,
          });
        } catch (e) {
          print('❌ TCP: Error streaming file: $e');
          // Ensure client is closed if an error occurs during streaming
          await client.close();
          return;
        }
      } else {
        // Regular file path (fallback)
        try {
          final file = File(fileUri);
          if (await file.exists()) {
            final stream = file.openRead();
            await for (final chunk in stream) {
              // Check pause state
              while (_isPausedList.length > fileIndex &&
                  _isPausedList[fileIndex].value) {
                await Future.delayed(Duration(milliseconds: 200));
              }

              client.add(chunk);
              bytesSent += chunk.length;

              // Flush regularly
              if (bytesSent % (512 * 1024) == 0) {
                await client.flush();
              }

              // Update progress logic
              final now = DateTime.now();
              final elapsed = now.difference(lastSpeedTime).inMilliseconds;

              if (elapsed > 0) {
                final bytesDelta = bytesSent - lastBytes;
                speedMbps = (bytesDelta * 8) / (elapsed * 1000); // Mbps
                lastBytes = bytesSent;
                lastSpeedTime = now;
              }

              final progress = (bytesSent / fileSize).clamp(0.0, 1.0);

              // Throttle UI updates
              if (now.difference(lastUpdate).inMilliseconds > 200 ||
                  (progress - lastProgress) > 0.01) {
                if (mounted) {
                  _progressList[fileIndex].value = progress;
                  _bytesSentList[fileIndex] = bytesSent;
                }

                showProgressNotification(
                  fileIndex,
                  progress,
                  fileName,
                  speedMbps: speedMbps,
                  paused: false,
                );

                lastUpdate = now;
                lastProgress = progress;
              }
            }
          }
        } catch (e) {
          print('❌ TCP: Error streaming file from path: $e');
          await client.close();
          return;
        }
      }

      await client.flush();

      // Completion updates
      if (mounted) {
        _progressList[fileIndex].value = 1.0;
        if (_completedFiles.length > fileIndex) {
          _completedFiles[fileIndex] = true;
        }
      }

      // Clean up notification
      await cancelProgressNotification(fileIndex);

      print('✅ TCP: File sent successfully: $fileName ($bytesSent bytes)');

      // Record transfer history
      try {
        final prefs = await SharedPreferences.getInstance();
        final history = prefs.getStringList('transfer_history') ?? [];
        final entry = {
          'fileName': fileName,
          'fileSize': fileSize,
          'direction': 'Sent',
          'peer': clientAddress,
          'protocol': 'TCP',
          'dateTime': DateTime.now().toIso8601String(),
        };
        history.insert(0, jsonEncode(entry));
        if (history.length > 100) history.removeLast();
        await prefs.setStringList('transfer_history', history);
      } catch (_) {}
    } catch (e) {
      print('❌ TCP: Error handling client: $e');
    } finally {
      try {
        // Give TCP stack time to drain send buffer before closing
        await Future.delayed(const Duration(milliseconds: 300));
        await client.flush();
        await client.close();
      } catch (_) {
        try {
          client.destroy();
        } catch (_) {}
      }
      print('🔌 TCP: Client disconnected: $clientAddress');
    }
  }

  Future<void> _stopServer() async {
    HapticFeedback.mediumImpact();
    setState(() => _loading = true);

    // Close both HTTP and TCP servers so stale file lists don't persist
    await _server?.close(force: true);
    _server = null;
    await _tcpServer?.close();
    _tcpServer = null;

    // Stop Wi-Fi Direct group
    try {
      await _wifiDirectService.removeGroup();
      print('✅ Wi-Fi Direct group removed');
    } catch (e) {
      print('Error stopping Wi-Fi Direct group: $e');
    }

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
      await _tcpServer?.close();
      _tcpServer = null;
      await FlutterForegroundTask.stopService();

      setState(() {
        _loading = false;
        // _displayCode = null; // Removed as it is undefined
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
    return await _channel.invokeMethod<String>('zipFilesToCache', {
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
                
                return `
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
                            \${isImage ? `<button class="preview-btn" onclick="previewImage(\${file.index})">Preview</button>` : ''}
                            <a href="/file/\${file.index}" class="download-btn" download onclick="startDownload(this, \${file.index})">
                                Download
                            </a>
                        </div>
                    </div>
                `;
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
            
            const fileItem = document.querySelector(`[data-index="\${fileIndex}"]`);
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
                downloadBtn.textContent = `Download Selected (\${selectedFiles.size})`;
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
                paginationInfo.textContent = `Page \${currentPage + 1} of \${totalPages} (\${startIndex}-\${endIndex} of \${allFiles.length} files)`;
                prevBtn.disabled = currentPage === 0;
                nextBtn.disabled = currentPage === totalPages - 1;
            } else {
                pagination.style.display = 'none';
            }
        }
        
        function previewImage(fileIndex) {
            const modal = document.getElementById('imageModal');
            const modalImg = document.getElementById('modalImage');
            
            modalImg.src = `/file/\${fileIndex}`;
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
                link.href = `/file/\${fileIndex}`;
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
    print('🔍 Initializing device discovery listeners...');

    // Note: Device Discovery Service start/stop is now handled by DiscoveryBloc

    // Listen for incoming connection requests
    // We still listen to this here because it triggers UI dialogs
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
        .listen((response) async {
          print(
            '📨 Connection response received: accepted=${response.accepted}, ip=${response.ipAddress}',
          );
          if (mounted && _pendingRequestDeviceIp != null) {
            // Cancel the timeout timer since we got a response
            _requestTimeoutTimer?.cancel();
            _requestTimeoutTimer = null;

            // Dismiss any loading dialog that might be showing
            if (response.accepted) {
              await _dismissLoadingDialog(showSuccess: true);
            } else {
              _dismissLoadingDialog();
            }

            if (response.accepted) {
              // Connection accepted! Start sharing
              print('✅ Connection accepted! Starting server...');
              _showModernToast(
                message: 'Connection accepted! Ready to share.',
                icon: Icons.check_circle_rounded,
                iconColor: Colors.green[400]!,
              );
              _startSharingToDevice(_pendingRequestDeviceIp!);
            } else {
              // Connection declined
              print('❌ Connection declined');
              _showModernToast(
                message: 'Connection request was declined',
                icon: Icons.close_rounded,
                iconColor: Colors.red[400]!,
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
    print('   Context mounted: $mounted');

    // Set flag to prevent multiple dialogs
    _isShowingConnectionDialog = true;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        print('📱 Building ConnectionRequestDialog...');
        return ConnectionRequestDialog(
          request: request,
          onAccept: () async {
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

            // For WiFi Direct connections, establish P2P connection first, then use that IP
            // For regular WiFi/HTTP connections, use the UDP broadcast IP directly

            // Navigate to receive screen with TCP mode for app-to-app transfer
            if (mounted) {
              final code = _ipToCode(request.ipAddress, port: request.port);

              Navigator.push(
                context,
                MaterialPageRoute(
                  builder:
                      (context) => AndroidReceiveScreen(
                        autoConnectCode: code,
                        useTcp:
                            true, // Always use TCP for app-to-app transfers when accepting dialog
                      ),
                ),
              );
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
    print('📱 Device tapped: ${device.deviceName}');

    // ─── Wi-Fi Direct Device Handling ──────────────────────
    if (device.discoveryMethod == DiscoveryMethod.wifiDirect &&
        device.wifiDirectAddress != null) {
      print('🔗 Wi-Fi Direct device detected - establishing connection...');

      _showStatus(
        message: 'Connecting to ${device.deviceName}...',
        subtitle: 'Establishing Wi-Fi Direct connection',
        icon: Icons.wifi_tethering_rounded,
      );

      // Connect to the Wi-Fi Direct peer - let Android negotiate group owner
      final connected = await _wifiDirectService.connectToPeer(
        device.wifiDirectAddress!,
        isGroupOwner:
            false, // Auto-negotiate group owner based on device capabilities
      );

      if (!connected) {
        print('❌ Failed to initiate Wi-Fi Direct connection');
        _showStatus(
          message: 'Connection Failed',
          subtitle: 'Could not connect to ${device.deviceName}',
          icon: Icons.error_outline,
          isError: true,
          autoDismiss: const Duration(seconds: 3),
        );
        // Restart peer discovery after failed connection
        _wifiDirectService.startPeerDiscovery();
        return;
      }

      print('⏳ Waiting for Wi-Fi Direct group formation...');

      // Wait for group formation and get connection info
      bool groupFormed = false;
      String? peerIp;
      bool? isGroupOwner;

      // Listen for connection info with timeout
      final connectionSubscription = _wifiDirectService.connectionInfoStream.listen((
        info,
      ) {
        if (info.groupFormed) {
          groupFormed = true;
          isGroupOwner = info.isGroupOwner;

          // CRITICAL: groupOwnerAddress is the GO's IP, not necessarily the peer's IP
          // If this device is GO, peer is at a client IP (need to get from group info)
          // If peer is GO, peer is at groupOwnerAddress
          if (info.isGroupOwner) {
            // This device is group owner at 192.168.49.1
            // Peer will be a client with IP like 192.168.49.x
            // We need to wait for the peer to connect and get their IP from HTTP request
            print(
              '📡 This device is Group Owner. Waiting for peer to connect...',
            );
            peerIp =
                null; // Will be determined when peer connects to our server
          } else {
            // Peer is group owner, use their address
            peerIp = info.groupOwnerAddress;
            print('📡 Peer is Group Owner at: $peerIp');
          }

          print('✅ Wi-Fi Direct group formed!');
          print(
            '   Group Owner: ${info.isGroupOwner ? "This device" : "Peer device"} ',
          );
          print('   Group Owner IP: ${info.groupOwnerAddress}');
          print('ℹ️ Group owner role negotiated automatically by WiFi Direct');
        }
      });

      // Wait up to 30 seconds for group formation (increased timeout for reliability)
      int attempts = 0;
      while (!groupFormed && attempts < 60) {
        await Future.delayed(const Duration(milliseconds: 500));
        attempts++;

        if (attempts % 4 == 0) {
          print('⏳ Still waiting for group formation... (${attempts ~/ 2}s)');

          // Update status every 5 seconds
          if (attempts % 10 == 0) {
            _showStatus(
              message: 'Connecting...',
              subtitle: 'Establishing WiFi Direct link (${attempts ~/ 2}s)',
              icon: Icons.wifi_tethering_rounded,
            );
          }
        }
      }

      await connectionSubscription.cancel();

      if (!groupFormed) {
        print('❌ Wi-Fi Direct group formation timed out');

        // Show retry dialog
        final retry = await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder:
              (context) => AlertDialog(
                backgroundColor: const Color(0xFF1C1C1E),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                ),
                title: Row(
                  children: [
                    Icon(Icons.wifi_off, color: Colors.red[400], size: 28),
                    const SizedBox(width: 12),
                    Text(
                      'Connection Failed',
                      style: GoogleFonts.outfit(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Could not establish WiFi Direct connection with ${device.deviceName}.',
                      style: GoogleFonts.outfit(
                        color: Colors.white70,
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Tips:',
                      style: GoogleFonts.outfit(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    _buildTipRow('Make sure WiFi is enabled on both devices'),
                    _buildTipRow('Try moving devices closer together'),
                    _buildTipRow('Ensure location permission is granted'),
                  ],
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: Text(
                      'Cancel',
                      style: GoogleFonts.outfit(color: Colors.white54),
                    ),
                  ),
                  ElevatedButton(
                    onPressed: () => Navigator.pop(context, true),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.yellow[300],
                      foregroundColor: Colors.black,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: Text(
                      'Retry',
                      style: GoogleFonts.outfit(fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
        );

        // Restart peer discovery after failed/timed-out connection
        _wifiDirectService.startPeerDiscovery();

        if (retry == true) {
          // Retry connection
          print('🔄 Retrying WiFi Direct connection...');
          return await _sendConnectionRequest(device);
        } else {
          _hideStatus();
          return;
        }
      }

      print('🎉 Wi-Fi Direct connection established!');

      // If this device is the group owner (rare with groupOwnerIntent=0), handle it
      if (isGroupOwner == true) {
        print('📡 This device is Group Owner (unexpected with intent=0)');
        _localIp = '192.168.49.1'; // Standard WiFi Direct GO IP
        print('   Local IP updated to: $_localIp');

        // Restart HTTP/TCP servers so they're reachable on the WiFi Direct interface
        await _stopServer();
        await _startListening();

        // As GO, the peer (client) gets IP via DHCP starting at 192.168.49.2
        // Try to reach the peer's HTTP server at the default client IP
        peerIp = '192.168.49.2';
        print('📡 Trying default client IP: $peerIp');
      }

      _showStatus(
        message: 'Connected via Wi-Fi Direct!',
        subtitle: 'Ready to share files',
        icon: Icons.check_circle_rounded,
        isSuccess: true,
        autoDismiss: const Duration(seconds: 2),
      );

      // Update device with peer's IP for connection
      if (peerIp != null && peerIp!.isNotEmpty) {
        device = DiscoveredDevice(
          deviceId: device.deviceId,
          deviceName: device.deviceName,
          ipAddress: peerIp!,
          port: device.port,
          platform: device.platform,
          lastSeen: DateTime.now(),
          discoveryMethod: DiscoveryMethod.wifiDirect,
          wifiDirectAddress: device.wifiDirectAddress,
          avatarUrl: device.avatarUrl,
          userName: device.userName,
        );

        print(
          '📡 Updated device IP to WiFi Direct address: ${device.ipAddress}',
        );
      } else {
        print('⚠️ Peer IP not available');
        _showStatus(
          message: 'Connection Error',
          subtitle: 'Could not determine peer IP address',
          icon: Icons.error_outline,
          isError: true,
          autoDismiss: const Duration(seconds: 3),
        );
        return;
      }
    }

    // ─── File Selection Check ──────────────────────────────
    // ALWAYS require files to be selected first (consistent with HTTP flow)

    if (_fileUris.isEmpty) {
      print('⚠️ No files selected');
      _showModernToast(
        message: 'Please select files first before sending',
        icon: Icons.folder_open_rounded,
        iconColor: const Color(0xFFFFD600),
      );
      return;
    }

    // ─── HTTP/UDP Device Handling (existing flow) ──────────
    setState(() {
      _pendingRequestDeviceIp = device.ipAddress;
      _pendingDevice = device;
    });

    // Start HTTP server immediately (needed for both HTTP and UDP flows)
    print('🚀 Starting HTTP server...');
    await _startSharingSession();

    // Show modern loading dialog for connection request
    _showModernLoadingDialog(
      title: 'Sending Request',
      subtitle: 'Asking ${device.deviceName} to accept connection...',
      step: 'REQUESTING',
      icon: Icons.send_rounded,
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
      // Dismiss loading dialog with success animation
      await _dismissLoadingDialog(showSuccess: true);

      _showModernToast(
        message: 'Connection established! Ready to share.',
        icon: Icons.check_circle_rounded,
        iconColor: Colors.green[400]!,
      );
      return;
    }

    // Fallback to UDP if HTTP fails (legacy support or firewall issue)
    print('⚠️ HTTP Handshake failed, falling back to UDP request...');

    // Update loading dialog for UDP fallback
    _updateLoadingDialog(
      title: 'Sending via UDP',
      subtitle: 'Trying alternative connection method...',
      step: 'FALLBACK',
      icon: Icons.sync_alt_rounded,
    );

    // Send connection request (UDP)
    print(
      '📤 Sending connection request to ${device.deviceName} (${device.ipAddress})',
    );
    await _discoveryService.sendConnectionRequest(
      device.ipAddress,
      _fileNames,
      totalSize,
      _port,
    );

    print('✅ Connection request sent successfully (UDP)');

    // Update dialog to show waiting state
    _updateLoadingDialog(
      title: 'Waiting for Response',
      subtitle: 'Waiting for ${device.deviceName} to accept...',
      step: 'WAITING',
      icon: Icons.hourglass_top_rounded,
    );

    // Start 10-second timeout timer - will show retry dialog
    _requestTimeoutTimer?.cancel();
    _requestTimeoutTimer = Timer(Duration(seconds: 10), () {
      if (mounted && _pendingRequestDeviceIp != null) {
        print('⏰ Connection request timeout - no response after 10 seconds');
        // Dismiss loading dialog first
        _dismissLoadingDialog();
        // Then show retry dialog
        _showRetryDialog();
      }
    });
  }

  // ────────────────────────────────────────────────
  //  Helper methods
  // ────────────────────────────────────────────────

  Widget _buildTipRow(String tip) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            margin: const EdgeInsets.only(top: 6),
            width: 4,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.yellow[300],
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              tip,
              style: GoogleFonts.outfit(color: Colors.white60, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  // ────────────────────────────────────────────────
  //  BLE / EasyShare send flow
  // ────────────────────────────────────────────────

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
    // Start the HTTP server session
    await _startSharingSession();

    print('✅ Server started successfully');
  }

  Future<void> _showQrDialog() async {
    if (_localIp == null) return;

    final scheme = _useHttps ? 'https' : 'http';
    final url = '$scheme://$_localIp:$_port';

    try {
      // Set high brightness
      try {
        await ScreenBrightness().setScreenBrightness(1.0);
      } catch (e) {
        print('Error setting brightness: $e');
      }

      if (!mounted) return;

      await showDialog(
        context: context,
        barrierColor: Colors.black.withOpacity(0.9),
        builder:
            (context) => Dialog(
              backgroundColor: Colors.transparent,
              child: Container(
                constraints: const BoxConstraints(maxWidth: 380),
                decoration: BoxDecoration(
                  color: Colors.black,
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(
                    color: const Color(0xFFFFD600).withOpacity(0.3),
                    width: 1,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFFFFD600).withOpacity(0.2),
                      blurRadius: 30,
                      offset: const Offset(0, 15),
                    ),
                  ],
                ),
                child: Padding(
                  padding: const EdgeInsets.all(28),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Title
                      Text(
                        'Scan to Connect',
                        style: GoogleFonts.outfit(
                          color: const Color(0xFFFFD600),
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.5,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Point your camera at this code',
                        style: GoogleFonts.outfit(
                          color: Colors.grey[600],
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 28),

                      // QR Code - Yellow background with black code
                      Container(
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFFD600),
                          borderRadius: BorderRadius.circular(16),
                          boxShadow: [
                            BoxShadow(
                              color: const Color(0xFFFFD600).withOpacity(0.3),
                              blurRadius: 25,
                              offset: const Offset(0, 10),
                            ),
                          ],
                        ),
                        child: QrImageView(
                          data: url,
                          version: QrVersions.auto,
                          size: 200.0,
                          backgroundColor: const Color(0xFFFFD600),
                          eyeStyle: const QrEyeStyle(
                            eyeShape: QrEyeShape.square,
                            color: Colors.black,
                          ),
                          dataModuleStyle: const QrDataModuleStyle(
                            dataModuleShape: QrDataModuleShape.square,
                            color: Colors.black,
                          ),
                        ),
                      ),
                      const SizedBox(height: 20),

                      // URL
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.05),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: const Color(0xFFFFD600).withOpacity(0.2),
                          ),
                        ),
                        child: Text(
                          url,
                          style: GoogleFonts.jetBrainsMono(
                            color: const Color(0xFFFFD600),
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ),
                      const SizedBox(height: 24),

                      // Close button
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          onPressed: () {
                            HapticFeedback.lightImpact();
                            Navigator.pop(context);
                          },
                          style: ElevatedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            backgroundColor: const Color(0xFFFFD600),
                            foregroundColor: Colors.black,
                            elevation: 0,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          child: Text(
                            'Close',
                            style: GoogleFonts.outfit(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
      );

      // Restore brightness
      try {
        await ScreenBrightness().resetScreenBrightness();
      } catch (e) {
        print('Error restoring brightness: $e');
      }
    } catch (e) {
      print('Error showing QR dialog: $e');
    }
  }

  // Duplicate initState removed from here.

  // ... (existing code) ...

  @override
  void dispose() {
    _server?.close(force: true);
    // Clean up Wi-Fi Direct group
    _wifiDirectService.removeGroup();
    _pageController.dispose();
    _discoveryBloc.close(); // Close the bloc
    // _devicesSubscription?.cancel(); // Removed
    _connectionRequestSubscription?.cancel();
    _connectionResponseSubscription?.cancel();
    _peersSubscription?.cancel();
    _groupInfoSubscription?.cancel();
    _requestTimeoutTimer?.cancel();
    _wifiDirectDiscoveryTimer?.cancel();
    _statusDismissTimer?.cancel(); // Cancel status timer

    // Don't stop the singleton discovery service - it runs globally
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Get screen dimensions to force layout consistency during Hero transition
    final size = MediaQuery.of(context).size;
    final isCompact = size.width < 600;
    final isLandscape = size.width > size.height;

    if (isLandscape) {
      return Scaffold(
        backgroundColor: const Color(0xFFF5C400),
        body: Hero(
          tag: 'send_card_container',
          child: Material(
            type: MaterialType.transparency,
            child: Container(
              width: size.width,
              height: size.height,
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xFFFFD84D), Color(0xFFF5C400)],
                ),
              ),
              child: SafeArea(
                child: Row(
                  children: [
                    // Left side: Pulse and Header
                    Expanded(
                      flex: 5,
                      child: Stack(
                        children: [
                          _buildDiscoveryBackground(),
                          Positioned(
                            top: 0,
                            left: 0,
                            right: 0,
                            child: _buildHeader(),
                          ),
                        ],
                      ),
                    ),
                    // Right side: Static Panel (replaces Bottom Sheet)
                    Expanded(
                      flex: 4,
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.black,
                          border: Border(
                            left: BorderSide(
                              color: Colors.white.withOpacity(0.1),
                            ),
                          ),
                        ),
                        child: _buildSidePanel(isCompact),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    // Portrait Mode (Existing Layout)
    return Scaffold(
      backgroundColor: const Color(0xFFF5C400),
      resizeToAvoidBottomInset: false,
      body: Hero(
        tag: 'send_card_container',
        createRectTween: (begin, end) {
          return MaterialRectCenterArcTween(begin: begin, end: end);
        },
        child: Material(
          type: MaterialType.transparency,
          child: Container(
            width: size.width,
            height: size.height,
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFFFFD84D), Color(0xFFF5C400)],
              ),
            ),
            child: OverflowBox(
              minWidth: size.width,
              maxWidth: size.width,
              minHeight: size.height,
              maxHeight: size.height,
              alignment: Alignment.center,
              child: Stack(
                children: [
                  // Pulse Background
                  KeyedSubtree(
                    key: ValueKey('discovery_pulse'),
                    child: _buildDiscoveryBackground(),
                  ),

                  // Header
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: SafeArea(child: _buildHeader()),
                  ),

                  // Bottom Sheet
                  _buildBottomSheet(isCompact),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSidePanel(bool isCompact) {
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              'Files',
              style: GoogleFonts.outfit(
                color: Colors.white,
                fontSize: 24,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
        // Action Buttons Row
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 24),
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
                          : (_isSharing ? _stopServer : _startSharingSession),
                  color:
                      _fileUris.isEmpty
                          ? Colors.grey[900]!
                          : (_isSharing
                              ? Colors.red[600]!
                              : const Color(0xFFFFD600)),
                  textColor:
                      _fileUris.isEmpty
                          ? Colors.grey[600]!
                          : (_isSharing ? Colors.white : Colors.black),
                  label: _isSharing ? 'Stop' : 'Send',
                  isPrimary: !_isSharing && _fileUris.isNotEmpty,
                ),
              ],
            ),
          ),
        ),

        SliverToBoxAdapter(child: SizedBox(height: 24)),

        SliverToBoxAdapter(
          child: Divider(color: Colors.white.withOpacity(0.05)),
        ),

        // Files List Header
        if (_fileNames.isNotEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 24, vertical: 16),
              child: _buildFileListHeader(),
            ),
          ),

        // Scrollable Files List Section
        if (_fileNames.isNotEmpty)
          SliverToBoxAdapter(child: _buildFileList(isCompact))
        else
          SliverFillRemaining(
            hasScrollBody: false,
            child: Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text(
                  'No files selected\nSwipe up or tap buttons to add',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.outfit(
                    color: Colors.grey[500],
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                    height: 1.5,
                  ),
                ),
              ),
            ),
          ),

        SliverToBoxAdapter(child: SizedBox(height: 20)),
      ],
    );
  }

  Widget _buildDiscoveryBackground() {
    return BlocBuilder<DiscoveryBloc, DiscoveryState>(
      bloc: _discoveryBloc, // Explicitly pass the bloc instance
      builder: (context, state) {
        List<DiscoveredDevice> nearbyDevices = [];
        if (state is DiscoveryLoaded) {
          nearbyDevices = state.devices;

          // Update device name mapping (side effect in builder is not ideal, but acceptable here for local cache)
          // Better to do this in BlocListener but this is a quick refactor
          for (var device in nearbyDevices) {
            _clientDeviceNames[device.ipAddress] = device.deviceName;
          }

          // Auto-connect logic removed - no longer using WiFi Direct
        }

        // Combine all devices into a positioned list
        final List<Widget> deviceNodes = [];
        // Center offset not needed for centered stack approach

        // Convert Wi-Fi Direct peers to DiscoveredDevice format
        List<DiscoveredDevice> wifiDirectDevices =
            _wifiDirectPeers.map((peer) {
              return DiscoveredDevice(
                deviceId: peer.deviceAddress, // Use MAC address as device ID
                deviceName: peer.deviceName,
                ipAddress: '', // Will be filled after connection
                port: _port,
                platform: 'android', // Assume Android for Wi-Fi Direct
                lastSeen:
                    DateTime.now(), // Wi-Fi Direct devices are currently being discovered
                discoveryMethod:
                    DiscoveryMethod.wifiDirect, // Mark as Wi-Fi Direct device
                wifiDirectAddress: peer.deviceAddress, // Store MAC address
                avatarUrl: null,
                userName: null,
              );
            }).toList();

        // Merge UDP-discovered devices with Wi-Fi Direct peers
        // Remove duplicates based on device name to avoid showing same device twice
        final allDevices = <DiscoveredDevice>[
          ...nearbyDevices,
          ...wifiDirectDevices.where((wdDevice) {
            // Only add if not already in nearbyDevices
            return !nearbyDevices.any(
              (udpDevice) => udpDevice.deviceName == wdDevice.deviceName,
            );
          }),
        ];

        // Responsive sizing based on screen dimensions
        final screenWidth = MediaQuery.of(context).size.width;
        final screenHeight = MediaQuery.of(context).size.height;
        final safeAreaTop = MediaQuery.of(context).padding.top;

        // Scale pulse size based on screen width (works on all devices)
        final double pulseSize = (screenWidth * 0.95).clamp(320.0, 520.0);

        // Calculate header area (code display + header)
        final headerHeight =
            safeAreaTop + 210; // Header + code display + 10px buffer
        final initialBottomSheetHeight = screenHeight * 0.35; // Fixed at 35%
        final availableHeight =
            screenHeight - headerHeight - initialBottomSheetHeight;
        final pulseTop = headerHeight + (availableHeight - pulseSize) / 2;

        // Circular Layout Calculation - Position devices inside pulse
        final int totalCount = allDevices.length;

        // Limit visible devices to prevent overlap (max 8 in single ring)
        final int maxVisibleDevices = 8;
        final int visibleCount = totalCount.clamp(0, maxVisibleDevices);
        final int overflowCount = totalCount - visibleCount;

        // Scale device size based on count (smaller when more devices)
        final double deviceScale =
            totalCount <= 4 ? 1.0 : (totalCount <= 6 ? 0.9 : 0.8);

        // Device node size (base is 56px for demo, 60px for real - use 60 as max)
        final double deviceNodeSize = 60.0 * deviceScale;

        // Calculate orbit radius so devices stay FULLY inside pulse
        // Orbit radius = pulse radius - half device size - generous padding
        final double pulseRadius = pulseSize / 2;
        final double orbitPadding = 24.0; // Generous padding from pulse edge
        final double orbitRadius =
            pulseRadius - (deviceNodeSize / 2) - orbitPadding;
        final double startAngle = -3.14159 / 2; // Start from top

        for (int i = 0; i < visibleCount; i++) {
          final double angle = startAngle + (2 * 3.14159 * i / visibleCount);
          final double offsetX = orbitRadius * cos(angle);
          final double offsetY = orbitRadius * sin(angle);

          // All devices use the same node builder (test or real)
          deviceNodes.add(
            Transform.translate(
              offset: Offset(offsetX, offsetY),
              child: Transform.scale(
                scale: deviceScale,
                child: _buildDeviceNode(allDevices[i]),
              ),
            ),
          );
        }

        // Add overflow indicator if there are more devices - positioned at center
        if (overflowCount > 0) {
          deviceNodes.add(
            GestureDetector(
              onTap: () => _showAllDevicesSheet(allDevices, isDemoMode: false),
              child: Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.85),
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white38, width: 1.5),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.3),
                      blurRadius: 8,
                      spreadRadius: 1,
                    ),
                  ],
                ),
                child: Center(
                  child: Text(
                    '+$overflowCount',
                    style: GoogleFonts.outfit(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.5,
                    ),
                  ),
                ),
              ),
            ),
          );
        }

        return Stack(
          alignment: Alignment.center,
          children: [
            // Pulse Effect - Responsive size
            Positioned(
              top: pulseTop,
              left: 0,
              right: 0,
              child: Center(
                child: SizedBox(
                  width: pulseSize,
                  height: pulseSize,
                  child: _PulseEffect(
                    key: const ValueKey('pulse_effect_stable'),
                    size: pulseSize,
                    color: Colors.black.withOpacity(0.12),
                  ),
                ),
              ),
            ),

            // Centered Devices "Orbit" - same size as pulse
            Positioned(
              top: pulseTop,
              left: 0,
              right: 0,
              child: Center(
                child: SizedBox(
                  width: pulseSize,
                  height: pulseSize,
                  child: Stack(
                    alignment: Alignment.center,
                    children: deviceNodes,
                  ),
                ),
              ),
            ),

            // Status label below pulse
            Positioned(
              top: pulseTop + pulseSize + 12,
              left: 0,
              right: 0,
              child: Center(
                child: _buildDiscoveryStatusLabel(state, allDevices.length),
              ),
            ),
          ],
        );
      },
    );
  }

  // Small status label below pulse
  Widget _buildDiscoveryStatusLabel(DiscoveryState state, int deviceCount) {
    String text;
    IconData icon;
    bool isLoading = false;
    bool isSuccess = false;
    bool isError = false;

    // Priority: Connection status > Discovery status
    if (_statusMessage != null) {
      text = _statusMessage!;
      icon = _statusIcon;
      isLoading = !_statusIsSuccess && !_statusIsError;
      isSuccess = _statusIsSuccess;
      isError = _statusIsError;
    } else if (state is DiscoveryInitial) {
      text = 'Scanning...';
      icon = Icons.radar_rounded;
      isLoading = true;
    } else if (deviceCount > 0) {
      text = '$deviceCount device${deviceCount > 1 ? 's' : ''} nearby';
      icon = Icons.check_circle_outline_rounded;
    } else {
      text = 'No devices nearby';
      icon = Icons.device_unknown_rounded;
    }

    Color bgColor = Colors.black.withOpacity(0.6);
    Color contentColor = Colors.white70;

    if (isSuccess) {
      bgColor = const Color(0xFF1B5E20).withOpacity(0.9);
      contentColor = Colors.white;
    } else if (isError) {
      bgColor = const Color(0xFFB71C1C).withOpacity(0.9);
      contentColor = Colors.white;
    }

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isLoading)
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 1.5,
                valueColor: AlwaysStoppedAnimation<Color>(contentColor),
              ),
            )
          else
            Icon(icon, color: contentColor, size: 14),
          const SizedBox(width: 6),
          Text(
            text,
            style: GoogleFonts.outfit(
              color: contentColor,
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  IconData _getDeviceIcon(String name, {String? platform}) {
    // Use platform field if available
    if (platform != null) {
      final p = platform.toLowerCase();
      if (p.contains('ios') || p.contains('iphone') || p.contains('ipad')) {
        return Icons.phone_iphone_rounded;
      } else if (p.contains('mac')) {
        return Icons.laptop_mac_rounded;
      } else if (p.contains('android')) {
        return Icons.phone_android_rounded;
      } else if (p.contains('windows') || p.contains('pc')) {
        return Icons.desktop_windows_rounded;
      }
    }

    // Fall back to name-based detection
    name = name.toLowerCase();
    if (name.contains('iphone') ||
        name.contains('ipad') ||
        name.contains('ios')) {
      return Icons.phone_iphone_rounded;
    } else if (name.contains('mac') || name.contains('apple')) {
      return Icons.laptop_mac_rounded;
    } else if (name.contains('windows') ||
        name.contains('pc') ||
        name.contains('desktop')) {
      return Icons.desktop_windows_rounded;
    } else if (name.contains('android') ||
        name.contains('phone') ||
        name.contains('pixel') ||
        name.contains('samsung')) {
      return Icons.phone_android_rounded;
    }
    return Icons.devices_other_rounded;
  }

  // Show all devices in a searchable bottom sheet
  void _showAllDevicesSheet(
    List<DiscoveredDevice> devices, {
    bool isDemoMode = false,
  }) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder:
          (context) => _AllDevicesSheet(
            devices: devices,
            isDemoMode: isDemoMode,
            getDeviceIcon: _getDeviceIcon,
            onDeviceTap: (device) {
              Navigator.pop(context);
              if (!isDemoMode) {
                _sendConnectionRequest(device);
              }
            },
          ),
    );
  }

  Widget _buildDeviceNode(DiscoveredDevice device) {
    // All devices are DiscoveredDevice type now (no more WiFiDirectPeer)
    String name = device.deviceName;
    String? platform = device.platform;
    String? avatarUrl = device.avatarUrl;
    String? userName = device.userName;

    // Use user name if available, otherwise device name
    String displayName = userName ?? name;

    // Check if connecting/pending
    bool isPending = _pendingRequestDeviceIp == device.ipAddress;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () {
          _sendConnectionRequest(device);
        },
        child: Padding(
          padding: const EdgeInsets.all(8.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 60,
                height: 60,
                decoration: BoxDecoration(
                  color: const Color(0xFF1C1C1E),
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.15),
                      blurRadius: 8,
                      offset: Offset(0, 4),
                    ),
                    if (isPending)
                      BoxShadow(
                        color: Colors.white.withOpacity(0.5),
                        blurRadius: 12,
                        spreadRadius: 1,
                      ),
                  ],
                  border: Border.all(
                    color: Colors.white.withOpacity(0.15),
                    width: 1.5,
                  ),
                ),
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    if (avatarUrl != null)
                      Builder(
                        builder: (context) {
                          bool isUrl =
                              avatarUrl.startsWith('http') ||
                              avatarUrl.startsWith('https');
                          // Check if it's a predefined avatar ID
                          bool isCustomAvatar = CustomAvatarWidget.avatars.any(
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
                                      _getDeviceIcon(name, platform: platform),
                                      color: Colors.white,
                                      size: 28,
                                    ),
                              ),
                            );
                          } else if (isCustomAvatar) {
                            return CustomAvatarWidget(
                              avatarId: avatarUrl,
                              size: 60,
                              useBackground: true,
                            );
                          } else {
                            // Fallback for raw emojis or text
                            return Center(
                              child: Text(
                                avatarUrl,
                                style: const TextStyle(
                                  fontSize: 28,
                                  color: Colors.white,
                                ),
                              ),
                            );
                          }
                        },
                      )
                    else
                      Icon(
                        _getDeviceIcon(name, platform: platform),
                        color: Colors.white,
                        size: 28,
                      ),
                    if (isPending)
                      CircularProgressIndicator(
                        color: Colors.white,
                        strokeWidth: 1.5,
                      ),
                  ],
                ),
              ),
              SizedBox(height: 6),
              Container(
                padding: EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.6),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  displayName.length > 12
                      ? '${displayName.substring(0, 10)}...'
                      : displayName,
                  style: GoogleFonts.outfit(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // Helper method to get platform icon
  IconData _getPlatformIcon(String platform) {
    switch (platform.toLowerCase()) {
      case 'android':
        return Icons.phone_android;
      case 'windows':
        return Icons.desktop_windows;
      case 'ios':
        return Icons.phone_iphone;
      case 'macos':
        return Icons.laptop_mac;
      case 'linux':
        return Icons.computer;
      default:
        return Icons.devices;
    }
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              IconButton(
                icon: Icon(
                  Icons.arrow_back_ios_rounded,
                  color: Colors.black,
                  size: 22,
                ),
                onPressed: () => Navigator.pop(context),
              ),
              Expanded(
                child: Text(
                  'Share Files',
                  style: GoogleFonts.outfit(
                    color: Colors.black,
                    fontSize: 24,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.5,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
              // Only refresh button on the right
              IconButton(
                icon: Icon(
                  Icons.refresh_rounded,
                  color: Colors.black,
                  size: 24,
                ),
                onPressed: _refreshIp,
              ),
            ],
          ),
          AnimatedSize(
            duration: Duration(milliseconds: 400),
            curve: Curves.easeOut,
            child: AnimatedSwitcher(
              duration: Duration(milliseconds: 400),
              switchInCurve: Curves.easeOut,
              switchOutCurve: Curves.easeIn,
              transitionBuilder:
                  (child, animation) => SlideTransition(
                    position: Tween<Offset>(
                      begin: Offset(0, -0.1),
                      end: Offset.zero,
                    ).animate(animation),
                    child: child,
                  ),
              child:
                  _localIp == null
                      ? Padding(
                        key: ValueKey('loading'),
                        padding: const EdgeInsets.only(top: 16.0),
                        child: SizedBox(
                          height: 48,
                          child: Center(
                            child: SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                valueColor: AlwaysStoppedAnimation<Color>(
                                  Colors.black.withOpacity(0.3),
                                ),
                              ),
                            ),
                          ),
                        ),
                      )
                      : Padding(
                        key: ValueKey('code'),
                        padding: const EdgeInsets.only(top: 16.0),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // Code display with QR button beside it
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                GestureDetector(
                                  onTap: () {
                                    Clipboard.setData(
                                      ClipboardData(
                                        text: _ipToCode(_localIp!, port: _port),
                                      ),
                                    );
                                    HapticFeedback.lightImpact();
                                    _showModernToast(
                                      message: 'Code copied to clipboard',
                                      icon: Icons.copy_rounded,
                                      iconColor: const Color(0xFFFFD600),
                                    );
                                  },
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 16,
                                      vertical: 10,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Colors.black,
                                      borderRadius: BorderRadius.circular(30),
                                      boxShadow: [
                                        BoxShadow(
                                          color: Colors.black.withOpacity(0.2),
                                          blurRadius: 10,
                                          offset: Offset(0, 4),
                                        ),
                                      ],
                                      border: Border.all(
                                        color: Colors.white.withOpacity(0.1),
                                      ),
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(
                                          'Code: ${_ipToCode(_localIp!, port: _port)}',
                                          style: GoogleFonts.outfit(
                                            color: Colors.white,
                                            fontSize: 16,
                                            fontWeight: FontWeight.w700,
                                            letterSpacing: 1.0,
                                          ),
                                        ),
                                        SizedBox(width: 8),
                                        Icon(
                                          Icons.copy_rounded,
                                          color: Colors.white.withOpacity(0.7),
                                          size: 16,
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                                SizedBox(width: 12),
                                // QR Code button in circle
                                Container(
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: Colors.black,
                                    boxShadow: [
                                      BoxShadow(
                                        color: Colors.black.withOpacity(0.2),
                                        blurRadius: 10,
                                        offset: Offset(0, 4),
                                      ),
                                    ],
                                    border: Border.all(
                                      color: Colors.white.withOpacity(0.1),
                                    ),
                                  ),
                                  child: IconButton(
                                    icon: Icon(
                                      Icons.qr_code_rounded,
                                      color: Colors.white,
                                      size: 24,
                                    ),
                                    onPressed: _showQrDialog,
                                    padding: EdgeInsets.all(12),
                                    constraints: BoxConstraints(),
                                  ),
                                ),
                              ],
                            ),
                            // Port information with settings button
                            Padding(
                              padding: const EdgeInsets.only(top: 12.0),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    'Port: $_port',
                                    style: GoogleFonts.outfit(
                                      color: Colors.black.withOpacity(0.5),
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  if (!_isSharing) ...[
                                    const SizedBox(width: 8),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 10,
                                        vertical: 4,
                                      ),
                                      decoration: BoxDecoration(
                                        color: Colors.black.withOpacity(0.05),
                                        borderRadius: BorderRadius.circular(8),
                                        border: Border.all(
                                          color: Colors.black.withOpacity(0.1),
                                        ),
                                      ),
                                      child: InkWell(
                                        onTap: _showPortDialog,
                                        borderRadius: BorderRadius.circular(8),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(
                                              Icons.settings_rounded,
                                              size: 14,
                                              color: Colors.black.withOpacity(
                                                0.5,
                                              ),
                                            ),
                                            const SizedBox(width: 4),
                                            Text(
                                              'Change',
                                              style: GoogleFonts.outfit(
                                                color: Colors.black.withOpacity(
                                                  0.5,
                                                ),
                                                fontSize: 14,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBottomSheet(bool isCompact) {
    return DraggableScrollableSheet(
      initialChildSize: 0.25,
      minChildSize: 0.25,
      maxChildSize: 0.85,
      snap: true,
      snapSizes: [0.25, 0.35, 0.85],
      builder: (context, scrollController) {
        return Container(
          decoration: BoxDecoration(
            color: Colors.black,
            borderRadius: BorderRadius.vertical(top: Radius.circular(32)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.5),
                blurRadius: 20,
                offset: Offset(0, -5),
              ),
            ],
          ),
          child: CustomScrollView(
            controller: scrollController,
            slivers: [
              // Handle
              SliverToBoxAdapter(
                child: Center(
                  child: Container(
                    margin: EdgeInsets.only(top: 12, bottom: 20),
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.grey[600],
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ),

              // Action Buttons Row (Fixed - not scrollable)
              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: 24),
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
                                : (_isSharing
                                    ? _stopServer
                                    : _startSharingSession),
                        color:
                            _fileUris.isEmpty
                                ? Colors.grey[900]!
                                : (_isSharing
                                    ? Colors.red[600]!
                                    : const Color(0xFFFFD600)),
                        textColor:
                            _fileUris.isEmpty
                                ? Colors.grey[600]!
                                : (_isSharing ? Colors.white : Colors.black),
                        label: _isSharing ? 'Stop' : 'Send',
                        isPrimary: !_isSharing && _fileUris.isNotEmpty,
                      ),
                    ],
                  ),
                ),
              ),

              SliverToBoxAdapter(child: SizedBox(height: 24)),

              SliverToBoxAdapter(
                child: Divider(color: Colors.white.withOpacity(0.05)),
              ),

              // Files List Header (Fixed - not scrollable)
              if (_fileNames.isNotEmpty)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                    child: _buildFileListHeader(),
                  ),
                ),

              // Scrollable Files List Section
              if (_fileNames.isNotEmpty)
                SliverToBoxAdapter(child: _buildFileList(isCompact))
              else
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(
                    child: Padding(
                      padding: EdgeInsets.all(32),
                      child: Text(
                        'No files selected\nSwipe up or tap buttons to add',
                        textAlign: TextAlign.center,
                        style: GoogleFonts.outfit(
                          color: Colors.grey[500],
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                          height: 1.5,
                        ),
                      ),
                    ),
                  ),
                ),

              SliverToBoxAdapter(child: SizedBox(height: 20)),
            ],
          ),
        );
      },
    );
  }

  // WiFi Direct peer list methods removed - no longer using WiFi Direct

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
    return BlocBuilder<DiscoveryBloc, DiscoveryState>(
      builder: (context, state) {
        final devices =
            state is DiscoveryLoaded ? state.devices : <DiscoveredDevice>[];

        return SizedBox(
          height: 85,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            itemCount: devices.length,
            itemBuilder: (context, index) {
              return _buildCircularDeviceItem(devices[index]);
            },
          ),
        );
      },
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
                  // Debug: Log avatar info
                  Builder(
                    builder: (context) {
                      print(
                        '🎨 Device ${device.deviceName}: avatarUrl=${device.avatarUrl}',
                      );
                      return SizedBox.shrink();
                    },
                  ),
                  // Platform icon
                  // Platform icon
                  if (device.avatarUrl != null)
                    device.avatarUrl!.startsWith('http')
                        ? ClipOval(
                          child: Image.network(
                            device.avatarUrl!,
                            width: 30,
                            height: 30,
                            fit: BoxFit.cover,
                            errorBuilder:
                                (_, __, ___) => Icon(
                                  _getPlatformIcon(device.platform),
                                  color:
                                      isPending
                                          ? Colors.black87
                                          : Colors.white70,
                                  size: 24,
                                ),
                          ),
                        )
                        : CustomAvatarWidget(
                          avatarId: device.avatarUrl!,
                          size: 30,
                          useBackground: false,
                        )
                  else
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
                fontSize: 13,
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
                    child: () {
                      print(
                        '🎨 [Dialog] Device ${device.deviceName}: avatarUrl=${device.avatarUrl}',
                      );
                      return device.avatarUrl != null
                          ? (device.avatarUrl!.startsWith('http')
                              ? ClipOval(
                                child: Image.network(
                                  device.avatarUrl!,
                                  width: 80,
                                  height: 80,
                                  fit: BoxFit.cover,
                                  errorBuilder:
                                      (_, __, ___) => Icon(
                                        _getPlatformIcon(device.platform),
                                        color: Colors.black87,
                                        size: 40,
                                      ),
                                ),
                              )
                              : CustomAvatarWidget(
                                avatarId: device.avatarUrl!,
                                size: 50,
                                useBackground: false,
                              ))
                          : Icon(
                            _getPlatformIcon(device.platform),
                            color: Colors.black87,
                            size: 40,
                          );
                    }(),
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

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: isPending ? null : () => _sendConnectionRequest(device),
        borderRadius: BorderRadius.circular(16),
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
                    if (device.avatarUrl != null)
                      device.avatarUrl!.startsWith('http')
                          ? ClipRRect(
                            borderRadius: BorderRadius.circular(14),
                            child: Image.network(
                              device.avatarUrl!,
                              width: 56,
                              height: 56,
                              fit: BoxFit.cover,
                              errorBuilder:
                                  (_, __, ___) => Icon(
                                    _getPlatformIcon(device.platform),
                                    color:
                                        isPending
                                            ? Colors.yellow[300]
                                            : Colors.white,
                                    size: 30,
                                  ),
                            ),
                          )
                          : CustomAvatarWidget(
                            avatarId: device.avatarUrl!,
                            size: 40,
                            useBackground: false,
                          )
                    else
                      Icon(
                        _getPlatformIcon(device.platform),
                        color: isPending ? Colors.yellow[300] : Colors.white,
                        size: 30,
                      ),
                    if (isPending)
                      Positioned.fill(
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation(
                            Colors.yellow[300],
                          ),
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
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
              if (isPending) ...[
                SizedBox(height: 8),
                Text(
                  'Connecting...',
                  style: TextStyle(
                    color: Colors.yellow[300],
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ],
          ),
        ),
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
    // Create a sorted list of indices
    final sortedIndices = List<int>.generate(_fileNames.length, (i) => i);

    // Sort: sharing files first (progress > 0 && !completed), then pending, then completed
    sortedIndices.sort((a, b) {
      final aProgress = _progressList.length > a ? _progressList[a].value : 0.0;
      final bProgress = _progressList.length > b ? _progressList[b].value : 0.0;

      // Check if any client has completed
      bool aHasClientCompleted = false;
      bool bHasClientCompleted = false;

      for (final clientIP in _connectedClients) {
        if (_clientDownloads.containsKey(clientIP)) {
          if (_clientDownloads[clientIP]!.containsKey(a) &&
              _clientDownloads[clientIP]![a]!.isCompleted) {
            aHasClientCompleted = true;
          }
          if (_clientDownloads[clientIP]!.containsKey(b) &&
              _clientDownloads[clientIP]![b]!.isCompleted) {
            bHasClientCompleted = true;
          }
        }
      }

      // Priority: sharing (progress > 0) > pending > completed
      final aIsSharing = _isSharing && aProgress > 0 && !aHasClientCompleted;
      final bIsSharing = _isSharing && bProgress > 0 && !bHasClientCompleted;

      if (aIsSharing && !bIsSharing) return -1;
      if (!aIsSharing && bIsSharing) return 1;

      if (aHasClientCompleted && !bHasClientCompleted) return 1;
      if (!aHasClientCompleted && bHasClientCompleted) return -1;

      return 0; // Keep original order for same priority
    });

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 24),
      child: ListView.builder(
        shrinkWrap: true,
        physics: NeverScrollableScrollPhysics(),
        itemCount: _fileNames.length,
        itemBuilder: (context, i) {
          final index = sortedIndices[i];
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
              _completedFiles.length > index ? _completedFiles[index] : false;

          // Get client download statuses for this file
          final clientStatuses = <String, DownloadStatus>{};
          for (final clientIP in _connectedClients) {
            if (_clientDownloads.containsKey(clientIP) &&
                _clientDownloads[clientIP]!.containsKey(index)) {
              clientStatuses[clientIP] = _clientDownloads[clientIP]![index]!;
            }
          }

          final hasAnyClientCompleted = clientStatuses.values.any(
            (status) => status.isCompleted,
          );
          final completedClients =
              clientStatuses.values
                  .where((status) => status.isCompleted)
                  .toList();

          return _buildVerticalFileCard(
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

  // New vertical file card widget
  Widget _buildVerticalFileCard({
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
      child: Container(
        margin: EdgeInsets.only(bottom: 12),
        padding: EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.grey[900],
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color:
                _isSharing && progress.value > 0 && !hasAnyClientCompleted
                    ? Colors.yellow[300]!.withOpacity(0.3)
                    : Colors.grey[800]!,
            width: 1.5,
          ),
        ),
        child: Row(
          children: [
            // File Icon with Fill Progress Effect
            if (_isSharing && !hasAnyClientCompleted)
              ValueListenableBuilder<double>(
                valueListenable: progress,
                builder: (context, value, _) {
                  return SizedBox(
                    width: 50,
                    height: 50,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Stack(
                        children: [
                          // Background container
                          Container(
                            width: 50,
                            height: 50,
                            decoration: BoxDecoration(
                              color: Colors.grey[800],
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          // Fill from bottom progress
                          Align(
                            alignment: Alignment.bottomCenter,
                            child: Container(
                              width: 50,
                              height: 50 * value,
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.bottomCenter,
                                  end: Alignment.topCenter,
                                  colors: [
                                    Colors.yellow[400]!,
                                    Colors.yellow[300]!,
                                  ],
                                ),
                              ),
                            ),
                          ),
                          // File Icon on top
                          Center(
                            child: Icon(
                              _getFileIcon(fileName),
                              color: value > 0.5 ? Colors.black : Colors.white,
                              size: 28,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              )
            else
              // Static File Icon (not sharing or completed)
              Container(
                width: 50,
                height: 50,
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
                  size: 28,
                ),
              ),
            SizedBox(width: 16),

            // File Info
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    fileName,
                    style: GoogleFonts.outfit(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  SizedBox(height: 4),
                  Text(
                    formatBytes(fileSize),
                    style: GoogleFonts.outfit(
                      color: Colors.grey[400],
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  // Use isolated widget for per-client progress (avoids parent rebuilds)
                  if (_isSharing)
                    RepaintBoundary(
                      child: _ClientProgressSection(
                        clientDownloads: _clientDownloads,
                        fileIndex: index,
                        clientDeviceNames: _clientDeviceNames,
                        formatClientIP: _formatClientIP,
                        hasAnyClientCompleted: hasAnyClientCompleted,
                      ),
                    ),
                  if (hasAnyClientCompleted) ...[
                    SizedBox(height: 6),
                    Row(
                      children: [
                        Icon(
                          Icons.check_circle_rounded,
                          size: 14,
                          color: Colors.green[400],
                        ),
                        SizedBox(width: 4),
                        Text(
                          'Sent to ${completedClients.length} client${completedClients.length == 1 ? '' : 's'}',
                          style: GoogleFonts.outfit(
                            color: Colors.green[400],
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),

            // Action Button
            if (_isSharing && !hasAnyClientCompleted)
              ValueListenableBuilder<bool>(
                valueListenable: isPaused,
                builder: (context, paused, _) {
                  return IconButton(
                    icon: Icon(
                      paused ? Icons.play_arrow_rounded : Icons.pause_rounded,
                      color: Colors.yellow[300],
                      size: 28,
                    ),
                    onPressed: () => _togglePause(index),
                  );
                },
              ),
          ],
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
                          boxShadow: null,
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
                                fontSize: 12,
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
                            (context, value, _) => SizedBox(
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

  // Enhanced button for the share code copy functionality

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

  // Rectangular button with consistent corner radius
  Widget _buildRectangularButton({
    required IconData icon,
    required VoidCallback? onTap,
    required Color color,
    required Color textColor,
    required String label,
    bool isPrimary = false,
  }) {
    final isEnabled = onTap != null;
    // Use the passed isPrimary or infer it if color matches the yellow
    final bool primary = isPrimary || color == Colors.yellow[300];

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
                borderRadius: BorderRadius.circular(24),
                splashColor: Colors.white.withOpacity(0.2),
                highlightColor: Colors.white.withOpacity(0.1),
                child: Container(
                  width: 90,
                  height: 90, // Slightly taller
                  decoration: BoxDecoration(
                    gradient:
                        primary && isEnabled
                            ? const LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [
                                Color(0xFFFFD84D), // Yellow at top-left
                                Color(
                                  0xFFF5C400,
                                ), // Dark yellow at bottom-right
                              ],
                            )
                            : null,
                    color:
                        primary && isEnabled
                            ? null // Use gradient instead
                            : isEnabled
                            ? color
                            : Colors.grey[900],
                    borderRadius: BorderRadius.circular(24),
                    boxShadow:
                        primary && isEnabled
                            ? [
                              BoxShadow(
                                color: const Color(0xFFFFD600).withOpacity(0.4),
                                blurRadius: isPressed ? 10 : 20,
                                offset: Offset(0, isPressed ? 4 : 8),
                              ),
                            ]
                            : [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.3),
                                blurRadius: 4,
                                offset: Offset(0, 2),
                              ),
                            ],
                    border: Border.all(
                      color: Colors.white.withOpacity(0.05),
                      width: 1,
                    ),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        icon,
                        color:
                            isEnabled
                                ? (primary ? Colors.black : textColor)
                                : Colors.grey[600],
                        size: 26,
                      ),
                      SizedBox(height: 8),
                      Text(
                        label,
                        style: GoogleFonts.outfit(
                          color:
                              isEnabled
                                  ? (primary ? Colors.black : textColor)
                                  : Colors.grey[600],
                          fontSize: 13,
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

  IconData _getFileIcon(String fileName) {
    if (!fileName.contains('.')) return Icons.insert_drive_file_rounded;
    final ext = fileName.split('.').last.toLowerCase();
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

// Physics-based Pulse Effect - clean, modern expanding rings
class _PulseEffect extends StatefulWidget {
  final double size;
  final Color color;

  const _PulseEffect({super.key, this.size = 300, this.color = Colors.black});

  @override
  State<_PulseEffect> createState() => _PulseEffectState();
}

class _PulseEffectState extends State<_PulseEffect>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
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
    return RepaintBoundary(
      child: SizedBox(
        width: widget.size,
        height: widget.size,
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
    );
  }
}

// Minimal CustomPainter - all math inlined
class _PulsePainter extends CustomPainter {
  final double progress;
  final Color color;

  const _PulsePainter({required this.progress, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxRadius = size.width / 2;

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

      // Stroke: 2.5 → 0.5
      final stroke = 2.5 - eased * 2.0;

      if (opacity > 0.02) {
        canvas.drawCircle(
          center,
          radius,
          Paint()
            ..color = color.withOpacity(opacity)
            ..style = PaintingStyle.stroke
            ..strokeWidth = stroke,
        );
      }
    }

    // Center dot - small, neat, darker
    final breathe = (0.5 + 0.5 * sin(progress * 2 * 3.14159)).abs();
    final dotR =
        size.width * 0.02 * (0.95 + breathe * 0.2); // Smaller: 2% of size

    // Subtle glow
    canvas.drawCircle(
      center,
      dotR * 1.5,
      Paint()
        ..color = color.withOpacity(0.10)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
    );

    // Solid dot - darker
    canvas.drawCircle(center, dotR, Paint()..color = color.withOpacity(0.5));
  }

  @override
  bool shouldRepaint(_PulsePainter old) => old.progress != progress;
}

// Pulsing Search Indicator Widget
class _PulsingSearchIndicator extends StatefulWidget {
  const _PulsingSearchIndicator();

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

// Modern Toast Widget
class _ModernToast extends StatefulWidget {
  final String message;
  final IconData icon;
  final Color backgroundColor;
  final Color iconColor;
  final VoidCallback onDismiss;
  final Duration duration;

  const _ModernToast({
    required this.message,
    required this.icon,
    required this.backgroundColor,
    required this.iconColor,
    required this.onDismiss,
    required this.duration,
  });

  @override
  State<_ModernToast> createState() => _ModernToastState();
}

class _ModernToastState extends State<_ModernToast>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _fadeAnimation;
  late Animation<Offset> _slideAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: 300),
    );

    _fadeAnimation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOut));

    _slideAnimation = Tween<Offset>(
      begin: Offset(0, -0.5),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOut));

    _controller.forward();

    Future.delayed(widget.duration, () {
      if (mounted) {
        _controller.reverse().then((_) => widget.onDismiss());
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: MediaQuery.of(context).padding.top + 16,
      left: 24,
      right: 24,
      child: SlideTransition(
        position: _slideAnimation,
        child: FadeTransition(
          opacity: _fadeAnimation,
          child: Material(
            color: Colors.transparent,
            child: Container(
              padding: EdgeInsets.symmetric(horizontal: 20, vertical: 16),
              decoration: BoxDecoration(
                color: widget.backgroundColor,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: widget.iconColor.withOpacity(0.3),
                  width: 1,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.3),
                    blurRadius: 20,
                    offset: Offset(0, 8),
                  ),
                ],
              ),
              child: Row(
                children: [
                  Container(
                    padding: EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: widget.iconColor.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(widget.icon, color: widget.iconColor, size: 20),
                  ),
                  SizedBox(width: 14),
                  Expanded(
                    child: Text(
                      widget.message,
                      style: GoogleFonts.outfit(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// Modern Loading Dialog Widget
class _ModernLoadingDialog extends StatefulWidget {
  final String title;
  final String subtitle;
  final String? step;
  final IconData icon;

  const _ModernLoadingDialog({
    required this.title,
    required this.subtitle,
    this.step,
    required this.icon,
  });

  @override
  State<_ModernLoadingDialog> createState() => _ModernLoadingDialogState();
}

class _ModernLoadingDialogState extends State<_ModernLoadingDialog>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnimation;
  late Animation<double> _rotationAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: 1500),
    )..repeat();

    _scaleAnimation = Tween<double>(
      begin: 0.95,
      end: 1.05,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));

    _rotationAnimation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.linear));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      child: Container(
        padding: EdgeInsets.all(28),
        decoration: BoxDecoration(
          color: const Color(0xFF1C1C1E),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(
            color: const Color(0xFFFFD600).withOpacity(0.3),
            width: 1.5,
          ),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFFFFD600).withOpacity(0.1),
              blurRadius: 30,
              spreadRadius: 5,
            ),
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
            // Animated icon container
            AnimatedBuilder(
              animation: _controller,
              builder: (context, child) {
                return Transform.scale(
                  scale: _scaleAnimation.value,
                  child: Container(
                    width: 80,
                    height: 80,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          const Color(0xFFFFD600),
                          const Color(0xFFFFA000),
                        ],
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFFFFD600).withOpacity(0.4),
                          blurRadius: 20,
                          spreadRadius: 2,
                        ),
                      ],
                    ),
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        // Rotating ring
                        RotationTransition(
                          turns: _rotationAnimation,
                          child: Container(
                            width: 70,
                            height: 70,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: Colors.black.withOpacity(0.2),
                                width: 3,
                              ),
                            ),
                            child: CustomPaint(
                              painter: _ArcPainter(
                                color: Colors.black,
                                strokeWidth: 3,
                              ),
                            ),
                          ),
                        ),
                        // Center icon
                        Icon(widget.icon, color: Colors.black, size: 32),
                      ],
                    ),
                  ),
                );
              },
            ),
            SizedBox(height: 28),
            // Step indicator
            if (widget.step != null) ...[
              Container(
                padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFD600).withOpacity(0.15),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: const Color(0xFFFFD600).withOpacity(0.3),
                  ),
                ),
                child: Text(
                  widget.step!,
                  style: GoogleFonts.outfit(
                    color: const Color(0xFFFFD600),
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
              SizedBox(height: 16),
            ],
            // Title
            Text(
              widget.title,
              style: GoogleFonts.outfit(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.5,
              ),
              textAlign: TextAlign.center,
            ),
            SizedBox(height: 10),
            // Subtitle
            Text(
              widget.subtitle,
              style: GoogleFonts.outfit(
                color: Colors.grey[400],
                fontSize: 14,
                fontWeight: FontWeight.w400,
                height: 1.4,
              ),
              textAlign: TextAlign.center,
            ),
            SizedBox(height: 24),
            // Progress dots
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(3, (index) {
                return AnimatedBuilder(
                  animation: _controller,
                  builder: (context, child) {
                    final delay = index * 0.2;
                    final value = ((_controller.value + delay) % 1.0);
                    final opacity = (value < 0.5 ? value * 2 : 2 - value * 2);
                    return Container(
                      margin: EdgeInsets.symmetric(horizontal: 4),
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: const Color(
                          0xFFFFD600,
                        ).withOpacity(0.3 + opacity * 0.7),
                      ),
                    );
                  },
                );
              }),
            ),
          ],
        ),
      ),
    );
  }
}

// Arc painter for rotating progress indicator
class _ArcPainter extends CustomPainter {
  final Color color;
  final double strokeWidth;

  _ArcPainter({required this.color, required this.strokeWidth});

  @override
  void paint(Canvas canvas, Size size) {
    final paint =
        Paint()
          ..color = color
          ..strokeWidth = strokeWidth
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round;

    final rect = Rect.fromLTWH(0, 0, size.width, size.height);
    canvas.drawArc(rect, -pi / 2, pi / 2, false, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

// Isolated widget for per-client progress display
// Uses its own timer to avoid rebuilding parent widget tree
class _ClientProgressSection extends StatefulWidget {
  final Map<String, Map<int, DownloadStatus>> clientDownloads;
  final int fileIndex;
  final Map<String, String> clientDeviceNames;
  final String Function(String) formatClientIP;
  final bool hasAnyClientCompleted;

  const _ClientProgressSection({
    required this.clientDownloads,
    required this.fileIndex,
    required this.clientDeviceNames,
    required this.formatClientIP,
    required this.hasAnyClientCompleted,
  });

  @override
  State<_ClientProgressSection> createState() => _ClientProgressSectionState();
}

class _ClientProgressSectionState extends State<_ClientProgressSection> {
  Timer? _updateTimer;

  @override
  void initState() {
    super.initState();
    // Start a local timer that only rebuilds this widget
    _updateTimer = Timer.periodic(Duration(milliseconds: 300), (_) {
      if (mounted && _hasActiveDownloads()) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _updateTimer?.cancel();
    super.dispose();
  }

  bool _hasActiveDownloads() {
    for (final entry in widget.clientDownloads.entries) {
      if (entry.value.containsKey(widget.fileIndex)) {
        final status = entry.value[widget.fileIndex]!;
        if (!status.isCompleted &&
            status.progress > 0 &&
            status.progress < 1.0) {
          return true;
        }
      }
    }
    return false;
  }

  List<MapEntry<String, DownloadStatus>> _getActiveClients() {
    final activeClients = <MapEntry<String, DownloadStatus>>[];
    for (final entry in widget.clientDownloads.entries) {
      if (entry.value.containsKey(widget.fileIndex)) {
        final status = entry.value[widget.fileIndex]!;
        if (!status.isCompleted && status.progress > 0) {
          activeClients.add(MapEntry(entry.key, status));
        }
      }
    }
    return activeClients;
  }

  @override
  Widget build(BuildContext context) {
    final activeClients = _getActiveClients();

    if (activeClients.isEmpty && !widget.hasAnyClientCompleted) {
      return Padding(
        padding: EdgeInsets.only(top: 4),
        child: Text(
          'Waiting for download...',
          style: GoogleFonts.outfit(
            color: Colors.grey[500],
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
        ),
      );
    }

    if (activeClients.isEmpty) {
      return SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children:
          activeClients.map((entry) {
            final clientIP = entry.key;
            final status = entry.value;
            final deviceName =
                widget.clientDeviceNames[clientIP] ??
                widget.formatClientIP(clientIP);

            return Padding(
              padding: EdgeInsets.only(top: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.devices_rounded,
                        size: 12,
                        color: Colors.yellow[300],
                      ),
                      SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          deviceName,
                          style: GoogleFonts.outfit(
                            color: Colors.grey[400],
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Text(
                        '${(status.progress * 100).toStringAsFixed(0)}%',
                        style: GoogleFonts.outfit(
                          color: Colors.yellow[300],
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (status.speedMbps > 0) ...[
                        SizedBox(width: 6),
                        Text(
                          '${status.speedMbps.toStringAsFixed(1)} Mbps',
                          style: GoogleFonts.outfit(
                            color: Colors.grey[500],
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ],
                  ),
                  SizedBox(height: 4),
                  // Use TweenAnimationBuilder for smooth progress animation
                  TweenAnimationBuilder<double>(
                    tween: Tween(begin: 0, end: status.progress),
                    duration: Duration(milliseconds: 250),
                    curve: Curves.easeOut,
                    builder: (context, value, _) {
                      return ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: value,
                          backgroundColor: Colors.grey[800],
                          valueColor: AlwaysStoppedAnimation<Color>(
                            Colors.yellow[300]!,
                          ),
                          minHeight: 4,
                        ),
                      );
                    },
                  ),
                ],
              ),
            );
          }).toList(),
    );
  }
}

// Smooth Loading Dialog with animated content transitions
class _SmoothLoadingDialog extends StatefulWidget {
  final String title;
  final String subtitle;
  final String? step;
  final IconData icon;

  const _SmoothLoadingDialog({
    required this.title,
    required this.subtitle,
    this.step,
    required this.icon,
  });

  @override
  State<_SmoothLoadingDialog> createState() => _SmoothLoadingDialogState();
}

class _SmoothLoadingDialogState extends State<_SmoothLoadingDialog>
    with TickerProviderStateMixin {
  late AnimationController _rotationController;
  late AnimationController _pulseController;
  late Animation<double> _scaleAnimation;

  late String _title;
  late String _subtitle;
  String? _step;
  late IconData _icon;
  bool _isSuccess = false;

  @override
  void initState() {
    super.initState();
    _title = widget.title;
    _subtitle = widget.subtitle;
    _step = widget.step;
    _icon = widget.icon;

    _rotationController = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: 1500),
    )..repeat();

    _pulseController = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: 1000),
    )..repeat(reverse: true);

    _scaleAnimation = Tween<double>(begin: 0.95, end: 1.05).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
  }

  void updateContent({
    required String title,
    required String subtitle,
    String? step,
    required IconData icon,
  }) {
    setState(() {
      _title = title;
      _subtitle = subtitle;
      _step = step;
      _icon = icon;
      _isSuccess = false;
    });
  }

  void showSuccess() {
    setState(() {
      _isSuccess = true;
      _title = 'Connected!';
      _subtitle = 'Connection established successfully';
      _step = 'COMPLETE';
      _icon = Icons.check_circle_rounded;
    });
  }

  @override
  void dispose() {
    _rotationController.dispose();
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      child: AnimatedContainer(
        duration: Duration(milliseconds: 300),
        curve: Curves.easeOutCubic,
        padding: EdgeInsets.all(28),
        decoration: BoxDecoration(
          color: const Color(0xFF1C1C1E),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(
            color:
                _isSuccess
                    ? Colors.green.withOpacity(0.5)
                    : const Color(0xFFFFD600).withOpacity(0.3),
            width: 1.5,
          ),
          boxShadow: [
            BoxShadow(
              color:
                  _isSuccess
                      ? Colors.green.withOpacity(0.15)
                      : const Color(0xFFFFD600).withOpacity(0.1),
              blurRadius: 30,
              spreadRadius: 5,
            ),
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
            // Animated icon container
            AnimatedBuilder(
              animation: _pulseController,
              builder: (context, child) {
                return Transform.scale(
                  scale: _isSuccess ? 1.0 : _scaleAnimation.value,
                  child: AnimatedContainer(
                    duration: Duration(milliseconds: 300),
                    width: 80,
                    height: 80,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors:
                            _isSuccess
                                ? [Colors.green, Colors.green[700]!]
                                : [
                                  const Color(0xFFFFD600),
                                  const Color(0xFFFFA000),
                                ],
                      ),
                      boxShadow: null,
                    ),
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        // Rotating arc (hidden on success)
                        if (!_isSuccess)
                          AnimatedBuilder(
                            animation: _rotationController,
                            builder: (context, child) {
                              return Transform.rotate(
                                angle: _rotationController.value * 2 * pi,
                                child: SizedBox(
                                  width: 70,
                                  height: 70,
                                  child: CustomPaint(
                                    painter: _ArcPainter(
                                      color: Colors.black.withOpacity(0.3),
                                      strokeWidth: 3,
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                        // Center icon with animation
                        AnimatedSwitcher(
                          duration: Duration(milliseconds: 200),
                          child: Icon(
                            _icon,
                            key: ValueKey(_icon),
                            color: _isSuccess ? Colors.white : Colors.black,
                            size: 32,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
            SizedBox(height: 28),
            // Step indicator with animation
            AnimatedSwitcher(
              duration: Duration(milliseconds: 200),
              transitionBuilder: (child, animation) {
                return FadeTransition(
                  opacity: animation,
                  child: SlideTransition(
                    position: Tween<Offset>(
                      begin: Offset(0, 0.2),
                      end: Offset.zero,
                    ).animate(animation),
                    child: child,
                  ),
                );
              },
              child:
                  _step != null
                      ? Container(
                        key: ValueKey(_step),
                        padding: EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color:
                              _isSuccess
                                  ? Colors.green.withOpacity(0.15)
                                  : const Color(0xFFFFD600).withOpacity(0.15),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color:
                                _isSuccess
                                    ? Colors.green.withOpacity(0.3)
                                    : const Color(0xFFFFD600).withOpacity(0.3),
                          ),
                        ),
                        child: Text(
                          _step!,
                          style: GoogleFonts.outfit(
                            color:
                                _isSuccess
                                    ? Colors.green
                                    : const Color(0xFFFFD600),
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0.5,
                          ),
                        ),
                      )
                      : SizedBox.shrink(),
            ),
            if (_step != null) SizedBox(height: 16),
            // Title with animation
            AnimatedSwitcher(
              duration: Duration(milliseconds: 200),
              transitionBuilder: (child, animation) {
                return FadeTransition(
                  opacity: animation,
                  child: SlideTransition(
                    position: Tween<Offset>(
                      begin: Offset(0, 0.1),
                      end: Offset.zero,
                    ).animate(animation),
                    child: child,
                  ),
                );
              },
              child: Text(
                _title,
                key: ValueKey(_title),
                style: GoogleFonts.outfit(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.5,
                ),
                textAlign: TextAlign.center,
              ),
            ),
            SizedBox(height: 10),
            // Subtitle with animation
            AnimatedSwitcher(
              duration: Duration(milliseconds: 200),
              child: Text(
                _subtitle,
                key: ValueKey(_subtitle),
                style: GoogleFonts.outfit(
                  color: Colors.grey[400],
                  fontSize: 14,
                  fontWeight: FontWeight.w400,
                  height: 1.4,
                ),
                textAlign: TextAlign.center,
              ),
            ),
            SizedBox(height: 24),
            // Progress dots (hidden on success)
            AnimatedOpacity(
              duration: Duration(milliseconds: 200),
              opacity: _isSuccess ? 0.0 : 1.0,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(3, (index) {
                  return AnimatedBuilder(
                    animation: _rotationController,
                    builder: (context, child) {
                      final delay = index * 0.2;
                      final value = ((_rotationController.value + delay) % 1.0);
                      final opacity = (value < 0.5 ? value * 2 : 2 - value * 2);
                      return Container(
                        margin: EdgeInsets.symmetric(horizontal: 4),
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: const Color(
                            0xFFFFD600,
                          ).withOpacity(0.3 + opacity * 0.7),
                        ),
                      );
                    },
                  );
                }),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// Searchable All Devices Bottom Sheet
class _AllDevicesSheet extends StatefulWidget {
  final List<DiscoveredDevice> devices;
  final bool isDemoMode;
  final IconData Function(String name, {String? platform}) getDeviceIcon;
  final void Function(DiscoveredDevice device) onDeviceTap;

  const _AllDevicesSheet({
    required this.devices,
    required this.isDemoMode,
    required this.getDeviceIcon,
    required this.onDeviceTap,
  });

  @override
  State<_AllDevicesSheet> createState() => _AllDevicesSheetState();
}

class _AllDevicesSheetState extends State<_AllDevicesSheet> {
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  List<DiscoveredDevice> get filteredDevices {
    if (_searchQuery.isEmpty) return widget.devices;

    return widget.devices.where((device) {
      return device.deviceName.toLowerCase().contains(
        _searchQuery.toLowerCase(),
      );
    }).toList();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.7,
      ),
      decoration: const BoxDecoration(
        color: Color(0xFF1C1C1E),
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Handle bar
          Container(
            margin: const EdgeInsets.only(top: 12),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.white24,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
            child: Row(
              children: [
                Icon(Icons.devices_rounded, color: Colors.white70, size: 22),
                const SizedBox(width: 12),
                Text(
                  'All Devices (${widget.devices.length})',
                  style: GoogleFonts.outfit(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                GestureDetector(
                  onTap: () => Navigator.pop(context),
                  child: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.1),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.close_rounded,
                      color: Colors.white70,
                      size: 18,
                    ),
                  ),
                ),
              ],
            ),
          ),
          // Search bar
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.08),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white12),
              ),
              child: TextField(
                controller: _searchController,
                onChanged: (value) => setState(() => _searchQuery = value),
                style: GoogleFonts.outfit(color: Colors.white, fontSize: 15),
                decoration: InputDecoration(
                  hintText: 'Search devices...',
                  hintStyle: GoogleFonts.outfit(
                    color: Colors.white38,
                    fontSize: 15,
                  ),
                  prefixIcon: const Icon(
                    Icons.search_rounded,
                    color: Colors.white38,
                    size: 20,
                  ),
                  suffixIcon:
                      _searchQuery.isNotEmpty
                          ? GestureDetector(
                            onTap: () {
                              _searchController.clear();
                              setState(() => _searchQuery = '');
                            },
                            child: const Icon(
                              Icons.clear_rounded,
                              color: Colors.white38,
                              size: 18,
                            ),
                          )
                          : null,
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 14,
                  ),
                ),
              ),
            ),
          ),
          const Divider(color: Colors.white12, height: 1),
          // Device list
          Flexible(
            child:
                filteredDevices.isEmpty
                    ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(40),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.search_off_rounded,
                              color: Colors.white24,
                              size: 48,
                            ),
                            const SizedBox(height: 12),
                            Text(
                              'No devices found',
                              style: GoogleFonts.outfit(
                                color: Colors.white38,
                                fontSize: 15,
                              ),
                            ),
                          ],
                        ),
                      ),
                    )
                    : ListView.builder(
                      shrinkWrap: true,
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      itemCount: filteredDevices.length,
                      itemBuilder: (context, index) {
                        final device = filteredDevices[index];

                        // Handle demo vs real devices
                        String name = device.deviceName;

                        // Determine icon and subtitle based on device/platform
                        String? platform = device.platform;
                        IconData icon = widget.getDeviceIcon(
                          name,
                          platform: platform,
                        );
                        String subtitle =
                            widget.isDemoMode ? 'Demo Device' : 'Network';

                        // Standard colors for all devices
                        // final bool useInvertedColors = false; // Unused

                        return ListTile(
                          onTap:
                              widget.isDemoMode
                                  ? null
                                  : () => widget.onDeviceTap(device),
                          leading: Container(
                            width: 48,
                            height: 48,
                            decoration: BoxDecoration(
                              color:
                                  (widget.isDemoMode
                                      ? Colors.grey[700]
                                      : Colors.black38),
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: Colors.white12,
                                width: 1,
                              ),
                            ),
                            child: Icon(icon, color: Colors.white, size: 22),
                          ),
                          title: Text(
                            name,
                            style: GoogleFonts.outfit(
                              color: Colors.white,
                              fontSize: 15,
                              fontWeight: FontWeight.w500,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            subtitle,
                            style: GoogleFonts.outfit(
                              color: Colors.white54,
                              fontSize: 12,
                            ),
                          ),
                          trailing:
                              widget.isDemoMode
                                  ? null
                                  : const Icon(
                                    Icons.chevron_right_rounded,
                                    color: Colors.white38,
                                    size: 24,
                                  ),
                        );
                      },
                    ),
          ),
          SizedBox(height: MediaQuery.of(context).padding.bottom + 8),
        ],
      ),
    );
  }
}
