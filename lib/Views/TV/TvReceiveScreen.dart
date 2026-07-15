import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:open_file/open_file.dart';
import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'package:zap_share/widgets/tv_widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zap_share/Views/TV/TvFileListScreen.dart';

// ─────────── Download task model ───────────

class DownloadTask {
  final String url;
  final String fileName;
  final int fileSize;
  String savePath;
  double progress;
  String status;
  bool isSelected;
  int bytesReceived;
  StreamSubscription? downloadSubscription;
  IOSink? fileSink;

  DownloadTask({
    required this.url,
    required this.fileName,
    required this.fileSize,
    required this.savePath,
    this.progress = 0.0,
    this.status = 'Waiting',
    this.isSelected = true,
    this.bytesReceived = 0,
  });

  Future<void> cancel() async {
    await downloadSubscription?.cancel();
    downloadSubscription = null;
    await fileSink?.close();
    fileSink = null;
    status = 'Cancelled';
  }
}

// ─────────── Keyboard layout ───────────

class TvReceiveScreen extends StatefulWidget {
  final String? autoConnectCode;
  const TvReceiveScreen({super.key, this.autoConnectCode});

  @override
  State<TvReceiveScreen> createState() => _TvReceiveScreenState();
}

class _TvReceiveScreenState extends State<TvReceiveScreen> {
  // ── State ──
  String _code = '';
  String? _serverIp;
  int _serverPort = 8080;
  bool _loading = false;
  bool _downloading = false;
  String? _saveFolder;

  List<DownloadTask> _tasks = [];
  List<String> _recentCodes = [];

  // Keyboard rows — groups of keys for the TV keyboard layout
  static const _keyboardRows = [
    ['1', '2', '3', '4', '5', '6', '7', '8', '9', '0'],
    ['A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J'],
    ['K', 'L', 'M', 'N', 'O', 'P', 'Q', 'R', 'S', 'T'],
    ['U', 'V', 'W', 'X', 'Y', 'Z', '⌫', 'CLR', '↵', ''],
  ];

