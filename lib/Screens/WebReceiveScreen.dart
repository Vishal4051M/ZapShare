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

class ReceivedFile {
  final String name;
  final int size;
  final String path;
  final DateTime receivedAt;
  double progress;
  String status;
  bool isUploading;

  ReceivedFile({
    required this.name,
    required this.size,
    required this.path,
    required this.receivedAt,
    this.progress = 1.0,
    this.status = 'Complete',
    this.isUploading = false,
  });
}

class PendingFile {
  final String id;
  final String name;
  final int size;
  final DateTime uploadedAt;
  final String browserSessionId; // Identifier for browser session
  bool isSelected;
  FileType fileType;

  PendingFile({
    required this.id,
    required this.name,
    required this.size,
    required this.uploadedAt,
    required this.browserSessionId,
    this.isSelected = true,
    required this.fileType,
  });
}

class PendingFileWithPreview extends PendingFile {
  final String previewPath; // Path to preview chunk file
  final int previewSize; // Size of preview chunk

  PendingFileWithPreview({
    required String id,
    required String name,
    required int size,
    required DateTime uploadedAt,
    required String browserSessionId,
    bool isSelected = true,
    required FileType fileType,
    required this.previewPath,
    required this.previewSize,
  }) : super(
    id: id,
    name: name,
    size: size,
    uploadedAt: uploadedAt,
    browserSessionId: browserSessionId,
    isSelected: isSelected,
    fileType: fileType,
  );
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
  String? _saveFolder;
  String? _customSaveFolder; // User-selected folder (persisted)
  bool _uploadApprovalActive = false;
  DateTime? _uploadApprovalExpiresAt;
  
  List<ReceivedFile> _receivedFiles = [];
  List<PendingFile> _pendingFiles = []; // Files uploaded but not yet received
  Map<String, ReceivedFile> _ongoingDownloads = {}; // Track downloads in progress
  final FlutterLocalNotificationsPlugin _notificationsPlugin = FlutterLocalNotificationsPlugin();
  final Map<String, int> _fileToNotificationId = {};
  
  int _currentTab = 0; // 0 = Pending Files, 1 = Received Files
  final PageController _pageController = PageController();
  
  @override
  void initState() {
    super.initState();
    _initializeServer();
    _initLocalNotifications();
  }

  Future<void> _initLocalNotifications() async {
    const AndroidInitializationSettings androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    final InitializationSettings initSettings = InitializationSettings(android: androidSettings);
    await _notificationsPlugin.initialize(initSettings);
  }

  Future<void> _startForegroundService() async {
    await FlutterForegroundTask.startService(
      notificationTitle: '⚡ ZapShare Web Receive',
      notificationText: 'Receiving files in background',
    );
  }

  Future<void> _stopForegroundService() async {
    await FlutterForegroundTask.stopService();
  }

  int _notificationIdFor(String key) {
    return _fileToNotificationId.putIfAbsent(key, () => 5000 + key.hashCode.abs() % 2000);
  }

  Future<void> _showProgressNotification({
    required String key,
    required String title,
    required String body,
    required int progress,
  }) async {
    final android = AndroidNotificationDetails(
      'web_receive_progress_$key',
      'Web Receive Progress $key',
      channelDescription: 'Shows the progress of an incoming file',
      importance: Importance.max,
      priority: Priority.high,
      showProgress: true,
      maxProgress: 100,
      progress: progress.clamp(0, 100),
      onlyAlertOnce: true,
      styleInformation: BigTextStyleInformation(body),
    );
    final details = NotificationDetails(android: android);
    await _notificationsPlugin.show(_notificationIdFor(key), title, body, details);
  }

  Future<void> _cancelProgressNotification(String key) async {
    await _notificationsPlugin.cancel(_notificationIdFor(key));
  }

