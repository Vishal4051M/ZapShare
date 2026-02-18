import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:open_file/open_file.dart';
import 'dart:convert';
import 'dart:io';

// Modern Color Constants
// Modern Color Constants
const Color kZapPrimary = Color(0xFFFFD84D); // Logo Yellow Light
const Color kZapPrimaryDark = Color(0xFFF5C400); // Logo Yellow Dark
const Color kZapSurface = Color(0xFF1C1C1E); 
const Color kZapBackgroundTop = Color(0xFF0E1116); // Soft Charcoal Top
const Color kZapBackgroundBottom = Color(0xFF07090D); // Soft Charcoal Bottom 

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

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TransferHistoryEntry &&
          runtimeType == other.runtimeType &&
          fileName == other.fileName &&
          fileSize == other.fileSize &&
          direction == other.direction &&
          peer == other.peer &&
          dateTime == other.dateTime;

  @override
  int get hashCode => Object.hash(fileName, fileSize, direction, peer, dateTime);

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
        fileName: json['fileName'] ?? 'Unknown File',
        fileSize: json['fileSize'] ?? 0,
        direction: json['direction'] ?? 'Unknown',
        peer: json['peer'] ?? 'Unknown',
        peerDeviceName: json['peerDeviceName'],
        dateTime: DateTime.tryParse(json['dateTime'] ?? '') ?? DateTime.now(),
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
  final VoidCallback? onBack;
  const TransferHistoryScreen({super.key, this.onBack});
  @override
  State<TransferHistoryScreen> createState() => _TransferHistoryScreenState();
}

class _TransferHistoryScreenState extends State<TransferHistoryScreen> {
  List<TransferHistoryEntry> _history = [];
  List<DeviceConversation> _conversations = [];
  final TextEditingController _searchController = TextEditingController();
  bool _isSearching = false;
  
  // Selection Mode State
  bool _isSelectionMode = false;
  final Set<String> _selectedPeers = {}; // Key by peer IP

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
    List<TransferHistoryEntry> loaded = [];
    
    for (var str in list) {
        try {
           final json = jsonDecode(str);
           loaded.add(TransferHistoryEntry.fromJson(json));
        } catch (e) {
           // Skip invalid entries
        }
    }
    
    setState(() {
      _history = loaded;
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
      transfers.sort((a, b) => a.dateTime.compareTo(b.dateTime));
      
      return DeviceConversation(
        deviceName: _getDeviceName(entry.key),
        deviceIp: entry.key,
        transfers: transfers,
        lastTransferTime: transfers.last.dateTime,
      );
    }).toList();

