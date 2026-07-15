import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:open_file/open_file.dart';
import 'package:zap_share/widgets/tv_widgets.dart';

// ─────────── Data models (same as Android) ───────────

class _TransferEntry {
  final String fileName;
  final int fileSize;
  final String direction;
  final String peer;
  final String? peerDeviceName;
  final DateTime dateTime;
  final String? fileLocation;

  const _TransferEntry({
    required this.fileName,
    required this.fileSize,
    required this.direction,
    required this.peer,
    this.peerDeviceName,
    required this.dateTime,
    this.fileLocation,
  });

  factory _TransferEntry.fromMap(Map<String, dynamic> m) => _TransferEntry(
        fileName: m['fileName'] ?? 'Unknown',
        fileSize: (m['fileSize'] as num?)?.toInt() ?? 0,
        direction: m['direction'] ?? 'Received',
        peer: m['peer'] ?? '',
        peerDeviceName: m['peerDeviceName'] as String?,
        dateTime: DateTime.tryParse(m['dateTime'] ?? '') ?? DateTime(0),
        fileLocation: m['fileLocation'] as String?,
      );
}

class _DeviceConversation {
  final String deviceKey;
  final String deviceName;
  final List<_TransferEntry> transfers;
  final DateTime lastTime;

  const _DeviceConversation({
    required this.deviceKey,
    required this.deviceName,
    required this.transfers,
    required this.lastTime,
  });
}

// ─────────── Screen ───────────

class TvHistoryScreen extends StatefulWidget {
  const TvHistoryScreen({super.key});

  @override
  State<TvHistoryScreen> createState() => _TvHistoryScreenState();
}

class _TvHistoryScreenState extends State<TvHistoryScreen> {
  List<_TransferEntry> _allHistory = [];
  List<_DeviceConversation> _conversations = [];
  bool _isLoading = true;
  int _selectedDeviceIndex = 0;

  // Focus nodes for two-panel navigation
  final FocusNode _devicePanelFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  @override
  void dispose() {
    _devicePanelFocus.dispose();
    super.dispose();
  }

  Future<void> _loadHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList('transfer_history') ?? [];
    final loaded = list.map((item) {
      try {
        return _TransferEntry.fromMap(Map<String, dynamic>.from(jsonDecode(item)));
      } catch (_) {
        return null;
      }
    }).whereType<_TransferEntry>().toList();

    loaded.sort((a, b) => b.dateTime.compareTo(a.dateTime));