  Future<void> _initializeServer() async {
    await _requestStoragePermissions();
    await _loadCustomFolder();
    _saveFolder = await _getDefaultDownloadFolder();
    await _startWebServer();
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
      // Use custom folder if set
      if (_customSaveFolder != null && _customSaveFolder!.isNotEmpty) {
        final dir = Directory(_customSaveFolder!);
        if (!await dir.exists()) {
          await dir.create(recursive: true);
        }
        return dir.path;
      }

      // Prefer public Downloads/ZapShare on Android
      final downloadsCandidate = Directory('/storage/emulated/0/Download/ZapShare');
      if (Platform.isAndroid) {
        try {
          if (!await downloadsCandidate.exists()) {
            await downloadsCandidate.create(recursive: true);
          }
          return downloadsCandidate.path;
        } catch (_) {}
      }

      // Try platform downloads directory if available
      try {
        final downloadsDir = await getDownloadsDirectory();
        if (downloadsDir != null) {
          final zapDir = Directory('${downloadsDir.path}/ZapShare');
          if (!await zapDir.exists()) {
            await zapDir.create(recursive: true);
          }
          return zapDir.path;
        }
      } catch (_) {}

      // Fallback to app documents
      final appDir = await getApplicationDocumentsDirectory();
      final fallback = Directory('${appDir.path}/ZapShare');
      if (!await fallback.exists()) {
        await fallback.create(recursive: true);
      }
      return fallback.path;
    } catch (e) {
      print('Error getting app folder: $e');
      // Fallback to a private folder in app storage
      final receivedDir = Directory('/data/data/com.example.zapshare/ZapShare');
      if (!await receivedDir.exists()) {
        await receivedDir.create(recursive: true);
      }
      return receivedDir.path;
    }
  }

  Future<void> _loadCustomFolder() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _customSaveFolder = prefs.getString('custom_save_folder');
    } catch (_) {}
  }

  Future<void> _setCustomFolder(String? folderPath) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (folderPath == null || folderPath.isEmpty) {
        await prefs.remove('custom_save_folder');
        setState(() {
          _customSaveFolder = null;
        });
      } else {
        await prefs.setString('custom_save_folder', folderPath);
        setState(() {
          _customSaveFolder = folderPath;
        });
      }
      // Refresh _saveFolder to reflect new choice
      _saveFolder = await _getDefaultDownloadFolder();
    } catch (_) {}
  }

  Future<String?> _getLocalIpv4() async {
    try {
      final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4, includeLoopback: false);
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          final ip = addr.address;
          if (ip.startsWith('127.') || ip.startsWith('169.254.')) continue;
          if (ip.startsWith('10.') || ip.startsWith('192.168.') || ip.startsWith('172.16.') || ip.startsWith('172.17.') || ip.startsWith('172.18.') || ip.startsWith('172.19.') || ip.startsWith('172.2') || ip.startsWith('172.30.') || ip.startsWith('172.31.')) {
            return ip;
          }
        }
      }
      // Fallback: first non-loopback IPv4
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          final ip = addr.address;
          if (!ip.startsWith('127.') && !ip.startsWith('169.254.')) return ip;
        }
      }
    } catch (_) {}
    return null;
  }

  Future<void> _startWebServer() async {
    try {
      _localIp ??= await _getLocalIpv4();
      _uploadServer?.close(force: true);
      _uploadServer = await HttpServer.bind(InternetAddress.anyIPv4, 8090);
      setState(() { _isHosting = true; });
      await _startForegroundService();
      
      _uploadServer!.listen((HttpRequest request) async {
        final path = request.uri.path;
        if (request.method == 'GET' && (path == '/' || path == '/index.html')) {
          await _serveUploadForm(request);
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
        if (request.method == 'GET' && path.startsWith('/download/')) {
          await _handleDownload(request);
          return;
        }
        if (request.method == 'GET' && path == '/files') {
          await _serveFilesList(request);
          return;
        }
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
      });
      
      _showSnackBar('Web server started! Share the URL with others.');
    } catch (e) {
      setState(() { _isHosting = false; });
      _showSnackBar('Failed to start web server: $e');
    }
  }

  Future<void> _stopWebServer() async {
    await _uploadServer?.close(force: true);
    setState(() { _isHosting = false; });
    _showSnackBar('Web server stopped');
    await _stopForegroundService();
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
    * { box-sizing: border-box; }
    body { 
      margin: 0; 
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; 
      background: linear-gradient(135deg, #000000, #1a1a1a); 
      color: #fff; 
      min-height: 100vh;
    }
    .container { 
      max-width: 600px; 
      margin: 0 auto; 
      padding: 24px; 
      min-height: 100vh;
      display: flex;
      flex-direction: column;
      justify-content: center;
    }
    .card { 
      background: rgba(26, 26, 26, 0.9); 
      border: 2px solid #FFD600; 
      border-radius: 20px; 
      padding: 32px; 
      backdrop-filter: blur(10px);
      box-shadow: 0 20px 40px rgba(0, 0, 0, 0.3);
    }
    .header {
      text-align: center;
      margin-bottom: 24px;
    }
    .logo {
      font-size: 32px;
      font-weight: 700;
      color: #FFD600;
      margin-bottom: 8px;
    }
    .subtitle {
      color: #bbb;
      font-size: 16px;
    }
    .upload-area { 
      border: 2px dashed #555; 
      border-radius: 16px; 
      padding: 32px; 
      text-align: center; 
      background: #111; 
      transition: all 0.3s ease;
      margin: 24px 0;
    }
    .upload-area:hover {
      border-color: #FFD600;
      background: #1a1a1a;
    }
    .upload-area.dragover {
      border-color: #FFD600;
      background: #1a1a1a;
      transform: scale(1.02);
    }
    input[type=file] { 
      display: none;
    }
    .file-input-label {
      display: inline-block;
      padding: 12px 24px;
      background: #FFD600;
      color: #000;
      border-radius: 12px;
      cursor: pointer;
      font-weight: 600;
      transition: all 0.2s;
    }
    .file-input-label:hover {
      background: #ffed4e;
      transform: translateY(-2px);
    }
    .upload-icon {
      font-size: 48px;
      color: #FFD600;
      margin-bottom: 16px;
    }
    .upload-text {
      margin: 16px 0;
      color: #ccc;
      font-size: 18px;
    }
    .upload-hint { 
      margin-top: 16px; 
      color: #888; 
      font-size: 14px; 
    }
    .selected-files {
      margin: 16px 0;
      padding: 16px;
      background: #222;
      border-radius: 12px;
      display: none;
    }
    .file-item {
      padding: 8px 0;
      border-bottom: 1px solid #333;
      display: flex;
      justify-content: space-between;
      align-items: center;
    }
    .file-item:last-child {
      border-bottom: none;
    }
    .file-name {
      color: #fff;
      font-weight: 500;
    }
    .file-size {
      color: #888;
      font-size: 12px;
    }
    .upload-btn { 
      width: 100%; 
      padding: 16px; 
      background: #FFD600; 
      color: #000; 
      border: none; 
      border-radius: 12px; 
      font-weight: 700; 
      font-size: 16px;
      cursor: pointer;
      transition: all 0.2s;
      margin-top: 16px;
    }
    .upload-btn:hover {
      background: #ffed4e;
      transform: translateY(-2px);
    }
    .upload-btn:disabled {
      background: #666;
      color: #999;
      cursor: not-allowed;
      transform: none;
    }
    .progress {
      width: 100%;
      height: 8px;
      background: #333;
      border-radius: 4px;
      overflow: hidden;
      margin: 16px 0;
      display: none;
    }
    .progress-bar {
      height: 100%;
      background: #FFD600;
      width: 0%;
      transition: width 0.3s ease;
    }
    .message { 
      margin-top: 16px; 
      padding: 12px; 
      border-radius: 8px; 
      text-align: center;
      font-weight: 500;
    }
    .success { 
      background: rgba(0, 255, 0, 0.1); 
      color: #0f0; 
      border: 1px solid #0f0;
    }
    .error { 
      background: rgba(255, 102, 102, 0.1); 
      color: #f66; 
      border: 1px solid #f66;
    }
    .stats {
      display: flex;
      justify-content: space-between;
      margin-top: 16px;
      padding: 16px;
      background: #222;
      border-radius: 12px;
    }
    .stat {
      text-align: center;
    }
    .stat-value {
      font-size: 24px;
      font-weight: 700;
      color: #FFD600;
    }
    .stat-label {
      font-size: 12px;
      color: #888;
      margin-top: 4px;
    }
    
    /* Available Files Section */
    .available-files-section {
      margin-top: 32px;
      padding-top: 24px;
      border-top: 1px solid #444;
    }
    
    .available-files {
      max-height: 300px;
      overflow-y: auto;
      border: 1px solid #444;
      border-radius: 8px;
      background: rgba(255, 255, 255, 0.05);
      padding: 8px;
    }
    
    .available-file-item {
      display: flex;
      justify-content: space-between;
      align-items: center;
      padding: 12px;
      margin: 4px 0;
      background: rgba(255, 255, 255, 0.08);
      border-radius: 6px;
      border: 1px solid #555;
    }
    
    .file-info {
      flex: 1;
    }
    
    .file-details {
      color: #ccc;
      font-size: 12px;
      margin-top: 4px;
    }
    
    .download-btn {
      background: #2196F3;
      color: white;
      border: none;
      padding: 6px 12px;
      border-radius: 4px;
      cursor: pointer;
      font-size: 12px;
      font-weight: 500;
      transition: background-color 0.2s;
    }
    
    .download-btn:hover {
      background: #1976D2;
    }
    
    .refresh-btn {
      background: #666;
      color: white;
      border: none;
      padding: 8px 16px;
      border-radius: 6px;
      cursor: pointer;
      font-size: 12px;
      margin-top: 12px;
      width: 100%;
      transition: background-color 0.2s;
    }
    
    .refresh-btn:hover {
      background: #777;
    }
    
    .loading, .no-files, .error {
      text-align: center;
      color: #ccc;
      padding: 20px;
      font-size: 14px;
    }
    
    .error {
      color: #f44336;
    }
  </style>
  <script>
    let selectedFiles = [];
    
    document.addEventListener('DOMContentLoaded', function() {
      const uploadArea = document.getElementById('uploadArea');
      const fileInput = document.getElementById('files');
      const selectedFilesDiv = document.getElementById('selectedFiles');
      const uploadBtn = document.getElementById('uploadBtn');
      const progress = document.getElementById('progress');
      const progressBar = document.getElementById('progressBar');
      const message = document.getElementById('message');
      
      uploadArea.addEventListener('dragover', function(e) {
        e.preventDefault();
        uploadArea.classList.add('dragover');
      });
      uploadArea.addEventListener('dragleave', function(e) {
        e.preventDefault();
        uploadArea.classList.remove('dragover');
      });
      uploadArea.addEventListener('drop', function(e) {
        e.preventDefault();
        uploadArea.classList.remove('dragover');
        handleFiles(e.dataTransfer.files);
      });
      fileInput.addEventListener('change', function(e) {
        handleFiles(e.target.files);
      });
      
      function handleFiles(files) {
        selectedFiles = Array.from(files);
        displaySelectedFiles();
        uploadBtn.disabled = selectedFiles.length === 0;
      }
      
      function displaySelectedFiles() {
        if (selectedFiles.length === 0) {
          selectedFilesDiv.style.display = 'none';
          return;
        }
        selectedFilesDiv.style.display = 'block';
        selectedFilesDiv.innerHTML = '<h4 style="margin: 0 0 12px 0; color: #FFD600;">Selected Files:</h4>';
        selectedFiles.forEach(file => {
          const fileItem = document.createElement('div');
          fileItem.className = 'file-item';
          fileItem.innerHTML = `
            <div>
              <div class="file-name">\${file.name}</div>
              <div class="file-size">\${formatFileSize(file.size)}</div>
            </div>
          `;
          selectedFilesDiv.appendChild(fileItem);
        });
      }
      
      function formatFileSize(bytes) {
        if (bytes === 0) return '0 Bytes';
        const k = 1024;
        const sizes = ['Bytes', 'KB', 'MB', 'GB'];
        const i = Math.floor(Math.log(bytes) / Math.log(k));
        return parseFloat((bytes / Math.pow(k, i)).toFixed(2)) + ' ' + sizes[i];
      }
      
      uploadBtn.addEventListener('click', async () => {
        if (selectedFiles.length === 0) return;
        uploadBtn.disabled = true;
        progress.style.display = 'block';
        message.innerHTML = '';
        
        try {
          // Ask device for permission
          const meta = selectedFiles.map(f => ({ name: f.name, size: f.size }));
          const approveResp = await fetch('/request-upload', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ files: meta })
          });
          const approve = await approveResp.json();
          if (!approve.approved) {
            message.innerHTML = '<div class="message error">Upload denied on device</div>';
            progress.style.display = 'none';
            uploadBtn.disabled = false;
            return;
          }

          // Build per-file progress list
          let list = document.getElementById('file-progress-list');
          if (!list) {
            list = document.createElement('div');
            list.id = 'file-progress-list';
            list.style.marginTop = '16px';
            selectedFilesDiv.appendChild(list);
          }
          list.innerHTML = '';

          const items = [];
          selectedFiles.forEach((file, i) => {
            const wrapper = document.createElement('div');
            wrapper.style.cssText = 'margin:8px 0; padding:8px; background: rgba(255,255,255,0.05); border-radius:8px;';
            wrapper.innerHTML = `
              <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:6px;">
                <div>
                  <div style="color:#fff; font-weight:500; font-size:14px;">\${file.name}</div>
                  <div style="color:#ccc; font-size:12px;">\${formatFileSize(file.size)}</div>
                </div>
                <div style="display:flex; align-items:center;">
                  <div style="width:140px; height:6px; background: rgba(255,255,255,0.2); border-radius:3px; margin-right:10px;">
                    <div id="fpb-\${i}" style="width:0%; height:100%; background:#FFD600; border-radius:3px;"></div>
                  </div>
                  <span id="fpp-\${i}" style="color:#FFD600; font-weight:600; font-size:12px; width:40px; text-align:right;">0%</span>
                </div>
              </div>`;
            list.appendChild(wrapper);
            items.push({ barId: `fpb-\${i}`, pctId: `fpp-\${i}` });
          });

          function updateOverall(currentIndex, currentFraction) {
            const overall = ((currentIndex + currentFraction) / selectedFiles.length) * 100;
            progressBar.style.width = overall + '%';
          }

          function uploadFileWithProgress(file, idx) {
            return new Promise((resolve) => {
              const xhr = new XMLHttpRequest();
              xhr.open('PUT', `/upload?name=\${encodeURIComponent(file.name)}`);
              xhr.upload.onprogress = (e) => {
                if (e.lengthComputable) {
                  const pct = Math.min(100, Math.max(0, Math.round((e.loaded / e.total) * 100)));
                  const bar = document.getElementById(items[idx].barId);
                  const pctEl = document.getElementById(items[idx].pctId);
                  if (bar) bar.style.width = pct + '%';
                  if (pctEl) pctEl.textContent = pct + '%';
                  updateOverall(idx, e.total ? (e.loaded / e.total) : 0);
                }
              };
              xhr.onload = () => {
                const bar = document.getElementById(items[idx].barId);
                const pctEl = document.getElementById(items[idx].pctId);
                if (xhr.status >= 200 && xhr.status < 300) {
                  if (bar) bar.style.background = '#4CAF50';
                  if (pctEl) pctEl.textContent = '100%';
                } else {
                  if (bar) bar.style.background = '#f44336';
                  if (pctEl) pctEl.textContent = '✗';
                  if (pctEl) pctEl.style.color = '#f44336';
                }
                updateOverall(idx + 1, 0);
                resolve(xhr.status >= 200 && xhr.status < 300);
              };
              xhr.onerror = () => {
                const bar = document.getElementById(items[idx].barId);
                const pctEl = document.getElementById(items[idx].pctId);
                if (bar) bar.style.background = '#f44336';
                if (pctEl) pctEl.textContent = '✗';
                if (pctEl) pctEl.style.color = '#f44336';
                updateOverall(idx + 1, 0);
                resolve(false);
              };
              xhr.send(file);
            });
          }

          let uploaded = 0;
          for (let i = 0; i < selectedFiles.length; i++) {
            const ok = await uploadFileWithProgress(selectedFiles[i], i);
            if (ok) uploaded++;
          }

          if (uploaded === selectedFiles.length) {
            message.innerHTML = `<div class=\"message success\">Uploaded \${uploaded} file(s) successfully</div>`;
          } else {
            message.innerHTML = `<div class=\"message error\">Uploaded \${uploaded}/\${selectedFiles.length} file(s)</div>`;
          }
        } catch (e) {
          message.innerHTML = `<div class=\"message error\">Upload failed: \${e}</div>`;
        } finally {
          progress.style.display = 'none';
          uploadBtn.disabled = false;
        }
      });
    });
  </script>