    _conversations.sort((a, b) => b.lastTransferTime.compareTo(a.lastTransferTime));
  }
  
  Future<void> _deleteSelectedConversations() async {
    if (_selectedPeers.isEmpty) return;
    
    // Filter out entries belonging to selected peers
    final entriesToKeep = _history.where((t) => !_selectedPeers.contains(t.peer)).toList();
    
    final prefs = await SharedPreferences.getInstance();
    final jsonList = entriesToKeep.map((e) => jsonEncode(e.toJson())).toList();
    await prefs.setStringList('transfer_history', jsonList);
    
    setState(() {
       _history = entriesToKeep;
       _groupByDevice();
       _isSelectionMode = false;
       _selectedPeers.clear();
    });
    
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Conversations deleted")));
  }

  String _getDeviceName(String ip) {
    if (ip.isEmpty || ip == 'Web Upload') return 'Web Browser';
    
    // Search all transfers for this IP to find a name
    try {
      final transferWithName = _history.firstWhere(
        (t) => t.peer == ip && t.peerDeviceName != null && t.peerDeviceName!.isNotEmpty,
      );
      return transferWithName.peerDeviceName!;
    } catch (_) {
      // No name found
    }
    
    if (ip.startsWith('192.168.') || ip.startsWith('10.') || ip.startsWith('172.')) {
      return 'Device ($ip)';
    }
    return ip;
  }

  void _onSearchChanged() {
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

  // --- File Helper Methods ---
  FileType _getFileType(String fileName) {
    final ext = fileName.split('.').last.toLowerCase();
    if (['jpg', 'jpeg', 'png', 'gif', 'bmp', 'webp', 'svg'].contains(ext)) return FileType.image;
    if (['mp4', 'mov', 'avi', 'mkv', 'webm'].contains(ext)) return FileType.video;
    if (['mp3', 'wav', 'flac', 'aac', 'ogg'].contains(ext)) return FileType.audio;
    if (['pdf'].contains(ext)) return FileType.pdf;
    if (['doc', 'docx'].contains(ext)) return FileType.document;
    if (['zip', 'rar', '7z', 'tar', 'gz'].contains(ext)) return FileType.archive;
    return FileType.other;
  }

  IconData _getFileIcon(FileType type) {
    switch (type) {
      case FileType.image: return Icons.image_rounded;
      case FileType.video: return Icons.videocam_rounded;
      case FileType.audio: return Icons.audiotrack_rounded;
      case FileType.pdf: return Icons.picture_as_pdf_rounded;
      case FileType.document: return Icons.description_rounded;
      case FileType.archive: return Icons.folder_zip_rounded;
      default: return Icons.insert_drive_file_rounded;
    }
  }
  // ----------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: _isSelectionMode ? _buildSelectionAppBar() : _buildNormalAppBar(),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
             begin: Alignment.topCenter,
             end: Alignment.bottomCenter,
             colors: [kZapBackgroundTop, kZapBackgroundBottom],
          ),
        ),
        child: _history.isEmpty
          ? _buildEmptyState()
          : ListView.builder(
              padding: const EdgeInsets.only(top: 100, bottom: 20), // Add top padding for AppBar
              itemCount: _conversations.length,
              itemBuilder: (context, index) {
                return _buildConversationCard(_conversations[index]);
              },
            ),
      ),
    );
  }
  
  PreferredSizeWidget _buildSelectionAppBar() {
     return AppBar(
        backgroundColor: kZapSurface,
        leading: IconButton(
           icon: const Icon(Icons.close, color: Colors.white),
           onPressed: () => setState(() {
              _isSelectionMode = false;
              _selectedPeers.clear();
           }),
        ),
        title: Text("${_selectedPeers.length} Selected", style: const TextStyle(color: Colors.white)),
        actions: [
           IconButton(
              icon: const Icon(Icons.delete_outline_rounded, color: Colors.redAccent),
              onPressed: _deleteSelectedConversations,
           )
        ],
     );
  }
  
  PreferredSizeWidget _buildNormalAppBar() {
    return AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        systemOverlayStyle: SystemUiOverlayStyle.light,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
          onPressed: () {
            if (widget.onBack != null) {
              widget.onBack!();
            } else {
              Navigator.pop(context);
            }
          },
        ),
        title: _isSearching
            ? Container(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: kZapSurface,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: TextField(
                  controller: _searchController,
                  autofocus: true,
                  style: const TextStyle(color: Colors.white, fontSize: 16),
                  cursorColor: kZapPrimary,
                  decoration: InputDecoration(
                    hintText: 'Search...',
                    hintStyle: TextStyle(color: Colors.grey[600], fontSize: 16),
                    border: InputBorder.none,
                    icon: Icon(Icons.search, color: Colors.grey[600]),
                  ),
                ),
              )
            : Row(
                children: [
                   Hero(
                    tag: 'history_fab',
                    child: const Icon(Icons.history_rounded, color: Colors.white, size: 28),
                  ),
                  const SizedBox(width: 12),
                  const Text(
                    'History',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      letterSpacing: -0.5,
                    ),
                  ),
                ],
              ),
        actions: [
          IconButton(
            icon: Icon(
              _isSearching ? Icons.close : Icons.search,
              color: Colors.white,
            ),
            onPressed: _toggleSearch,
          ),
        ],
      );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: kZapSurface,
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.history_edu_rounded,
              size: 48,
              color: kZapPrimary.withOpacity(0.5),
            ),
          ),
          const SizedBox(height: 24),
          Text(
            'Keep Track',
            style: TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Your transfer history will appear here',
            style: TextStyle(
              color: Colors.grey[600],
              fontSize: 15,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildConversationCard(DeviceConversation conversation) {
    final totalFiles = conversation.transfers.length;
    final lastTransfer = conversation.transfers.last;
    final isSelected = _selectedPeers.contains(conversation.deviceIp);

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      decoration: BoxDecoration(
        color: isSelected ? kZapPrimary.withOpacity(0.1) : kZapSurface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
             color: isSelected ? kZapPrimary : Colors.white.withOpacity(0.05),
             width: isSelected ? 1.5 : 1
        ),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () {
             if (_isSelectionMode) {
                setState(() {
                   if (isSelected) {
                      _selectedPeers.remove(conversation.deviceIp);
                      if (_selectedPeers.isEmpty) _isSelectionMode = false;
                   } else {
                      _selectedPeers.add(conversation.deviceIp);
                   }
                });
             } else {
                _openConversationDetail(conversation);
             }
          },
          onLongPress: () {
             if (!_isSelectionMode) {
                setState(() {
                   _isSelectionMode = true;
                   _selectedPeers.add(conversation.deviceIp);
                });
                HapticFeedback.mediumImpact();
             }
          },
          borderRadius: BorderRadius.circular(20),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                if (isSelected) ...[
                   Icon(Icons.check_circle_rounded, color: kZapPrimary, size: 24),
                   const SizedBox(width: 16),
                ] else if (_isSelectionMode) ...[
                   Icon(Icons.circle_outlined, color: Colors.grey, size: 24),
                   const SizedBox(width: 16),
                ],
              
                // Device icon
                Container(
                  width: 56, height: 56,
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.05),
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: const Icon(Icons.devices_other_rounded, color: Colors.white, size: 26),
                ),
                const SizedBox(width: 16),
                
                // Content
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        conversation.deviceName,
                        style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          Icon(_getFileIcon(_getFileType(lastTransfer.fileName)), size: 14, color: kZapPrimary),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              lastTransfer.fileName,
                              style: TextStyle(color: Colors.grey[400], fontSize: 13),
                              overflow: TextOverflow.ellipsis, maxLines: 1,
                            ),
                          ),
                        ],
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
                      style: TextStyle(color: Colors.grey[600], fontSize: 12, fontWeight: FontWeight.w500),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                       decoration: BoxDecoration(
                         color: kZapPrimary.withOpacity(0.1),
                         borderRadius: BorderRadius.circular(8),
                       ),
                       child: Text('$totalFiles files', style: const TextStyle(color: kZapPrimary, fontSize: 10, fontWeight: FontWeight.bold)),
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

  void _openConversationDetail(DeviceConversation conversation) async {
    // Wait for return to reload history if deleted in detail screen
    await Navigator.push(
      context,
      PageRouteBuilder(
        pageBuilder: (context, animation, secondaryAnimation) => ConversationDetailScreen(
           conversation: conversation,
           onDeleted: _loadHistory, // Callback to reload if deletion happens
        ),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          return SlideTransition(
            position: animation.drive(Tween(begin: const Offset(1.0, 0.0), end: Offset.zero).chain(CurveTween(curve: Curves.fastOutSlowIn))),
            child: child,
          );
        },
      ),
    );
    _loadHistory();
  }
}

