import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:flutter/services.dart';
import 'dart:convert';

const Color kAccentYellow = Color(0xFFFFD600);

class WindowsFileShareScreen extends StatefulWidget {
  const WindowsFileShareScreen({super.key});
  @override
  State<WindowsFileShareScreen> createState() => _WindowsFileShareScreenState();
}

class _WindowsFileShareScreenState extends State<WindowsFileShareScreen> {
  List<PlatformFile> _files = [];
  bool _loading = false;
  HttpServer? _server;
  String? _localIp;
  bool _isSharing = false;
  List<double> _progressList = [];
  List<bool> _isPausedList = []; // Add pause state tracking
  String? _displayCode;
  bool _isDragOver = false; // Track drag and drop state
  static const MethodChannel _channel = MethodChannel('zapshare/drag_drop');

  final _pageController = PageController();
  // Removed: bool _isNavExpanded = false;
  // Removed: int _selectedNavIndex = 0;

  String _ipToCode(String ip) {
    final parts = ip.split('.').map(int.parse).toList();
    if (parts.length != 4) return '';
    int n = (parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3];
    String code = n.toRadixString(36).toUpperCase();
    return code.padLeft(8, '0');
  }

  @override
  void initState() {
    super.initState();
    _fetchLocalIp();
    _setupDragDrop();
  }