</head>
<body>
  <div class="container">
    <div class="card">
      <div class="header">
        <div class="logo">⚡ ZapShare</div>
        <div class="subtitle">Send files to this device</div>
      </div>
      
      <div class="upload-area" id="uploadArea">
        <div class="upload-icon">📁</div>
        <div class="upload-text">Drag & drop files here</div>
        <div>or</div>
        <label for="files" class="file-input-label">Choose Files</label>
        <input id="files" type="file" multiple />
        <div class="upload-hint">Files will be uploaded and ready for download on the device</div>
      </div>
      
      <div id="selectedFiles" class="selected-files"></div>
      
      <div class="progress" id="progress">
        <div class="progress-bar" id="progressBar"></div>
      </div>
      
      <button id="uploadBtn" class="upload-btn" disabled>Send File Previews</button>
      
      <div id="message"></div>
      
      
    </div>
  </div>
  
  <script>
    // Load pending files on page load
    document.addEventListener('DOMContentLoaded', function() {
      loadPendingFiles();
      // Refresh every 3 seconds
      setInterval(loadPendingFiles, 3000);
    });
    
    async function loadPendingFiles() {
      try {
        const response = await fetch('/pending');
        const files = await response.json();
        displayPendingFiles(files);
      } catch (error) {
        console.error('Failed to load pending files:', error);
        document.getElementById('availableFiles').innerHTML = '<div class="error">Failed to load pending files</div>';
      }
    }
    
    function displayPendingFiles(files) {
      const container = document.getElementById('availableFiles');
      
      if (files.length === 0) {
        container.innerHTML = '<div class="no-files">No pending files - upload some files to see them here</div>';
        return;
      }
      
      container.innerHTML = files.map(file => `
        <div class="file-item available-file-item">
          <div class="file-info">
            <div class="file-name">\${file.name}</div>
            <div class="file-details">\${formatFileSize(file.size)} • \${formatDate(file.uploadedAt)} • Pending download</div>
          </div>
          <div style="color: #FFD600; font-size: 12px; font-weight: 500;">
            � Ready on device
          </div>
        </div>
      `).join('');
    }
    
    async function downloadFile(fileName) {
      try {
        const response = await fetch(`/download/\${fileName}`);
        if (response.ok) {
          const blob = await response.blob();
          const url = window.URL.createObjectURL(blob);
          const a = document.createElement('a');
          a.style.display = 'none';
          a.href = url;
          a.download = decodeURIComponent(fileName);
          document.body.appendChild(a);
          a.click();
          window.URL.revokeObjectURL(url);
          document.body.removeChild(a);
        } else {
          alert('Download failed: ' + response.statusText);
        }
      } catch (error) {
        alert('Download failed: ' + error.message);
      }
    }
    
    function formatDate(dateString) {
      const date = new Date(dateString);
      return date.toLocaleTimeString();
    }
  </script>
