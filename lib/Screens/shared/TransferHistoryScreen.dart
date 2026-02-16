import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:open_file/open_file.dart';
import 'package:zap_share/blocs/navigation/smooth_page_route.dart';
import 'dart:convert';
import 'dart:io';

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

class TransferHistoryEntry {
  final String fileName;
  final int fileSize;
  final String direction; // 'Sent' or 'Received'
  final String peer; // Can be IP or device name
  final String? peerDeviceName; // Optional device name
  final DateTime dateTime;
  final String? fileLocation;

  TransferHistoryEntry({
    required this.fileName,
    required this.fileSize,
    required this.direction,
    required this.peer,
    this.peerDeviceName,
    required this.dateTime,
    this.fileLocation,
  });

  Map<String, dynamic> toJson() => {
    'fileName': fileName,
    'fileSize': fileSize,
    'direction': direction,
    'peer': peer,
    'peerDeviceName': peerDeviceName,
    'dateTime': dateTime.toIso8601String(),
    'fileLocation': fileLocation,
  };

  static TransferHistoryEntry fromJson(Map<String, dynamic> json) =>
      TransferHistoryEntry(
        fileName: json['fileName'],
        fileSize: json['fileSize'],
        direction: json['direction'],
        peer: json['peer'],
        peerDeviceName: json['peerDeviceName'],
        dateTime: DateTime.parse(json['dateTime']),
        fileLocation: json['fileLocation'],
      );
}

class DeviceConversation {
  final String deviceName;
  final String deviceIp;
  final List<TransferHistoryEntry> transfers;
  final DateTime lastTransferTime;

  DeviceConversation({
    required this.deviceName,
    required this.deviceIp,
    required this.transfers,
    required this.lastTransferTime,
  });
}

class TransferHistoryScreen extends StatefulWidget {
  const TransferHistoryScreen({super.key});
  @override
  State<TransferHistoryScreen> createState() => _TransferHistoryScreenState();
}