// Detail screen showing chat-like conversation
class ConversationDetailScreen extends StatefulWidget {
  final DeviceConversation conversation;
  final VoidCallback onDeleted;

  const ConversationDetailScreen({super.key, required this.conversation, required this.onDeleted});

  @override
  State<ConversationDetailScreen> createState() => _ConversationDetailScreenState();
}

class _ConversationDetailScreenState extends State<ConversationDetailScreen> {
  final ScrollController _scrollController = ScrollController();
  bool _showScrollToBottom = false;
  
  // Selection State
  bool _isSelectionMode = false;
  final Set<TransferHistoryEntry> _selectedEntries = {};
  late List<TransferHistoryEntry> _currentTransfers;

  @override
  void initState() {
    super.initState();
    _currentTransfers = List.from(widget.conversation.transfers); // Copy mutable list
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
      final isAtBottom = _scrollController.offset >= _scrollController.position.maxScrollExtent - 100;
      if (isAtBottom != !_showScrollToBottom) {
        setState(() => _showScrollToBottom = !isAtBottom);
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
  
  Future<void> _deleteSelectedTransfers() async {
    if (_selectedEntries.isEmpty) return;
    
    // Load full history, remove valid entries, save back
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList('transfer_history') ?? [];
    List<TransferHistoryEntry> allHistory = [];
    
    // 1. Decode all
    for (var str in list) {
       try { allHistory.add(TransferHistoryEntry.fromJson(jsonDecode(str))); } catch(_) {}
    }
    
    // 2. Remove selected (Using custom equals)
    allHistory.removeWhere((entry) => _selectedEntries.contains(entry));
    
    // 3. Encode and Save
    final jsonList = allHistory.map((e) => jsonEncode(e.toJson())).toList();
    await prefs.setStringList('transfer_history', jsonList);
    
    setState(() {
       _currentTransfers.removeWhere((e) => _selectedEntries.contains(e));
       _selectedEntries.clear();
       _isSelectionMode = false;
    });
    
    widget.onDeleted(); // Notify parent
    
    if (_currentTransfers.isEmpty) {
       Navigator.pop(context); // Close detail if empty
    }
    
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Messages deleted")));
  }

  String _formatDateTime(DateTime dateTime) {
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

  // --- Helper Duplicates (Can be extracted to utils mainly) ---
  String _formatBytes(int bytes) {
    if (bytes < 1024) return "$bytes B";
    if (bytes < 1024 * 1024) return "${(bytes / 1024).toStringAsFixed(1)} KB";
    if (bytes < 1024 * 1024 * 1024) return "${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB";
    return "${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB";
  }

  FileType _getFileType(String fileName) {
    final ext = fileName.split('.').last.toLowerCase();
    if (['jpg', 'jpeg', 'png', 'gif', 'bmp', 'webp', 'svg'].contains(ext)) return FileType.image;
    if (['mp4', 'mov', 'avi', 'mkv', 'webm'].contains(ext)) return FileType.video;
    if (['mp3', 'wav', 'flac', 'aac', 'ogg'].contains(ext)) return FileType.audio;
    if (['pdf'].contains(ext)) return FileType.pdf;
    if (['doc', 'docx'].contains(ext)) return FileType.document;
    if (['zip', 'rar', '7z', 'tar', 'gz'].contains(ext)) return FileType.archive;
    return FileType.other;
  }

  IconData _getFileIcon(FileType type) {
    switch (type) {
      case FileType.image: return Icons.image_rounded;
      case FileType.video: return Icons.videocam_rounded;
      case FileType.audio: return Icons.audiotrack_rounded;
      case FileType.pdf: return Icons.picture_as_pdf_rounded;
      case FileType.document: return Icons.description_rounded;
      case FileType.archive: return Icons.folder_zip_rounded;
      default: return Icons.insert_drive_file_rounded;
    }
  }

  Color _getFileColor(FileType type) {
    switch (type) {
      case FileType.image: return Colors.blueAccent;
      case FileType.video: return Colors.purpleAccent;
      case FileType.audio: return Colors.orangeAccent;
      case FileType.pdf: return Colors.pinkAccent;
      case FileType.document: return Colors.indigoAccent;
      case FileType.archive: return Colors.amberAccent;
      default: return Colors.blueGrey;
    }
  }

  Future<void> _openFile(BuildContext context, String? filePath, String fileName) async {
    if (_isSelectionMode) return; // Disable opening in selection mode
    if (filePath == null || filePath.isEmpty) return;
    if (!await File(filePath).exists()) return;
    await OpenFile.open(filePath);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: _isSelectionMode ? _buildSelectionAppBar() : _buildNormalAppBar(),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
             begin: Alignment.topCenter,
             end: Alignment.bottomCenter,
             colors: [kZapBackgroundTop, kZapBackgroundBottom],
          ),
        ),
        child: Stack(
         children: [
           ListView.builder(
             controller: _scrollController,
             padding: const EdgeInsets.only(top: 100, bottom: 20, left: 16, right: 16),
             itemCount: _currentTransfers.length,
             itemBuilder: (context, index) {
               final transfer = _currentTransfers[index];
               return _buildMessageBubble(context, transfer);
             },
           ),
          if (_showScrollToBottom && !_isSelectionMode)
            Positioned(
              right: 20,
              bottom: 20,
              child: Material(
                elevation: 8,
                borderRadius: BorderRadius.circular(30),
                color: kZapSurface,
                child: InkWell(
                  onTap: _scrollToBottom,
                  borderRadius: BorderRadius.circular(30),
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    child: const Icon(Icons.arrow_downward_rounded, color: kZapPrimary),
                  ),
                ),
              ),
            ),
        ],
      ),
      ),
    );
  }
  
  PreferredSizeWidget _buildSelectionAppBar() {
     return AppBar(
        backgroundColor: kZapSurface,
        leading: IconButton(
           icon: const Icon(Icons.close, color: Colors.white),
           onPressed: () => setState(() {
              _isSelectionMode = false;
              _selectedEntries.clear();
           }),
        ),
        title: Text("${_selectedEntries.length} Selected", style: const TextStyle(color: Colors.white)),
        actions: [
           IconButton(
              icon: const Icon(Icons.delete_outline_rounded, color: Colors.redAccent),
              onPressed: _deleteSelectedTransfers,
           )
        ],
     );
  }

  PreferredSizeWidget _buildNormalAppBar() {
    return AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        systemOverlayStyle: SystemUiOverlayStyle.light,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.conversation.deviceName,
              style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
            ),
            Text(
              '${_currentTransfers.length} files shared',
              style: TextStyle(color: Colors.grey[400], fontSize: 12),
            ),
          ],
        ),
      );
  }

  Widget _buildMessageBubble(BuildContext context, TransferHistoryEntry transfer) {
    final isSent = transfer.direction == 'Sent';
    final fileType = _getFileType(transfer.fileName);
    final fileColor = _getFileColor(fileType);
    final fileIcon = _getFileIcon(fileType);
    final isSelected = _selectedEntries.contains(transfer);

    return GestureDetector(
       onLongPress: () {
          if (!_isSelectionMode) {
             HapticFeedback.mediumImpact();
             setState(() {
                _isSelectionMode = true;
                _selectedEntries.add(transfer);
             });
          }
       },
       onTap: () {
          if (_isSelectionMode) {
             setState(() {
                if (isSelected) {
                   _selectedEntries.remove(transfer);
                   if (_selectedEntries.isEmpty) _isSelectionMode = false;
                } else {
                   _selectedEntries.add(transfer);
                }
             });
          } else {
             _openFile(context, transfer.fileLocation, transfer.fileName);
          }
       },
       child: Align(
          alignment: isSent ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            margin: const EdgeInsets.only(bottom: 16),
            constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.75),
            child: Column(
               crossAxisAlignment: isSent ? CrossAxisAlignment.end : CrossAxisAlignment.start,
               children: [
               Container(
                 decoration: BoxDecoration(
                   color: isSelected 
                       ? kZapPrimary.withOpacity(0.3) // Selected Color
                       : (isSent ? kZapPrimary : kZapSurface),
                   border: isSelected ? Border.all(color: kZapPrimary, width: 2) : null,
                   borderRadius: BorderRadius.only(
                     topLeft: const Radius.circular(20),
                     topRight: const Radius.circular(20),
                     bottomLeft: Radius.circular(isSent ? 20 : 4),
                     bottomRight: Radius.circular(isSent ? 4 : 20),
                   ),
                 ),
                 child: ClipRRect(
                  borderRadius: BorderRadius.only(
                     topLeft: const Radius.circular(20),
                     topRight: const Radius.circular(20),
                     bottomLeft: Radius.circular(isSent ? 20 : 4),
                     bottomRight: Radius.circular(isSent ? 4 : 20),
                   ),
                  child: Material(
                    color: Colors.transparent,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                               if (isSelected) ...[
                                    Icon(Icons.check_circle, size: 20, color: isSent ? Colors.black : kZapPrimary),
                                    const SizedBox(width: 8),
                               ] else if (_isSelectionMode) ...[
                                    Icon(Icons.circle_outlined, size: 20, color: isSent ? Colors.black.withOpacity(0.5) : Colors.grey),
                                    const SizedBox(width: 8),
                               ],
                              Container(
                                padding: const EdgeInsets.all(8),
                                decoration: BoxDecoration(
                                  color: isSent
                                      ? Colors.black.withOpacity(0.1) // Darker bg on neon
                                      : Colors.white.withOpacity(0.05), // Lighter bg on dark
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Icon(
                                  fileIcon,
                                  color: isSent ? Colors.black : fileColor,
                                  size: 24,
                                ),
                              ),
                              const SizedBox(width: 12),
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
                                        fontSize: 11,
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
               const SizedBox(height: 6),
               Padding(
                 padding: const EdgeInsets.symmetric(horizontal: 4),
                 child: Text(
                   _formatDateTime(transfer.dateTime),
                   style: TextStyle(
                     color: Colors.grey[600],
                     fontSize: 10,
                     fontWeight: FontWeight.w500,
                   ),
                 ),
               ),
              ],
            ),
         ),
      ),
    );
  }
}
