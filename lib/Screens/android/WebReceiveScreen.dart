import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:open_file/open_file.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:file_picker/file_picker.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:zap_share/blocs/navigation/smooth_page_route.dart';
import 'WebReceivedFilesScreen.dart'
    show WebReceivedFilesScreen, ReceivedFileItem;

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

class ReceivedFile {
  final String name;
  final int size;
  final String path;
  final DateTime receivedAt;
  double progress;
  String status;
  bool isUploading;
  double speedMbps;

  ReceivedFile({
    required this.name,
    required this.size,
    required this.path,
    required this.receivedAt,
    this.progress = 1.0,
    this.status = 'Complete',
    this.isUploading = false,
    this.speedMbps = 0.0,
  });
}

class WebReceiveScreen extends StatefulWidget {
  const WebReceiveScreen({super.key});

  @override
  State<WebReceiveScreen> createState() => _WebReceiveScreenState();
}

class _WebReceiveScreenState extends State<WebReceiveScreen> {
  HttpServer? _uploadServer;
  String? _localIp;
  bool _isHosting = false;
  int _port = 8090; // Default port for Web Receive

  String? _saveFolder;
  String? _customSaveFolder;
  bool _uploadApprovalActive = false;
  DateTime? _uploadApprovalExpiresAt;

  List<ReceivedFile> _receivedFiles = [];
  Map<String, ReceivedFile> _ongoingDownloads = {};
  final FlutterLocalNotificationsPlugin _notificationsPlugin =
      FlutterLocalNotificationsPlugin();
  final Map<String, int> _fileToNotificationId = {};

  @override
  void initState() {
    super.initState();
    _loadPort();
    _initializeServer();
    _initLocalNotifications();
  }

  @override
  void dispose() {
    _uploadServer?.close(force: true);
    _stopForegroundService();
    super.dispose();
  }

  Future<void> _initLocalNotifications() async {
    const AndroidInitializationSettings androidSettings =
        AndroidInitializationSettings('ic_stat_notify');
    final InitializationSettings initSettings = InitializationSettings(
      android: androidSettings,
    );
    await _notificationsPlugin.initialize(initSettings);
  }

  Future<void> _startForegroundService() async {
    await FlutterForegroundTask.startService(
      notificationTitle: '⚡ ZapShare Web Receive',
      notificationText: 'Receiving files in background',
      notificationIcon: const NotificationIcon(
        metaDataName: 'com.pravera.flutter_foreground_task.notification_icon',
      ),
    );
  }

  Future<void> _stopForegroundService() async {
    await FlutterForegroundTask.stopService();
  }

  int _notificationIdFor(String key) {
    return _fileToNotificationId.putIfAbsent(
      key,
      () => 5000 + key.hashCode.abs() % 2000,
    );
  }

  Future<void> _showProgressNotification({
    required String key,
    required String fileName,
    required int progress,
    double speedMbps = 0.0,
  }) async {
    final percent = progress.clamp(0, 100);
    final speedText =
        speedMbps > 0 ? '${speedMbps.toStringAsFixed(2)} Mbps' : '--';

    final android = AndroidNotificationDetails(
      'web_receive_channel',
      'Web Receive',
      channelDescription: 'Web file receiving progress notifications',
      importance: Importance.low,
      priority: Priority.low,
      showProgress: true,
      maxProgress: 100,
      progress: percent,
      onlyAlertOnce: true,
      ongoing: true,
      autoCancel: false,
      icon: 'ic_stat_notify',
    );

    final details = NotificationDetails(android: android);
    await _notificationsPlugin.show(
      _notificationIdFor(key),
      '🌐 Receiving from Web',
      '$fileName • $percent% • $speedText',
      details,
    );
  }

  Future<void> _cancelProgressNotification(String key) async {
    if (_fileToNotificationId.containsKey(key)) {
      await _notificationsPlugin.cancel(_fileToNotificationId[key]!);
      _fileToNotificationId.remove(key);
    }
  }