  void _setupDragDrop() {
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onFilesDropped':
          final List<dynamic> filePaths = call.arguments;
          final List<String> paths = filePaths.cast<String>();
          _handleDroppedFiles(paths);
          // Show a brief visual feedback
          setState(() {
            _isDragOver = true;
          });
          Future.delayed(Duration(milliseconds: 500), () {
            if (mounted) {
              setState(() {
                _isDragOver = false;
              });
            }
          });
          break;
        case 'onDragEnter':
          setState(() {
            _isDragOver = true;
          });
          break;
        case 'onDragLeave':
          setState(() {
            _isDragOver = false;
          });
          break;
      }
    });
  }

  Future<void> _fetchLocalIp() async {
    String? bestIp;
    List<String> allIps = [];
    
    try {
      // Get all network interfaces
      final interfaces = await NetworkInterface.list(
        includeLinkLocal: false,
        type: InternetAddressType.IPv4,
      );
      
      // Look for the best IP address for sharing
      for (final interface in interfaces) {
        for (final addr in interface.addresses) {
          final ip = addr.address;
          allIps.add('${interface.name}: $ip');
          
          // Skip localhost and loopback
          if (ip == '127.0.0.1' || ip == 'localhost') continue;
          
          // Skip link-local addresses (169.254.x.x)
          if (ip.startsWith('169.254.')) continue;
          
          // Skip APIPA addresses
          if (ip.startsWith('169.254.')) continue;
          
          // Prefer certain IP ranges for sharing
          if (ip.startsWith('192.168.') || 
              ip.startsWith('10.') || 
              ip.startsWith('172.')) {
            bestIp = ip;
            break;
          }
          
          // If no preferred range found, use the first valid IP
          if (bestIp == null) {
            bestIp = ip;
          }
        }
        
        if (bestIp != null) break;
      }
    } catch (e) {
      print('Error getting network interfaces: $e');
    }
    
    // Fallback to network_info_plus if no IP found
    if (bestIp == null) {
      try {
        final info = NetworkInfo();
        bestIp = await info.getWifiIP();
      } catch (e) {
        print('Error getting WiFi IP: $e');
      }
    }
    
    // Final fallback
    bestIp ??= '192.168.1.100';
    
    // Debug: Print all available IPs
    print('All available IPs: ${allIps.join(', ')}');
    print('Selected IP: $bestIp');
    
    setState(() {
      _localIp = bestIp;
      _displayCode = _ipToCode(bestIp!);
    });
  }

  void _showAllNetworkInterfaces() async {
    try {
      final interfaces = await NetworkInterface.list(
        includeLinkLocal: true,
        type: InternetAddressType.IPv4,
      );
      
      final interfaceInfo = interfaces.map((interface) {
        final addresses = interface.addresses.map((addr) => addr.address).join(', ');
        return '${interface.name}: $addresses';
      }).join('\n');
      
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: Colors.grey[900],
          title: Text(
            'Network Interfaces',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
          ),
          content: SingleChildScrollView(
            child: Text(
              interfaceInfo,
              style: TextStyle(
                color: Colors.grey[300],
                fontFamily: 'monospace',
                fontSize: 12,
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(
                'Close',
                style: TextStyle(color: Colors.yellow[300], fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      );
    } catch (e) {
      print('Error showing network interfaces: $e');
    }
  }

  Future<void> _pickFiles() async {
    setState(() => _loading = true);
    final result = await FilePicker.platform.pickFiles(allowMultiple: true);
    if (result != null) {
      setState(() {
        // Append to existing lists instead of replacing
        _files.addAll(result.files);
        _progressList.addAll(List.filled(result.files.length, 0.0));
        _isPausedList.addAll(List.filled(result.files.length, false)); // Initialize pause state
        if (_localIp != null) _displayCode = _ipToCode(_localIp!);
      });
    }
    setState(() => _loading = false);
  }

  Future<void> _pickFolder() async {
    String? folderPath = await FilePicker.platform.getDirectoryPath(dialogTitle: 'Select Folder to Share');
    if (folderPath == null) return;
    final dir = Directory(folderPath);
    final files = await dir.list(recursive: true, followLinks: false).where((e) => e is File).toList();
    setState(() {
      // Append to existing lists instead of replacing
      final newFiles = files.map((e) => PlatformFile(
        name: e.uri.pathSegments.last,
        path: e.path,
        size: File(e.path).lengthSync(),
      )).toList();
              _files.addAll(newFiles);
        _progressList.addAll(List.filled(newFiles.length, 0.0));
        _isPausedList.addAll(List.filled(newFiles.length, false)); // Initialize pause state
        if (_localIp != null) _displayCode = _ipToCode(_localIp!);
    });
    }

  Future<void> _startServer() async {
    if (_files.isEmpty) return;
    await _server?.close(force: true);
    _server = await HttpServer.bind(InternetAddress.anyIPv4, 8080);
    if (_localIp != null) {
      setState(() {
        _displayCode = _ipToCode(_localIp!);
      });
    }
    setState(() => _isSharing = true);
    _server!.listen((HttpRequest request) async {
      final path = request.uri.path;
      
      // Serve web interface at root
      if (path == '/' || path == '/index.html') {
        await _serveWebInterface(request);
        return;
      }
      
      // Serve /list endpoint
      if (path == '/list') {
        final list = List.generate(_files.length, (i) => {
          'index': i,
          'name': _files[i].name,
          'size': _files[i].size,
        });
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(list));
        await request.response.close();
        return;
      }
      
      // Serve /file/<index> endpoint
      final segments = request.uri.pathSegments;
      if (segments.length == 2 && segments[0] == 'file') {
        final index = int.tryParse(segments[1]);
        if (index == null || index >= _files.length) return;
        final file = _files[index];
        final filePath = file.path;
        if (filePath == null) return;
        final fileToSend = File(filePath);
        final fileSize = await fileToSend.length();
        request.response.headers.contentType = ContentType.binary;
        request.response.headers.set('Content-Disposition', 'attachment; filename="${file.name}"');
        request.response.headers.set('Content-Length', fileSize.toString());
        int sent = 0;
        final sink = request.response;
        final stream = fileToSend.openRead();
        await for (final chunk in stream) {
          sink.add(chunk);
          sent += chunk.length;
          setState(() {
            _progressList[index] = sent / fileSize;
          });
          await sink.flush();
        }
        await sink.close();
        setState(() {
          _progressList[index] = 0.0;
        });
        return;
      }
      
      // 404 for other paths
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
    });
  }

  Future<void> _stopServer() async {
    await _server?.close(force: true);
    setState(() => _isSharing = false);
  }

  void _clearFiles() {
    setState(() {
      _files.clear();
      _progressList.clear();
      _isPausedList.clear(); // Clear pause state
    });
  }

  void _togglePause(int index) {
    if (index < _isPausedList.length) {
      setState(() {
        _isPausedList[index] = !_isPausedList[index];
      });
    }
  }

  Future<void> _handleDroppedFiles(List<String> filePaths) async {
    setState(() => _loading = true);
    
    try {
      final newFiles = <PlatformFile>[];
      
      for (final path in filePaths) {
        final file = File(path);
        if (await file.exists()) {
          final stat = await file.stat();
          newFiles.add(PlatformFile(
            name: file.path.split(Platform.pathSeparator).last,
            path: file.path,
            size: stat.size,
          ));
        }
      }
      
      if (newFiles.isNotEmpty) {
        setState(() {
          _files.addAll(newFiles);
          _progressList.addAll(List.filled(newFiles.length, 0.0));
          _isPausedList.addAll(List.filled(newFiles.length, false));
          if (_localIp != null) _displayCode = _ipToCode(_localIp!);
        });
        
        // Files added successfully
      }
    } catch (e) {
      // Handle error silently or show a snackbar
      print('Error handling dropped files: $e');
    } finally {
      setState(() => _loading = false);
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
            background: linear-gradient(135deg, #FFD600 0%, #FF6B35 100%);
            min-height: 100vh;
            padding: 20px;
        }
        
        .container {
            max-width: 900px;
            margin: 0 auto;
            background: #1a1a1a;
            border-radius: 20px;
            box-shadow: 0 20px 40px rgba(0,0,0,0.3);
            overflow: hidden;
            border: 3px solid #FFD600;
        }
        
        .header {
            background: linear-gradient(135deg, #FFD600 0%, #FF6B35 100%);
            padding: 30px;
            text-align: center;
            color: #1a1a1a;
            position: relative;
            overflow: hidden;
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
            text-shadow: 0 2px 4px rgba(0,0,0,0.1);
        }
        
        .header p {
            font-size: 1.1rem;
            opacity: 0.9;
        }
        
        .content {
            padding: 30px;
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
            <div id="fileList" class="file-list">
                <div class="loading">
                    <div class="pikachu-runner">🏃</div>
                    <h3>Pikachu is running to fetch your files! ⚡</h3>
                </div>
            </div>
        </div>
        
        <div class="footer">
            <p>Powered by ZapShare • Fast & Secure File Sharing</p>
        </div>
    </div>

    <script>
        let selectedFiles = new Set();
        
        async function loadFiles() {
            try {
                const response = await fetch('/list');
                if (!response.ok) {
                    throw new Error('Failed to fetch files');
                }
                
                const files = await response.json();
                displayFiles(files);
            } catch (error) {
                console.error('Error loading files:', error);
                document.getElementById('fileList').innerHTML = 
                    '<div class="no-files"><h3>Error loading files</h3><p>Please try again later</p></div>';
            }
        }
        
        function displayFiles(files) {
            const fileList = document.getElementById('fileList');
            const bulkActions = document.getElementById('bulkActions');
            
            if (files.length === 0) {
                fileList.innerHTML = 
                    '<div class="no-files"><h3>No files available</h3><p>No files have been shared yet</p></div>';
                bulkActions.style.display = 'none';
                return;
            }
            
            const filesHtml = files.map((file, index) => {
                const size = formatFileSize(file.size);
                const icon = getFileIcon(file.name);
                const isSelected = selectedFiles.has(file.index);
                
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
                        <a href="/file/\${file.index}" class="download-btn" download onclick="startPikachuRun(this, \${file.index})">
                            Download
                        </a>
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
            const checkboxes = document.querySelectorAll('.file-checkbox');
            checkboxes.forEach(checkbox => {
                checkbox.checked = true;
                toggleFileSelection(parseInt(checkbox.closest('.file-item').dataset.index), true);
            });
        }
        
        function deselectAll() {
            const checkboxes = document.querySelectorAll('.file-checkbox');
            checkboxes.forEach(checkbox => {
                checkbox.checked = false;
                toggleFileSelection(parseInt(checkbox.closest('.file-item').dataset.index), false);
            });
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

  @override
  void dispose() {
    _server?.close(force: true);
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
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
                    icon: Icon(Icons.info_outline_rounded, color: Colors.grey[400], size: 20),
                    onPressed: () {
                      showDialog(
                        context: context,
                        builder: (context) => AlertDialog(
                          backgroundColor: Colors.grey[900],
                          title: Text(
                            'ZapShare Info',
                            style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                          ),
                          content: Text(
                            'Version 1.0.0\n\nA fast and secure file sharing app.',
                            style: TextStyle(color: Colors.grey[300]),
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(context),
                              child: Text(
                                'OK',
                                style: TextStyle(color: Colors.yellow[300], fontWeight: FontWeight.w600),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
            
            // Main content with native drag and drop support
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: _isDragOver ? Colors.yellow[300]!.withOpacity(0.1) : Colors.transparent,
                  border: _isDragOver ? Border.all(
                    color: Colors.yellow[300]!,
                    width: 2,
                    style: BorderStyle.solid,
                  ) : null,
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Column(
                    children: [
                      // Connection status
                      if (_localIp != null) ...[
                        _buildConnectionStatus(),
                        const SizedBox(height: 24),
                      ],
                      
                      // Share code section
                      if (_displayCode != null && _files.isNotEmpty) ...[
                        _buildShareCode(),
                        const SizedBox(height: 24),
                      ],
                      
                      // File list section
                      if (_files.isNotEmpty) ...[
                        _buildFileListHeader(),
                        const SizedBox(height: 16),
                        Expanded(child: _buildFileList()),
                      ],
                      
                      // Empty state
                      if (_files.isEmpty && !_loading) ...[
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
                      
                      // Network error state
                      if (_localIp == null && !_loading) ...[
                        Expanded(
                          child: _buildNetworkErrorState(),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
            
            // Action buttons
            if (_files.isNotEmpty) ...[
              Container(
                padding: const EdgeInsets.all(24),
                child: Row(
                  children: [
                    Expanded(
                      child: _buildActionButton(
                        icon: Icons.attach_file_rounded,
                        label: 'Add Files',
                        onTap: _pickFiles,
                        color: Colors.grey[900]!,
                        textColor: Colors.white,
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: _buildActionButton(
                        icon: Icons.folder_rounded,
                        label: 'Add Folder',
                        onTap: _pickFolder,
                        color: Colors.grey[900]!,
                        textColor: Colors.white,
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.only(bottom: 24, left: 24, right: 24),
                child: Row(
                  children: [
                    Expanded(
                      child: _buildActionButton(
                        icon: Icons.clear_all_rounded,
                        label: 'Clear All',
                        onTap: _files.isEmpty ? null : _clearFiles,
                        color: _files.isEmpty ? Colors.grey[700]! : Colors.red[600]!,
                        textColor: _files.isEmpty ? Colors.grey[400]! : Colors.white,
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: _buildActionButton(
                        icon: _isSharing ? Icons.stop_circle_rounded : Icons.send_rounded,
                        label: _isSharing ? 'Stop Sharing' : 'Start Sharing',
                        onTap: _files.isEmpty ? null : (_isSharing ? _stopServer : _startServer),
                        color: _files.isEmpty
                            ? Colors.grey[700]!
                            : _isSharing
                                ? Colors.red[600]!
                                : Colors.yellow[300]!,
                        textColor: _files.isEmpty
                            ? Colors.grey[400]!
                            : _isSharing
                                ? Colors.white
                                : Colors.black,
                      ),
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
          '${_files.length} file${_files.length == 1 ? '' : 's'}',
          style: TextStyle(
            color: Colors.grey[400],
            fontSize: 14,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }


  Widget _buildConnectionStatus() {
    return GestureDetector(
      onLongPress: _showAllNetworkInterfaces,
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.grey[900],
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.grey[800]!, width: 1),
        ),
        child: Row(
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
            Expanded(
              child: Text(
                'Connected • $_localIp',
                style: TextStyle(
                  color: Colors.grey[300],
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  fontFamily: 'monospace',
                ),
              ),
            ),
            GestureDetector(
              onTap: _fetchLocalIp,
              child: Container(
                padding: EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: Colors.grey[800],
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Icon(
                  Icons.refresh_rounded,
                  color: Colors.grey[400],
                  size: 16,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildShareCode() {
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
                child: Text(
                  _displayCode!,
                  style: TextStyle(
                    fontSize: 18,
                    color: Colors.yellow[300],
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
              GestureDetector(
                onTap: () {
                  Clipboard.setData(ClipboardData(text: _displayCode!));
                },
                child: Icon(
                  Icons.copy_rounded,
                  color: Colors.yellow[300],
                  size: 20,
                ),
              ),
            ],
          ),
          SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Text(
                  shareUrl,
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.grey[400],
                    fontWeight: FontWeight.w500,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
              GestureDetector(
                onTap: () {
                  Clipboard.setData(ClipboardData(text: shareUrl));
                },
                child: Container(
                  padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.yellow[300],
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.link_rounded,
                        color: Colors.black,
                        size: 16,
                      ),
                      SizedBox(width: 4),
                      Text(
                        'Copy Link',
                        style: TextStyle(
                          color: Colors.black,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildFileList() {
    return ListView.builder(
      itemCount: _files.length,
      itemBuilder: (context, index) {
        final file = _files[index];
        final progress = _progressList.length > index ? _progressList[index] : 0.0;
        
        return Container(
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
                        _getFileIcon(file.name),
                        color: Colors.black,
                        size: 20,
                      ),
                    ),
                    SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            file.name,
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          SizedBox(height: 4),
                          Text(
                            _formatBytes(file.size),
                            style: TextStyle(
                              color: Colors.grey[400],
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (_isSharing) ...[
                      SizedBox(width: 12),
                      // Check if file is completed (progress = 1.0 means 100%)
                      if (progress >= 1.0) ...[
                        // Completion indicator
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
                        Text(
                          'Completed',
                          style: TextStyle(
                            color: Colors.green[400],
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ] else ...[
                        // Small circular progress indicator inline
                        Container(
                          width: 32,
                          height: 32,
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              CircularProgressIndicator(
                                value: progress,
                                backgroundColor: Colors.grey[800]!.withOpacity(0.3),
                                color: Colors.yellow[300],
                                strokeWidth: 3,
                                strokeCap: StrokeCap.round,
                              ),
                              // Pause/Resume button overlay
                              Container(
                                width: 20,
                                height: 20,
                                decoration: BoxDecoration(
                                  color: _isPausedList.length > index ? (_isPausedList[index] ? Colors.green[400] : Colors.orange[400]) : Colors.orange[400],
                                  shape: BoxShape.circle,
                                  boxShadow: [
                                    BoxShadow(
                                      color: (_isPausedList.length > index ? (_isPausedList[index] ? Colors.green[400] : Colors.orange[400]) : Colors.orange[400])!.withOpacity(0.4),
                                      blurRadius: 6,
                                      offset: Offset(0, 2),
                                    ),
                                  ],
                                ),
                                child: Material(
                                  color: Colors.transparent,
                                  child: InkWell(
                                    onTap: () => _togglePause(index),
                                    borderRadius: BorderRadius.circular(10),
                                    child: Center(
                                      child: Icon(
                                        _isPausedList.length > index && _isPausedList[index] ? Icons.play_arrow_rounded : Icons.pause_rounded,
                                        color: Colors.white,
                                        size: 12,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        SizedBox(width: 8),
                        // Progress percentage inline
                        Text(
                          _isPausedList.length > index && _isPausedList[index] ? 'Paused' : '${(progress * 100).toStringAsFixed(1)}%',
                          style: TextStyle(
                            color: _isPausedList.length > index && _isPausedList[index] ? Colors.orange[400] : Colors.yellow[300],
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ],
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              color: Colors.grey[900],
              borderRadius: BorderRadius.circular(40),
              border: Border.all(color: Colors.grey[800]!, width: 1),
            ),
            child: Icon(
              Icons.attach_file_rounded,
              color: Colors.grey[600],
              size: 40,
            ),
          ),
          const SizedBox(height: 24),
          Text(
            'No Files Selected',
            style: TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Drag and drop files here or use the buttons below',
            style: TextStyle(
              color: Colors.grey[400],
              fontSize: 16,
              fontWeight: FontWeight.w400,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          Container(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.yellow[300]!.withOpacity(0.1),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Colors.yellow[300]!.withOpacity(0.3), width: 1),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.drag_indicator_rounded,
                  color: Colors.yellow[300],
                  size: 16,
                ),
                SizedBox(width: 8),
                Text(
                  'Drop files anywhere on this screen',
                  style: TextStyle(
                    color: Colors.yellow[300],
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 32),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 120,
                height: 48,
                child: _buildActionButton(
                  icon: Icons.attach_file_rounded,
                  label: 'Add Files',
                  onTap: _pickFiles,
                  color: Colors.yellow[300]!,
                  textColor: Colors.black,
                ),
              ),
              SizedBox(width: 16),
              Container(
                width: 120,
                height: 48,
                child: _buildActionButton(
                  icon: Icons.folder_rounded,
                  label: 'Add Folder',
                  onTap: _pickFolder,
                  color: Colors.grey[900]!,
                  textColor: Colors.white,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildLoadingState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              color: Colors.grey[900],
              borderRadius: BorderRadius.circular(40),
              border: Border.all(color: Colors.grey[800]!, width: 1),
            ),
            child: CircularProgressIndicator(
              color: Colors.yellow[300],
              strokeWidth: 3,
            ),
          ),
          const SizedBox(height: 24),
          Text(
            'Loading...',
            style: TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNetworkErrorState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              color: Colors.grey[900],
              borderRadius: BorderRadius.circular(40),
              border: Border.all(color: Colors.grey[800]!, width: 1),
            ),
            child: Icon(
              Icons.wifi_off_rounded,
              color: Colors.red[400],
              size: 40,
            ),
          ),
          const SizedBox(height: 24),
          Text(
            'No Network Connection',
            style: TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Please connect to WiFi or Ethernet\nto start sharing files',
            style: TextStyle(
              color: Colors.grey[400],
              fontSize: 16,
              fontWeight: FontWeight.w400,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _buildActionButton({
    required IconData icon,
    required String label,
    required VoidCallback? onTap,
    required Color color,
    required Color textColor,
  }) {
    return Container(
      height: 56,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, color: textColor, size: 20),
                SizedBox(width: 8),
                Text(
                  label,
                  style: TextStyle(
                    color: textColor,
                    fontSize: 16,
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

  IconData _getFileIcon(String fileName) {
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

  String _formatBytes(int bytes) {
    if (bytes < 1024) return "$bytes B";
    if (bytes < 1024 * 1024) return "${(bytes / 1024).toStringAsFixed(1)} KB";
    if (bytes < 1024 * 1024 * 1024) return "${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB";
    return "${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB";
  }
} 