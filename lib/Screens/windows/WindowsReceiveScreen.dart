import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;
import 'dart:io';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

class WindowsReceiveScreen extends StatefulWidget {
  const WindowsReceiveScreen({super.key});
  @override
  State<WindowsReceiveScreen> createState() => _WindowsReceiveScreenState();
}

const Color kPikachuYellow = Color(0xFFFFD600);
const Color kPikachuRed = Color(0xFFFF6B35);

class DownloadTask {
  final String url;
  String savePath;
  double progress;
  String status;
  DownloadTask({required this.url, this.savePath = '', this.progress = 0.0, this.status = 'Waiting'});
}

class _WindowsReceiveScreenState extends State<WindowsReceiveScreen> {
  final TextEditingController _codeController = TextEditingController();
  String? _saveFolder;
  List<DownloadTask> _tasks = [];
  bool _downloading = false;
  int _activeDownloads = 0;
  final int _maxParallel = 2;
  String? _serverIp;
  List<Map<String, dynamic>> _fileList = [];
  bool _loading = false;

  List<String> _recentCodes = [];
  String _receiveView = 'available'; // 'available' or 'downloaded'
  List<Map<String, dynamic>> _downloadHistory = [];

  @override
  void initState() {
    super.initState();
    _loadRecentCodes();
  }

