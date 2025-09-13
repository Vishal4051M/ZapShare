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
  final String peer;
  final DateTime dateTime;
  final String? fileLocation; // File path for received files

  TransferHistoryEntry({
    required this.fileName,
    required this.fileSize,
    required this.direction,
    required this.peer,
    required this.dateTime,
    this.fileLocation,
  });

  Map<String, dynamic> toJson() => {
        'fileName': fileName,
        'fileSize': fileSize,
        'direction': direction,
        'peer': peer,
        'dateTime': dateTime.toIso8601String(),
        'fileLocation': fileLocation,
      };

  static TransferHistoryEntry fromJson(Map<String, dynamic> json) => TransferHistoryEntry(
        fileName: json['fileName'],
        fileSize: json['fileSize'],
        direction: json['direction'],
        peer: json['peer'],
        dateTime: DateTime.parse(json['dateTime']),
        fileLocation: json['fileLocation'],
      );
}

class TransferHistoryScreen extends StatefulWidget {
  const TransferHistoryScreen({super.key});
  @override
  State<TransferHistoryScreen> createState() => _TransferHistoryScreenState();
}

class _TransferHistoryScreenState extends State<TransferHistoryScreen> {
  List<TransferHistoryEntry> _history = [];
  List<TransferHistoryEntry> _filteredHistory = [];
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
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
    _searchFocusNode.dispose();
    super.dispose();
  }

  Future<void> _loadHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList('transfer_history') ?? [];
    setState(() {
      _history = list.map((e) => TransferHistoryEntry.fromJson(jsonDecode(e))).toList();
      _filteredHistory = _history;
    });
  }

  void _onSearchChanged() {
    final query = _searchController.text.toLowerCase();
    setState(() {
      if (query.isEmpty) {
        _filteredHistory = _history;
      } else {
        _filteredHistory = _history.where((entry) =>
          entry.fileName.toLowerCase().contains(query)
        ).toList();
      }
    });
  }

  void _toggleSearch() {
    setState(() {
      _isSearching = !_isSearching;
      if (!_isSearching) {
        _searchController.clear();
        _searchFocusNode.unfocus();
      } else {
        _searchFocusNode.requestFocus();
      }
    });
  }

  Future<void> _clearHistory() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('transfer_history');
    setState(() {
      _history = [];
      _filteredHistory = [];
    });
  }

  Future<void> _deleteEntry(int index) async {
    final entry = _filteredHistory[index];
    final originalIndex = _history.indexOf(entry);
    
    if (originalIndex == -1) return;
    
    HapticFeedback.mediumImpact();
    
    // Remove from history
    _history.removeAt(originalIndex);
    _filteredHistory.removeAt(index);
    
    // Save to SharedPreferences
    final prefs = await SharedPreferences.getInstance();
    final list = _history.map((e) => jsonEncode(e.toJson())).toList();
    await prefs.setStringList('transfer_history', list);
    
    setState(() {});
  }

  Future<bool> _showDeleteConfirmation(String fileName) async {
    return await showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          backgroundColor: Colors.grey[900],
          title: Text(
            'Delete Entry',
            style: TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w600,
            ),
          ),
          content: Text(
            'Are you sure you want to remove "$fileName" from transfer history?',
            style: TextStyle(
              color: Colors.grey[300],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(
                'Cancel',
                style: TextStyle(
                  color: Colors.grey[400],
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              style: TextButton.styleFrom(
                backgroundColor: Colors.red[600],
                foregroundColor: Colors.white,
              ),
              child: Text(
                'Delete',
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        );
      },
    ) ?? false;
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return "$bytes B";
    if (bytes < 1024 * 1024) return "${(bytes / 1024).toStringAsFixed(1)} KB";
    if (bytes < 1024 * 1024 * 1024) return "${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB";
    return "${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB";
  }

  // Get file type category
  FileType _getFileType(String fileName) {
    final ext = fileName.split('.').last.toLowerCase();
    
    if (['jpg', 'jpeg', 'png', 'gif', 'bmp', 'webp', 'svg', 'ico', 'tiff', 'tif', 'heic', 'heif', 'avif', 'jxl'].contains(ext)) {
      return FileType.image;
    } else if (['mp4', 'mov', 'avi', 'mkv', 'wmv', 'flv', 'webm', 'm4v', '3gp'].contains(ext)) {
      return FileType.video;
    } else if (['mp3', 'wav', 'flac', 'aac', 'ogg', 'm4a', 'wma'].contains(ext)) {
      return FileType.audio;
    } else if (['pdf'].contains(ext)) {
      return FileType.pdf;
    } else if (['doc', 'docx'].contains(ext)) {
      return FileType.document;
    } else if (['xls', 'xlsx'].contains(ext)) {
      return FileType.spreadsheet;
    } else if (['ppt', 'pptx'].contains(ext)) {
      return FileType.presentation;
    } else if (['zip', 'rar', '7z', 'tar', 'gz'].contains(ext)) {
      return FileType.archive;
    } else if (['txt', 'rtf', 'md'].contains(ext)) {
      return FileType.text;
    } else {
      return FileType.other;
    }
  }

  // Open file based on type
  Future<void> _openFileByType(String filePath, String fileName) async {
    final fileType = _getFileType(fileName);
    
    try {
      switch (fileType) {
        case FileType.image:
          await _openImageFile(filePath, fileName);
          break;
        case FileType.video:
          await _openVideoFile(filePath, fileName);
          break;
        case FileType.audio:
          await _openAudioFile(filePath, fileName);
          break;
        case FileType.pdf:
          await _openPdfFile(filePath, fileName);
          break;
        case FileType.document:
        case FileType.spreadsheet:
        case FileType.presentation:
          await _openDocumentFile(filePath, fileName);
          break;
        case FileType.text:
          await _openTextFile(filePath, fileName);
          break;
        case FileType.archive:
          await _openArchiveFile(filePath, fileName);
          break;
        case FileType.other:
          await _openGenericFile(filePath, fileName);
          break;
      }
    } catch (e) {
      _showFileNotFoundDialog(fileName);
    }
  }

  Future<void> _openImageFile(String filePath, String fileName) async {
    // Try to open with image viewer
    final result = await OpenFile.open(filePath, type: 'image/*');
    if (result.type != ResultType.done) {
      _showFileNotFoundDialog(fileName);
    }
  }

  Future<void> _openVideoFile(String filePath, String fileName) async {
    final result = await OpenFile.open(filePath, type: 'video/*');
    if (result.type != ResultType.done) {
      _showFileNotFoundDialog(fileName);
    }
  }

  Future<void> _openAudioFile(String filePath, String fileName) async {
    final result = await OpenFile.open(filePath, type: 'audio/*');
    if (result.type != ResultType.done) {
      _showFileNotFoundDialog(fileName);
    }
  }

  Future<void> _openPdfFile(String filePath, String fileName) async {
    final result = await OpenFile.open(filePath, type: 'application/pdf');
    if (result.type != ResultType.done) {
      _showFileNotFoundDialog(fileName);
    }
  }

  Future<void> _openDocumentFile(String filePath, String fileName) async {
    final result = await OpenFile.open(filePath);
    if (result.type != ResultType.done) {
      _showFileNotFoundDialog(fileName);
    }
  }

  Future<void> _openTextFile(String filePath, String fileName) async {
    final result = await OpenFile.open(filePath, type: 'text/*');
    if (result.type != ResultType.done) {
      _showFileNotFoundDialog(fileName);
    }
  }

  Future<void> _openArchiveFile(String filePath, String fileName) async {
    final result = await OpenFile.open(filePath);
    if (result.type != ResultType.done) {
      _showFileNotFoundDialog(fileName);
    }
  }

  Future<void> _openGenericFile(String filePath, String fileName) async {
    final result = await OpenFile.open(filePath);
    if (result.type != ResultType.done) {
      _showFileNotFoundDialog(fileName);
    }
  }

  Future<void> _openFile(TransferHistoryEntry entry) async {
    try {
      String? filePath;
      
      if (entry.direction == 'Received') {
        // First try the saved file location
        if (entry.fileLocation != null && await File(entry.fileLocation!).exists()) {
          filePath = entry.fileLocation;
        } else {
          // Try common download directories
          final downloadPaths = [
            '/storage/emulated/0/Download/${entry.fileName}',
            '/storage/emulated/0/Downloads/${entry.fileName}',
            '/sdcard/Download/${entry.fileName}',
            '/sdcard/Downloads/${entry.fileName}',
          ];
          
          for (final path in downloadPaths) {
            if (await File(path).exists()) {
              filePath = path;
              break;
            }
          }
        }
      }
      
      if (filePath != null) {
        await _openFileByType(filePath, entry.fileName);
      } else {
        _showFileNotFoundDialog(entry.fileName);
      }
    } catch (e) {
      _showFileNotFoundDialog(entry.fileName);
    }
  }

  void _showFileNotFoundDialog(String fileName) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          backgroundColor: Colors.grey[900],
          title: Text(
            'File Not Found',
            style: TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w600,
            ),
          ),
          content: Text(
            'The file "$fileName" could not be found in the expected location.',
            style: TextStyle(
              color: Colors.grey[300],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(
                'OK',
                style: TextStyle(
                  color: Colors.yellow[300],
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        );
      },
    );
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
                  IconButton(
                    icon: Icon(Icons.arrow_back_ios_rounded, color: Colors.white, size: 20),
                    onPressed: () => Navigator.pop(context),
                  ),
                  Expanded(
                    child: Text(
                      'Transfer History',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 28,
                        fontWeight: FontWeight.w300,
                        letterSpacing: -0.5,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                  if (_history.isNotEmpty) ...[
                    IconButton(
                      icon: Icon(
                        _isSearching ? Icons.close_rounded : Icons.search_rounded,
                        color: Colors.grey[400],
                        size: 20,
                      ),
                      onPressed: _toggleSearch,
                    ),
                    IconButton(
                      icon: Icon(Icons.delete_outline_rounded, color: Colors.grey[400], size: 20),
                      onPressed: _clearHistory,
                    ),
                  ] else
                    const SizedBox(width: 48), // Balance the back button
                ],
              ),
            ),
            
            // Search Bar
            if (_isSearching)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
                child: TextField(
                  controller: _searchController,
                  focusNode: _searchFocusNode,
                  style: TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    hintText: 'Search by file name...',
                    hintStyle: TextStyle(color: Colors.grey[500]),
                    prefixIcon: Icon(Icons.search_rounded, color: Colors.grey[400]),
                    suffixIcon: _searchController.text.isNotEmpty
                        ? IconButton(
                            icon: Icon(Icons.clear_rounded, color: Colors.grey[400]),
                            onPressed: () {
                              _searchController.clear();
                            },
                          )
                        : null,
                    filled: true,
                    fillColor: Colors.grey[900],
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: Colors.grey[800]!),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: Colors.grey[800]!),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: Colors.yellow[300]!),
                    ),
                    contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  ),
                ),
              ),
            
            // Main content
            Expanded(
              child: _history.isEmpty
                ? _buildEmptyState()
                : _filteredHistory.isEmpty && _isSearching
                  ? _buildNoSearchResults()
                  : _buildHistoryList(),
            ),
          ],
        ),
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
              Icons.history_rounded,
              color: Colors.grey[600],
              size: 40,
            ),
          ),
          const SizedBox(height: 24),
          Text(
            'No Transfer History',
            style: TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Your file transfer history will appear here',
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

  Widget _buildNoSearchResults() {
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
              Icons.search_off_rounded,
              color: Colors.grey[600],
              size: 40,
            ),
          ),
          const SizedBox(height: 24),
          Text(
            'No Results Found',
            style: TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Try searching with a different file name',
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

  Widget _buildHistoryList() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _isSearching ? 'Search Results' : 'Recent Transfers',
            style: TextStyle(
              color: Colors.grey[400],
              fontSize: 14,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 16),
          Expanded(
            child: ListView.builder(
              itemCount: _filteredHistory.length,
              itemBuilder: (context, index) {
                final entry = _filteredHistory[index];
                return _buildSwipeToDeleteEntry(entry, index);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSwipeToDeleteEntry(TransferHistoryEntry entry, int index) {
    return Dismissible(
      key: Key('${entry.fileName}_${entry.dateTime.millisecondsSinceEpoch}'),
      direction: DismissDirection.endToStart, // Swipe right to left
      background: Container(
        margin: EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(
          color: Colors.red[600],
          borderRadius: BorderRadius.circular(12),
        ),
        alignment: Alignment.centerRight,
        padding: EdgeInsets.only(right: 16),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.delete_rounded,
              color: Colors.white,
              size: 24,
            ),
            SizedBox(height: 2),
            Text(
              'Delete',
              style: TextStyle(
                color: Colors.white,
                fontSize: 10,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
      confirmDismiss: (direction) async {
        final shouldDelete = await _showDeleteConfirmation(entry.fileName);
        if (shouldDelete) {
          _deleteEntry(index);
        }
        return false; // Always return false to prevent automatic dismissal
      },
      resizeDuration: Duration(milliseconds: 200),
      child: Container(
        margin: EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(
          color: Colors.grey[900],
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.grey[800]!, width: 1),
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () {
              if (entry.direction == 'Received') {
                _openFile(entry);
              }
            },
            child: Padding(
              padding: EdgeInsets.all(12),
              child: Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: entry.direction == 'Sent' 
                        ? Colors.yellow[300] 
                        : Colors.grey[700],
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(
                      entry.direction == 'Sent' 
                        ? Icons.upload_rounded 
                        : Icons.download_rounded,
                      color: entry.direction == 'Sent' 
                        ? Colors.black 
                        : Colors.white,
                      size: 18,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          entry.fileName,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Row(
                          children: [
                            Container(
                              padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: entry.direction == 'Sent' 
                                  ? Colors.yellow[300]!.withOpacity(0.2)
                                  : Colors.grey[700],
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                entry.direction,
                                style: TextStyle(
                                  color: entry.direction == 'Sent' 
                                    ? Colors.yellow[300] 
                                    : Colors.grey[300],
                                  fontSize: 10,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              _formatBytes(entry.fileSize),
                              style: TextStyle(
                                color: Colors.grey[400],
                                fontSize: 10,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${entry.peer} • ${_formatDateTime(entry.dateTime)}',
                          style: TextStyle(
                            color: Colors.grey[500],
                            fontSize: 10,
                            fontWeight: FontWeight.w400,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (entry.direction == 'Received')
                    Icon(
                      Icons.open_in_new_rounded,
                      color: Colors.grey[500],
                      size: 16,
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _formatDateTime(DateTime dateTime) {
    final now = DateTime.now();
    final difference = now.difference(dateTime);
    
    if (difference.inDays > 0) {
      return '${difference.inDays}d ago';
    } else if (difference.inHours > 0) {
      return '${difference.inHours}h ago';
    } else if (difference.inMinutes > 0) {
      return '${difference.inMinutes}m ago';
    } else {
      return 'Just now';
    }
  }
} 