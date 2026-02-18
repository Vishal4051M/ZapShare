import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
// import 'package:permission_handler/permission_handler.dart'; // Unused
import 'package:open_file/open_file.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:qr_flutter/qr_flutter.dart';

// Modern Color Constants
// Modern Color Constants
const Color kZapPrimary = Color(0xFFFFD84D); // Logo Yellow Light
const Color kZapPrimaryDark = Color(0xFFF5C400); // Logo Yellow Dark
const Color kZapSurface = Color(0xFF1C1C1E); 
const Color kZapBackgroundTop = Color(0xFF0E1116);
const Color kZapBackgroundBottom = Color(0xFF07090D); 

// Reuse the same FileType enum and models as Android to keep logic consistent
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
  final String browserSessionId;
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

class IOSWebReceiveScreen extends StatefulWidget {
  const IOSWebReceiveScreen({super.key});

  @override
  State<IOSWebReceiveScreen> createState() => _IOSWebReceiveScreenState();
}

class _IOSWebReceiveScreenState extends State<IOSWebReceiveScreen> {
  HttpServer? _uploadServer;
  String? _localIp;
  bool _isHosting = false;
  String? _saveFolder;
  bool _uploadApprovalActive = false;
  DateTime? _uploadApprovalExpiresAt;

  List<ReceivedFile> _receivedFiles = [];
  List<PendingFile> _pendingFiles = []; 
  Map<String, ReceivedFile> _ongoingDownloads = {};
  final FlutterLocalNotificationsPlugin _notificationsPlugin = FlutterLocalNotificationsPlugin();
  final Map<String, int> _fileToNotificationId = {};
  int _currentTab = 0;

  @override
  void initState() {
    super.initState();
    _initializeServer();
    _initLocalNotifications();
  }

  @override
  void dispose() {
    _stopWebServer();
    super.dispose();
  }

