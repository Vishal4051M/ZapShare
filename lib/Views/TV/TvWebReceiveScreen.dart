import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:open_file/open_file.dart';
import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'package:zap_share/widgets/tv_widgets.dart';

class TvWebReceiveScreen extends StatefulWidget {
  const TvWebReceiveScreen({super.key});

  @override
  State<TvWebReceiveScreen> createState() => _TvWebReceiveScreenState();
}

class _TvWebReceiveScreenState extends State<TvWebReceiveScreen> {
  HttpServer? _server;
  String? _localIp;
  bool _isHosting = false;
  final int _port = 8090;
  String? _saveFolder;
  final List<Map<String, dynamic>> _receivedFiles = [];

  @override
  void initState() {
    super.initState();
    _startTvReceiver();
  }

  @override
  void dispose() {
    _server?.close(force: true);
    super.dispose();
  }

  Future<void> _startTvReceiver() async {
    await _requestPermissions();
    _saveFolder = await _getDefaultDownloadFolder();
    _localIp = await _getLocalIpv4();
    if (_localIp != null) {
      await _startServer();
    }
  }

  Future<void> _requestPermissions() async {
    try {
      if (await Permission.storage.isDenied) {
        await Permission.storage.request();
      }
      if (await Permission.manageExternalStorage.isDenied) {
        await Permission.manageExternalStorage.request();
      }
    } catch (_) {}
  }

  Future<String> _getDefaultDownloadFolder() async {
    final downloadsCandidate = Directory('/storage/emulated/0/Download/ZapShare');
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
  }

