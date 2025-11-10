import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:open_file/open_file.dart';
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

  static TransferHistoryEntry fromJson(Map<String, dynamic> json) => TransferHistoryEntry(
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
      _history = list.map((e) => TransferHistoryEntry.fromJson(jsonDecode(e))).toList();
      _groupByDevice();
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

    _conversations = deviceMap.entries.map((entry) {
      final transfers = entry.value;
      // Sort oldest first (for chat-like display, oldest at top, newest at bottom)
      transfers.sort((a, b) => a.dateTime.compareTo(b.dateTime));
      
      return DeviceConversation(
        deviceName: _getDeviceName(entry.key),
        deviceIp: entry.key,
        transfers: transfers,
        lastTransferTime: transfers.last.dateTime, // Last is now the most recent
      );
    }).toList();

    // Sort conversations by last transfer time
    _conversations.sort((a, b) => b.lastTransferTime.compareTo(a.lastTransferTime));
  }

  String _getDeviceName(String ip) {
    // Try to get device name from the first transfer's peerDeviceName
    final transfersForIp = _history.where((t) => t.peer == ip).toList();
    if (transfersForIp.isNotEmpty && transfersForIp.first.peerDeviceName != null) {
      return transfersForIp.first.peerDeviceName!;
    }
    
    // Fallback logic
    if (ip.isEmpty || ip == 'Web Upload') return 'Web Browser';
    if (ip.startsWith('192.168.') || ip.startsWith('10.') || ip.startsWith('172.')) {
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
        _conversations = _conversations.where((conv) {
          return conv.deviceName.toLowerCase().contains(query) ||
                 conv.transfers.any((t) => t.fileName.toLowerCase().contains(query));
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
    if (bytes < 1024 * 1024 * 1024) return "${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB";
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
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_rounded, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        title: _isSearching
            ? TextField(
                controller: _searchController,
                autofocus: true,
                style: const TextStyle(color: Colors.white, fontSize: 16),
                decoration: InputDecoration(
                  hintText: 'Search devices or files...',
                  hintStyle: TextStyle(color: Colors.grey[600], fontSize: 16),
                  border: InputBorder.none,
                ),
              )
            : const Text(
                'Transfer History',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 24,
                  fontWeight: FontWeight.w300,
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
      body: _history.isEmpty
          ? _buildEmptyState()
          : ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: _conversations.length,
              itemBuilder: (context, index) {
                return _buildConversationCard(_conversations[index]);
              },
            ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.history,
            size: 80,
            color: Colors.grey[800],
          ),
          const SizedBox(height: 16),
          Text(
            'No Transfer History',
            style: TextStyle(
              color: Colors.grey[400],
              fontSize: 18,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Sent and received files will appear here',
            style: TextStyle(
              color: Colors.grey[600],
              fontSize: 14,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildConversationCard(DeviceConversation conversation) {
    final totalFiles = conversation.transfers.length;
    final sentCount = conversation.transfers.where((t) => t.direction == 'Sent').length;
    final receivedCount = conversation.transfers.where((t) => t.direction == 'Received').length;
    final lastTransfer = conversation.transfers.first;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.grey[900],
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey[800]!, width: 1),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => _openConversationDetail(conversation),
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                // Device icon/avatar
                Container(
                  width: 50,
                  height: 50,
                  decoration: BoxDecoration(
                    color: Colors.yellow[300]!.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    Icons.devices,
                    color: Colors.yellow[300],
                    size: 24,
                  ),
                ),
                const SizedBox(width: 14),
                
                // Device info and last transfer
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        conversation.deviceName,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Icon(
                            _getFileIcon(_getFileType(lastTransfer.fileName)),
                            size: 14,
                            color: Colors.grey[500],
                          ),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              lastTransfer.fileName,
                              style: TextStyle(
                                color: Colors.grey[400],
                                fontSize: 13,
                              ),
                              overflow: TextOverflow.ellipsis,
                              maxLines: 1,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '$totalFiles files • ↑ $sentCount sent • ↓ $receivedCount received',
                        style: TextStyle(
                          color: Colors.grey[600],
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
                
                // Time
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      _formatTime(lastTransfer.dateTime),
                      style: TextStyle(
                        color: Colors.grey[500],
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Icon(
                      Icons.chevron_right,
                      color: Colors.grey[700],
                      size: 18,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _openConversationDetail(DeviceConversation conversation) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ConversationDetailScreen(conversation: conversation),
      ),
    );
  }
}

// Detail screen showing chat-like conversation
class ConversationDetailScreen extends StatelessWidget {
  final DeviceConversation conversation;

  const ConversationDetailScreen({super.key, required this.conversation});

  String _formatBytes(int bytes) {
    if (bytes < 1024) return "$bytes B";
    if (bytes < 1024 * 1024) return "${(bytes / 1024).toStringAsFixed(1)} KB";
    if (bytes < 1024 * 1024 * 1024) return "${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB";
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

  Future<void> _openFile(BuildContext context, String? filePath, String fileName) async {
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
        backgroundColor: Colors.grey[900],
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_rounded, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              conversation.deviceName,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            Text(
              '${conversation.transfers.length} transfers',
              style: TextStyle(
                color: Colors.grey[400],
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
      body: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: conversation.transfers.length,
        itemBuilder: (context, index) {
          final transfer = conversation.transfers[index];
          return _buildMessageBubble(context, transfer);
        },
      ),
    );
  }

  Widget _buildMessageBubble(BuildContext context, TransferHistoryEntry transfer) {
    final isSent = transfer.direction == 'Sent';
    final fileType = _getFileType(transfer.fileName);
    final fileColor = _getFileColor(fileType);
    final fileIcon = _getFileIcon(fileType);

    return Align(
      alignment: isSent ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.75),
        child: Column(
          crossAxisAlignment: isSent ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            Container(
              decoration: BoxDecoration(
                color: isSent ? Colors.yellow[300] : Colors.grey[850],
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(16),
                  topRight: const Radius.circular(16),
                  bottomLeft: Radius.circular(isSent ? 16 : 4),
                  bottomRight: Radius.circular(isSent ? 4 : 16),
                ),
              ),
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: () => _openFile(context, transfer.fileLocation, transfer.fileName),
                  borderRadius: BorderRadius.only(
                    topLeft: const Radius.circular(16),
                    topRight: const Radius.circular(16),
                    bottomLeft: Radius.circular(isSent ? 16 : 4),
                    bottomRight: Radius.circular(isSent ? 4 : 16),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: isSent
                                    ? Colors.black.withOpacity(0.1)
                                    : fileColor.withOpacity(0.15),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Icon(
                                fileIcon,
                                color: isSent ? Colors.black : fileColor,
                                size: 24,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Flexible(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    transfer.fileName,
                                    style: TextStyle(
                                      color: isSent ? Colors.black : Colors.white,
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                    maxLines: 2,
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    _formatBytes(transfer.fileSize),
                                    style: TextStyle(
                                      color: isSent
                                          ? Colors.black.withOpacity(0.6)
                                          : Colors.grey[400],
                                      fontSize: 12,
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
                style: TextStyle(
                  color: Colors.grey[600],
                  fontSize: 11,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