  @override
  void initState() {
    super.initState();
    _initStorage();
    _loadRecentCodes();
    if (widget.autoConnectCode != null && widget.autoConnectCode!.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        setState(() {
          _code = widget.autoConnectCode!;
        });
        _fetchFiles();
      });
    }
  }

  Future<void> _initStorage() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString('tv_download_folder');
    _saveFolder = saved ?? await _getDefaultDownloadFolder();
    setState(() {});
  }

  Future<void> _loadRecentCodes() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      setState(() {
        _recentCodes = prefs.getStringList('recent_codes') ?? [];
      });
    } catch (_) {}
  }

  Future<void> _saveRecentCode(String code) async {
    if (code.trim().isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      _recentCodes.remove(code);
      _recentCodes.insert(0, code);
      if (_recentCodes.length > 5) _recentCodes = _recentCodes.sublist(0, 5);
      await prefs.setStringList('recent_codes', _recentCodes);
      setState(() {});
    } catch (_) {}
  }

  Future<String> _getDefaultDownloadFolder() async {
    final candidate = Directory('/storage/emulated/0/Download/ZapShare');
    if (Platform.isAndroid) {
      try {
        if (!await Permission.storage.isGranted) await Permission.storage.request();
        if (!await candidate.exists()) await candidate.create(recursive: true);
        return candidate.path;
      } catch (_) {}
    }
    final dir = await getDownloadsDirectory();
    if (dir != null) {
      final zap = Directory('${dir.path}/ZapShare');
      if (!await zap.exists()) await zap.create(recursive: true);
      return zap.path;
    }
    return '/storage/emulated/0/Download/ZapShare';
  }

  bool _decodeCode(String code) {
    try {
      if (code.length < 8) return false;
      int n = int.parse(code.substring(0, 8), radix: 36);
      _serverIp = '${(n >> 24) & 0xFF}.${(n >> 16) & 0xFF}.${(n >> 8) & 0xFF}.${n & 0xFF}';
      _serverPort = code.length >= 11 ? int.parse(code.substring(8, 11), radix: 36) : 8080;
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _fetchFiles() async {
    if (!_decodeCode(_code)) {
      _showMessage('Invalid connection code', Colors.red);
      return;
    }
    setState(() {
      _loading = true;
      _tasks.clear();
    });
    try {
      final response = await http
          .get(Uri.parse('http://$_serverIp:$_serverPort/list'))
          .timeout(const Duration(seconds: 8));
      if (response.statusCode == 200) {
        final files = jsonDecode(response.body) as List;
        _saveRecentCode(_code);
        setState(() {
          _loading = false;
        });
        if (mounted) {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => TvFileListScreen(
                serverIp: _serverIp!,
                serverPort: _serverPort,
                files: List<Map<String, dynamic>>.from(files),
              ),
            ),
          );
        }
      } else {
        throw Exception('Server error: ${response.statusCode}');
      }
    } catch (e) {
      setState(() => _loading = false);
      _showMessage('Failed to connect: $e', Colors.red);
    }
  }

  Future<void> _startDownloads() async {
    if (_tasks.isEmpty) return;
    setState(() => _downloading = true);
    for (final task in _tasks) {
      if (!task.isSelected) continue;
      await _downloadFile(task);
    }
    setState(() => _downloading = false);
    _showMessage('Downloads complete', const Color(0xFFFFD600));
  }

  Future<void> _downloadFile(DownloadTask task) async {
    setState(() => task.status = 'Downloading');
    try {
      final client = http.Client();
      final response = await client.send(http.Request('GET', Uri.parse(task.url)));
      final saveDir = _saveFolder ?? '/storage/emulated/0/Download/ZapShare';
      final file = File('$saveDir/${task.fileName}');
      final sink = file.openWrite();
      task.fileSink = sink;
      int received = 0;
      final completer = Completer<void>();
      task.downloadSubscription = response.stream.listen(
        (chunk) {
          sink.add(chunk);
          received += chunk.length;
          if (mounted) {
            setState(() {
              task.bytesReceived = received;
              task.progress = task.fileSize > 0 ? received / task.fileSize : 0.5;
            });
          }
        },
        onDone: () => completer.complete(),
        onError: (e) => completer.completeError(e),
        cancelOnError: true,
      );
      await completer.future;
      await sink.close();
      task.fileSink = null;
      task.downloadSubscription = null;
      if (mounted) {
        setState(() {
          task.status = 'Complete';
          task.savePath = file.path;
        });
      }
    } catch (e) {
      if (mounted) setState(() => task.status = task.status != 'Cancelled' ? 'Failed' : 'Cancelled');
    }
  }

  Future<void> _cancelDownload(DownloadTask task) async {
    await task.cancel();
    if (mounted) setState(() {});
  }

  void _showMessage(String msg, Color color) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg, style: GoogleFonts.outfit(color: Colors.black, fontWeight: FontWeight.w600)),
      backgroundColor: color,
      duration: const Duration(seconds: 2),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      behavior: SnackBarBehavior.floating,
      margin: const EdgeInsets.fromLTRB(48, 0, 48, 24),
    ));
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  void _onKeyPress(String key) {
    if (key == '⌫') {
      if (_code.isNotEmpty) setState(() => _code = _code.substring(0, _code.length - 1));
    } else if (key == 'CLR') {
      setState(() => _code = '');
    } else if (key == '↵') {
      _fetchFiles();
    } else if (key.isNotEmpty && _code.length < 11) {
      setState(() => _code += key);
    }
  }

  @override
  Widget build(BuildContext context) {
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
                // ── Header ──
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
                    Expanded(
                      child: RichText(
                        text: TextSpan(
                          children: [
                            TextSpan(
                              text: 'Receive ',
                              style: GoogleFonts.outfit(
                                color: const Color(0xFFFFD600),
                                fontSize: 26,
                                fontWeight: FontWeight.w800,
                                letterSpacing: -0.5,
                              ),
                            ),
                            TextSpan(
                              text: 'By Code',
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
                    ),
                    // Download folder indicator
                    TVFocusableButton(
                      onPressed: null, // folder selection not available via TV
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                      borderRadius: BorderRadius.circular(14),
                      backgroundColor: const Color(0xFF1C1C1E),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.folder_open_rounded, color: Color(0xFFFFD600), size: 16),
                          const SizedBox(width: 8),
                          Text(
                            _saveFolder?.split('/').last ?? 'ZapShare',
                            style: GoogleFonts.outfit(color: Colors.white70, fontSize: 13),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 28),

                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // ── Left: Code Entry + Keyboard ──
                      SizedBox(
                        width: 420,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'ENTER CODE',
                              style: GoogleFonts.outfit(
                                color: Colors.grey[400],
                                fontSize: 11,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 1.2,
                              ),
                            ),
                            const SizedBox(height: 12),

                            // Code display
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                              decoration: BoxDecoration(
                                color: const Color(0xFF1C1C1E),
                                borderRadius: BorderRadius.circular(20),
                                border: Border.all(
                                  color: _code.isNotEmpty
                                      ? const Color(0xFFFFD600).withValues(alpha: 0.4)
                                      : Colors.white.withValues(alpha: 0.07),
                                  width: 1.5,
                                ),
                              ),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: List.generate(11, (i) {
                                  final hasChar = i < _code.length;
                                  final isCursor = i == _code.length && _code.length < 11;
                                  return Container(
                                    width: 28,
                                    height: 40,
                                    margin: EdgeInsets.symmetric(horizontal: 1.5)
                                        .copyWith(left: i == 8 ? 8 : 1.5),
                                    decoration: BoxDecoration(
                                      color: hasChar
                                          ? const Color(0xFFFFD600).withValues(alpha: 0.12)
                                          : Colors.black.withValues(alpha: 0.3),
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(
                                        color: isCursor
                                            ? const Color(0xFFFFD600)
                                            : hasChar
                                                ? const Color(0xFFFFD600).withValues(alpha: 0.35)
                                                : Colors.white.withValues(alpha: 0.1),
                                        width: isCursor ? 2.0 : 1.0,
                                      ),
                                      boxShadow: isCursor
                                          ? [
                                              BoxShadow(
                                                color: const Color(0xFFFFD600).withValues(alpha: 0.4),
                                                blurRadius: 10,
                                                spreadRadius: 1,
                                              ),
                                            ]
                                          : null,
                                    ),
                                    child: Center(
                                      child: hasChar
                                          ? Text(
                                              _code[i],
                                              style: GoogleFonts.outfit(
                                                color: Colors.white,
                                                fontSize: 18,
                                                fontWeight: FontWeight.w700,
                                              ),
                                            )
                                          : isCursor
                                              ? Container(width: 2, height: 20, color: const Color(0xFFFFD600))
                                              : Text(
                                                  '•',
                                                  style: TextStyle(color: Colors.grey[700], fontSize: 18),
                                                ),
                                    ),
                                  );
                                }),
                              ),
                            ),

                            // Recent codes
                            if (_recentCodes.isNotEmpty) ...[
                              const SizedBox(height: 14),
                              Text(
                                'RECENT',
                                style: GoogleFonts.outfit(
                                  color: Colors.grey[400],
                                  fontSize: 10,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 1.2,
                                ),
                              ),
                              const SizedBox(height: 8),
                              SizedBox(
                                height: 42,
                                child: ListView.separated(
                                  scrollDirection: Axis.horizontal,
                                  itemCount: _recentCodes.length,
                                  separatorBuilder: (_, __) => const SizedBox(width: 8),
                                  itemBuilder: (context, i) => TVFocusableButton(
                                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                                    borderRadius: BorderRadius.circular(12),
                                    backgroundColor: const Color(0xFF1C1C1E),
                                    onPressed: () => setState(() => _code = _recentCodes[i]),
                                    child: Text(
                                      _recentCodes[i],
                                      style: GoogleFonts.outfit(
                                        color: const Color(0xFFFFD600),
                                        fontSize: 12,
                                        fontWeight: FontWeight.bold,
                                        letterSpacing: 1.5,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ],

                            const SizedBox(height: 16),

                            // TV Keyboard grid
                            Expanded(child: _buildKeyboard()),
                          ],
                        ),
                      ),

                      const SizedBox(width: 24),
                      Container(width: 1, color: Colors.white.withValues(alpha: 0.06)),
                      const SizedBox(width: 24),

                      // ── Right: Files panel ──
                      Expanded(
                        child: Container(
                          padding: const EdgeInsets.all(24),
                          decoration: BoxDecoration(
                            color: const Color(0xFF141416),
                            borderRadius: BorderRadius.circular(24),
                            border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(
                                    'AVAILABLE FILES',
                                    style: GoogleFonts.outfit(
                                      color: Colors.grey[400],
                                      fontSize: 11,
                                      fontWeight: FontWeight.w800,
                                      letterSpacing: 1.2,
                                    ),
                                  ),
                                  if (_tasks.isNotEmpty && !_downloading)
                                    TVFocusableButton(
                                      onPressed: _startDownloads,
                                      backgroundColor: const Color(0xFFFFD600),
                                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
                                      borderRadius: BorderRadius.circular(12),
                                      child: Text(
                                        'Download All',
                                        style: GoogleFonts.outfit(
                                          color: Colors.black,
                                          fontSize: 13,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                              const SizedBox(height: 16),
                              Expanded(
                                child: _loading
                                    ? const Center(child: CircularProgressIndicator(color: Color(0xFFFFD600)))
                                    : _tasks.isEmpty
                                        ? Center(
                                            child: Column(
                                              mainAxisAlignment: MainAxisAlignment.center,
                                              children: [
                                                Icon(Icons.download_rounded, size: 52, color: Colors.white.withValues(alpha: 0.08)),
                                                const SizedBox(height: 14),
                                                Text(
                                                  'Enter the code on the left\nto pull shared files.',
                                                  style: GoogleFonts.outfit(color: Colors.white38, fontSize: 15, height: 1.6),
                                                  textAlign: TextAlign.center,
                                                ),
                                              ],
                                            ),
                                          )
                                        : ListView.builder(
                                            itemCount: _tasks.length,
                                            itemBuilder: (context, i) => _buildFileTask(_tasks[i]),
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

  Widget _buildKeyboard() {
    return Column(
      children: _keyboardRows.map((row) {
        return Expanded(
          child: Row(
            children: row.map((key) {
              if (key.isEmpty) return const Expanded(child: SizedBox());
              final isConnect = key == '↵';
              final isBackspace = key == '⌫';
              final isClear = key == 'CLR';
              final isSpecial = isConnect || isBackspace || isClear;

              return Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(3.0),
                  child: SizedBox(
                    height: double.infinity,
                    child: TVFocusableButton(
                      padding: EdgeInsets.zero,
                      borderRadius: BorderRadius.circular(12),
                      backgroundColor: isConnect
                          ? const Color(0xFFFFD600)
                          : isSpecial
                              ? const Color(0xFF2C2C2E)
                              : const Color(0xFF1C1C1E),
                      focusColor: isConnect ? const Color(0xFFFFD600) : const Color(0xFFFFD600),
                      onPressed: () => _onKeyPress(key),
                      child: Center(
                        child: isBackspace
                            ? Icon(Icons.backspace_rounded,
                                color: Colors.white, size: 18)
                            : Text(
                                key,
                                style: GoogleFonts.outfit(
                                  color: isConnect ? Colors.black : Colors.white,
                                  fontSize: isConnect ? 12 : 16,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                      ),
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildFileTask(DownloadTask task) {
    final isComplete = task.status == 'Complete';
    final isDownloading = task.status == 'Downloading';

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.02),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFD600).withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  isComplete ? Icons.done_all_rounded : Icons.download_rounded,
                  color: const Color(0xFFFFD600),
                  size: 18,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      task.fileName,
                      style: GoogleFonts.outfit(color: Colors.white, fontWeight: FontWeight.w600),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      _formatBytes(task.fileSize),
                      style: const TextStyle(color: Colors.white38, fontSize: 12),
                    ),
                  ],
                ),
              ),
              if (isComplete)
                TVFocusableButton(
                  onPressed: () => OpenFile.open(task.savePath),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                  borderRadius: BorderRadius.circular(10),
                  backgroundColor: const Color(0xFFFFD600).withValues(alpha: 0.12),
                  child: Text('Open', style: GoogleFonts.outfit(color: const Color(0xFFFFD600), fontSize: 13, fontWeight: FontWeight.bold)),
                )
              else if (isDownloading)
                TVFocusableButton(
                  onPressed: () => _cancelDownload(task),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                  borderRadius: BorderRadius.circular(10),
                  backgroundColor: Colors.red.withValues(alpha: 0.1),
                  focusColor: Colors.redAccent,
                  child: Text('Cancel', style: GoogleFonts.outfit(color: Colors.redAccent, fontSize: 13)),
                ),
            ],
          ),
          if (isDownloading) ...[
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: task.progress,
                backgroundColor: Colors.white12,
                valueColor: const AlwaysStoppedAnimation(Color(0xFFFFD600)),
                minHeight: 4,
              ),
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  _formatBytes(task.bytesReceived),
                  style: GoogleFonts.outfit(color: Colors.white38, fontSize: 11),
                ),
                Text(
                  '${(task.progress * 100).toStringAsFixed(0)}%',
                  style: GoogleFonts.outfit(color: const Color(0xFFFFD600), fontSize: 11, fontWeight: FontWeight.bold),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