  Future<void> _loadRecentCodes() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _recentCodes = prefs.getStringList('recent_codes') ?? [];
    });
  }

  Future<void> _saveRecentCode(String code) async {
    final prefs = await SharedPreferences.getInstance();
    List<String> codes = prefs.getStringList('recent_codes') ?? [];
    codes.remove(code);
    codes.insert(0, code);
    if (codes.length > 2) codes = codes.sublist(0, 2);
    await prefs.setStringList('recent_codes', codes);
    setState(() {
      _recentCodes = codes;
    });
  }

  Future<void> _pickSaveFolder() async {
    String? result = await FilePicker.platform.getDirectoryPath(dialogTitle: 'Select Folder to Save');
    setState(() => _saveFolder = result);
  }

  Future<String> _getDefaultDownloadFolder() async {
    try {
      final downloadsDir = await getDownloadsDirectory();
      if (downloadsDir != null) return downloadsDir.path;
    } catch (e) {
      // ignore
    }
    return '${Platform.environment['USERPROFILE'] ?? 'C:\\Users\\User'}\\Downloads';
  }

  Future<void> _fetchFileListAndStart(String code) async {
    if (_saveFolder == null) {
      _saveFolder = await _getDefaultDownloadFolder();
      setState(() {});
    }

    // decode code into IP
    try {
      if (!RegExp(r'^[A-Z0-9]{8}\$').hasMatch(code)) {
        // still attempt; fallthrough
      }
    } catch (_) {}

    // Very small, forgiving implementation: set serverIp if code decodes
    try {
      final n = int.parse(code, radix: 36);
      final ip = '${(n >> 24) & 0xFF}.${(n >> 16) & 0xFF}.${(n >> 8) & 0xFF}.${n & 0xFF}';
      _serverIp = ip;
    } catch (_) {
      // ignore - invalid code
    }

    if (_serverIp == null) return;

    await _saveRecentCode(code);
    setState(() { _loading = true; _tasks.clear(); _fileList.clear(); });
    try {
        final url = 'http://$_serverIp:8080/list';
      final resp = await http.get(Uri.parse(url));
      if (resp.statusCode == 200) {
        final List files = jsonDecode(resp.body);
        _fileList = files.cast<Map<String, dynamic>>();
  _tasks = _fileList.map((f) => DownloadTask(url: 'http://$_serverIp:8080/file/${f['index']}', savePath: '', progress: 0.0)).toList();
        setState(() { _loading = false; });
        _startQueuedDownloads();
      } else {
        setState(() { _loading = false; });
      }
    } catch (e) {
      setState(() { _loading = false; });
    }
  }

  Future<void> _loadDownloadHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final history = prefs.getStringList('transfer_history') ?? [];
    setState(() {
      _downloadHistory = history.map((s) {
        try {
          return jsonDecode(s) as Map<String, dynamic>;
        } catch (_) {
          return {'fileName': s, 'fileLocation': ''};
        }
      }).toList();
    });
  }

  Widget _buildDownloadedList() {
    if (_downloadHistory.isEmpty) {
      return Center(child: Text('No downloads yet', style: TextStyle(color: Colors.grey[400], fontSize: 16)));
    }
    return ListView.builder(
      itemCount: _downloadHistory.length,
      itemBuilder: (context, index) {
        final item = _downloadHistory[index];
        return Container(
          margin: EdgeInsets.only(bottom: 12),
          decoration: BoxDecoration(color: Colors.grey[900], borderRadius: BorderRadius.circular(12), border: Border.all(color: Colors.grey[800]!, width: 1)),
          child: ListTile(
            title: Text(item['fileName'] ?? 'Unknown', style: TextStyle(color: Colors.white)),
            subtitle: Text(item['fileLocation'] ?? '', style: TextStyle(color: Colors.grey[400])),
          ),
        );
      },
    );
  }


  void _startQueuedDownloads() {
    while (_activeDownloads < _maxParallel) {
      final next = _tasks.indexWhere((t) => t.status == 'Waiting');
      if (next == -1) break;
      _downloadFile(_tasks[next]);
      _activeDownloads++;
    }
  }

  Future<void> _downloadFile(DownloadTask task) async {
    setState(() { task.status = 'Downloading'; });
    try {
      final response = await http.Client().send(http.Request('GET', Uri.parse(task.url)));
      final contentDisposition = response.headers['content-disposition'];
      String fileName = 'received_file';
      if (contentDisposition != null) {
        final match = RegExp(r'filename=\"?([^\";]+)\"?').firstMatch(contentDisposition);
        if (match != null) fileName = match.group(1)!;
      }
      final savePath = '$_saveFolder/$fileName';
      task.savePath = savePath;
      final file = File(savePath);
      final sink = file.openWrite();
      int received = 0;
      final contentLength = response.contentLength ?? 1;
      await for (var chunk in response.stream) {
        sink.add(chunk);
        received += chunk.length;
        setState(() { task.progress = received / contentLength; });
      }
      await sink.close();
      setState(() { task.status = 'Complete'; });
      // Record transfer history
      try {
        final prefs = await SharedPreferences.getInstance();
        final history = prefs.getStringList('transfer_history') ?? [];
        final entry = {
          'fileName': fileName,
          'fileSize': contentLength,
          'direction': 'Received',
          'peer': _serverIp ?? '',
          'peerDeviceName': null, // Could be enhanced to lookup device name
          'dateTime': DateTime.now().toIso8601String(),
          'fileLocation': savePath, // Save the actual file path
        };
        history.insert(0, jsonEncode(entry));
        if (history.length > 100) history.removeLast();
        await prefs.setStringList('transfer_history', history);
      } catch (_) {}
      _activeDownloads--;
      _startQueuedDownloads();
    } catch (e) {
      setState(() { task.status = 'Error: $e'; });
    } finally {
      _activeDownloads--;
      _startQueuedDownloads();
    }
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
                  Expanded(
                    child: Text(
                      'Receive Files',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 24,
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
                // Reduce top padding and add some bottom padding
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 20),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    return Container(
                      decoration: BoxDecoration(
                        color: Colors.transparent,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: IntrinsicHeight(
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            // Left panel (50%)
                            Flexible(
                              flex: 5,
                              child: Container(
                                padding: const EdgeInsets.only(top: 0, right: 12.0, bottom: 12.0),
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: Colors.grey[850],
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  padding: const EdgeInsets.all(12),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      if (_recentCodes.isNotEmpty) ...[
                                        _buildSectionHeader('Recent Codes'),
                                        const SizedBox(height: 12),
                                        Container(
                                          height: 50,
                                          child: ListView.builder(
                                            scrollDirection: Axis.horizontal,
                                            itemCount: _recentCodes.length,
                                            itemBuilder: (context, index) {
                                              final code = _recentCodes[index];
                                              return Container(
                                                margin: EdgeInsets.only(right: 12),
                                                child: _buildCodeChip(code),
                                              );
                                            },
                                          ),
                                        ),
                                        const SizedBox(height: 10),
                                      ],

                                      _buildSectionHeader('Enter Code'),
                                      const SizedBox(height: 10),
                                      _buildCodeInput(),
                                      const SizedBox(height: 10),

                                      _buildSectionHeader('Save Location'),
                                      const SizedBox(height: 10),
                                      _buildFolderSelector(),
                                      const SizedBox(height: 10),

                                      if (_codeController.text.isNotEmpty) ...[
                                        _buildDownloadButton(),
                                        const SizedBox(height: 10),
                                      ],
                                    ],
                                  ),
                                ),
                              ),
                            ),

                            const SizedBox(width: 10),

                            // Right panel (50%)
                            Flexible(
                              flex: 5,
                              child: Container(
                                padding: const EdgeInsets.only(top: 0, left: 12.0, bottom: 12.0),
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: Colors.grey[850],
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  padding: const EdgeInsets.all(12),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Expanded(
                                            child: GestureDetector(
                                              onTap: () {
                                                setState(() {
                                                  _receiveView = 'available';
                                                });
                                              },
                                              child: Container(
                                                padding: EdgeInsets.symmetric(vertical: 12),
                                                decoration: BoxDecoration(
                                                  color: _receiveView == 'available' ? Colors.grey[850] : Colors.grey[900],
                                                  borderRadius: BorderRadius.circular(12),
                                                  border: Border.all(color: _receiveView == 'available' ? Colors.yellow[300]! : Colors.grey[800]!, width: 1),
                                                ),
                                                child: Center(child: Text('Available', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600))),
                                              ),
                                            ),
                                          ),
                                          SizedBox(width: 12),
                                          Expanded(
                                            child: GestureDetector(
                                              onTap: () async {
                                                await _loadDownloadHistory();
                                                setState(() {
                                                  _receiveView = 'downloaded';
                                                });
                                              },
                                              child: Container(
                                                padding: EdgeInsets.symmetric(vertical: 12),
                                                decoration: BoxDecoration(
                                                  color: _receiveView == 'downloaded' ? Colors.grey[850] : Colors.grey[900],
                                                  borderRadius: BorderRadius.circular(12),
                                                  border: Border.all(color: _receiveView == 'downloaded' ? Colors.yellow[300]! : Colors.grey[800]!, width: 1),
                                                ),
                                                child: Center(child: Text('Downloaded', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600))),
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),

                                      const SizedBox(height: 12),

                                      Expanded(
                                        child: _receiveView == 'available' ? _buildFileList() : _buildDownloadedList(),
                                      ),
                                    ],
                                  ),
                                ),
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
          ],
        ),
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Text(
      title,
      style: TextStyle(
        color: Colors.grey[400],
        fontSize: 14,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.5,
      ),
    );
  }

  Widget _buildCodeChip(String code) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.grey[900],
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.grey[800]!, width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            code,
            style: TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.w500,
              fontFamily: 'monospace',
            ),
          ),
          SizedBox(width: 8),
          GestureDetector(
            onTap: () {
              Clipboard.setData(ClipboardData(text: code));
              _codeController.text = code;
            },
            child: Icon(
              Icons.copy_rounded,
              color: Colors.yellow[300],
              size: 18,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCodeInput() {
    return Container(
      height: 50,
      decoration: BoxDecoration(
        color: Colors.grey[900],
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey[800]!, width: 1),
      ),
      child: TextField(
        controller: _codeController,
        decoration: InputDecoration(
          hintText: 'Enter 8-character code',
          hintStyle: TextStyle(color: Colors.grey[500], fontSize: 16),
          border: InputBorder.none,
          contentPadding: EdgeInsets.symmetric(horizontal: 20, vertical: 18),
        ),
        style: TextStyle(
          color: Colors.white,
          fontSize: 18,
          fontWeight: FontWeight.w500,
          fontFamily: 'monospace',
        ),
        textAlign: TextAlign.center,
        onSubmitted: (val) => _fetchFileListAndStart(val.trim()),
      ),
    );
  }
Widget _buildFolderSelector() {
  return Container(
    height: 80,
    padding: EdgeInsets.symmetric(horizontal: 20),
    decoration: BoxDecoration(
      color: Colors.grey[900],
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: Colors.grey[800]!, width: 1),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Icon(
          Icons.folder_rounded,
          color: Colors.yellow[300],
          size: 26,
        ),

        SizedBox(width: 16),

        Expanded(
          child: Text(
            _saveFolder ?? 'Downloads (default)',
            style: TextStyle(
              color: _saveFolder != null ? Colors.white : Colors.grey[500],
              fontSize: 15,
              fontWeight: FontWeight.w500,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),

        SizedBox(width: 16),

        // FIXED BUTTON
        Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: Colors.yellow[300],
            borderRadius: BorderRadius.circular(12),
          ),
          child: IconButton(
            padding: EdgeInsets.zero, // important fix
            icon: Icon(Icons.edit_rounded, color: Colors.black, size: 20),
            onPressed: _pickSaveFolder,
          ),
        ),
      ],
    ),
  );
}

  Widget _buildDownloadButton() {
    final isEnabled = !_downloading;
    
    return Container(
      width: double.infinity,
      height: 50,
      decoration: BoxDecoration(
        color: isEnabled ? Colors.yellow[300] : Colors.grey[700],
        borderRadius: BorderRadius.circular(16),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: isEnabled ? () => _fetchFileListAndStart(_codeController.text.trim()) : null,
          borderRadius: BorderRadius.circular(16),
          child: Center(
            child: Text(
              'Start Download',
              style: TextStyle(
                color: isEnabled ? Colors.black : Colors.grey[400],
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFileList() {
    return ListView.builder(
                itemCount: _tasks.length,
                itemBuilder: (context, index) {
                  final task = _tasks[index];
        return Container(
          margin: EdgeInsets.only(bottom: 12),
          decoration: BoxDecoration(
            color: Colors.grey[900],
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.grey[800]!, width: 1),
          ),
          child: Padding(
            padding: EdgeInsets.all(20),
            child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        task.url.split('/').last,
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                          if (task.savePath.isNotEmpty)
                      Container(
                        padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: Colors.grey[800],
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          'Saved',
                          style: TextStyle(
                            color: Colors.green[300],
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                  ],
                ),
                if (task.savePath.isNotEmpty) ...[
                  SizedBox(height: 8),
                  Text(
                    'Saved to: ${task.savePath}',
                    style: TextStyle(
                      color: Colors.grey[400],
                      fontSize: 12,
                    ),
                  ),
                ],
                SizedBox(height: 16),
                          Row(
                            children: [
                              Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                                child: LinearProgressIndicator(
                                  value: task.progress,
                          backgroundColor: Colors.grey[800],
                          color: Colors.yellow[300],
                          minHeight: 6,
                                ),
                              ),
                          ),
                    SizedBox(width: 16),
                          Text(
                            '${(task.progress * 100).toStringAsFixed(1)}%',
                            style: TextStyle(
                        color: Colors.yellow[300],
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                SizedBox(height: 8),
                          Text(
                            task.status,
                            style: TextStyle(
                              color: task.status == 'Complete' 
                      ? Colors.green[300] 
                                : task.status == 'Error' 
                        ? Colors.red[300] 
                        : Colors.yellow[300],
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
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
            'Fetching Files...',
            style: TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Please wait while we connect to the server',
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
              Icons.folder_open_rounded,
              color: Colors.grey[600],
              size: 40,
            ),
          ),
          const SizedBox(height: 24),
          Text(
            'No Files Found',
            style: TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Make sure the sender is sharing files\nand both devices are on the same network',
            style: TextStyle(
              color: Colors.grey[400],
              fontSize: 16,
              fontWeight: FontWeight.w400,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 32),
          _buildActionButton(
            icon: Icons.refresh_rounded,
            label: 'Try Again',
            onTap: () => _fetchFileListAndStart(_codeController.text.trim()),
            color: Colors.yellow[300]!,
            textColor: Colors.black,
          ),
        ],
      ),
    );
  }

  Widget _buildActionButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
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
} 