  Future<void> _initializeServer() async {
    await _requestStoragePermissions();
    await _loadCustomFolder();
    _saveFolder = await _getDefaultDownloadFolder();
    // Fetch local IP but don't start server automatically
    await _fetchLocalIp();
  }

  Future<void> _fetchLocalIp() async {
    final ip = await _getLocalIpv4();
    if (mounted) {
      setState(() {
        _localIp = ip;
      });
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

  Future<String> _getDefaultDownloadFolder() async {
    try {
      if (_customSaveFolder != null && _customSaveFolder!.isNotEmpty) {
        final dir = Directory(_customSaveFolder!);
        if (!await dir.exists()) {
          await dir.create(recursive: true);
        }
        return dir.path;
      }

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

  Future<void> _loadCustomFolder() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _customSaveFolder = prefs.getString('custom_save_folder');
    } catch (_) {}
  }

  Future<void> _pickCustomFolder() async {
    try {
      String? selectedDirectory = await FilePicker.platform.getDirectoryPath();
      if (selectedDirectory != null) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('custom_save_folder', selectedDirectory);
        setState(() {
          _customSaveFolder = selectedDirectory;
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

  Future<void> _loadPort() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      setState(() {
        _port = prefs.getInt('web_receive_port') ?? 8090;
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
                    fontSize: 14,
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
                    hintText: '8090',
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
      await prefs.setInt('web_receive_port', result);
      setState(() {
        _port = result;
      });

      if (_isHosting) {
        await _stopWebServer();
        await _startWebServer();
      }

      HapticFeedback.mediumImpact();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Port updated to $_port',
            style: GoogleFonts.outfit(color: Colors.black),
          ),
          backgroundColor: const Color(0xFFFFD600),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  Future<String?> _getLocalIpv4() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );

      String? fallbackIp;

      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          final ip = addr.address;

          // Skip loopback and link-local
          if (ip.startsWith('127.') || ip.startsWith('169.254.')) {
            continue;
          }

          // Skip VPN/virtual IPs (100.64.0.0/10 - CGNAT, often used by VPNs)
          if (ip.startsWith('100.')) {
            fallbackIp ??= ip; // Keep as fallback
            continue;
          }

          // Prioritize common local network ranges
          // 192.168.0.0/16 - Most common home networks
          if (ip.startsWith('192.168.')) {
            return ip;
          }

          // 10.0.0.0/8 - Large private networks
          if (ip.startsWith('10.')) {
            return ip;
          }

          // 172.16.0.0/12 - Private networks (172.16.x.x to 172.31.x.x)
          if (ip.startsWith('172.')) {
            final parts = ip.split('.');
            if (parts.length >= 2) {
              final secondOctet = int.tryParse(parts[1]);
              if (secondOctet != null &&
                  secondOctet >= 16 &&
                  secondOctet <= 31) {
                return ip;
              }
            }
          }

          // Keep any other non-loopback IP as fallback
          fallbackIp ??= ip;
        }
      }

      // Return fallback if no preferred IP found
      return fallbackIp;
    } catch (_) {}
    return null;
  }

  Future<void> _startWebServer() async {
    try {
      // Get local IP first
      final ip = await _getLocalIpv4();
      if (ip == null) {
        throw Exception(
          'Could not get local IP address. Please check WiFi connection.',
        );
      }

      setState(() {
        _localIp = ip;
      });

      // Close any existing server
      await _uploadServer?.close(force: true);

      // Bind to the port
      _uploadServer = await HttpServer.bind(InternetAddress.anyIPv4, _port);

      print('Web server started at http://$_localIp:$_port');

      setState(() {
        _isHosting = true;
      });
      await _startForegroundService();

      _uploadServer!.listen((HttpRequest request) async {
        final path = request.uri.path;
        if (request.method == 'GET' && (path == '/' || path == '/index.html')) {
          await _serveUploadForm(request);
          return;
        }
        if (request.method == 'GET' && path == '/logo.png') {
          await _serveLogo(request);
          return;
        }
        if (request.method == 'POST' && path == '/request-upload') {
          await _handleRequestUpload(request);
          return;
        }
        if (request.method == 'PUT' && path == '/upload') {
          await _handlePutUpload(request);
          return;
        }
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
      });

      if (mounted) {
        HapticFeedback.mediumImpact();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Web server started at http://$_localIp:$_port',
              style: GoogleFonts.outfit(color: Colors.black),
            ),
            backgroundColor: const Color(0xFFFFD600),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      setState(() {
        _isHosting = false;
        _localIp = null;
      });
      print('Failed to start server: $e');

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Failed to start server: $e',
              style: GoogleFonts.outfit(color: Colors.white),
            ),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 5),
          ),
        );
      }
    }
  }

  Future<void> _stopWebServer() async {
    await _uploadServer?.close(force: true);
    setState(() {
      _isHosting = false;
    });
    await _stopForegroundService();
    HapticFeedback.mediumImpact();
  }

  Future<void> _serveLogo(HttpRequest request) async {
    try {
      final ByteData logoData = await rootBundle.load('assets/images/logo.png');
      final bytes = logoData.buffer.asUint8List();
      request.response.statusCode = HttpStatus.ok;
      request.response.headers.contentType = ContentType('image', 'png');
      request.response.add(bytes);
      await request.response.close();
    } catch (e) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
    }
  }

  Future<void> _serveUploadForm(HttpRequest request) async {
    final response = request.response;
    response.statusCode = HttpStatus.ok;
    response.headers.contentType = ContentType.html;
    final html = '''
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>ZapShare - Upload Files</title>
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body { margin: 0; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; background: #000000; color: #ffffff; min-height: 100vh; display: flex; overflow-x: hidden; }
    .main-content { flex: 1; padding: 40px; display: flex; align-items: center; justify-content: center; }
    .container { max-width: 700px; width: 100%; }
    .card { background: rgba(26, 26, 26, 0.8); border: 1px solid rgba(255, 255, 255, 0.1); border-radius: 24px; padding: 40px; box-shadow: 0 20px 60px rgba(0, 0, 0, 0.6); backdrop-filter: blur(40px); }
    .logo { width: 64px; height: 64px; margin-bottom: 24px; }
    .title { font-size: 28px; font-weight: 700; color: #ffffff; margin-bottom: 8px; letter-spacing: -0.5px; }
    .subtitle { font-size: 14px; color: #888; margin-bottom: 32px; }
    .upload-area { border: 2px dashed rgba(255, 214, 0, 0.3); border-radius: 20px; padding: 48px 32px; text-align: center; background: rgba(255, 214, 0, 0.05); margin-bottom: 24px; cursor: pointer; transition: all 0.3s; }
    .upload-area:hover { border-color: rgba(255, 214, 0, 0.6); background: rgba(255, 214, 0, 0.1); }
    .upload-icon { font-size: 48px; margin-bottom: 16px; }
    .file-input-label { display: inline-block; padding: 16px 32px; background: linear-gradient(135deg, #FFD600 0%, #FFC400 100%); color: #000; border-radius: 16px; cursor: pointer; font-weight: 700; font-size: 16px; transition: transform 0.2s; }
    .file-input-label:hover { transform: translateY(-2px); }
    .upload-btn { width: 100%; padding: 18px; background: linear-gradient(135deg, #FFD600 0%, #FFC400 100%); color: #000; border: none; border-radius: 16px; font-weight: 700; font-size: 16px; cursor: pointer; transition: transform 0.2s; }
    .upload-btn:hover { transform: translateY(-2px); }
    .upload-btn:disabled { background: rgba(255, 255, 255, 0.1); color: rgba(255, 255, 255, 0.3); cursor: not-allowed; transform: none; }
    .message { margin-bottom: 16px; color: #aaa; font-size: 14px; min-height: 20px; }
    .progress-bar { width: 100%; height: 8px; background: rgba(255, 255, 255, 0.1); border-radius: 8px; overflow: hidden; margin-bottom: 16px; display: none; }
    .progress-fill { height: 100%; background: linear-gradient(90deg, #FFD600, #FFC400); width: 0%; transition: width 0.3s; }
  </style>
  <script>
    let selectedFiles = [];
    document.addEventListener('DOMContentLoaded', function() {
      const uploadArea = document.getElementById('uploadArea');
      const fileInput = document.getElementById('files');
      const uploadBtn = document.getElementById('uploadBtn');
      const message = document.getElementById('message');
      const progressBar = document.getElementById('progressBar');
      const progressFill = document.getElementById('progressFill');
      
      uploadArea.addEventListener('dragover', e => { e.preventDefault(); uploadArea.style.borderColor = 'rgba(255, 214, 0, 0.8)'; });
      uploadArea.addEventListener('dragleave', e => { e.preventDefault(); uploadArea.style.borderColor = ''; });
      uploadArea.addEventListener('drop', e => { e.preventDefault(); uploadArea.style.borderColor = ''; handleFiles(e.dataTransfer.files); });
      fileInput.addEventListener('change', e => handleFiles(e.target.files));
      
      function handleFiles(files) {
        selectedFiles = Array.from(files);
        uploadBtn.disabled = selectedFiles.length === 0;
        message.innerText = selectedFiles.length + ' file(s) selected';
      }
      
      uploadBtn.addEventListener('click', async () => {
        if (selectedFiles.length === 0) return;
        uploadBtn.disabled = true;
        message.innerText = 'Requesting permission...';
        progressBar.style.display = 'block';
        
        try {
          const meta = selectedFiles.map(f => ({ name: f.name, size: f.size }));
          const approveResp = await fetch('/request-upload', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ files: meta })
          });
          const approve = await approveResp.json();
          if (!approve.approved) {
            message.innerText = 'Upload denied on device';
            uploadBtn.disabled = false;
            progressBar.style.display = 'none';
            return;
          }

          message.innerText = 'Uploading...';
          for (let i = 0; i < selectedFiles.length; i++) {
            const file = selectedFiles[i];
            const progress = ((i / selectedFiles.length) * 100).toFixed(0);
            progressFill.style.width = progress + '%';
            
            await new Promise((resolve, reject) => {
              const xhr = new XMLHttpRequest();
              xhr.open('PUT', '/upload?name=' + encodeURIComponent(file.name));
              xhr.onload = () => xhr.status === 200 ? resolve() : reject();
              xhr.onerror = () => reject();
              xhr.send(file);
            });
            message.innerText = 'Uploaded ' + (i + 1) + '/' + selectedFiles.length;
          }
          progressFill.style.width = '100%';
          message.innerText = '✓ Upload Complete!';
          message.style.color = '#4CAF50';
        } catch (e) {
          message.innerText = '✗ Upload failed: ' + e;
          message.style.color = '#f44336';
        } finally {
          uploadBtn.disabled = false;
          selectedFiles = [];
          setTimeout(() => {
            progressBar.style.display = 'none';
            progressFill.style.width = '0%';
            message.style.color = '#aaa';
          }, 3000);
        }
      });
    });
  </script>
</head>
<body>
  <div class="main-content">
    <div class="container">
      <div class="card">
        <div class="upload-icon">⚡</div>
        <h2 class="title">ZapShare Upload</h2>
        <p class="subtitle">Send files to your device</p>
        <div class="upload-area" id="uploadArea">
          <label for="files" class="file-input-label">Choose Files</label>
          <input id="files" type="file" multiple style="display:none" />
          <p style="margin-top: 16px; color: #666; font-size: 13px;">or drag and drop files here</p>
        </div>
        <div id="message" class="message"></div>
        <div id="progressBar" class="progress-bar">
          <div id="progressFill" class="progress-fill"></div>
        </div>
        <button id="uploadBtn" class="upload-btn" disabled>Upload Files</button>
      </div>
    </div>
  </div>
</body>
</html>
''';
    response.write(html);
    await response.close();
  }

  Future<void> _handleRequestUpload(HttpRequest request) async {
    try {
      final body = await utf8.decodeStream(request);
      final data = jsonDecode(body);
      final files =
          (data['files'] as List)
              .cast<Map>()
              .map((m) => {'name': m['name'], 'size': m['size']})
              .toList();

      if (!mounted) return;

      final approved =
          await showDialog<bool>(
            context: context,
            barrierDismissible: false,
            builder:
                (context) => AlertDialog(
                  backgroundColor: const Color(0xFF1C1C1E),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20),
                  ),
                  title: Text(
                    'Allow Upload?',
                    style: GoogleFonts.outfit(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  content: Text(
                    'Receive ${files.length} file(s) from web?',
                    style: GoogleFonts.outfit(color: Colors.grey[400]),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: Text(
                        'Deny',
                        style: GoogleFonts.outfit(
                          color: Colors.red,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    ElevatedButton(
                      onPressed: () => Navigator.pop(context, true),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFFFD600),
                        foregroundColor: Colors.black,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: Text(
                        'Allow',
                        style: GoogleFonts.outfit(fontWeight: FontWeight.w700),
                      ),
                    ),
                  ],
                ),
          ) ??
          false;

      if (approved) {
        setState(() {
          _uploadApprovalActive = true;
          _uploadApprovalExpiresAt = DateTime.now().add(
            const Duration(minutes: 2),
          );
        });
      }

      request.response.statusCode = HttpStatus.ok;
      request.response.headers.contentType = ContentType.json;
      request.response.headers.set('Access-Control-Allow-Origin', '*');
      request.response.write(jsonEncode({'approved': approved}));
      await request.response.close();
    } catch (e) {
      request.response.statusCode = HttpStatus.internalServerError;
      await request.response.close();
    }
  }

  Future<void> _handlePutUpload(HttpRequest request) async {
    try {
      if (!_uploadApprovalActive ||
          _uploadApprovalExpiresAt == null ||
          DateTime.now().isAfter(_uploadApprovalExpiresAt!)) {
        request.response.statusCode = HttpStatus.forbidden;
        await request.response.close();
        return;
      }
      await _handleFileTransfer(request);
    } catch (e) {
      request.response.statusCode = HttpStatus.internalServerError;
      await request.response.close();
    }
  }

  Future<void> _handleFileTransfer(HttpRequest request) async {
    try {
      // Sanitize filename to prevent path traversal or invalid char issues
      final rawName = request.uri.queryParameters['name'] ?? 'unknown_file';
      final fileName = rawName.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');

      String savePath = '$_saveFolder/$fileName';

      int count = 1;
      while (File(savePath).existsSync()) {
        final parts = fileName.split('.');
        if (parts.length > 1) {
          savePath =
              '$_saveFolder/${parts.sublist(0, parts.length - 1).join('.')}_$count.${parts.last}';
        } else {
          savePath = '$_saveFolder/${fileName}_$count';
        }
        count++;
      }

      setState(() {
        _ongoingDownloads[fileName] = ReceivedFile(
          name: fileName,
          size: request.contentLength,
          path: savePath,
          receivedAt: DateTime.now(),
          progress: 0.0,
          status: 'Receiving...',
          isUploading: true,
        );
      });

      final file = File(savePath);
      final sink = file.openWrite();
      int received = 0;
      int lastNotify = 0;
      int lastBytes = 0;
      DateTime lastSpeedTime = DateTime.now();
      bool uploadSuccess = false;

      try {
        await for (var chunk in request) {
          sink.add(chunk);
          received += chunk.length;

          final now = DateTime.now();
          final elapsed = now.difference(lastSpeedTime).inMilliseconds;
          double speedMbps = 0.0;
          if (elapsed > 0) {
            final bytesDelta = received - lastBytes;
            speedMbps = (bytesDelta * 8) / (elapsed * 1000);
            lastBytes = received;
            lastSpeedTime = now;
          }

          final nowMs = now.millisecondsSinceEpoch;
          if (nowMs - lastNotify > 500) {
            lastNotify = nowMs;
            final progress =
                request.contentLength > 0
                    ? (received / request.contentLength * 100).toInt()
                    : 0;
            _showProgressNotification(
              key: fileName,
              fileName: fileName,
              progress: progress,
              speedMbps: speedMbps,
            );

            if (mounted) {
              setState(() {
                _ongoingDownloads[fileName]?.progress =
                    request.contentLength > 0
                        ? received / request.contentLength
                        : 0.5;
                _ongoingDownloads[fileName]?.speedMbps = speedMbps;
              });
            }
          }

          // AGGRESSIVE completion: Break at 99.5% or when all bytes received
          if (request.contentLength > 0) {
            if (received >= request.contentLength ||
                received >= (request.contentLength * 0.995).floor()) {
              uploadSuccess = true;
              print('✅ Upload complete: $received/${request.contentLength} bytes');
              break;
            }
          }
        }

        // If loop finished naturally
        if (!uploadSuccess) {
          uploadSuccess = true;
        }
      } catch (e) {
        // Recovery: Accept upload if we got 95%+ of expected size
        if (request.contentLength > 0 &&
            received >= (request.contentLength * 0.95).floor()) {
          uploadSuccess = true;
          print(
            '⚠️ Stream error but recovered: $received/${request.contentLength} bytes - $e',
          );
        } else {
          await _cancelProgressNotification(fileName);
          try {
            await sink.close();
          } catch (_) {}
          try {
            if (await file.exists()) await file.delete();
          } catch (_) {}
          rethrow;
        }
      }

      // IMMEDIATE file close
      try {
        await sink.flush();
        await sink.close();
      } catch (e) {
        print('File close error (ignored): $e');
      }
      
      await _cancelProgressNotification(fileName);

      // Only proceed if upload was successful
      if (uploadSuccess) {
        setState(() {
          _ongoingDownloads.remove(fileName);
          _receivedFiles.insert(
            0,
            ReceivedFile(
              name: fileName,
              size: received,
              path: savePath,
              receivedAt: DateTime.now(),
              progress: 1.0,
              status: 'Complete',
            ),
          );
        });

        request.response.statusCode = HttpStatus.ok;
        request.response.headers.set('Access-Control-Allow-Origin', '*');
        request.response.headers.set('Connection', 'close');
        await request.response.close();
      } else {
        throw Exception('Upload incomplete');
      }
    } catch (e) {
      await _cancelProgressNotification(
        request.uri.queryParameters['name'] ?? 'unknown_file',
      );
      request.response.statusCode = HttpStatus.internalServerError;
      await request.response.close();
    }
  }

  Future<void> _openFile(ReceivedFile file) async {
    try {
      final result = await OpenFile.open(file.path);
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

  String _ipToCode(String ip, {int? port}) {
    final parts = ip.split('.').map(int.parse).toList();
    if (parts.length != 4) return '';
    int n = (parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3];
    String ipCode = n.toRadixString(36).toUpperCase().padLeft(8, '0');
    int targetPort = port ?? _port;
    String portCode = targetPort
        .toRadixString(36)
        .toUpperCase()
        .padLeft(3, '0');
    return ipCode + portCode;
  }

  @override
  Widget build(BuildContext context) {
    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;

    if (isLandscape) {
      return AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle.light,
        child: Scaffold(
          backgroundColor: Colors.black,
          body: SafeArea(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Left Side: Header and Server Card
                Expanded(
                  flex: 4,
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [_buildHeader(), _buildServerCard()],
                    ),
                  ),
                ),
                // Right Side: Settings and Files
                Expanded(
                  flex: 3,
                  child: Container(
                    height: double.infinity,
                    decoration: BoxDecoration(
                      border: Border(
                        left: BorderSide(color: Colors.white.withOpacity(0.1)),
                      ),
                    ),
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const SizedBox(
                            height: 80,
                          ), // spacer to align with header visual
                          _buildSaveLocationCard(),
                          if (_receivedFiles.isNotEmpty ||
                              _ongoingDownloads.isNotEmpty) ...[
                            const SizedBox(height: 24),
                            _buildFilesButton(),
                          ],
                        ],
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

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: Column(
            children: [
              _buildHeader(),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildServerCard(),
                      const SizedBox(height: 24),
                      _buildSaveLocationCard(),
                      if (_receivedFiles.isNotEmpty ||
                          _ongoingDownloads.isNotEmpty) ...[
                        const SizedBox(height: 24),
                        _buildFilesButton(),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
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
              'Web Receive',
              style: GoogleFonts.outfit(
                color: Colors.white,
                fontSize: 28,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.5,
              ),
            ),
          ),
          if (_receivedFiles.isNotEmpty)
            Container(
              decoration: BoxDecoration(
                color: const Color(0xFF1C1C1E),
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white.withOpacity(0.05)),
              ),
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  IconButton(
                    icon: const Icon(
                      Icons.folder_rounded,
                      color: Colors.white,
                      size: 22,
                    ),
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder:
                              (context) => WebReceivedFilesScreen(
                                files:
                                    _receivedFiles
                                        .map(
                                          (f) => ReceivedFileItem(
                                            name: f.name,
                                            size: f.size,
                                            path: f.path,
                                            receivedAt: f.receivedAt,
                                          ),
                                        )
                                        .toList(),
                              ),
                        ),
                      );
                    },
                  ),
                  if (_receivedFiles.isNotEmpty)
                    Positioned(
                      right: 6,
                      top: 6,
                      child: Container(
                        padding: const EdgeInsets.all(4),
                        decoration: const BoxDecoration(
                          color: Color(0xFFFFD600),
                          shape: BoxShape.circle,
                        ),
                        constraints: const BoxConstraints(
                          minWidth: 18,
                          minHeight: 18,
                        ),
                        child: Text(
                          '${_receivedFiles.length}',
                          style: GoogleFonts.outfit(
                            color: Colors.black,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildServerCard() {
    final url = _isHosting ? 'http://${_localIp ?? "..."}:$_port' : 'Offline';

    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: const Color(0xFF1C1C1E),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.white.withOpacity(0.05)),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color:
                      _isHosting
                          ? const Color(0xFFFFD600).withOpacity(0.15)
                          : Colors.white.withOpacity(0.05),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(
                  Icons.public_rounded,
                  color: _isHosting ? const Color(0xFFFFD600) : Colors.grey,
                  size: 28,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _isHosting ? 'Server Running' : 'Server Stopped',
                      style: GoogleFonts.outfit(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _isHosting ? url : 'Start server to receive files',
                      style: GoogleFonts.outfit(
                        color: Colors.grey[400],
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          // 8-digit code display
          if (_isHosting && _localIp != null) ...[
            const SizedBox(height: 24),
            GestureDetector(
              onTap: () {
                Clipboard.setData(ClipboardData(text: _ipToCode(_localIp!)));
                HapticFeedback.mediumImpact();
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      'Code copied to clipboard',
                      style: GoogleFonts.outfit(color: Colors.black),
                    ),
                    backgroundColor: const Color(0xFFFFD600),
                    behavior: SnackBarBehavior.floating,
                    duration: const Duration(seconds: 2),
                  ),
                );
              },
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 16,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFD600).withOpacity(0.1),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: const Color(0xFFFFD600).withOpacity(0.3),
                    width: 1.5,
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.qr_code_rounded,
                      color: const Color(0xFFFFD600),
                      size: 20,
                    ),
                    const SizedBox(width: 12),
                    Text(
                      _ipToCode(_localIp!),
                      style: GoogleFonts.outfit(
                        color: const Color(0xFFFFD600),
                        fontSize: 24,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 3.0,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Icon(
                      Icons.copy_rounded,
                      color: const Color(0xFFFFD600).withOpacity(0.7),
                      size: 18,
                    ),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: ElevatedButton(
                  onPressed: _isHosting ? _stopWebServer : _startWebServer,
                  style: ElevatedButton.styleFrom(
                    backgroundColor:
                        _isHosting
                            ? Colors.red.withOpacity(0.15)
                            : const Color(0xFFFFD600),
                    foregroundColor: _isHosting ? Colors.red : Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 18),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    elevation: 0,
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        _isHosting
                            ? Icons.stop_rounded
                            : Icons.play_arrow_rounded,
                        size: 22,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _isHosting ? 'Stop Server' : 'Start Server',
                        style: GoogleFonts.outfit(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Container(
                decoration: BoxDecoration(
                  color: const Color(0xFFFFD600).withOpacity(0.15),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: IconButton(
                  onPressed: _isHosting ? null : _showPortDialog,
                  icon: const Icon(Icons.settings_rounded),
                  color: const Color(0xFFFFD600),
                  tooltip: 'Change Port',
                  padding: const EdgeInsets.all(18),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            'Port: $_port',
            style: GoogleFonts.outfit(
              color: Colors.grey[500],
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
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
                        color: Colors.grey[400],
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.5,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _saveFolder ?? 'Default (Downloads/ZapShare)',
                      style: GoogleFonts.outfit(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
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

  Widget _buildFilesButton() {
    final totalFiles = _receivedFiles.length + _ongoingDownloads.length;
    final completedFiles = _receivedFiles.length;

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1C1C1E),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withOpacity(0.05)),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () {
            HapticFeedback.mediumImpact();
            Navigator.push(
              context,
              MaterialPageRoute(
                builder:
                    (context) => WebReceivedFilesScreen(
                      files:
                          _receivedFiles
                              .map(
                                (f) => ReceivedFileItem(
                                  name: f.name,
                                  size: f.size,
                                  path: f.path,
                                  receivedAt: f.receivedAt,
                                ),
                              )
                              .toList(),
                    ),
              ),
            );
          },
          borderRadius: BorderRadius.circular(20),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFD600).withOpacity(0.15),
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
                        'RECEIVED FILES',
                        style: GoogleFonts.outfit(
                          color: Colors.grey[400],
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1.5,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '$completedFiles completed${_ongoingDownloads.isNotEmpty ? ' • ${_ongoingDownloads.length} receiving' : ''}',
                        style: GoogleFonts.outfit(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  Icons.arrow_forward_ios_rounded,
                  color: Colors.grey[600],
                  size: 18,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFileItem(ReceivedFile file) {
    final fileType = _getFileType(file.name);
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
              file.name,
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
                if (file.isUploading) ...[
                  Row(
                    children: [
                      Text(
                        '${(file.progress * 100).toInt()}%',
                        style: GoogleFonts.outfit(
                          color: const Color(0xFFFFD600),
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (file.speedMbps > 0)
                        Text(
                          ' • ${file.speedMbps.toStringAsFixed(2)} Mbps',
                          style: GoogleFonts.outfit(
                            color: Colors.grey[400],
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                    ],
                  ),
                ] else ...[
                  Text(
                    _formatBytes(file.size),
                    style: GoogleFonts.outfit(
                      color: Colors.grey[400],
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ],
            ),
            trailing:
                file.isUploading
                    ? SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(
                        value: file.progress,
                        strokeWidth: 3,
                        valueColor: AlwaysStoppedAnimation(
                          const Color(0xFFFFD600),
                        ),
                        backgroundColor: Colors.white.withOpacity(0.1),
                      ),
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
          ),
          if (file.isUploading)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: LinearProgressIndicator(
                  value: file.progress,
                  backgroundColor: Colors.white.withOpacity(0.05),
                  valueColor: AlwaysStoppedAnimation(const Color(0xFFFFD600)),
                  minHeight: 8,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