    if (mounted) {
      setState(() {
        _allHistory = loaded;
        _buildConversations();
        _isLoading = false;
      });
    }
  }

  void _buildConversations() {
    final Map<String, List<_TransferEntry>> deviceMap = {};
    for (final entry in _allHistory) {
      final key = entry.peer.isEmpty ? 'Unknown' : entry.peer;
      deviceMap.putIfAbsent(key, () => []).add(entry);
    }

    _conversations = deviceMap.entries.map((e) {
      final transfers = List<_TransferEntry>.from(e.value)
        ..sort((a, b) => a.dateTime.compareTo(b.dateTime)); // oldest first (chat style)
      final displayName = _getDeviceName(e.key, e.value);
      return _DeviceConversation(
        deviceKey: e.key,
        deviceName: displayName,
        transfers: transfers,
        lastTime: transfers.last.dateTime,
      );
    }).toList()
      ..sort((a, b) => b.lastTime.compareTo(a.lastTime));
  }

  String _getDeviceName(String key, List<_TransferEntry> transfers) {
    final named = transfers.firstWhere((t) => t.peerDeviceName != null && t.peerDeviceName!.isNotEmpty, orElse: () => transfers.first);
    if (named.peerDeviceName != null && named.peerDeviceName!.isNotEmpty) return named.peerDeviceName!;
    if (key == 'Web Upload' || key.isEmpty) return 'Web Browser';
    return key;
  }

  Future<void> _clearHistory() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('transfer_history');
    if (mounted) {
      setState(() {
        _allHistory = [];
        _conversations = [];
        _selectedDeviceIndex = 0;
      });
    }
  }

  Future<void> _deleteConversation(int index) async {
    final conv = _conversations[index];
    _allHistory.removeWhere((e) => e.peer == conv.deviceKey);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      'transfer_history',
      _allHistory.map((e) => jsonEncode({
            'fileName': e.fileName,
            'fileSize': e.fileSize,
            'direction': e.direction,
            'peer': e.peer,
            'peerDeviceName': e.peerDeviceName,
            'dateTime': e.dateTime.toIso8601String(),
            'fileLocation': e.fileLocation,
          })).toList(),
    );
    if (mounted) {
      setState(() {
        _conversations.removeAt(index);
        if (_selectedDeviceIndex >= _conversations.length) {
          _selectedDeviceIndex = (_conversations.length - 1).clamp(0, 9999);
        }
      });
    }
  }

  // ─── Helpers ───

  String _formatRelativeTime(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inHours < 1) return '${diff.inMinutes}m ago';
    if (diff.inDays < 1) return '${diff.inHours}h ago';
    if (diff.inDays == 1) return 'Yesterday';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${dt.day}/${dt.month}/${dt.year % 100}';
  }

  String _formatTimestamp(DateTime dt) {
    final now = DateTime.now();
    final isToday = dt.year == now.year && dt.month == now.month && dt.day == now.day;
    final hour = dt.hour > 12 ? dt.hour - 12 : (dt.hour == 0 ? 12 : dt.hour);
    final ampm = dt.hour >= 12 ? 'PM' : 'AM';
    final time = '$hour:${dt.minute.toString().padLeft(2, '0')} $ampm';
    if (isToday) return time;
    return '${dt.day}/${dt.month}  $time';
  }

  String _formatSize(int bytes) {
    if (bytes <= 0) return '0 B';
    const s = ['B', 'KB', 'MB', 'GB'];
    int i = 0;
    double size = bytes.toDouble();
    while (size >= 1024 && i < s.length - 1) {
      size /= 1024;
      i++;
    }
    return '${size.toStringAsFixed(1)} ${s[i]}';
  }

  IconData _fileIcon(String name) {
    final ext = name.split('.').last.toLowerCase();
    if (['mp4', 'mkv', 'avi', 'mov', 'webm'].contains(ext)) return Icons.movie_rounded;
    if (['mp3', 'flac', 'aac', 'wav', 'ogg'].contains(ext)) return Icons.music_note_rounded;
    if (['jpg', 'jpeg', 'png', 'gif', 'bmp', 'webp'].contains(ext)) return Icons.image_rounded;
    if (['pdf'].contains(ext)) return Icons.picture_as_pdf_rounded;
    if (['zip', 'rar', '7z', 'tar', 'gz'].contains(ext)) return Icons.folder_zip_rounded;
    if (['doc', 'docx', 'odt'].contains(ext)) return Icons.description_rounded;
    if (['xls', 'xlsx', 'csv'].contains(ext)) return Icons.table_chart_rounded;
    return Icons.insert_drive_file_rounded;
  }

  Color _accentColor(bool isSent) =>
      isSent ? const Color(0xFFFFD600) : const Color(0xFF69C9FF);

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
                              text: 'Transfer ',
                              style: GoogleFonts.outfit(
                                color: const Color(0xFFFFD600),
                                fontSize: 26,
                                fontWeight: FontWeight.w800,
                                letterSpacing: -0.5,
                              ),
                            ),
                            TextSpan(
                              text: 'History',
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
                    if (_conversations.isNotEmpty)
                      TVFocusableButton(
                        onPressed: _clearHistory,
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                        borderRadius: BorderRadius.circular(16),
                        backgroundColor: Colors.red.withValues(alpha: 0.08),
                        focusColor: Colors.redAccent,
                        child: Text(
                          'Clear All',
                          style: GoogleFonts.outfit(
                            color: Colors.redAccent,
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
                        ),
                      ),
                  ],
                ),

                const SizedBox(height: 28),

                // ── Content ──
                Expanded(
                  child: _isLoading
                      ? const Center(
                          child: CircularProgressIndicator(
                            valueColor: AlwaysStoppedAnimation(Color(0xFFFFD600)),
                          ),
                        )
                      : _conversations.isEmpty
                          ? _buildEmptyState()
                          : _buildTwoPanel(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.history_rounded, size: 72, color: Colors.white.withValues(alpha: 0.08)),
          const SizedBox(height: 20),
          Text(
            'No transfers yet',
            style: GoogleFonts.outfit(color: Colors.white38, fontSize: 18),
          ),
        ],
      ),
    );
  }

  Widget _buildTwoPanel() {
    return Row(
      children: [
        // ── Left: Device list ──
        SizedBox(
          width: 280,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  'DEVICES  (${_conversations.length})',
                  style: GoogleFonts.outfit(
                    color: Colors.grey[400],
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.2,
                  ),
                ),
              ),
              Expanded(
                child: ListView.separated(
                  itemCount: _conversations.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (context, i) {
                    final conv = _conversations[i];
                    final isSelected = i == _selectedDeviceIndex;
                    final sentCount = conv.transfers.where((t) => t.direction == 'Sent').length;
                    final recvCount = conv.transfers.length - sentCount;

                    return TVFocusableCard(
                      autofocus: i == 0,
                      borderRadius: const BorderRadius.all(Radius.circular(16)),
                      backgroundColor: isSelected
                          ? const Color(0xFFFFD600).withValues(alpha: 0.12)
                          : const Color(0xFF1C1C1E),
                      focusColor: const Color(0xFFFFD600),
                      onPressed: () => setState(() => _selectedDeviceIndex = i),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                        child: Row(
                          children: [
                            // Device icon
                            Container(
                              width: 40,
                              height: 40,
                              decoration: BoxDecoration(
                                color: isSelected
                                    ? const Color(0xFFFFD600).withValues(alpha: 0.2)
                                    : Colors.white.withValues(alpha: 0.06),
                                shape: BoxShape.circle,
                              ),
                              child: Icon(
                                conv.deviceName == 'Web Browser'
                                    ? Icons.language_rounded
                                    : Icons.phone_android_rounded,
                                color: isSelected ? const Color(0xFFFFD600) : Colors.white38,
                                size: 20,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    conv.deviceName,
                                    style: GoogleFonts.outfit(
                                      color: isSelected ? const Color(0xFFFFD600) : Colors.white,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 14,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    '${conv.transfers.length} transfers  •  ${_formatRelativeTime(conv.lastTime)}',
                                    style: GoogleFonts.outfit(
                                      color: Colors.white38,
                                      fontSize: 11,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ),
                            ),
                            // Sent/Received mini badges
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                if (sentCount > 0)
                                  _buildMiniChip('$sentCount↑', const Color(0xFFFFD600)),
                                if (recvCount > 0) ...[
                                  const SizedBox(height: 2),
                                  _buildMiniChip('$recvCount↓', const Color(0xFF69C9FF)),
                                ],
                              ],
                            ),
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

        const SizedBox(width: 20),

        // Divider
        Container(width: 1, color: Colors.white.withValues(alpha: 0.06)),

        const SizedBox(width: 20),

        // ── Right: Transfer list for selected device ──
        Expanded(
          child: _conversations.isEmpty
              ? const SizedBox()
              : _buildTransferList(_conversations[_selectedDeviceIndex]),
        ),
      ],
    );
  }

  Widget _buildTransferList(_DeviceConversation conv) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Device info header
        Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: const Color(0xFFFFD600).withValues(alpha: 0.15),
                shape: BoxShape.circle,
              ),
              child: Icon(
                conv.deviceName == 'Web Browser' ? Icons.language_rounded : Icons.phone_android_rounded,
                color: const Color(0xFFFFD600),
                size: 20,
              ),
            ),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  conv.deviceName,
                  style: GoogleFonts.outfit(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
                Text(
                  '${conv.transfers.length} transfers',
                  style: GoogleFonts.outfit(color: Colors.white38, fontSize: 12),
                ),
              ],
            ),
            const Spacer(),
            TVFocusableButton(
              onPressed: () {
                final idx = _conversations.indexOf(conv);
                if (idx >= 0) _deleteConversation(idx);
              },
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              borderRadius: BorderRadius.circular(14),
              backgroundColor: Colors.red.withValues(alpha: 0.08),
              focusColor: Colors.redAccent,
              child: Text(
                'Delete Device',
                style: GoogleFonts.outfit(color: Colors.redAccent, fontSize: 12, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Text(
          'TRANSFERS',
          style: GoogleFonts.outfit(
            color: Colors.grey[400],
            fontSize: 11,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.2,
          ),
        ),
        const SizedBox(height: 12),
        // Transfer list — oldest first (chat style, like Android)
        Expanded(
          child: ListView.separated(
            itemCount: conv.transfers.length,
            separatorBuilder: (_, __) => const SizedBox(height: 10),
            itemBuilder: (context, i) => _buildTransferTile(conv.transfers[i]),
          ),
        ),
      ],
    );
  }

  Widget _buildTransferTile(_TransferEntry entry) {
    final isSent = entry.direction == 'Sent';
    final accent = _accentColor(isSent);
    final canOpen = !isSent &&
        entry.fileLocation != null &&
        File(entry.fileLocation!).existsSync();

    return TVFocusableCard(
      borderRadius: const BorderRadius.all(Radius.circular(16)),
      onPressed: canOpen ? () => OpenFile.open(entry.fileLocation!) : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            // Direction indicator bar
            Container(
              width: 3,
              height: 40,
              decoration: BoxDecoration(
                color: accent,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: 14),
            // File icon
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(_fileIcon(entry.fileName), color: accent, size: 18),
            ),
            const SizedBox(width: 14),
            // Info
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.fileName,
                    style: GoogleFonts.outfit(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '${_formatSize(entry.fileSize)}  •  ${_formatTimestamp(entry.dateTime)}',
                    style: GoogleFonts.outfit(color: Colors.white38, fontSize: 11),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            // Direction badge
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: accent.withValues(alpha: 0.2)),
              ),
              child: Text(
                isSent ? '↑ Sent' : '↓ Recv',
                style: GoogleFonts.outfit(color: accent, fontSize: 11, fontWeight: FontWeight.w700),
              ),
            ),
            if (canOpen) ...[
              const SizedBox(width: 8),
              Icon(Icons.open_in_new_rounded, color: accent, size: 16),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildMiniChip(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w700),
      ),
    );
  }
}