  Future<void> _initLocalNotifications() async {
    const AndroidInitializationSettings androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const DarwinInitializationSettings iosSettings = DarwinInitializationSettings();
    final InitializationSettings initSettings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
    );
    await _notificationsPlugin.initialize(initSettings);
  }

  /* Unused
  int _notificationIdFor(String key) {
    return _fileToNotificationId.putIfAbsent(
      key,
      () => 5000 + key.hashCode.abs() % 2000,
    );
  }
  */

  Future<void> _initializeServer() async {
    _saveFolder = await _getDefaultDownloadFolder();
    await _startWebServer();
  }

  Future<String> _getDefaultDownloadFolder() async {
    final appDir = await getApplicationDocumentsDirectory();
    final zapDir = Directory('${appDir.path}/ZapShare');
    if (!await zapDir.exists()) {
      await zapDir.create(recursive: true);
    }
    return zapDir.path;
  }

  // Helper to get local IP
  Future<String?> _getLocalIpv4() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          final ip = addr.address;
          if (!ip.startsWith('127.') && !ip.startsWith('169.254.')) {
            return ip;
          }
        }
      }
    } catch (_) {}
    return null;
  }

  Future<void> _startWebServer() async {
    try {
      _localIp ??= await _getLocalIpv4();
      if (_localIp == null) {
        _showSnackBar('Could not determine local IP. Connect to WiFi.');
        return;
      }

      _uploadServer = await HttpServer.bind(InternetAddress.anyIPv4, 8090);
      setState(() {
        _isHosting = true;
      });

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
        if (request.method == 'GET' && path == '/files') {
            await _serveFilesList(request);
            return;
        }
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
      });

    } catch (e) {
      setState(() => _isHosting = false);
      _showSnackBar('Failed to start web server: $e');
    }
  }

  Future<void> _stopWebServer() async {
    await _uploadServer?.close(force: true);
    setState(() => _isHosting = false);
  }

  // --- HTTP Handlers ---

  Future<void> _serveUploadForm(HttpRequest request) async {
    final response = request.response;
    response.statusCode = HttpStatus.ok;
    response.headers.contentType = ContentType.html;
    final html = _getHtmlContent(); 
    response.write(html);
    await response.close();
  }

  Future<void> _serveFilesList(HttpRequest request) async {
      try {
        final filesList = _pendingFiles.map((f) => {
          'id': f.id,
          'name': f.name,
          'size': f.size,
          'uploadedAt': f.uploadedAt.toIso8601String(),
          'fileType': f.fileType.toString().split('.').last,
        }).toList();

        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentType = ContentType.json;
         request.response.headers.set('Access-Control-Allow-Origin', '*');
        request.response.write(jsonEncode(filesList));
        await request.response.close();
      } catch (e) {
        request.response.statusCode = HttpStatus.internalServerError;
        await request.response.close();
      }
  }

  Future<void> _handleRequestUpload(HttpRequest request) async {
      try {
        final body = await utf8.decodeStream(request);
        final data = jsonDecode(body);
        final files = (data['files'] as List).cast<Map>().map((m) => {'name': m['name'], 'size': m['size']}).toList();

        if (!mounted) {
           _sendJson(request, {'approved': false});
           return;
        }

        final approved = await _showUploadApprovalDialog(files);
        if (approved) {
           setState(() {
             _uploadApprovalActive = true;
             _uploadApprovalExpiresAt = DateTime.now().add(const Duration(minutes: 2));
           });
        }
        _sendJson(request, {'approved': approved});
      } catch (e) {
        request.response.statusCode = HttpStatus.internalServerError;
        await request.response.close();
      }
  }

  Future<void> _handlePutUpload(HttpRequest request) async {
       try {
        final now = DateTime.now();
        if (!_uploadApprovalActive || _uploadApprovalExpiresAt == null || now.isAfter(_uploadApprovalExpiresAt!)) {
           request.response.statusCode = HttpStatus.forbidden;
           request.response.write("Not approved");
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
       final fileName = request.uri.queryParameters['name'] ?? 'unknown_file';
       String savePath = '$_saveFolder/$fileName';
       
       int count = 1;
       String originalName = fileName;
       while (await File(savePath).exists()) {
           final bits = originalName.split('.');
           if(bits.length > 1) {
              final base = bits.sublist(0, bits.length - 1).join('.');
              final ext = bits.last;
              savePath = '$_saveFolder/${base}_$count.$ext';
           } else {
              savePath = '$_saveFolder/${originalName}_$count';
           }
           count++;
       }

       setState(() {
          _ongoingDownloads[fileName] = ReceivedFile(
             name: fileName,
             size: request.headers.contentLength,
             path: savePath,
             receivedAt: DateTime.now(),
             progress: 0.0,
             status: 'Receiving...',
             isUploading: true
          );
       });

       final file = File(savePath);
       final sink = file.openWrite();
       int bytesReceived = 0;
       final totalBytesLength = request.headers.contentLength; // Used to be totalBytes, renamed to avoid unused if logic doesn't use it. Actually it's just unused in the logic below.
       // We can just ignore it or use it for progress updates if we implement stream listener manually.
       // For now, let's just comment it out effectively or keep it but ignore warning if I could, but I can't suppress easily.
       // effectively:
       // final totalBytes = request.headers.contentLength;

       await request.listen((chunk) {
          sink.add(chunk);
          bytesReceived += chunk.length;
       }).asFuture();

       await sink.flush();
       await sink.close();

       setState(() {
          _ongoingDownloads.remove(fileName);
          _receivedFiles.insert(0, ReceivedFile(
             name: fileName,
             size: bytesReceived,
             path: savePath,
             receivedAt: DateTime.now(),
             progress: 1.0,
             status: 'Complete',
             isUploading: false
          ));
       });

       _saveHistory(fileName, bytesReceived, savePath);

       request.response.statusCode = HttpStatus.ok;
       request.response.write("Uploaded");
       await request.response.close();

     } catch (e) {
       request.response.statusCode = HttpStatus.internalServerError;
       await request.response.close();
     }
  }

  Future<void> _sendJson(HttpRequest request, Map<String, dynamic> json) async {
      request.response.headers.contentType = ContentType.json;
      request.response.headers.set('Access-Control-Allow-Origin', '*');
      request.response.write(jsonEncode(json));
      await request.response.close();
  }

  Future<void> _saveHistory(String name, int size, String path) async {
     try {
        final prefs = await SharedPreferences.getInstance();
        final history = prefs.getStringList('transfer_history') ?? [];
        final entry = {
           'fileName': name,
           'fileSize': size,
           'direction': 'Received',
           'peer': 'Web Upload',
           'dateTime': DateTime.now().toIso8601String(),
           'fileLocation': path
        };
        history.insert(0, jsonEncode(entry));
        await prefs.setStringList('transfer_history', history);
     } catch (_) {}
  }

  Future<bool> _showUploadApprovalDialog(List<Map<dynamic, dynamic>> files) async {
     return await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (context) {
           return AlertDialog(
              backgroundColor: kZapSurface,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              title: const Text('Allow upload?', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
              content: Text('${files.length} files requesting to upload.', style: TextStyle(color: Colors.grey[400])),
              actions: [
                 TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Refuse', style: TextStyle(color: Colors.red))),
                 TextButton(onPressed: () => Navigator.pop(context, true), child: Text('Accept', style: TextStyle(color: kZapPrimary))),
              ],
           );
        }
     ) ?? false;
  }

  void _showSnackBar(String msg) {
      if(mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), backgroundColor: kZapSurface, behavior: SnackBarBehavior.floating));
  }

  String _formatBytes(int bytes) {
      if (bytes <= 0) return "0 B";
      if (bytes < 1024) return "$bytes B";
      double num = bytes / 1024;
      if (num < 1024) return "${num.toStringAsFixed(1)} KB";
      num /= 1024;
      if (num < 1024) return "${num.toStringAsFixed(1)} MB";
      num /= 1024;
      return "${num.toStringAsFixed(1)} GB";
  }

  // --- UI Build ---

  @override
  Widget build(BuildContext context) {
    return Scaffold(
       extendBody: true,
       body: Container(
         decoration: const BoxDecoration(
           gradient: LinearGradient(
             begin: Alignment.topCenter,
             end: Alignment.bottomCenter,
             colors: [kZapBackgroundTop, kZapBackgroundBottom],
           ),
         ),
         child: SafeArea(
           child: Column(
             children: [
                // Header
                Container(
                  padding: const EdgeInsets.fromLTRB(16, 16, 24, 24),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Container(
                        decoration: BoxDecoration(
                          color: kZapSurface,
                          shape: BoxShape.circle,
                        ),
                        child: IconButton(
                          icon: const Icon(Icons.close_rounded, color: Colors.white),
                          onPressed: () => Navigator.pop(context),
                        ),
                      ),
                      const SizedBox(width: 16),
                      Text(
                        'Web Direct',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const Spacer(),
                    ],
                  ),
                ),
                
                // Server Status
                if (_isHosting && _localIp != null)
                   Container(
                      margin: const EdgeInsets.symmetric(horizontal: 24),
                      padding: const EdgeInsets.all(24),
                      decoration: BoxDecoration(
                         color: kZapSurface,
                         borderRadius: BorderRadius.circular(24),
                         border: Border.all(color: Colors.white.withOpacity(0.05)),
                         boxShadow: [
                           BoxShadow(color: Colors.black.withOpacity(0.2), blurRadius: 10, offset: const Offset(0, 4))
                         ]
                      ),
                      child: Column(
                         children: [
                            Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: kZapPrimary.withOpacity(0.1),
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(Icons.wifi_tethering, color: kZapPrimary, size: 32),
                            ),
                            const SizedBox(height: 16),
                            const Text("Ready to receive", style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                            const SizedBox(height: 8),
                            const Text("Scan this with your computer or phone camera", style: TextStyle(color: Colors.grey, fontSize: 13), textAlign: TextAlign.center),
                            const SizedBox(height: 24),
                             
                            Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: QrImageView(
                                  data: "http://$_localIp:8090",
                                  version: QrVersions.auto,
                                  size: 160.0,
                                  backgroundColor: Colors.white,
                              ),
                            ),
                            
                            const SizedBox(height: 24),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                              decoration: BoxDecoration(
                                color: Colors.black,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text("http://$_localIp:8090", style: const TextStyle(color: kZapPrimary, fontSize: 16, fontWeight: FontWeight.w600, fontFamily: 'monospace')),
                                ],
                              ),
                            ),
                         ],
                      ),
                   )
                else
                   Center(child: CircularProgressIndicator(color: kZapPrimary)),

                const SizedBox(height: 32),
                
                // Tabs
                Padding(
                   padding: const EdgeInsets.symmetric(horizontal: 24),
                   child: Row(
                      children: [
                         _buildTab("Transfers", 0),
                         const SizedBox(width: 16),
                         _buildTab("History", 1),
                      ],
                   ),
                ),

                const SizedBox(height: 16),

                Expanded(
                   child: Container(
                     margin: const EdgeInsets.symmetric(horizontal: 12),
                     decoration: BoxDecoration(
                       color: Colors.transparent, 
                       borderRadius: BorderRadius.circular(24),
                     ),
                     child: _currentTab == 0 ? _buildPendingList() : _buildReceivedList(),
                   ),
                ),

             ],
          ),
       ),
       ),
    );
  }

  Widget _buildTab(String title, int index) {
      final isSelected = _currentTab == index;
      return InkWell(
         onTap: () => setState(() => _currentTab = index),
         child: Container(
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 20),
            decoration: BoxDecoration(
               color: isSelected ? kZapPrimary : kZapSurface,
               borderRadius: BorderRadius.circular(30),
            ),
            child: Text(
              title, 
              style: TextStyle(
                color: isSelected ? Colors.black : Colors.grey, 
                fontWeight: FontWeight.bold,
                fontSize: 14
              )
            ),
         ),
      );
  }

  Widget _buildPendingList() {
      if (_ongoingDownloads.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.cloud_upload_outlined, size: 48, color: Colors.grey[800]),
                const SizedBox(height: 16),
                Text("Waiting for files...", style: TextStyle(color: Colors.grey[600])),
              ],
            ),
          );
      }
      return ListView.builder(
         itemCount: _ongoingDownloads.length,
         itemBuilder: (context, index) {
            final file = _ongoingDownloads.values.elementAt(index);
            return Container(
              margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
              decoration: BoxDecoration(
                color: kZapSurface,
                borderRadius: BorderRadius.circular(12),
              ),
              child: ListTile(
                 title: Text(file.name, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                 subtitle: Text("Downloading...", style: TextStyle(color: kZapPrimary, fontSize: 12)),
                 trailing: SizedBox(
                   width: 20, height: 20,
                   child: CircularProgressIndicator(color: kZapPrimary, strokeWidth: 2),
                 ),
              ),
            );
         },
      );
  }

  Widget _buildReceivedList() {
      if (_receivedFiles.isEmpty) {
          return Center(child: Text("No files received yet", style: TextStyle(color: Colors.grey[700])));
      }
      return ListView.builder(
         itemCount: _receivedFiles.length,
         itemBuilder: (context, index) {
            final file = _receivedFiles[index];
            return Container(
               margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
               decoration: BoxDecoration(
                 color: kZapSurface,
                 borderRadius: BorderRadius.circular(12),
               ),
               child: ListTile(
                  leading: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(color: Colors.white.withOpacity(0.05), borderRadius: BorderRadius.circular(8)),
                    child: const Icon(Icons.file_present_rounded, color: Colors.white, size: 20),
                  ),
                  title: Text(file.name, style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w500)),
                  subtitle: Text(_formatBytes(file.size), style: TextStyle(color: Colors.grey[500], fontSize: 12)),
                  trailing: IconButton(
                     icon: const Icon(Icons.open_in_new_rounded, color: kZapPrimary),
                     onPressed: () {
                        OpenFile.open(file.path);
                     },
                  ),
               ),
            );
         },
      );
  }

  String _getHtmlContent() {
    return '''
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>ZapShare Web</title>
  <style>
    :root {
      --primary: #FFD84D;
      --surface: #1e1e1e;
      --bg: #0c0c0c;
      --text: #ffffff;
      --text-dim: #888888;
    }
    body { 
      margin: 0; 
      font-family: 'Inter', -apple-system, BlinkMacSystemFont, sans-serif; 
      background: var(--bg); 
      color: var(--text); 
      display: flex; 
      align-items: center; 
      justify-content: center; 
      min-height: 100vh; 
    }
    .container {
      width: 90%;
      max-width: 480px;
    }
    .card { 
      background: var(--surface); 
      padding: 40px; 
      border-radius: 24px; 
      text-align: center; 
      box-shadow: 0 20px 50px rgba(0,0,0,0.5);
      border: 1px solid rgba(255,255,255,0.05);
    }
    h1 { margin: 0 0 10px; font-weight: 800; letter-spacing: -1px; }
    p { color: var(--text-dim); margin-top: 0; }
    
    .drop-zone { 
      border: 2px dashed #444; 
      background: rgba(255,255,255,0.02);
      padding: 60px 20px; 
      border-radius: 16px; 
      margin-top: 30px; 
      cursor: pointer; 
      transition: all 0.3s ease;
    }
    .drop-zone:hover, .drop-zone.dragover { 
      border-color: var(--primary); 
      background: rgba(255, 214, 0, 0.05);
      color: var(--primary);
    }
    
    .status-area { margin-top: 20px; font-size: 14px; min-height: 20px; }
    .success { color: var(--primary); }
    .error { color: #ff5252; }
    
    .footer { margin-top: 40px; font-size: 12px; color: #444; }
  </style>
</head>
<body>
  <div class="container">
    <div class="card">
      <div style="font-size: 40px; margin-bottom: 20px;">⚡️</div>
      <h1>ZapShare</h1>
      <p>Secure local file transfer</p>
      
      <div class="drop-zone" id="dropZone" onclick="document.getElementById('fileInput').click()">
         <strong>Click to browse</strong><br>
         <span style="font-size: 14px; opacity: 0.7;">or drag files here</span>
      </div>
      
      <input type="file" id="fileInput" multiple onchange="uploadFiles(this.files)">
      
      <div id="status" class="status-area"></div>
    </div>
    <div class="footer">Keep this tab open while transferring</div>
  </div>

  <script>
    const dropZone = document.getElementById('dropZone');
    
    dropZone.addEventListener('dragover', (e) => {
        e.preventDefault();
        dropZone.classList.add('dragover');
    });
    
    dropZone.addEventListener('dragleave', () => {
        dropZone.classList.remove('dragover');
    });
    
    dropZone.addEventListener('drop', (e) => {
        e.preventDefault();
        dropZone.classList.remove('dragover');
        if(e.dataTransfer.files.length) {
            uploadFiles(e.dataTransfer.files);
        }
    });

    async function uploadFiles(files) {
        if(!files.length) return;
        const status = document.getElementById('status');
        
        // 1. Request Approval
        const meta = Array.from(files).map(f => ({name: f.name, size: f.size}));
        status.className = 'status-area';
        status.innerText = "Requesting approval on device...";
        
        try {
            const resp = await fetch('/request-upload', {
                method: 'POST',
                body: JSON.stringify({files: meta})
            });
            const data = await resp.json();
            if(!data.approved) {
                status.className = 'status-area error';
                status.innerText = "Upload denied by user.";
                return;
            }
        } catch(e) {
            status.className = 'status-area error';
            status.innerText = "Connection error. Check WiFi.";
            return;
        }

        // 2. Upload
        status.innerText = "Uploading " + files.length + " files...";
        let successCount = 0;
        
        for(let file of files) {
           try {
              await fetch('/upload?name=' + encodeURIComponent(file.name), {
                  method: 'PUT',
                  body: file
              });
              successCount++;
           } catch(e) {
               console.error(e);
           }
        }
        
        status.className = 'status-area success';
        status.innerText = "Successfully sent " + successCount + " files!";
        setTimeout(() => status.innerText = "", 5000);
    }
  </script>
</body>
</html>
    ''';
  }
}
