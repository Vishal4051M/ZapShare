import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;
import 'dart:io';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/services.dart';

class DownloadTask {
  final String url;
  String savePath;
  double progress;
  String status;
  DownloadTask({required this.url, required this.savePath, this.progress = 0.0, this.status = 'Waiting'});
}

class AndroidReceiveScreen extends StatefulWidget {
  const AndroidReceiveScreen({super.key});
  @override
  State<AndroidReceiveScreen> createState() => _AndroidReceiveScreenState();
}

class _AndroidReceiveScreenState extends State<AndroidReceiveScreen> {
  final TextEditingController _codeController = TextEditingController();
  String? _saveFolder;
  List<DownloadTask> _tasks = [];
  bool _downloading = false;
  int _activeDownloads = 0;
  final int _maxParallel = 2;
  String? _serverIp;
  List<Map<String, dynamic>> _fileList = [];

  List<String> _recentCodes = [];

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

  bool _decodeCode(String code) {
    try {
      if (!RegExp(r'^[A-Z0-9]{8}$').hasMatch(code)) return false;
      int n = int.parse(code, radix: 36);
      final ip = '${(n >> 24) & 0xFF}.${(n >> 16) & 0xFF}.${(n >> 8) & 0xFF}.${n & 0xFF}';
      final parts = ip.split('.').map(int.parse).toList();
      if (parts.length != 4 || parts.any((p) => p < 0 || p > 255)) return false;
      _serverIp = ip;
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _fetchFileListAndStart(String code) async {
    if (_saveFolder == null) return;
    if (!_decodeCode(code)) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Invalid code.')));
      return;
    }
    await _saveRecentCode(code);
    setState(() { _downloading = true; _tasks.clear(); _fileList.clear(); _activeDownloads = 0; });
    try {
      final url = 'http://$_serverIp:8080/list';
      final resp = await http.get(Uri.parse(url));
      if (resp.statusCode == 200) {
        final List files = jsonDecode(resp.body);
        _fileList = files.cast<Map<String, dynamic>>();
        _tasks = _fileList.map((f) => DownloadTask(
          url: 'http://$_serverIp:8080/file/${f['index']}',
          savePath: '',
          progress: 0.0,
          status: 'Waiting',
        )).toList();
        setState(() {});
        _startQueuedDownloads();
      } else {
        setState(() { _downloading = false; });
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to fetch file list')));
      }
    } catch (e) {
      setState(() { _downloading = false; });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
    }
  }

  void _startQueuedDownloads() {
    while (_activeDownloads < _maxParallel) {
      final next = _tasks.indexWhere((t) => t.status == 'Waiting');
      if (next == -1) break;
      setState(() { _activeDownloads++; });
      _downloadFile(_tasks[next]);
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
      String savePath = '$_saveFolder/$fileName';
      int count = 1;
      while (await File(savePath).exists()) {
        final parts = fileName.split('.');
        if (parts.length > 1) {
          final base = parts.sublist(0, parts.length - 1).join('.');
          final ext = parts.last;
          savePath = '$_saveFolder/${base}_$count.$ext';
        } else {
          savePath = '$_saveFolder/${fileName}_$count';
        }
        count++;
      }
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
      setState(() { task.status = 'Complete'; _activeDownloads--; });
      // Record transfer history
      try {
        final prefs = await SharedPreferences.getInstance();
        final history = prefs.getStringList('transfer_history') ?? [];
        final entry = {
          'fileName': fileName,
          'fileSize': contentLength,
          'direction': 'Received',
          'peer': _serverIp ?? '',
          'dateTime': DateTime.now().toIso8601String(),
        };
        history.insert(0, jsonEncode(entry));
        if (history.length > 100) history.removeLast();
        await prefs.setStringList('transfer_history', history);
      } catch (_) {}
      _startQueuedDownloads();
    } catch (e) {
      setState(() { task.status = 'Error: $e'; _activeDownloads--; });
      _startQueuedDownloads();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('ZapShare - Receive'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (_recentCodes.isNotEmpty)
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Recent Codes:', style: TextStyle(fontWeight: FontWeight.bold)),
                  ..._recentCodes.map((code) => Row(
                        children: [
                          Expanded(child: Text(code, style: const TextStyle(fontSize: 16))),
                          IconButton(
                            icon: const Icon(Icons.copy, size: 18),
                            onPressed: () {
                              Clipboard.setData(ClipboardData(text: code));
                              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Code copied!')));
                            },
                          ),
                        ],
                      )),
                  const SizedBox(height: 12),
                ],
              ),
            TextField(
              controller: _codeController,
              decoration: const InputDecoration(
                labelText: 'Enter 8-char ZapShare code',
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.text,
              onSubmitted: (val) {
                _fetchFileListAndStart(val.trim());
              },
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: Text(_saveFolder ?? 'No folder selected'),
                ),
                ElevatedButton(
                  onPressed: _pickSaveFolder,
                  child: const Text('Pick Folder'),
                ),
              ],
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: (_saveFolder != null && _codeController.text.isNotEmpty && !_downloading)
                  ? () {
                      _fetchFileListAndStart(_codeController.text.trim());
                    }
                  : null,
              icon: const Icon(Icons.download_rounded),
              label: const Text('Start Download'),
            ),
            const SizedBox(height: 24),
            Expanded(
              child: ListView.builder(
                itemCount: _tasks.length,
                itemBuilder: (context, index) {
                  final task = _tasks[index];
                  return Card(
                    margin: const EdgeInsets.symmetric(vertical: 8),
                    child: ListTile(
                      title: Text(task.url, style: const TextStyle(fontSize: 13)),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (task.savePath.isNotEmpty)
                            Text('Saved to: ${task.savePath}', style: const TextStyle(fontSize: 11)),
                          LinearProgressIndicator(
                            value: task.progress,
                            backgroundColor: Colors.black.withOpacity(0.12),
                            color: Colors.black,
                          ),
                          Text(task.status, style: TextStyle(fontSize: 12, color: task.status == 'Complete' ? Colors.green : Colors.black)),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
} 