</body>
</html>
''';
    response.write(html);
    await response.close();
  }

  Future<void> _ensureSaveFolder() async {
    if (_saveFolder == null) {
      _saveFolder = await _getDefaultDownloadFolder();
    }
    final dir = Directory(_saveFolder!);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
  }

  Future<void> _promptForFolderPath() async {
    final controller = TextEditingController(text: _customSaveFolder ?? _saveFolder ?? '');
    final chosen = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: Colors.grey[900],
          title: Text('Set save folder', style: TextStyle(color: Colors.white)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Enter a folder path. If it does not exist, it will be created.', style: TextStyle(color: Colors.grey[400], fontSize: 12)),
              const SizedBox(height: 10),
              TextField(
                controller: controller,
                style: TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  hintText: '/storage/emulated/0/Download/ZapShare',
                  hintStyle: TextStyle(color: Colors.grey[600]),
                  filled: true,
                  fillColor: Colors.grey[850],
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: Colors.grey[800]!)),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(null),
              child: Text('Cancel', style: TextStyle(color: Colors.grey[400])),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(''),
              child: Text('Use Default', style: TextStyle(color: Colors.yellow[300])),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(controller.text.trim()),
              child: Text('Save', style: TextStyle(color: Colors.yellow[300])),
            ),
          ],
        );
      },
    );

    if (chosen == null) return; // cancelled
    if (chosen.isEmpty) {
      await _setCustomFolder(null);
      _showSnackBar('Save folder reset to default');
      return;
    }

    try {
      final dir = Directory(chosen);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      await _setCustomFolder(dir.path);
      _showSnackBar('Save folder set');
    } catch (e) {
      _showSnackBar('Failed to set folder: $e');
    }
  }

  Future<void> _handlePutUpload(HttpRequest request) async {
    try {
      // Enforce approval window
      final now = DateTime.now();
      if (!_uploadApprovalActive || _uploadApprovalExpiresAt == null || now.isAfter(_uploadApprovalExpiresAt!)) {
        request.response.statusCode = HttpStatus.forbidden;
        request.response.headers.set('Access-Control-Allow-Origin', '*');
        request.response.write('Upload not approved on device');
        await request.response.close();
        return;
      }
      // Handle full file transfer
      await _handleFileTransfer(request);
    } catch (e) {
      request.response.statusCode = HttpStatus.internalServerError;
      request.response.write('Upload failed: $e');
      await request.response.close();
    }
  }

  // Handle browser asking for permission to upload files
  Future<void> _handleRequestUpload(HttpRequest request) async {
    try {
      final body = await utf8.decodeStream(request);
      final data = jsonDecode(body);
      final files = (data['files'] as List).cast<Map>().map((m) => {
        'name': m['name'],
        'size': m['size']
      }).toList();

      if (!mounted) {
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.set('Content-Type', 'application/json');
        request.response.headers.set('Access-Control-Allow-Origin', '*');
        request.response.write(jsonEncode({'approved': false}));
        await request.response.close();
        return;
      }

      final approved = await _showUploadApprovalDialog(files);
      if (approved) {
        setState(() {
          _uploadApprovalActive = true;
          _uploadApprovalExpiresAt = DateTime.now().add(const Duration(minutes: 2));
        });
      }

      request.response.statusCode = HttpStatus.ok;
      request.response.headers.set('Content-Type', 'application/json');
      request.response.headers.set('Access-Control-Allow-Origin', '*');
      request.response.write(jsonEncode({'approved': approved}));
      await request.response.close();
    } catch (e) {
      request.response.statusCode = HttpStatus.internalServerError;
      request.response.write('Failed to request approval: $e');
      await request.response.close();
    }
  }

  Future<bool> _showUploadApprovalDialog(List<Map<String, dynamic>> files) async {
    final totalSize = files.fold<int>(0, (sum, f) => sum + (f['size'] as int? ?? 0));
    return await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return AlertDialog(
          backgroundColor: Colors.grey[900],
          title: Text('Allow upload?', style: TextStyle(color: Colors.white)),
          content: SizedBox(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${files.length} file(s) • ${_formatBytes(totalSize)}',
                  style: TextStyle(color: Colors.grey[300]),
                ),
                const SizedBox(height: 12),
                Container(
                  constraints: const BoxConstraints(maxHeight: 180),
                  decoration: BoxDecoration(
                    color: Colors.grey[850],
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.grey[800]!),
                  ),
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: files.length,
                    itemBuilder: (context, index) {
                      final f = files[index];
                      return Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        child: Row(
                          children: [
                            Icon(Icons.insert_drive_file, color: Colors.yellow[300], size: 16),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                '${f['name']}',
                                style: TextStyle(color: Colors.white, fontSize: 13),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              _formatBytes((f['size'] as int?) ?? 0),
                              style: TextStyle(color: Colors.grey[400], fontSize: 12),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'Uploads will be allowed for 2 minutes.',
                  style: TextStyle(color: Colors.grey[500], fontSize: 12),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(context).pop(false);
              },
              child: Text('Deny', style: TextStyle(color: Colors.red[300])),
            ),
            TextButton(
              onPressed: () {
                Navigator.of(context).pop(true);
              },
              child: Text('Allow', style: TextStyle(color: Colors.yellow[300])),
            ),
          ],
        );
      },
    ) ?? false;
  }

  // (Removed preview chunk handler as previews are no longer used)

  // Handle actual file transfer when download is initiated
  Future<void> _handleFileTransfer(HttpRequest request) async {
    try {
      await _ensureSaveFolder();
      final fileName = request.uri.queryParameters['name'] ?? 'unknown_file';
      String savePath = '$_saveFolder/$fileName';
      final totalBytes = request.headers.contentLength; // -1 if unknown
      
      // Handle duplicate filenames
      int count = 1;
      String originalFileName = fileName;
      while (await File(savePath).exists()) {
        final bits = originalFileName.split('.');
        if (bits.length > 1) {
          final base = bits.sublist(0, bits.length - 1).join('.');
          final ext = bits.last;
          savePath = '$_saveFolder/${base}_$count.$ext';
        } else {
          savePath = '$_saveFolder/${originalFileName}_$count';
        }
        count++;
      }
      
      // Prepare ongoing download entry for progress UI
      setState(() {
        _ongoingDownloads[fileName] = ReceivedFile(
          name: fileName,
          size: totalBytes > 0 ? totalBytes : 0,
          path: savePath,
          receivedAt: DateTime.now(),
          progress: 0.0,
          status: 'Receiving... 0%',
          isUploading: true,
        );
      });

      // Save file content directly to final destination
      final file = File(savePath);
      final sink = file.openWrite();
      int bytesReceived = 0;
      var lastUiUpdate = DateTime.now();
      
      await request.listen((chunk) {
        sink.add(chunk);
        bytesReceived += chunk.length;
        // Throttle UI updates to ~10fps
        final now = DateTime.now();
        if (now.difference(lastUiUpdate).inMilliseconds >= 100) {
          lastUiUpdate = now;
          if (mounted) {
            setState(() {
              final entry = _ongoingDownloads[fileName];
              if (entry != null) {
                final hasTotal = totalBytes > 0;
                entry.progress = hasTotal ? (bytesReceived / totalBytes).clamp(0.0, 1.0) : entry.progress;
                entry.status = hasTotal
                    ? 'Receiving... ${((entry.progress) * 100).toInt()}%'
                    : 'Receiving... ${_formatBytes(bytesReceived)}';
              }
            });
          }
          // Update notification
          final hasTotal = totalBytes > 0;
          final pct = hasTotal ? ((bytesReceived / totalBytes) * 100).clamp(0, 100).toInt() : 0;
          final body = hasTotal
              ? 'Receiving $fileName • $pct%'
              : 'Receiving $fileName • ${_formatBytes(bytesReceived)}';
          _showProgressNotification(
            key: fileName,
            title: 'Receiving file',
            body: body,
            progress: hasTotal ? pct : 0,
          );
        }
      }).asFuture();
      
      await sink.close();

      // Add to received files and remove from pending
      setState(() {
        // Remove from ongoing downloads
        _ongoingDownloads.remove(fileName);
        _receivedFiles.insert(0, ReceivedFile(
          name: fileName,
          size: bytesReceived,
          path: savePath,
          receivedAt: DateTime.now(),
          progress: 1.0,
          status: 'Complete',
          isUploading: false,
        ));
        
        // Remove from pending files
        _pendingFiles.removeWhere((pf) => pf.name == fileName);
      });

      // Record transfer history
      try {
        final prefs = await SharedPreferences.getInstance();
        final history = prefs.getStringList('transfer_history') ?? [];
        final entry = {
          'fileName': fileName,
          'fileSize': bytesReceived,
          'direction': 'Received',
          'peer': 'Web Upload',
          'dateTime': DateTime.now().toIso8601String(),
          'fileLocation': savePath,
        };
        history.insert(0, jsonEncode(entry));
        if (history.length > 100) history.removeLast();
        await prefs.setStringList('transfer_history', history);
      } catch (_) {}

      request.response.statusCode = HttpStatus.ok;
      request.response.write('File transfer completed');
      await request.response.close();
      await _cancelProgressNotification(fileName);
      // Stop service if no more transfers and server not hosting
      if (!_isHosting && _ongoingDownloads.isEmpty) {
        await _stopForegroundService();
      }
    } catch (e) {
      request.response.statusCode = HttpStatus.internalServerError;
      request.response.write('File transfer failed: $e');
      await request.response.close();
      // Try to cancel notification on error
      try { await _cancelProgressNotification(request.uri.queryParameters['name'] ?? 'unknown_file'); } catch (_) {}
    }
  }

  // Handle file downloads from web interface
  Future<void> _handleDownload(HttpRequest request) async {
    try {
      final path = request.uri.path;
      final fileName = Uri.decodeComponent(path.substring('/download/'.length));
      
      // Find the file in received files
      final file = _receivedFiles.firstWhere(
        (f) => f.name == fileName,
        orElse: () => throw Exception('File not found'),
      );
      
      final fileObj = File(file.path);
      if (!await fileObj.exists()) {
        request.response.statusCode = HttpStatus.notFound;
        request.response.write('File not found');
        await request.response.close();
        return;
      }
      
      request.response.headers.set('Content-Type', 'application/octet-stream');
      request.response.headers.set('Content-Disposition', 'attachment; filename="$fileName"');
      request.response.headers.set('Content-Length', '${await fileObj.length()}');
      
      await request.response.addStream(fileObj.openRead());
      await request.response.close();
    } catch (e) {
      request.response.statusCode = HttpStatus.internalServerError;
      request.response.write('Download failed: $e');
      await request.response.close();
    }
  }

  // Serve files list as JSON for web interface
  Future<void> _serveFilesList(HttpRequest request) async {
    try {
      final filesList = _receivedFiles.map((file) => {
        'name': file.name,
        'size': file.size,
        'receivedAt': file.receivedAt.toIso8601String(),
        'downloadUrl': '/download/${Uri.encodeComponent(file.name)}',
      }).toList();
      
      request.response.headers.set('Content-Type', 'application/json');
      request.response.headers.set('Access-Control-Allow-Origin', '*');
      request.response.write(jsonEncode(filesList));
      await request.response.close();
    } catch (e) {
      request.response.statusCode = HttpStatus.internalServerError;
      request.response.write('Failed to get files list: $e');
      await request.response.close();
    }
  }

  // (Removed pending files list API as previews/pending list are removed from web UI)

  // (Removed request-file API as uploads are direct after approval)

  // (Removed check-requests API)

  String _formatBytes(int bytes) {
    if (bytes < 1024) return "$bytes B";
    if (bytes < 1024 * 1024) return "${(bytes / 1024).toStringAsFixed(1)} KB";
    if (bytes < 1024 * 1024 * 1024) return "${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB";
    return "${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB";
  }

  String _formatTime(DateTime dateTime) {
    final now = DateTime.now();
    final difference = now.difference(dateTime);
    
    if (difference.inDays > 0) {
      return '${difference.inDays}d ago';
    } else if (difference.inHours > 0) {
      return '${difference.inHours}h ago';
    } else if (difference.inMinutes > 0) {
      return '${difference.inMinutes}m ago';
    } else {
      return 'Just now';
    }
  }

  void _showSnackBar(String message) {
    // Snack bars disabled as requested
  }

  void _showStorageInfo() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.grey[900],
        title: Text(
          'Storage Information',
          style: TextStyle(color: Colors.white),
        ),
        content: Text(
          'Files are received and stored in app storage. Use the "Download" button to copy files to your Downloads folder.',
          style: TextStyle(color: Colors.grey[300]),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(
              'OK',
              style: TextStyle(color: Colors.yellow[300]),
            ),
          ),
        ],
      ),
    );
  }

  void _copyUrlToClipboard() {
    final url = 'http://${_localIp ?? '0.0.0.0'}:8090';
    Clipboard.setData(ClipboardData(text: url));
    _showSnackBar('URL copied to clipboard');
  }

  @override
  void dispose() {
    _uploadServer?.close(force: true);
    _stopForegroundService();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final url = 'http://${_localIp ?? '0.0.0.0'}:8090';
    
    return Scaffold(
      backgroundColor: Colors.black,
      resizeToAvoidBottomInset: false,
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
                      'Web Receive',
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
            ),

            // Main content
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Column(
                  children: [
                    const SizedBox(height: 8),
                    
                    // Server status section
                    _buildServerSection(url),
                    
                    const SizedBox(height: 12),
                    
                    // Swipe tabs for files
                    _buildSwipeTabs(),
                    const SizedBox(height: 12),
                    
                    // Content area with swipe
                    Expanded(
                      child: PageView(
                        controller: _pageController,
                        onPageChanged: (index) {
                          setState(() {
                            _currentTab = index;
                          });
                        },
                        children: [
                          _buildAvailableContent(url),
                          _buildReceivedFilesContent(),
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
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.file_upload,
            color: Colors.grey[600],
            size: 48,
          ),
          const SizedBox(height: 16),
          Text(
            'No files received yet',
            style: TextStyle(
              color: Colors.grey[400],
              fontSize: 16,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Files uploaded through the web interface\nwill appear here',
            style: TextStyle(
              color: Colors.grey[600],
              fontSize: 14,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Future<void> _openFile(ReceivedFile file) async {
    try {
      final result = await OpenFile.open(file.path);
      if (result.type != ResultType.done) {
        _showSnackBar('No app found to open this file');
      }
    } catch (e) {
      _showSnackBar('Error opening file: $e');
    }
  }

  // Server section - compact design
  Widget _buildServerSection(String url) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.grey[900],
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey[800]!, width: 1),
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                Row(
                  children: [
                    Container(
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(
                        color: _isHosting ? Colors.yellow[300] : Colors.red,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        _isHosting ? 'Web Server Running' : 'Web Server Stopped',
                        style: TextStyle(
                          color: _isHosting ? Colors.yellow[300] : Colors.red,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    ElevatedButton(
                      onPressed: _isHosting ? _stopWebServer : _startWebServer,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _isHosting ? Colors.red : Colors.yellow[300],
                        foregroundColor: _isHosting ? Colors.white : Colors.black,
                        padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        minimumSize: Size(0, 32),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      child: Text(
                        _isHosting ? 'Stop' : 'Start',
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
                if (_isHosting) ...[
                  const SizedBox(height: 16),
                  GestureDetector(
                    onTap: _copyUrlToClipboard,
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.grey[800],
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.grey[700]!),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.link,
                            color: Colors.yellow[300],
                            size: 16,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              url,
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 14,
                                fontWeight: FontWeight.w500,
                                fontFamily: 'monospace',
                              ),
                            ),
                          ),
                          Icon(
                            Icons.copy,
                            color: Colors.grey[400],
                            size: 14,
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Share this URL with others to let them upload files',
                    style: TextStyle(
                      color: Colors.grey[400],
                      fontSize: 12,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
                
                // Save Location
                const SizedBox(height: 16),
                Row(
                  children: [
                    Icon(
                      Icons.folder,
                      color: Colors.yellow[300],
                      size: 16,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Save Location',
                            style: TextStyle(
                              color: Colors.grey[400],
                              fontSize: 11,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          Text(
                            _customSaveFolder != null && _customSaveFolder!.isNotEmpty
                                ? _customSaveFolder!
                                : 'Download/ZapShare',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                    // Change/Info buttons
                    IconButton(
                      onPressed: () => _promptForFolderPath(),
                      style: IconButton.styleFrom(
                        minimumSize: Size(28, 28),
                        padding: EdgeInsets.all(4),
                      ),
                      icon: Icon(Icons.create_new_folder_outlined, color: Colors.yellow[300], size: 18),
                    ),
                    IconButton(
                      onPressed: () => _showStorageInfo(),
                      style: IconButton.styleFrom(minimumSize: Size(28, 28), padding: EdgeInsets.all(4)),
                      icon: Icon(Icons.info_outline, color: Colors.grey[400], size: 16),
                    )
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // Swipe tabs matching AndroidReceiveScreen
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
              // Available Tab
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
                            Icons.wifi_tethering,
                            color: _currentTab == 0 ? Colors.black : Colors.grey[400],
                            size: 18,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            isCompact ? 'Available' : 'Available',
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
              // Received Files Tab
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
                                ? 'Pending (${_pendingFiles.length})'
                                : 'Received (${_receivedFiles.length + _ongoingDownloads.length})',
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

  // Available content
  // Available content - shows pending files ready for download
  Widget _buildAvailableContent(String url) {
    return Container(
      margin: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.grey[900],
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey[800]!, width: 1),
      ),
      child: Column(
        children: [
          // Server status header
          Container(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                Row(
                  children: [
                    Icon(
                      _isHosting ? Icons.cloud_upload : Icons.cloud_off,
                      color: _isHosting ? Colors.yellow[300] : Colors.grey[600],
                      size: 24,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        _isHosting ? 'Server Running - Files Available' : 'Server Stopped',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    ElevatedButton(
                      onPressed: _isHosting ? _stopWebServer : _startWebServer,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _isHosting ? Colors.red : Colors.yellow[300],
                        foregroundColor: _isHosting ? Colors.white : Colors.black,
                        padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        minimumSize: Size(0, 32),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      child: Text(
                        _isHosting ? 'Stop' : 'Start',
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
                if (_isHosting) ...[
                  const SizedBox(height: 16),
                  if (_pendingFiles.isEmpty) ...[
                    Container(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        children: [
                          Icon(
                            Icons.upload_file,
                            color: Colors.grey[600],
                            size: 48,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            'No files uploaded yet',
                            style: TextStyle(
                              color: Colors.grey[400],
                              fontSize: 16,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Files will appear here when uploaded from web browsers',
                            style: TextStyle(
                              color: Colors.grey[500],
                              fontSize: 12,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    ),
                  ] else ...[
                    // Download selected files button
                    if (_pendingFiles.any((f) => f.isSelected)) 
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: SizedBox(
                          width: double.infinity,
                          child: ElevatedButton(
                            onPressed: _startSelectedDownloads,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.yellow[300],
                              foregroundColor: Colors.black,
                              padding: EdgeInsets.symmetric(vertical: 12),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
                            ),
                            child: Text(
                              'Download Selected Files (${_pendingFiles.where((f) => f.isSelected).length})',
                              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                            ),
                          ),
                        ),
                      ),
                  ],
                ],
              ],
            ),
          ),
          
          // Ongoing transfers summary with progress (Android UI)
          if (_ongoingDownloads.isNotEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.downloading, color: Colors.yellow[300], size: 18),
                      const SizedBox(width: 8),
                      Text(
                        'Receiving ${_ongoingDownloads.length} file(s)...',
                        style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  ..._ongoingDownloads.values.map((file) {
                    final progressPercent = (file.progress * 100).clamp(0, 100).toInt();
                    return Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.grey[850],
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.grey[800]!, width: 1),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  file.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                '${progressPercent}%',
                                style: TextStyle(color: Colors.yellow[300], fontSize: 12, fontWeight: FontWeight.w600),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Container(
                            height: 6,
                            decoration: BoxDecoration(
                              color: Colors.grey[700],
                              borderRadius: BorderRadius.circular(3),
                            ),
                            child: FractionallySizedBox(
                              widthFactor: file.progress,
                              alignment: Alignment.centerLeft,
                              child: Container(
                                decoration: BoxDecoration(
                                  color: Colors.yellow[300],
                                  borderRadius: BorderRadius.circular(3),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            file.status,
                            style: TextStyle(color: Colors.grey[400], fontSize: 11),
                          ),
                        ],
                      ),
                    );
                  }).toList(),
                ],
              ),
            ),

          // Files list - show pending files
          if (_isHosting && _pendingFiles.isNotEmpty) 
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                itemCount: _pendingFiles.length,
                itemBuilder: (context, index) {
                  final file = _pendingFiles[index];
                  return _buildPendingFileItem(file, index);
                },
              ),
            ),
            
          if (!_isHosting)
            Expanded(
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.cloud_off,
                      color: Colors.grey[600],
                      size: 64,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Server Stopped',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Start the server to begin receiving files',
                      style: TextStyle(
                        color: Colors.grey[400],
                        fontSize: 14,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  // Pending file item with selection checkbox
  Widget _buildPendingFileItem(PendingFile file, int index) {
    final screenWidth = MediaQuery.of(context).size.width;
    final isCompact = screenWidth < 400;
    
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 3),
      padding: EdgeInsets.all(isCompact ? 10 : 12),
      decoration: BoxDecoration(
        color: file.isSelected ? Colors.grey[800] : Colors.grey[850],
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: file.isSelected ? Colors.yellow[300]! : Colors.grey[700]!, 
          width: file.isSelected ? 2 : 1,
        ),
      ),
      child: Row(
        children: [
          // Selection checkbox
          Checkbox(
            value: file.isSelected,
            onChanged: (value) {
              setState(() {
                file.isSelected = value ?? false;
              });
            },
            activeColor: Colors.yellow[300],
            checkColor: Colors.black,
          ),
          const SizedBox(width: 8),
          
          // File type icon
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.grey[700],
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              _getFileTypeIcon(file.fileType),
              color: Colors.yellow[300],
              size: isCompact ? 20 : 24,
            ),
          ),
          const SizedBox(width: 12),
          
          // File info
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  file.name,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: isCompact ? 13 : 14,
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                Text(
                  '${_formatBytes(file.size)} • ${_formatTime(file.uploadedAt)}',
                  style: TextStyle(
                    color: Colors.grey[400],
                    fontSize: isCompact ? 11 : 12,
                  ),
                ),
              ],
            ),
          ),
          
          // Remove button
          IconButton(
            onPressed: () => _removePendingFile(index),
            icon: Icon(
              Icons.delete_outline,
              color: Colors.red[400],
              size: 20,
            ),
            tooltip: 'Remove file',
          ),
        ],
      ),
    );
  }

  // Start downloading selected files - now triggers file transfer from browser
  Future<void> _startSelectedDownloads() async {
    final selectedFiles = _pendingFiles.where((f) => f.isSelected).toList();
    if (selectedFiles.isEmpty) return;

    await _ensureSaveFolder();
    
    for (final pendingFile in selectedFiles) {
      await _requestFileFromBrowser(pendingFile);
    }
  }

  // Request actual file transfer from browser
  Future<void> _requestFileFromBrowser(PendingFile pendingFile) async {
    try {
      setState(() {
        // Add to ongoing downloads to show progress
        _ongoingDownloads[pendingFile.id] = ReceivedFile(
          name: pendingFile.name,
          size: pendingFile.size,
          path: 'requesting...',
          receivedAt: DateTime.now(),
          progress: 0.0,
          status: 'Requesting file from browser...',
          isUploading: true,
        );
      });

      // Register file request - browser will poll and send file when detected
      final requestData = jsonEncode({'fileName': pendingFile.name});
      final response = await HttpClient().postUrl(Uri.parse('http://localhost:8090/request-file'))
        ..headers.contentType = ContentType.json
        ..write(requestData);
      
      await response.close();
      
      _showSnackBar('Requesting ${pendingFile.name} from browser...');
      
    } catch (e) {
      setState(() {
        _ongoingDownloads.remove(pendingFile.id);
      });
      _showSnackBar('Failed to request ${pendingFile.name}: $e');
    }
  }

  // Remove pending file
  void _removePendingFile(int index) {
    final file = _pendingFiles[index];
    
    setState(() {
      _pendingFiles.removeAt(index);
    });
    
    _showSnackBar('${file.name} removed');
  }


  // Received files content matching AndroidReceiveScreen style
  Widget _buildReceivedFilesContent() {
    // Combine ongoing downloads and received files
    final allFiles = <ReceivedFile>[
      ..._ongoingDownloads.values.toList(),
      ..._receivedFiles,
    ];
    
    if (allFiles.isEmpty) {
      return Container(
        margin: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: Colors.grey[900],
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.grey[800]!, width: 1),
        ),
        child: _buildEmptyState(),
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
        itemCount: allFiles.length,
        itemBuilder: (context, index) {
          final file = allFiles[index];
          return _buildReceivedFileItem(file);
        },
      ),
    );
  }

  // File item matching AndroidReceiveScreen style
  Widget _buildReceivedFileItem(ReceivedFile file) {
    final fileType = _getFileType(file.name);
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
                  file.name,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: isCompact ? 15 : 16,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                // Show progress bar if uploading
                if (file.isUploading) ...[
                  Container(
                    height: 4,
                    width: double.infinity,
                    margin: const EdgeInsets.symmetric(vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.grey[700],
                      borderRadius: BorderRadius.circular(2),
                    ),
                    child: Stack(
                      children: [
                        Container(
                          height: 4,
                          width: double.infinity,
                          decoration: BoxDecoration(
                            color: Colors.grey[700],
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                        FractionallySizedBox(
                          widthFactor: file.progress,
                          child: Container(
                            height: 4,
                            decoration: BoxDecoration(
                              color: Colors.yellow[300],
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Row(
                    children: [
                      Text(
                        file.status,
                        style: TextStyle(
                          color: Colors.yellow[300],
                          fontSize: isCompact ? 11 : 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        '${(file.progress * 100).toInt()}%',
                        style: TextStyle(
                          color: Colors.yellow[300],
                          fontSize: isCompact ? 11 : 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ] else ...[
                  Row(
                    children: [
                      Text(
                        _formatBytes(file.size),
                        style: TextStyle(
                          color: Colors.grey,
                          fontSize: isCompact ? 12 : 13,
                          fontWeight: FontWeight.w400,
                        ),
                      ),
                      Text(
                        ' • ',
                        style: TextStyle(
                          color: Colors.grey[600],
                          fontSize: isCompact ? 12 : 13,
                        ),
                      ),
                      Text(
                        _formatTime(file.receivedAt),
                        style: TextStyle(
                          color: Colors.grey,
                          fontSize: isCompact ? 12 : 13,
                          fontWeight: FontWeight.w400,
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          
          // Open button (only show for completed files)
          if (!file.isUploading)
            GestureDetector(
              onTap: () => _openFile(file),
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
          // Progress indicator for uploading files
          if (file.isUploading)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.grey[700],
                borderRadius: BorderRadius.circular(6),
              ),
              child: SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation<Color>(Colors.yellow[300]!),
                ),
              ),
            ),
        ],
      ),
    );
  }

  // Get file type category (matching AndroidReceiveScreen)
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

  // Get file type icon (matching AndroidReceiveScreen)
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
}