  Future<String?> _getLocalIpv4() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          final ip = addr.address;
          if (ip.startsWith('127.') || ip.startsWith('169.254.')) continue;
          if (ip.startsWith('192.168.') || ip.startsWith('10.') || ip.startsWith('172.')) {
            return ip;
          }
        }
      }
    } catch (_) {}
    return null;
  }

  IconData _fileTypeIcon(String fileName) {
    final ext = fileName.split('.').last.toLowerCase();
    if (['mp4', 'mkv', 'avi', 'mov', 'webm', 'flv'].contains(ext)) return Icons.movie_rounded;
    if (['mp3', 'flac', 'aac', 'wav', 'ogg', 'm4a'].contains(ext)) return Icons.music_note_rounded;
    if (['jpg', 'jpeg', 'png', 'gif', 'bmp', 'webp', 'heic'].contains(ext)) return Icons.image_rounded;
    if (['pdf'].contains(ext)) return Icons.picture_as_pdf_rounded;
    if (['zip', 'rar', '7z', 'tar', 'gz'].contains(ext)) return Icons.folder_zip_rounded;
    if (['doc', 'docx', 'odt'].contains(ext)) return Icons.description_rounded;
    if (['xls', 'xlsx', 'ods', 'csv'].contains(ext)) return Icons.table_chart_rounded;
    if (['ppt', 'pptx', 'odp'].contains(ext)) return Icons.slideshow_rounded;
    if (['apk'].contains(ext)) return Icons.android_rounded;
    return Icons.insert_drive_file_rounded;
  }

  Future<void> _startServer() async {
    try {
      _server = await HttpServer.bind(InternetAddress.anyIPv4, _port);
      setState(() {
        _isHosting = true;
      });

      _server!.listen((HttpRequest request) async {
        final path = request.uri.path;
        request.response.headers.set('Access-Control-Allow-Origin', '*');
        request.response.headers.set('Access-Control-Allow-Methods', 'GET, POST, PUT, OPTIONS');
        request.response.headers.set('Access-Control-Allow-Headers', '*');

        if (request.method == 'OPTIONS') {
          request.response.statusCode = HttpStatus.ok;
          await request.response.close();
          return;
        }

        if (request.method == 'GET' && (path == '/' || path == '/index.html')) {
          await _serveUploadForm(request);
          return;
        }

        if (request.method == 'POST' && path == '/request-upload') {
          request.response.statusCode = HttpStatus.ok;
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode({'approved': true}));
          await request.response.close();
          return;
        }

        if (request.method == 'PUT' && path == '/upload') {
          await _handlePutUpload(request);
          return;
        }

        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
      });
    } catch (e) {
      print('TvReceiver server failed to start: $e');
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
  <title>ZapShare - TV Upload</title>
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body { font-family: system-ui, -apple-system, sans-serif; background: #0C0C0E; color: #fff; min-height: 100vh; display: flex; flex-direction: column; align-items: center; justify-content: center; padding: 20px; }
    .card { background: #1C1C1E; border: 1px solid rgba(255, 255, 255, 0.05); border-radius: 24px; padding: 32px; width: 100%; max-width: 500px; text-align: center; }
    h1 { font-size: 24px; font-weight: 700; margin-bottom: 8px; color: #FFD600; }
    p.subtitle { color: #888; font-size: 14px; margin-bottom: 24px; }
    .upload-area { border: 2px dashed rgba(255, 214, 0, 0.3); border-radius: 16px; padding: 40px 20px; cursor: pointer; background: rgba(255, 214, 0, 0.02); transition: 0.2s; }
    .upload-area:hover { border-color: #FFD600; background: rgba(255, 214, 0, 0.05); }
    .btn { display: block; width: 100%; padding: 14px; background: #FFD600; color: #000; border-radius: 12px; font-weight: 700; border: none; cursor: pointer; margin-top: 20px; font-size: 16px; }
    .btn:disabled { background: rgba(255,255,255,0.1); color: #666; cursor: not-allowed; }
    .file-item { background: rgba(255,255,255,0.02); border: 1px solid rgba(255,255,255,0.05); border-radius: 12px; margin-top: 12px; padding: 12px; display: flex; flex-direction: column; gap: 8px; text-align: left; }
    .file-name { font-weight: 600; font-size: 14px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .progress-bg { width: 100%; height: 6px; background: rgba(255,255,255,0.1); border-radius: 3px; overflow: hidden; }
    .progress-fill { height: 100%; width: 0%; background: #FFD600; transition: width 0.2s; }
  </style>
</head>
<body>
  <div class="card">
    <h1>ZapShare TV</h1>
    <p class="subtitle">Upload files directly to your TV screen</p>
    <div class="upload-area" id="dropZone">
      <p style="margin-bottom: 4px; font-weight: 600;">Tap to Choose Files</p>
      <p style="color: #666; font-size: 13px;">or drag files here</p>
      <input type="file" id="fileInput" multiple style="display: none" />
    </div>
    <div id="fileList"></div>
    <button id="uploadBtn" class="btn" disabled>Upload to TV</button>
  </div>
  <script>
    const dropZone = document.getElementById('dropZone');
    const fileInput = document.getElementById('fileInput');
    const fileList = document.getElementById('fileList');
    const uploadBtn = document.getElementById('uploadBtn');
    let filesList = [];

    dropZone.addEventListener('click', () => fileInput.click());
    fileInput.addEventListener('change', e => handleFiles(e.target.files));
    dropZone.addEventListener('dragover', e => { e.preventDefault(); });
    dropZone.addEventListener('drop', e => { e.preventDefault(); handleFiles(e.dataTransfer.files); });

    function handleFiles(files) {
      filesList = Array.from(files).map((f, i) => ({ file: f, id: 'f_' + Date.now() + '_' + i, status: 'Ready' }));
      fileList.innerHTML = '';
      filesList.forEach(item => {
        const div = document.createElement('div');
        div.className = 'file-item';
        div.innerHTML = `
          <div style="display:flex; justify-content:space-between;">
            <span class="file-name" style="max-width:75%;">\${item.file.name}</span>
            <span id="pct_\${item.id}" style="color:#FFD600; font-size:12px; font-weight:bold;">Ready</span>
          </div>
          <div class="progress-bg"><div class="progress-fill" id="bar_\${item.id}"></div></div>
        `;
        fileList.appendChild(div);
      });
      uploadBtn.disabled = filesList.length === 0;
    }

    uploadBtn.addEventListener('click', async () => {
      uploadBtn.disabled = true;
      try {
        const meta = filesList.map(f => ({ name: f.file.name, size: f.file.size }));
        const req = await fetch('/request-upload', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ files: meta })
        });
        const res = await req.json();
        if (!res.approved) return;

        for (let item of filesList) {
          const bar = document.getElementById('bar_' + item.id);
          const pct = document.getElementById('pct_' + item.id);
          await new Promise((resolve, reject) => {
            const xhr = new XMLHttpRequest();
            xhr.open('PUT', '/upload?name=' + encodeURIComponent(item.file.name));
            xhr.upload.onprogress = e => {
              if (e.lengthComputable) {
                const p = Math.round((e.loaded / e.total) * 100);
                bar.style.width = p + '%';
                pct.innerText = p + '%';
              }
            };
             xhr.onload = () => {
              if (xhr.status === 200) {
                pct.innerText = 'Sent';
                pct.style.color = '#FFD600';
                bar.style.background = '#FFD600';
                resolve();
              } else reject();
            };
            xhr.onerror = () => reject();
            xhr.send(item.file);
          });
        }
      } catch (e) {
        alert('Upload failed: ' + e);
      }
    });
  </script>
</body>
</html>
''';
    response.write(html);
    await response.close();
  }

  Future<void> _handlePutUpload(HttpRequest request) async {
    try {
      final rawName = request.uri.queryParameters['name'] ?? 'unknown_file';
      final fileName = rawName.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');
      final String savePath = '$_saveFolder/$fileName';

      final file = File(savePath);
      final sink = file.openWrite();

      final totalBytes = request.contentLength;
      int bytesReceived = 0;

      // Add to list immediately
      Map<String, dynamic> fileItem = {
        'name': fileName,
        'progress': 0.0,
        'path': savePath,
        'time': DateTime.now(),
      };
      setState(() {
        _receivedFiles.insert(0, fileItem);
      });

      await request.listen((chunk) {
        sink.add(chunk);
        bytesReceived += chunk.length;
        if (totalBytes > 0) {
          setState(() {
            fileItem['progress'] = (bytesReceived / totalBytes).clamp(0.0, 1.0);
          });
        }
      }).asFuture();

      await sink.close();
      setState(() {
        fileItem['progress'] = 1.0;
      });

      request.response.statusCode = HttpStatus.ok;
      await request.response.close();
    } catch (e) {
      request.response.statusCode = HttpStatus.internalServerError;
      await request.response.close();
    }
  }

  @override
  Widget build(BuildContext context) {
    final connectionUrl = _localIp != null ? 'http://$_localIp:$_port' : 'Checking network...';

    return Scaffold(
      backgroundColor: Colors.black,
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFF0E0E10), Color(0xFF08080A)],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 48.0, vertical: 24.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ── Android-style header ──
                Row(
                  children: [
                    Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: const Color(0xFF1C1C1E),
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
                      ),
                      child: TVFocusableButton(
                        borderRadius: BorderRadius.circular(24),
                        padding: EdgeInsets.zero,
                        onPressed: () => Navigator.of(context).pop(),
                        child: const Icon(Icons.arrow_back_ios_new_rounded, color: Colors.white, size: 20),
                      ),
                    ),
                    const SizedBox(width: 16),
                    RichText(
                      text: TextSpan(
                        children: [
                          TextSpan(
                            text: 'Web ',
                            style: GoogleFonts.outfit(
                              color: const Color(0xFFFFD600),
                              fontSize: 26,
                              fontWeight: FontWeight.w800,
                              letterSpacing: -0.5,
                            ),
                          ),
                          TextSpan(
                            text: 'Upload',
                            style: GoogleFonts.outfit(
                              color: Colors.white,
                              fontSize: 26,
                              fontWeight: FontWeight.bold,
                              letterSpacing: -0.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 24),

                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Left Panel: Connection Info & QR Code
                      Expanded(
                        flex: 4,
                        child: Container(
                          padding: const EdgeInsets.all(32),
                          decoration: BoxDecoration(
                            color: const Color(0xFF1C1C1E),
                            borderRadius: BorderRadius.circular(24),
                            border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
                          ),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                               if (_isHosting && _localIp != null)
                                Container(
                                  color: Colors.white,
                                  padding: const EdgeInsets.all(16),
                                  child: QrImageView(
                                    data: connectionUrl,
                                    version: QrVersions.auto,
                                    size: 220.0,
                                  ),
                                )
                              else
                                const SizedBox(
                                  height: 220,
                                  child: Center(child: CircularProgressIndicator(color: Color(0xFFFFD600))),
                                ),
                              const SizedBox(height: 32),
                              Text(
                                'Scan QR Code or visit this link on your phone/PC:',
                                textAlign: TextAlign.center,
                                style: GoogleFonts.outfit(
                                  color: Colors.white70,
                                  fontSize: 16,
                                ),
                              ),
                              const SizedBox(height: 12),
                              Text(
                                connectionUrl,
                                style: GoogleFonts.robotoMono(
                                  color: const Color(0xFFFFD600),
                                  fontSize: 24,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(height: 16),
                              const Text(
                                'Both devices must be on the same Wi-Fi network.',
                                style: TextStyle(color: Colors.white38, fontSize: 13),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 32),

                      // Right Panel: Received Files Monitor
                      Expanded(
                        flex: 5,
                        child: Container(
                          padding: const EdgeInsets.all(32),
                          decoration: BoxDecoration(
                            color: const Color(0xFF1C1C1E),
                            borderRadius: BorderRadius.circular(24),
                            border: Border.all(color: Colors.white.withOpacity(0.05)),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'TRANSFERS MONITOR',
                                style: GoogleFonts.outfit(
                                  color: Colors.white38,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 1.5,
                                ),
                              ),
                              const SizedBox(height: 24),
                              Expanded(
                                child: _receivedFiles.isEmpty
                                    ? Center(
                                        child: Text(
                                          'No active or completed transfers yet.',
                                          style: GoogleFonts.outfit(color: Colors.white38, fontSize: 15),
                                        ),
                                      )
                                    : ListView.builder(
                                        itemCount: _receivedFiles.length,
                                        itemBuilder: (context, index) {
                                          final file = _receivedFiles[index];
                                          final progress = file['progress'] as double;
                                          final isComplete = progress >= 1.0;
                                          final name = file['name'] as String;
                                          final path = file['path'] as String;

                                          return Container(
                                            margin: const EdgeInsets.only(bottom: 12),
                                            decoration: BoxDecoration(
                                              borderRadius: BorderRadius.circular(16),
                                              color: Colors.transparent,
                                            ),
                                            child: TVFocusableCard(
                                              autofocus: index == 0,
                                              onPressed: isComplete ? () => OpenFile.open(path) : null,
                                              backgroundColor: isComplete
                                                  ? const Color(0xFF00E676).withOpacity(0.06)
                                                  : const Color(0xFFFFD600).withOpacity(0.02),
                                              child: Padding(
                                                padding: const EdgeInsets.all(14.0),
                                                child: Column(
                                                  children: [
                                                    Row(
                                                      children: [
                                                        Container(
                                                          padding: const EdgeInsets.all(8),
                                                          decoration: BoxDecoration(
                                                            color: isComplete
                                                                ? const Color(0xFF00E676).withOpacity(0.15)
                                                                : const Color(0xFFFFD600).withOpacity(0.15),
                                                            shape: BoxShape.circle,
                                                          ),
                                                          child: Icon(
                                                            isComplete ? Icons.check_circle_rounded : _fileTypeIcon(name),
                                                            color: isComplete ? const Color(0xFF00E676) : const Color(0xFFFFD600),
                                                            size: 20,
                                                          ),
                                                        ),
                                                        const SizedBox(width: 12),
                                                        Expanded(
                                                          child: Column(
                                                            crossAxisAlignment: CrossAxisAlignment.start,
                                                            children: [
                                                              Text(
                                                                name,
                                                                style: GoogleFonts.outfit(
                                                                  color: Colors.white,
                                                                  fontWeight: FontWeight.w600,
                                                                ),
                                                                maxLines: 1,
                                                                overflow: TextOverflow.ellipsis,
                                                              ),
                                                              if (!isComplete)
                                                                Text(
                                                                  'Downloading... ${(progress * 100).toStringAsFixed(0)}%',
                                                                  style: const TextStyle(color: Color(0xFFFFD600), fontSize: 11),
                                                                )
                                                              else
                                                                const Text('Transfer complete ✓', style: TextStyle(color: Color(0xFF00E676), fontSize: 11)),
                                                            ],
                                                          ),
                                                        ),
                                                        if (isComplete)
                                                          const Icon(Icons.open_in_new_rounded, color: Color(0xFF00E676), size: 20),
                                                      ],
                                                    ),
                                                    if (!isComplete) ...[
                                                      const SizedBox(height: 10),
                                                      ClipRRect(
                                                        borderRadius: BorderRadius.circular(4),
                                                        child: LinearProgressIndicator(
                                                          value: progress,
                                                          minHeight: 4,
                                                          backgroundColor: Colors.white12,
                                                          valueColor: const AlwaysStoppedAnimation(Color(0xFFFFD600)),
                                                        ),
                                                      ),
                                                    ],
                                                  ],
                                                ),
                                              ),
                                            ),
                                          );
                                        },
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
        ),
      ),
    );
  }
}
