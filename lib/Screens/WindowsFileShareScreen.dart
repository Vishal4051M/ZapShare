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
  String? _displayCode;

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
  }

  Future<void> _fetchLocalIp() async {
    final info = NetworkInfo();
    String? ip = await info.getWifiIP();
    setState(() {
      _localIp = ip;
      _displayCode = ip != null ? _ipToCode(ip) : null;
    });
  }

  Future<void> _pickFiles() async {
    setState(() => _loading = true);
    final result = await FilePicker.platform.pickFiles(allowMultiple: true);
    if (result != null) {
      setState(() {
        _files = result.files;
        _progressList = List.filled(result.files.length, 0.0);
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
      _files = files.map((e) => PlatformFile(
        name: e.uri.pathSegments.last,
        path: e.path,
        size: File(e.path).lengthSync(),
      )).toList();
      _progressList = List.filled(_files.length, 0.0);
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
    });
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
      appBar: AppBar(
        title: const Text('ZapShare',textAlign: TextAlign.center,style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold), ),
      ),
      body: Stack(
        children: [
          _buildFileSharingContent(),
          // App Info floating button (top right)
          Positioned(
            top: 32,
            right: 32,
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(24),
                onTap: () {
                  showDialog(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: Text('ZapShare Info'),
                      content: Text('Version 1.0.0\n\nA fast and secure file sharing app.'),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: Text('OK'),
                        ),
                      ],
                    ),
                  );
                },
                child: Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.08),
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: Icon(Icons.info_outline_rounded, color: Colors.white, size: 26),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // Only show File Sharing content
  Widget _buildFileSharingContent() {
    return Stack(
      children: [
        Column(
          children: [
            // File action buttons row (without Start/Stop Sharing)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24.0, horizontal: 16.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _buildActionButton(
                    icon: Icons.attach_file_rounded,
                    label: "Pick Files",
                    onPressed: _pickFiles,
                    color: kAccentYellow,
                  ),
                  const SizedBox(width: 16),
                  _buildActionButton(
                    icon: Icons.folder_rounded,
                    label: "Pick Folder",
                    onPressed: _pickFolder,
                    color: kAccentYellow,
                  ),
                  const SizedBox(width: 16),
                  _buildActionButton(
                    icon: Icons.clear_all_rounded,
                    label: "Clear Files",
                    onPressed: _files.isEmpty ? null : _clearFiles,
                    color: _files.isEmpty ? Colors.grey : Colors.orange,
                  ),
                ],
              ),
            ),
            // Existing file sharing content
            Expanded(
              child: Center(
                child: _loading
                    ? CircularProgressIndicator(color: kAccentYellow)
                    : _localIp == null
                        ? Padding(
                            padding: const EdgeInsets.all(24.0),
                            child: Text(
                              "No network connection detected. Please connect to WiFi or Ethernet.",
                              style: TextStyle(color: Colors.red, fontSize: 16, fontWeight: FontWeight.bold),
                              textAlign: TextAlign.center,
                            ),
                          )
                        : _files.isEmpty
                            ? const Text("No file selected", style: TextStyle(color: Colors.white))
                            : Column(
                                mainAxisAlignment: MainAxisAlignment.start,
                                crossAxisAlignment: CrossAxisAlignment.center,
                                children: [
                                  if (_isSharing && _displayCode != null)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 32, bottom: 12),
                                      child: Row(
                                        mainAxisAlignment: MainAxisAlignment.center,
                                        children: [
                                          SelectableText(
                                            _displayCode!,
                                            style: TextStyle(fontSize: 32, color: kAccentYellow, fontWeight: FontWeight.bold, letterSpacing: 2, shadows: [Shadow(color: Colors.black26, blurRadius: 6)]),
                                          ),
                                          IconButton(
                                            icon: Icon(Icons.copy, color: Colors.black),
                                            tooltip: "Copy Code",
                                            onPressed: () {
                                              Clipboard.setData(ClipboardData(text: _displayCode!));
                                              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Code copied!")));
                                            },
                                          ),
                                        ],
                                      ),
                                    ),
                                  if (_isSharing && _displayCode != null)
                                    Padding(
                                      padding: const EdgeInsets.only(bottom: 16),
                                      child: Text(
                                        "Share this code with the receiver.",
                                        style: TextStyle(fontSize: 15, color: Colors.black87),
                                        textAlign: TextAlign.center,
                                      ),
                                    ),
                                  Expanded(
                                    child: Padding(
                                      padding: const EdgeInsets.only(top: 32),
                                      child: Center(
                                        child: ConstrainedBox(
                                          constraints: BoxConstraints(maxWidth: 480),
                                          child: ListView.builder(
                                            itemCount: _files.length,
                                            itemBuilder: (context, index) {
                                              return Card(
                                                margin: const EdgeInsets.symmetric(vertical: 8, horizontal: 24),
                                                child: ListTile(
                                                  title: Text(_files[index].name, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                                                  subtitle: Column(
                                                    crossAxisAlignment: CrossAxisAlignment.start,
                                                    children: [
                                                      Text(_files[index].size != null ? '${_files[index].size} bytes' : '', style: const TextStyle(fontSize: 12)),
                                                      if (_isSharing)
                                                        Padding(
                                                          padding: const EdgeInsets.only(top: 6),
                                                          child: LinearProgressIndicator(
                                                            value: _progressList.length > index ? _progressList[index] : 0.0,
                                                            backgroundColor: Colors.black.withOpacity(0.12),
                                                            color: Colors.black,
                                                          ),
                                                        ),
                                                    ],
                                                  ),
                                                ),
                                              );
                                            },
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
              ),
            ),
          ],
        ),
        // Bottom center Start/Stop Sharing button
        if (_localIp != null)
          Positioned(
            left: 0,
            right: 0,
            bottom: 32,
            child: Center(
              child: ElevatedButton.icon(
                icon: Icon(_isSharing ? Icons.stop_rounded : Icons.send_rounded, color: Colors.white),
                label: Text(_isSharing ? "Stop Sharing" : "Start Sharing", style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _files.isEmpty
                      ? Colors.grey
                      : _isSharing
                          ? Colors.red
                          : kAccentYellow,
                  padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 18),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  elevation: 4,
                ),
                onPressed: (_files.isEmpty || _loading || _localIp == null)
                    ? null
                    : _isSharing
                        ? _stopServer
                        : _startServer,
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildActionButton({
    required IconData icon,
    required String label,
    required VoidCallback? onPressed,
    required Color color,
  }) {
    return ElevatedButton.icon(
      icon: Icon(icon, color: color),
      label: Text(label, style: TextStyle(color: color)),
      style: ElevatedButton.styleFrom(
        backgroundColor: Colors.white.withOpacity(0.08),
        foregroundColor: color,
        disabledBackgroundColor: Colors.grey.withOpacity(0.08),
        disabledForegroundColor: Colors.grey,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        elevation: 0,
      ),
      onPressed: onPressed,
    );
  }
} 