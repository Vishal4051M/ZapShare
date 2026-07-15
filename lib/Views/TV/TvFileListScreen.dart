import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:open_file/open_file.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:zap_share/widgets/tv_widgets.dart';
import 'package:zap_share/Views/TV/TvHomeScreen.dart';

class TvFileListScreen extends StatefulWidget {
  final String serverIp;
  final int serverPort;
  final List<Map<String, dynamic>> files;

  const TvFileListScreen({
    super.key,
    required this.serverIp,
    required this.serverPort,
    required this.files,
  });

  @override
  State<TvFileListScreen> createState() => _TvFileListScreenState();
}

class _TvFileListScreenState extends State<TvFileListScreen> with TickerProviderStateMixin {
  List<TvFileItem> _fileItems = [];
  bool _downloading = false;
  String? _saveFolder;
  
  // Stats
  double _overallProgress = 0.0;
  String _currentSpeed = '0 KB/s';
  int _downloadedCount = 0;

  // Animation controller for pulsing central stats
  late AnimationController _pulseController;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    )..repeat(reverse: true);
    _initializeFiles();
    _loadSaveFolder();
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  void _initializeFiles() {
    _fileItems = widget.files.map((f) {
      final name = f['name'] ?? 'Unknown File';
      final size = f['size'] ?? 0;
      final index = f['index'] ?? 0;
      return TvFileItem(
        name: name,
        size: size,
        url: 'http://${widget.serverIp}:${widget.serverPort}/file/$index',
      );
    }).toList();
  }

  Future<void> _loadSaveFolder() async {
    try {
      final downloadsCandidate = Directory('/storage/emulated/0/Download/ZapShare');
      if (!await downloadsCandidate.exists()) {
        await downloadsCandidate.create(recursive: true);
      }
      setState(() => _saveFolder = downloadsCandidate.path);
    } catch (_) {
      final dir = await getExternalStorageDirectory() ?? await getApplicationDocumentsDirectory();
      setState(() => _saveFolder = dir.path);
    }
  }

  Future<void> _startDownloads() async {
    final selected = _fileItems.where((f) => f.isSelected && f.status != 'Complete').toList();
    if (selected.isEmpty) return;

    // Check storage permissions
    if (await Permission.storage.isDenied) {
      await Permission.storage.request();
    }
    if (await Permission.manageExternalStorage.isDenied) {
      await Permission.manageExternalStorage.request();
    }

    setState(() {
      _downloading = true;
      _overallProgress = 0.0;
      _downloadedCount = 0;
    });

    final client = http.Client();
    int totalBytesToDownload = selected.fold(0, (sum, item) => sum + item.size);
    int totalBytesDownloadedSoFar = 0;

    for (var item in selected) {
      if (!mounted) break;
      setState(() {
        item.status = 'Downloading';
        item.progress = 0.05;
      });

      try {
        final request = http.Request('GET', Uri.parse(item.url));
        final response = await client.send(request);
        
        final file = File('${_saveFolder ?? ""}/${item.name}');
        if (await file.exists()) {
          await file.delete();
        }
        final sink = file.openWrite();

        int itemBytesDownloaded = 0;
        final stopwatch = Stopwatch()..start();

        await for (var chunk in response.stream) {
          if (!mounted) {
            await sink.close();
            break;
          }

          sink.add(chunk);
          itemBytesDownloaded += chunk.length;
          totalBytesDownloadedSoFar += chunk.length;

          // Speed calculation
          final elapsed = stopwatch.elapsed.inMilliseconds;
          if (elapsed > 200) {
            final kbps = (itemBytesDownloaded / 1024) / (elapsed / 1000);
            if (mounted) {
              setState(() {
                _currentSpeed = kbps > 1024 
                    ? '${(kbps / 1024).toStringAsFixed(1)} MB/s'
                    : '${kbps.toStringAsFixed(0)} KB/s';
                item.progress = itemBytesDownloaded / item.size;
                if (totalBytesToDownload > 0) {
                  _overallProgress = totalBytesDownloadedSoFar / totalBytesToDownload;
                }
              });
            }
            stopwatch.reset();
            stopwatch.start();
          }
        }

        await sink.close();
        if (mounted) {
          setState(() {
            item.progress = 1.0;
            item.status = 'Complete';
            item.savePath = file.path;
            _downloadedCount++;
          });
        }
      } catch (e) {
        if (mounted) {
          setState(() {
            item.status = 'Failed';
            item.progress = 0.0;
          });
        }
      }
    }

    client.close();
    if (mounted) {
      setState(() {
        _downloading = false;
        _currentSpeed = '0 KB/s';
      });
    }
  }

  String _formatSize(int bytes) {
    if (bytes <= 0) return '0 B';
    final kb = bytes / 1024;
    final mb = kb / 1024;
    if (mb > 1) return '${mb.toStringAsFixed(1)} MB';
    return '${kb.toStringAsFixed(0)} KB';
  }

  Color _getFileTypeColor(String name) {
    final ext = name.split('.').last.toLowerCase();
    if (['mp4', 'mkv', 'avi', 'mov', 'webm'].contains(ext)) return const Color(0xFFFF3B30); // Video -> Red
    if (['mp3', 'flac', 'aac', 'wav', 'ogg'].contains(ext)) return const Color(0xFF34C759); // Audio -> Green
    if (['jpg', 'jpeg', 'png', 'gif', 'webp'].contains(ext)) return const Color(0xFFFF9500); // Image -> Orange
    if (['pdf'].contains(ext)) return const Color(0xFF5856D6); // PDF -> Purple
    if (['zip', 'rar', '7z'].contains(ext)) return const Color(0xFF007AFF); // Archive -> Blue
    if (ext == 'apk') return const Color(0xFFAF52DE); // APK -> Purple/Indigo
    return const Color(0xFF8E8E93); // Other -> Grey
  }

  IconData _getFileIcon(String name) {
    final ext = name.split('.').last.toLowerCase();
    if (['mp4', 'mkv', 'avi', 'mov', 'webm'].contains(ext)) return Icons.movie_rounded;
    if (['mp3', 'flac', 'aac', 'wav', 'ogg'].contains(ext)) return Icons.music_note_rounded;
    if (['jpg', 'jpeg', 'png', 'gif', 'webp'].contains(ext)) return Icons.image_rounded;
    if (['pdf'].contains(ext)) return Icons.picture_as_pdf_rounded;
    if (['zip', 'rar', '7z'].contains(ext)) return Icons.folder_zip_rounded;
    if (ext == 'apk') return Icons.android_rounded;
    return Icons.insert_drive_file_rounded;
  }

  @override
  Widget build(BuildContext context) {
    final selectedCount = _fileItems.where((f) => f.isSelected).length;
    final completedCount = _fileItems.where((f) => f.status == 'Complete').length;

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
                // Header
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
                        onPressed: () {
                          Navigator.pushAndRemoveUntil(
                            context,
                            MaterialPageRoute(builder: (context) => const TvHomeScreen()),
                            (route) => false,
                          );
                        },
                        child: const Icon(Icons.arrow_back_ios_new_rounded, color: Colors.white, size: 20),
                      ),
                    ),
                    const SizedBox(width: 16),
                    RichText(
                      text: TextSpan(
                        children: [
                          TextSpan(
                            text: 'Incoming ',
                            style: GoogleFonts.outfit(
                              color: const Color(0xFFFFD600),
                              fontSize: 26,
                              fontWeight: FontWeight.w800,
                              letterSpacing: -0.5,
                            ),
                          ),
                          TextSpan(
                            text: 'Files',
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
                    const Spacer(),
                    // Select All / Deselect Action
                    TVFocusableButton(
                      onPressed: _downloading
                          ? null
                          : () {
                              final allSelected = _fileItems.every((f) => f.isSelected);
                              setState(() {
                                for (var f in _fileItems) {
                                  if (f.status != 'Complete' && f.status != 'Downloading') {
                                    f.isSelected = !allSelected;
                                  }
                                }
                              });
                            },
                      backgroundColor: const Color(0xFF1C1C1E),
                      borderRadius: BorderRadius.circular(12),
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            _fileItems.every((f) => f.isSelected)
                                ? Icons.deselect_rounded
                                : Icons.select_all_rounded,
                            color: const Color(0xFFFFD600),
                            size: 18,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            _fileItems.every((f) => f.isSelected) ? 'Deselect All' : 'Select All',
                            style: GoogleFonts.outfit(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 24),

                Expanded(
                  child: Row(
                    children: [
                      // Left: File list (D-pad navigable list)
                      Expanded(
                        flex: 3,
                        child: ListView.separated(
                          itemCount: _fileItems.length,
                          separatorBuilder: (_, __) => const SizedBox(height: 12),
                          itemBuilder: (context, index) {
                            final item = _fileItems[index];
                            final isDone = item.status == 'Complete';
                            final isDownloading = item.status == 'Downloading';
                            final themeColor = _getFileTypeColor(item.name);
                            
                            return TVFocusableCard(
                              borderRadius: BorderRadius.circular(20),
                              onPressed: _downloading
                                  ? null
                                  : () {
                                      if (isDone && item.savePath != null) {
                                        OpenFile.open(item.savePath);
                                      } else {
                                        setState(() => item.isSelected = !item.isSelected);
                                      }
                                    },
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                                child: Row(
                                  children: [
                                    // File type icon
                                    Container(
                                      padding: const EdgeInsets.all(10),
                                      decoration: BoxDecoration(
                                        color: isDone
                                            ? const Color(0xFF00E676).withValues(alpha: 0.15)
                                            : themeColor.withValues(alpha: 0.12),
                                        shape: BoxShape.circle,
                                      ),
                                      child: Icon(
                                        isDone ? Icons.check : _getFileIcon(item.name),
                                        color: isDone ? const Color(0xFF00E676) : themeColor,
                                        size: 20,
                                      ),
                                    ),
                                    const SizedBox(width: 16),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            item.name,
                                            style: GoogleFonts.outfit(
                                              color: Colors.white,
                                              fontWeight: FontWeight.bold,
                                              fontSize: 15,
                                            ),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                          const SizedBox(height: 4),
                                          Row(
                                            children: [
                                              Text(
                                                _formatSize(item.size),
                                                style: GoogleFonts.robotoMono(
                                                  color: Colors.white38,
                                                  fontSize: 12,
                                                ),
                                              ),
                                              if (isDownloading) ...[
                                                const SizedBox(width: 12),
                                                Text(
                                                  '${(item.progress * 100).toStringAsFixed(0)}%',
                                                  style: GoogleFonts.robotoMono(
                                                    color: const Color(0xFFFFD600),
                                                    fontSize: 12,
                                                    fontWeight: FontWeight.bold,
                                                  ),
                                                ),
                                              ]
                                            ],
                                          ),
                                          if (isDownloading) ...[
                                            const SizedBox(height: 8),
                                            ClipRRect(
                                              borderRadius: BorderRadius.circular(4),
                                              child: LinearProgressIndicator(
                                                value: item.progress,
                                                minHeight: 4,
                                                backgroundColor: Colors.white12,
                                                color: const Color(0xFFFFD600),
                                              ),
                                            ),
                                          ]
                                        ],
                                      ),
                                    ),
                                    if (!_downloading && !isDone)
                                      Checkbox(
                                        value: item.isSelected,
                                        activeColor: const Color(0xFFFFD600),
                                        checkColor: Colors.black,
                                        onChanged: (val) {
                                          if (val != null) {
                                            setState(() => item.isSelected = val);
                                          }
                                        },
                                      ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                      const SizedBox(width: 32),
                      Container(width: 1, color: Colors.white.withValues(alpha: 0.06)),
                      const SizedBox(width: 32),

                      // Right: Download Stats Panel featuring the premium Pie Chart!
                      Expanded(
                        flex: 2,
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            // Premium Pie Chart in the center of the right panel
                            SizedBox(
                              width: 180,
                              height: 180,
                              child: AnimatedBuilder(
                                animation: _pulseController,
                                builder: (context, _) {
                                  return CustomPaint(
                                    painter: _PieChartPainter(
                                      files: _fileItems,
                                      sectorColors: _fileItems.map((f) => _getFileTypeColor(f.name)).toList(),
                                      pulseValue: _pulseController.value,
                                    ),
                                    child: Center(
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Text(
                                            _downloading
                                                ? '${(_overallProgress * 100).toInt()}%'
                                                : '$completedCount/${_fileItems.length}',
                                            style: GoogleFonts.outfit(
                                              color: Colors.white,
                                              fontSize: _downloading ? 26 : 24,
                                              fontWeight: FontWeight.w800,
                                              letterSpacing: -1.0,
                                            ),
                                          ),
                                          const SizedBox(height: 1),
                                          Text(
                                            _downloading
                                                ? 'downloading'
                                                : (completedCount == _fileItems.length && _fileItems.isNotEmpty
                                                    ? 'complete!'
                                                    : 'selected'),
                                            style: GoogleFonts.outfit(
                                              color: _downloading ? const Color(0xFFFFD600) : Colors.grey[500],
                                              fontSize: 10,
                                              fontWeight: FontWeight.w500,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ),
                            const SizedBox(height: 24),
                            // Speed / Status text below Pie Chart
                            if (_downloading) ...[
                              Text(
                                'Speed: $_currentSpeed',
                                style: GoogleFonts.robotoMono(
                                  color: const Color(0xFFFFD600),
                                  fontSize: 14,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ] else ...[
                              Text(
                                selectedCount == 0
                                    ? 'Select files on the left'
                                    : 'Ready to download $selectedCount files',
                                style: GoogleFonts.outfit(
                                  color: Colors.white70,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                            const SizedBox(height: 20),
                            SizedBox(
                              width: double.infinity,
                              child: TVFocusableButton(
                                onPressed: selectedCount == 0 || _downloading ? null : _startDownloads,
                                autofocus: true,
                                backgroundColor: const Color(0xFFFFD600),
                                padding: const EdgeInsets.symmetric(vertical: 14),
                                borderRadius: BorderRadius.circular(16),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    const Icon(Icons.download_rounded, color: Colors.black, size: 18),
                                    const SizedBox(width: 8),
                                    Text(
                                      _downloading ? 'Downloading...' : 'Download Selected',
                                      style: GoogleFonts.outfit(
                                        color: Colors.black,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 14,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      )
                    ],
                  ),
                )
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class TvFileItem {
  final String name;
  final int size;
  final String url;
  bool isSelected;
  double progress;
  String status;
  String? savePath;

  TvFileItem({
    required this.name,
    required this.size,
    required this.url,
    this.isSelected = true,
    this.progress = 0.0,
    this.status = 'Waiting',
    this.savePath,
  });
}

// ─────────── PREMIUM PIE CHART PAINTER FOR TV ───────────

class _PieChartPainter extends CustomPainter {
  final List<TvFileItem> files;
  final List<Color> sectorColors;
  final double pulseValue;

  _PieChartPainter({
    required this.files,
    required this.sectorColors,
    required this.pulseValue,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (files.isEmpty) return;

    final center = Offset(size.width / 2, size.height / 2);
    final outerR = size.width / 2;
    final innerR = outerR * 0.55;
    final total = files.length;
    final gapAngle = total > 1 ? 0.04 : 0.0;
    final sectorAngle = (2 * pi - gapAngle * total) / total;

    double startAngle = -pi / 2;

    for (int i = 0; i < total; i++) {
      final file = files[i];
      final color = sectorColors[i % sectorColors.length];
      final sel = file.isSelected;
      final complete = file.status == 'Complete';
      final downloading = file.status == 'Downloading';

      final sc = center;

      // Sector Background fill
      final bgPaint = Paint()
        ..color = sel ? color.withOpacity(0.12) : Colors.white.withOpacity(0.03)
        ..style = PaintingStyle.fill;
      _sector(canvas, sc, innerR, outerR, startAngle, sectorAngle, bgPaint);

      // Progress fill
      if (file.progress > 0 && sel) {
        final progressAngle = sectorAngle * file.progress;
        final pPaint = Paint()
          ..color = complete ? Colors.green.withOpacity(0.65) : color.withOpacity(0.50 + pulseValue * 0.18)
          ..style = PaintingStyle.fill;
        _sector(canvas, sc, innerR, outerR, startAngle, progressAngle, pPaint);
      }

      // Outer arc outline
      final arcPaint = Paint()
        ..color = sel ? color.withOpacity(0.55) : Colors.white.withOpacity(0.08)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..strokeCap = StrokeCap.round;
      _arc(canvas, sc, outerR - 0.5, startAngle, sectorAngle, arcPaint);

      // Inner arc outline
      final innerArcPaint = Paint()
        ..color = sel ? color.withOpacity(0.20) : Colors.white.withOpacity(0.04)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.8
        ..strokeCap = StrokeCap.round;
      _arc(canvas, sc, innerR + 0.5, startAngle, sectorAngle, innerArcPaint);

      // Glow while downloading
      if (downloading && sel) {
        final glow = Paint()
          ..color = color.withOpacity(0.12 + pulseValue * 0.12)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 5
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8);
        _arc(canvas, sc, outerR + 3, startAngle, sectorAngle * file.progress, glow);
      }

      // Extension label inside sector
      final ext = _ext(file.name);
      if (sectorAngle > 0.25 && ext.isNotEmpty) {
        final labelR = (innerR + outerR) / 2;
        final lx = sc.dx + cos(startAngle + sectorAngle / 2) * labelR;
        final ly = sc.dy + sin(startAngle + sectorAngle / 2) * labelR;
        final tp = TextPainter(
          text: TextSpan(
            text: ext,
            style: TextStyle(
              color: sel ? (file.progress > 0.5 ? Colors.black.withOpacity(0.8) : color) : Colors.white.withOpacity(0.2),
              fontSize: total <= 4 ? 10 : 8,
              fontWeight: FontWeight.w800,
              fontFamily: 'monospace',
            ),
          ),
          textDirection: ui.TextDirection.ltr,
        )..layout();
        tp.paint(canvas, Offset(lx - tp.width / 2, ly - tp.height / 2));
      }

      startAngle += sectorAngle + gapAngle;
    }

    // Central core drawing
    final centerGradient = Paint()
      ..shader = ui.Gradient.radial(
        center,
        innerR,
        [const Color(0xFF161618), const Color(0xFF0C0C0E)],
        [0.0, 1.0],
      );
    canvas.drawCircle(center, innerR, centerGradient);
    
    // Outer ring outline for central core
    canvas.drawCircle(
      center,
      innerR,
      Paint()
        ..color = Colors.white.withOpacity(0.09)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
  }

  void _sector(Canvas c, Offset ctr, double iR, double oR, double start, double sweep, Paint p) {
    final path = Path()
      ..moveTo(ctr.dx + cos(start) * iR, ctr.dy + sin(start) * iR)
      ..lineTo(ctr.dx + cos(start) * oR, ctr.dy + sin(start) * oR)
      ..arcTo(Rect.fromCircle(center: ctr, radius: oR), start, sweep, false)
      ..lineTo(ctr.dx + cos(start + sweep) * iR, ctr.dy + sin(start + sweep) * iR)
      ..arcTo(Rect.fromCircle(center: ctr, radius: iR), start + sweep, -sweep, false)
      ..close();
    c.drawPath(path, p);
  }

  void _arc(Canvas c, Offset ctr, double r, double start, double sweep, Paint p) {
    c.drawArc(Rect.fromCircle(center: ctr, radius: r), start, sweep, false, p);
  }

  String _ext(String name) {
    final p = name.split('.');
    return p.length > 1 ? p.last.toUpperCase() : '';
  }

  @override
  bool shouldRepaint(covariant _PieChartPainter old) => true;
}