class _TransferHistoryScreenState extends State<TransferHistoryScreen> {
  List<TransferHistoryEntry> _history = [];
  List<DeviceConversation> _conversations = [];
  final TextEditingController _searchController = TextEditingController();
  bool _isSearching = false;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadHistory();
    _searchController.addListener(_onSearchChanged);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList('transfer_history') ?? [];
    setState(() {
      _history =
          list
              .map((e) => TransferHistoryEntry.fromJson(jsonDecode(e)))
              .toList();
      _groupByDevice();
      _isLoading = false;
    });
  }

  void _groupByDevice() {
    final Map<String, List<TransferHistoryEntry>> deviceMap = {};

    for (var entry in _history) {
      final key = entry.peer;
      if (!deviceMap.containsKey(key)) {
        deviceMap[key] = [];
      }
      deviceMap[key]!.add(entry);
    }

    _conversations =
        deviceMap.entries.map((entry) {
          final transfers = entry.value;
          // Sort oldest first (for chat-like display, oldest at top, newest at bottom)
          transfers.sort((a, b) => a.dateTime.compareTo(b.dateTime));

          return DeviceConversation(
            deviceName: _getDeviceName(entry.key),
            deviceIp: entry.key,
            transfers: transfers,
            lastTransferTime:
                transfers.last.dateTime, // Last is now the most recent
          );
        }).toList();

    // Sort conversations by last transfer time
    _conversations.sort(
      (a, b) => b.lastTransferTime.compareTo(a.lastTransferTime),
    );
  }

  String _getDeviceName(String ip) {
    // Try to get device name from the first transfer's peerDeviceName
    final transfersForIp = _history.where((t) => t.peer == ip).toList();
    if (transfersForIp.isNotEmpty &&
        transfersForIp.first.peerDeviceName != null) {
      return transfersForIp.first.peerDeviceName!;
    }

    // Fallback logic
    if (ip.isEmpty || ip == 'Web Upload') return 'Web Browser';
    if (ip.startsWith('192.168.') ||
        ip.startsWith('10.') ||
        ip.startsWith('172.')) {
      return 'Device ($ip)';
    }
    return ip;
  }

  void _onSearchChanged() {
    // Filter conversations by device name or file names
    final query = _searchController.text.toLowerCase();
    if (query.isEmpty) {
      _groupByDevice();
    } else {
      setState(() {
        _conversations =
            _conversations.where((conv) {
              return conv.deviceName.toLowerCase().contains(query) ||
                  conv.transfers.any(
                    (t) => t.fileName.toLowerCase().contains(query),
                  );
            }).toList();
      });
    }
  }

  void _toggleSearch() {
    setState(() {
      _isSearching = !_isSearching;
      if (!_isSearching) {
        _searchController.clear();
        _groupByDevice();
      }
    });
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return "$bytes B";
    if (bytes < 1024 * 1024) return "${(bytes / 1024).toStringAsFixed(1)} KB";
    if (bytes < 1024 * 1024 * 1024)
      return "${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB";
    return "${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB";
  }

  String _formatTime(DateTime dateTime) {
    final now = DateTime.now();
    final diff = now.difference(dateTime);

    if (diff.inDays == 0) {
      return '${dateTime.hour.toString().padLeft(2, '0')}:${dateTime.minute.toString().padLeft(2, '0')}';
    } else if (diff.inDays == 1) {
      return 'Yesterday';
    } else if (diff.inDays < 7) {
      final weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
      return weekdays[dateTime.weekday - 1];
    } else {
      return '${dateTime.day}/${dateTime.month}/${dateTime.year}';
    }
  }

  FileType _getFileType(String fileName) {
    final ext = fileName.split('.').last.toLowerCase();

    if (['jpg', 'jpeg', 'png', 'gif', 'bmp', 'webp', 'svg'].contains(ext)) {
      return FileType.image;
    } else if (['mp4', 'mov', 'avi', 'mkv', 'webm'].contains(ext)) {
      return FileType.video;
    } else if (['mp3', 'wav', 'flac', 'aac', 'ogg'].contains(ext)) {
      return FileType.audio;
    } else if (['pdf'].contains(ext)) {
      return FileType.pdf;
    } else if (['doc', 'docx'].contains(ext)) {
      return FileType.document;
    } else if (['zip', 'rar', '7z', 'tar', 'gz'].contains(ext)) {
      return FileType.archive;
    } else {
      return FileType.other;
    }
  }

  IconData _getFileIcon(FileType type) {
    switch (type) {
      case FileType.image:
        return Icons.image;
      case FileType.video:
        return Icons.video_file;
      case FileType.audio:
        return Icons.audio_file;
      case FileType.pdf:
        return Icons.picture_as_pdf;
      case FileType.document:
        return Icons.description;
      case FileType.archive:
        return Icons.folder_zip;
      default:
        return Icons.insert_drive_file;
    }
  }

  Color _getFileColor(FileType type) {
    switch (type) {
      case FileType.image:
        return Colors.blue;
      case FileType.video:
        return Colors.purple;
      case FileType.audio:
        return Colors.yellow;
      case FileType.pdf:
        return Colors.red;
      case FileType.document:
        return Colors.indigo;
      case FileType.archive:
        return Colors.amber;
      default:
        return Colors.grey;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Hero(
      tag: 'history_card_container',
      createRectTween: (begin, end) {
        return RectTween(begin: begin, end: end);
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          systemOverlayStyle: SystemUiOverlayStyle.light,
          backgroundColor: Colors.black,
          elevation: 0,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back_ios_rounded, color: Colors.white),
            onPressed: () => context.navigateBack(),
          ),
          title:
              _isSearching
                  ? TextField(
                    controller: _searchController,
                    autofocus: true,
                    style: GoogleFonts.outfit(
                      color: Colors.white,
                      fontSize: 16,
                    ),
                    decoration: InputDecoration(
                      hintText: 'Search devices or files...',
                      hintStyle: GoogleFonts.outfit(
                        color: Colors.grey[600],
                        fontSize: 16,
                      ),
                      border: InputBorder.none,
                    ),
                  )
                  : Text(
                    'Transfer History',
                    style: GoogleFonts.outfit(
                      color: Colors.white,
                      fontSize: 28,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.5,
                    ),
                  ),
          actions: [
            IconButton(
              icon: Icon(
                _isSearching ? Icons.close : Icons.search,
                color: Colors.grey[400],
              ),
              onPressed: _toggleSearch,
            ),
          ],
        ),
        body:
            _isLoading
                ? const Center(
                  child: CircularProgressIndicator(color: Color(0xFFFFD600)),
                )
                : _history.isEmpty
                ? _buildEmptyState()
                : ListView.builder(
                  padding: const EdgeInsets.symmetric(
                    vertical: 8,
                    horizontal: 16,
                  ),
                  itemCount: _conversations.length,
                  itemBuilder: (context, index) {
                    return _buildConversationCard(_conversations[index]);
                  },
                ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.history_rounded, size: 80, color: Colors.grey[800]),
          const SizedBox(height: 16),
          Text(
            'No Transfer History',
            style: GoogleFonts.outfit(
              color: Colors.grey[400],
              fontSize: 20,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Sent and received files will appear here',
            style: GoogleFonts.outfit(color: Colors.grey[600], fontSize: 14),
          ),
        ],
      ),
    );
  }

  Widget _buildConversationCard(DeviceConversation conversation) {
    final totalFiles = conversation.transfers.length;
    final lastTransfer = conversation.transfers.last;
    final isSent = lastTransfer.direction == 'Sent';

    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      decoration: BoxDecoration(
        color: Colors.transparent,
        border: Border(bottom: BorderSide(color: Colors.grey[900]!, width: 1)),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => _openConversationDetail(conversation),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 14),
            child: Row(
              children: [
                // Circular Avatar (WhatsApp style)
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFD600).withOpacity(0.15),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.devices_rounded,
                    color: Color(0xFFFFD600),
                    size: 28,
                  ),
                ),

                const SizedBox(width: 16),

                // Device info and last transfer
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Expanded(
                            child: Text(
                              conversation.deviceName,
                              style: GoogleFonts.outfit(
                                color: Colors.white,
                                fontSize: 18,
                                fontWeight: FontWeight.w700,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            _formatTime(lastTransfer.dateTime),
                            style: GoogleFonts.outfit(
                              color: Colors.grey[500],
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          Icon(
                            isSent
                                ? Icons.arrow_upward_rounded
                                : Icons.arrow_downward_rounded,
                            size: 18,
                            color:
                                isSent
                                    ? const Color(0xFFFFD600)
                                    : Colors.grey[500],
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              lastTransfer.fileName,
                              style: GoogleFonts.outfit(
                                color: Colors.grey[300],
                                fontSize: 16,
                                fontWeight: FontWeight.w500,
                              ),
                              overflow: TextOverflow.ellipsis,
                              maxLines: 1,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '$totalFiles ${totalFiles == 1 ? 'file' : 'files'}',
                        style: GoogleFonts.outfit(
                          color: Colors.grey[500],
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
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

  void _openConversationDetail(DeviceConversation conversation) {
    context.navigateSlideRight(
      ConversationDetailScreen(conversation: conversation),
    );
  }
}

// Detail screen showing chat-like conversation
class ConversationDetailScreen extends StatefulWidget {
  final DeviceConversation conversation;

  const ConversationDetailScreen({super.key, required this.conversation});

  @override
  State<ConversationDetailScreen> createState() =>
      _ConversationDetailScreenState();
}

class _ConversationDetailScreenState extends State<ConversationDetailScreen> {
  final ScrollController _scrollController = ScrollController();
  bool _showScrollToBottom = false;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.hasClients) {
      final isAtBottom =
          _scrollController.offset >=
          _scrollController.position.maxScrollExtent - 100;
      if (isAtBottom != !_showScrollToBottom) {
        setState(() {
          _showScrollToBottom = !isAtBottom;
        });
      }
    }
  }

  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return "$bytes B";
    if (bytes < 1024 * 1024) return "${(bytes / 1024).toStringAsFixed(1)} KB";
    if (bytes < 1024 * 1024 * 1024)
      return "${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB";
    return "${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB";
  }

  String _formatDateTime(DateTime dateTime) {
    return '${dateTime.hour.toString().padLeft(2, '0')}:${dateTime.minute.toString().padLeft(2, '0')}';
  }

  FileType _getFileType(String fileName) {
    final ext = fileName.split('.').last.toLowerCase();

    if (['jpg', 'jpeg', 'png', 'gif', 'bmp', 'webp', 'svg'].contains(ext)) {
      return FileType.image;
    } else if (['mp4', 'mov', 'avi', 'mkv', 'webm'].contains(ext)) {
      return FileType.video;
    } else if (['mp3', 'wav', 'flac', 'aac', 'ogg'].contains(ext)) {
      return FileType.audio;
    } else if (['pdf'].contains(ext)) {
      return FileType.pdf;
    } else if (['doc', 'docx'].contains(ext)) {
      return FileType.document;
    } else if (['zip', 'rar', '7z', 'tar', 'gz'].contains(ext)) {
      return FileType.archive;
    } else {
      return FileType.other;
    }
  }

  IconData _getFileIcon(FileType type) {
    switch (type) {
      case FileType.image:
        return Icons.image;
      case FileType.video:
        return Icons.video_file;
      case FileType.audio:
        return Icons.audio_file;
      case FileType.pdf:
        return Icons.picture_as_pdf;
      case FileType.document:
        return Icons.description;
      case FileType.archive:
        return Icons.folder_zip;
      default:
        return Icons.insert_drive_file;
    }
  }

  Color _getFileColor(FileType type) {
    switch (type) {
      case FileType.image:
        return Colors.blue;
      case FileType.video:
        return Colors.purple;
      case FileType.audio:
        return Colors.yellow;
      case FileType.pdf:
        return Colors.red;
      case FileType.document:
        return Colors.indigo;
      case FileType.archive:
        return Colors.amber;
      default:
        return Colors.grey;
    }
  }

  Future<void> _openFile(
    BuildContext context,
    String? filePath,
    String fileName,
  ) async {
    if (filePath == null || filePath.isEmpty) {
      print('File location not available');
      return;
    }

    if (!await File(filePath).exists()) {
      print('File not found');
      return;
    }

    final result = await OpenFile.open(filePath);
    if (result.type != ResultType.done) {
      print('No app found to open this file');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_rounded, color: Colors.white),
          onPressed: () => context.navigateBack(),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.conversation.deviceName,
              style: GoogleFonts.outfit(
                color: Colors.white,
                fontSize: 19,
                fontWeight: FontWeight.w700,
              ),
            ),
            Text(
              '${widget.conversation.transfers.length} transfers',
              style: GoogleFonts.outfit(
                color: Colors.grey[400],
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
      body: Stack(
        children: [
          ListView.builder(
            controller: _scrollController,
            padding: const EdgeInsets.all(16),
            itemCount: widget.conversation.transfers.length,
            itemBuilder: (context, index) {
              final transfer = widget.conversation.transfers[index];
              return _buildMessageBubble(context, transfer);
            },
          ),
          // Scroll to bottom FAB
          if (_showScrollToBottom)
            Positioned(
              right: 16,
              bottom: 16,
              child: Material(
                elevation: 4,
                borderRadius: BorderRadius.circular(30),
                color: Colors.yellow[300],
                child: InkWell(
                  onTap: _scrollToBottom,
                  borderRadius: BorderRadius.circular(30),
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.arrow_downward,
                          color: Colors.black,
                          size: 20,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          'Latest',
                          style: TextStyle(
                            color: Colors.black,
                            fontSize: 13,
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
    );
  }

  Widget _buildMessageBubble(
    BuildContext context,
    TransferHistoryEntry transfer,
  ) {
    final isSent = transfer.direction == 'Sent';
    final fileType = _getFileType(transfer.fileName);
    final fileColor = _getFileColor(fileType);
    final fileIcon = _getFileIcon(fileType);

    return Align(
      alignment: isSent ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.75,
        ),
        child: Column(
          crossAxisAlignment:
              isSent ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            Container(
              decoration: BoxDecoration(
                color:
                    isSent ? const Color(0xFFFFD600) : const Color(0xFF1C1C1E),
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(20),
                  topRight: const Radius.circular(20),
                  bottomLeft: Radius.circular(isSent ? 20 : 4),
                  bottomRight: Radius.circular(isSent ? 4 : 20),
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.2),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap:
                      () => _openFile(
                        context,
                        transfer.fileLocation,
                        transfer.fileName,
                      ),
                  borderRadius: BorderRadius.only(
                    topLeft: const Radius.circular(20),
                    topRight: const Radius.circular(20),
                    bottomLeft: Radius.circular(isSent ? 20 : 4),
                    bottomRight: Radius.circular(isSent ? 4 : 20),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color:
                                    isSent
                                        ? Colors.black.withOpacity(0.1)
                                        : fileColor.withOpacity(0.15),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Icon(
                                fileIcon,
                                color: isSent ? Colors.black : fileColor,
                                size: 28,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Flexible(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    transfer.fileName,
                                    style: GoogleFonts.outfit(
                                      color:
                                          isSent ? Colors.black : Colors.white,
                                      fontSize: 16,
                                      fontWeight: FontWeight.w700,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                    maxLines: 2,
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    _formatBytes(transfer.fileSize),
                                    style: GoogleFonts.outfit(
                                      color:
                                          isSent
                                              ? Colors.black.withOpacity(0.7)
                                              : Colors.grey[400],
                                      fontSize: 14,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                _formatDateTime(transfer.dateTime),
                style: GoogleFonts.outfit(
                  color: Colors.grey[600],
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
