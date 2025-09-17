import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:open_file/open_file.dart';

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
  
  List<ReceivedFile> _receivedFiles = [];
  Map<String, ReceivedFile> _ongoingUploads = {}; // Track uploads in progress
  int _currentTab = 0; // 0 = Available, 1 = Received Files
  final PageController _pageController = PageController();
  
  @override
  void initState() {
    super.initState();
    _initializeServer();
  }

  Future<void> _initializeServer() async {
    await _requestStoragePermissions();
    _saveFolder = await _getDefaultDownloadFolder();
    await _startWebServer();
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

  Future<String> _getDefaultDownloadFolder() async {
    try {
      // Use app's document directory for received files (not public Downloads)
      final appDir = await getApplicationDocumentsDirectory();
      final receivedDir = Directory('${appDir.path}/ReceivedFiles');
      
      if (!await receivedDir.exists()) {
        await receivedDir.create(recursive: true);
      }
      
      return receivedDir.path;
    } catch (e) {
      print('Error getting app folder: $e');
      // Fallback to a private folder in app storage
      final receivedDir = Directory('/data/data/com.example.zapshare/ReceivedFiles');
      if (!await receivedDir.exists()) {
        await receivedDir.create(recursive: true);
      }
      return receivedDir.path;
    }
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
      
      _uploadServer!.listen((HttpRequest request) async {
        final path = request.uri.path;
        if (request.method == 'GET' && (path == '/' || path == '/index.html')) {
          await _serveUploadForm(request);
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
      
      // Drag and drop functionality
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
      
      uploadBtn.addEventListener('click', uploadFiles);
      
      async function uploadFiles() {
        if (selectedFiles.length === 0) return;
        
        uploadBtn.disabled = true;
        progress.style.display = 'block';
        message.innerHTML = '';
        
        let uploaded = 0;
        let failed = 0;
        const totalFiles = selectedFiles.length;
        
        // Add individual file progress display
        const progressDiv = document.createElement('div');
        progressDiv.id = 'file-progress-list';
        progressDiv.style.marginTop = '16px';
        selectedFilesDiv.appendChild(progressDiv);
        
        for (let i = 0; i < selectedFiles.length; i++) {
          const file = selectedFiles[i];
          
          // Create progress item for each file
          const fileProgressItem = document.createElement('div');
          fileProgressItem.className = 'file-progress-item';
          fileProgressItem.innerHTML = `
            <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 8px; padding: 8px; background: rgba(255, 255, 255, 0.05); border-radius: 8px;">
              <div>
                <div style="color: white; font-weight: 500; font-size: 14px;">\${file.name}</div>
                <div style="color: #ccc; font-size: 12px;">\${formatFileSize(file.size)}</div>
              </div>
              <div style="display: flex; align-items: center;">
                <div style="width: 100px; height: 6px; background: rgba(255, 255, 255, 0.2); border-radius: 3px; margin-right: 12px;">
                  <div id="file-progress-\${i}" style="width: 0%; height: 100%; background: #FFD600; border-radius: 3px; transition: width 0.3s;"></div>
                </div>
                <span id="file-percent-\${i}" style="color: #FFD600; font-weight: 500; font-size: 12px; width: 40px;">0%</span>
              </div>
            </div>
          `;
          progressDiv.appendChild(fileProgressItem);
          
          try {
            const xhr = new XMLHttpRequest();
            
            // Track upload progress
            xhr.upload.addEventListener('progress', function(e) {
              if (e.lengthComputable) {
                const percent = Math.round((e.loaded / e.total) * 100);
                const progressBar = document.getElementById(`file-progress-\${i}`);
                const percentText = document.getElementById(`file-percent-\${i}`);
                if (progressBar && percentText) {
                  progressBar.style.width = percent + '%';
                  percentText.textContent = percent + '%';
                }
              }
            });
            
            const uploadPromise = new Promise((resolve, reject) => {
              xhr.onload = function() {
                if (xhr.status === 200) {
                  uploaded++;
                  // Mark as completed
                  const progressBar = document.getElementById(`file-progress-\${i}`);
                  const percentText = document.getElementById(`file-percent-\${i}`);
                  if (progressBar && percentText) {
                    progressBar.style.background = '#4CAF50';
                    percentText.textContent = '✓';
                    percentText.style.color = '#4CAF50';
                  }
                  resolve();
                } else {
                  failed++;
                  // Mark as failed
                  const progressBar = document.getElementById(`file-progress-\${i}`);
                  const percentText = document.getElementById(`file-percent-\${i}`);
                  if (progressBar && percentText) {
                    progressBar.style.background = '#f44336';
                    percentText.textContent = '✗';
                    percentText.style.color = '#f44336';
                  }
                  reject();
                }
              };
              
              xhr.onerror = function() {
                failed++;
                // Mark as failed
                const progressBar = document.getElementById(`file-progress-\${i}`);
                const percentText = document.getElementById(`file-percent-\${i}`);
                if (progressBar && percentText) {
                  progressBar.style.background = '#f44336';
                  percentText.textContent = '✗';
                  percentText.style.color = '#f44336';
                }
                reject();
              };
            });
            
            xhr.open('PUT', '/upload?name=' + encodeURIComponent(file.name));
            xhr.send(file);
            
            await uploadPromise;
          } catch (error) {
            // Error already handled in xhr.onerror
          }
          
          // Update overall progress
          const overallPercent = ((i + 1) / totalFiles) * 100;
          progressBar.style.width = overallPercent + '%';
        }
        
        progress.style.display = 'none';
        uploadBtn.disabled = false;
        
        if (failed === 0) {
          message.innerHTML = `<div class="message success">Successfully uploaded \${uploaded} file\${uploaded !== 1 ? 's' : ''}!</div>`;
        } else {
          message.innerHTML = `<div class="message error">Uploaded \${uploaded} file\${uploaded !== 1 ? 's' : ''}, \${failed} failed</div>`;
        }
        
        // Clear selection after upload (after a delay to show results)
        setTimeout(() => {
          selectedFiles = [];
          fileInput.value = '';
          selectedFilesDiv.style.display = 'none';
          uploadBtn.disabled = true;
        }, 3000);
      }
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
        <div class="upload-hint">Files will be received and stored in the app</div>
      </div>
      
      <div id="selectedFiles" class="selected-files"></div>
      
      <div class="progress" id="progress">
        <div class="progress-bar" id="progressBar"></div>
      </div>
      
      <button id="uploadBtn" class="upload-btn" disabled>Upload Files</button>
      
      <div id="message"></div>
      
      <!-- Available Files Section -->
      <div class="available-files-section">
        <h3 style="color: white; margin: 24px 0 16px 0; text-align: center;">Available Files</h3>
        <div id="availableFiles" class="available-files">
          <div class="loading">Loading available files...</div>
        </div>
        <button id="refreshBtn" class="refresh-btn" onclick="loadAvailableFiles()">Refresh Files</button>
      </div>
    </div>
  </div>
  
  <script>
    // Load available files on page load
    document.addEventListener('DOMContentLoaded', function() {
      loadAvailableFiles();
      // Refresh every 5 seconds
      setInterval(loadAvailableFiles, 5000);
    });
    
    async function loadAvailableFiles() {
      try {
        const response = await fetch('/files');
        const files = await response.json();
        displayAvailableFiles(files);
      } catch (error) {
        console.error('Failed to load files:', error);
        document.getElementById('availableFiles').innerHTML = '<div class="error">Failed to load files</div>';
      }
    }
    
    function displayAvailableFiles(files) {
      const container = document.getElementById('availableFiles');
      
      if (files.length === 0) {
        container.innerHTML = '<div class="no-files">No files available</div>';
        return;
      }
      
      container.innerHTML = files.map(file => `
        <div class="file-item available-file-item">
          <div class="file-info">
            <div class="file-name">\${file.name}</div>
            <div class="file-details">\${formatFileSize(file.size)} • \${formatDate(file.receivedAt)}</div>
          </div>
          <button class="download-btn" onclick="downloadFile('\${encodeURIComponent(file.name)}')">
            📥 Download
          </button>
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

  Future<void> _handlePutUpload(HttpRequest request) async {
    try {
      await _ensureSaveFolder();
      String fileName = request.uri.queryParameters['name'] ?? 'upload_${DateTime.now().millisecondsSinceEpoch}.bin';
      fileName = fileName.split('/').last.split('\\').last;
      String savePath = '$_saveFolder/$fileName';
      
      // Handle duplicate filenames
      int count = 1;
      String originalFileName = fileName;
      while (await File(savePath).exists()) {
        final bits = originalFileName.split('.');
        if (bits.length > 1) {
          final base = bits.sublist(0, bits.length - 1).join('.');
          final ext = bits.last;
          fileName = '${base}_$count.$ext';
          savePath = '$_saveFolder/$fileName';
        } else {
          fileName = '${originalFileName}_$count';
          savePath = '$_saveFolder/$fileName';
        }
        count++;
      }
      
      // Get content length for progress tracking
      final contentLength = request.contentLength;
      
      // Create an uploading file entry
      final uploadingFile = ReceivedFile(
        name: fileName,
        size: contentLength > 0 ? contentLength : 0,
        path: savePath,
        receivedAt: DateTime.now(),
        progress: 0.0,
        status: 'Receiving',
        isUploading: true,
      );
      
      final uploadId = '${fileName}_${DateTime.now().millisecondsSinceEpoch}';
      
      setState(() {
        _ongoingUploads[uploadId] = uploadingFile;
      });
      
      final file = File(savePath);
      final sink = file.openWrite();
      int bytesReceived = 0;
      
      await request.listen((chunk) {
        sink.add(chunk);
        bytesReceived += chunk.length;
        
        // Update progress
        if (contentLength > 0) {
          final progress = bytesReceived / contentLength;
          setState(() {
            if (_ongoingUploads.containsKey(uploadId)) {
              _ongoingUploads[uploadId] = ReceivedFile(
                name: fileName,
                size: contentLength,
                path: savePath,
                receivedAt: uploadingFile.receivedAt,
                progress: progress,
                status: progress >= 1.0 ? 'Complete' : 'Receiving',
                isUploading: progress < 1.0,
              );
            }
          });
        }
      }).asFuture();
      
      await sink.close();

      // Remove from ongoing uploads and add to received files
      setState(() {
        _ongoingUploads.remove(uploadId);
        _receivedFiles.insert(0, ReceivedFile(
          name: fileName,
          size: bytesReceived,
          path: savePath,
          receivedAt: DateTime.now(),
          progress: 1.0,
          status: 'Complete',
          isUploading: false,
        ));
        // Keep only last 20 files in the list to avoid memory issues
        if (_receivedFiles.length > 20) {
          _receivedFiles = _receivedFiles.take(20).toList();
        }
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
      request.response.write('File uploaded successfully');
      await request.response.close();
    } catch (e) {
      request.response.statusCode = HttpStatus.internalServerError;
      request.response.write('Upload failed: $e');
      await request.response.close();
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

  String _formatBytes(int bytes) {
    if (bytes < 1024) return "$bytes B";
    if (bytes < 1024 * 1024) return "${(bytes / 1024).toStringAsFixed(1)} KB";
    if (bytes < 1024 * 1024 * 1024) return "${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB";
    return "${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB";
  }

  void _showSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.grey[800],
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
        margin: EdgeInsets.all(16),
      ),
    );
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

  // Start download - copy from app storage to public Downloads folder
  Future<void> _startDownload(ReceivedFile file) async {
    try {
      _showSnackBar('Starting download: ${file.name}');
      
      // Get the public Downloads directory
      final publicDownloadsPath = '/storage/emulated/0/Download';
      final zapShareDownloadsDir = Directory('$publicDownloadsPath/ZapShare');
      
      // Ensure ZapShare Downloads folder exists
      if (!await zapShareDownloadsDir.exists()) {
        await zapShareDownloadsDir.create(recursive: true);
      }
      
      // Copy file from app storage to Downloads
      final originalFile = File(file.path);
      if (await originalFile.exists()) {
        // Handle duplicate names in downloads
        String finalPath = '${zapShareDownloadsDir.path}/${file.name}';
        int count = 1;
        while (await File(finalPath).exists()) {
          final bits = file.name.split('.');
          if (bits.length > 1) {
            final base = bits.sublist(0, bits.length - 1).join('.');
            final ext = bits.last;
            finalPath = '${zapShareDownloadsDir.path}/${base}_$count.$ext';
          } else {
            finalPath = '${zapShareDownloadsDir.path}/${file.name}_$count';
          }
          count++;
        }
        
        await originalFile.copy(finalPath);
        _showSnackBar('Downloaded to Downloads/ZapShare: ${finalPath.split('/').last}');
      } else {
        _showSnackBar('File not found: ${file.name}');
      }
    } catch (e) {
      _showSnackBar('Download failed: $e');
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
                            'Received Files',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                    // Info button instead of change folder
                    IconButton(
                      onPressed: () => _showStorageInfo(),
                      style: IconButton.styleFrom(
                        minimumSize: Size(28, 28),
                        padding: EdgeInsets.all(4),
                      ),
                      icon: Icon(
                        Icons.info_outline,
                        color: Colors.grey[400],
                        size: 16,
                      ),
                    ),
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
                                ? 'Files (${_receivedFiles.length + _ongoingUploads.length})'
                                : 'Received (${_receivedFiles.length + _ongoingUploads.length})',
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
  // Available content - shows ongoing uploads and all available files
  Widget _buildAvailableContent(String url) {
    // Combine ongoing uploads and received files
    final allFiles = <ReceivedFile>[
      ..._ongoingUploads.values.toList(),
      ..._receivedFiles,
    ];
    
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
                  if (allFiles.isEmpty) ...[
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
                            'No files available yet',
                            style: TextStyle(
                              color: Colors.grey[400],
                              fontSize: 16,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Files will appear here as they are uploaded',
                            style: TextStyle(
                              color: Colors.grey[500],
                              fontSize: 12,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ],
            ),
          ),
          
          // Files list
          if (_isHosting && allFiles.isNotEmpty) 
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                itemCount: allFiles.length,
                itemBuilder: (context, index) {
                  final file = allFiles[index];
                  return _buildAvailableFileItem(file);
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

  // Available file item with download option
  Widget _buildAvailableFileItem(ReceivedFile file) {
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
          
          // Action buttons
          if (!file.isUploading) ...[
            // Download button
            GestureDetector(
              onTap: () => _startDownload(file),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                margin: const EdgeInsets.only(right: 8),
                decoration: BoxDecoration(
                  color: Colors.blue[600],
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.download,
                      color: Colors.white,
                      size: 14,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      'Download',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            // Open button
            GestureDetector(
              onTap: () => _openFile(file),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.yellow[300],
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  'Open',
                  style: TextStyle(
                    color: Colors.black,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ],
          
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

  // Received files content matching AndroidReceiveScreen style
  Widget _buildReceivedFilesContent() {
    // Combine ongoing uploads and received files
    final allFiles = <ReceivedFile>[
      ..._ongoingUploads.values.toList(),
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
