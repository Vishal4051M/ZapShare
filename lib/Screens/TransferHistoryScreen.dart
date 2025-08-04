import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';

class TransferHistoryEntry {
  final String fileName;
  final int fileSize;
  final String direction; // 'Sent' or 'Received'
  final String peer;
  final DateTime dateTime;

  TransferHistoryEntry({
    required this.fileName,
    required this.fileSize,
    required this.direction,
    required this.peer,
    required this.dateTime,
  });

  Map<String, dynamic> toJson() => {
        'fileName': fileName,
        'fileSize': fileSize,
        'direction': direction,
        'peer': peer,
        'dateTime': dateTime.toIso8601String(),
      };

  static TransferHistoryEntry fromJson(Map<String, dynamic> json) => TransferHistoryEntry(
        fileName: json['fileName'],
        fileSize: json['fileSize'],
        direction: json['direction'],
        peer: json['peer'],
        dateTime: DateTime.parse(json['dateTime']),
      );
}

class TransferHistoryScreen extends StatefulWidget {
  const TransferHistoryScreen({super.key});
  @override
  State<TransferHistoryScreen> createState() => _TransferHistoryScreenState();
}

class _TransferHistoryScreenState extends State<TransferHistoryScreen> {
  List<TransferHistoryEntry> _history = [];

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  Future<void> _loadHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList('transfer_history') ?? [];
    setState(() {
      _history = list.map((e) => TransferHistoryEntry.fromJson(jsonDecode(e))).toList();
    });
  }

  Future<void> _clearHistory() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('transfer_history');
    setState(() {
      _history = [];
    });
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return "$bytes B";
    if (bytes < 1024 * 1024) return "${(bytes / 1024).toStringAsFixed(1)} KB";
    if (bytes < 1024 * 1024 * 1024) return "${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB";
    return "${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB";
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Transfer History'),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete),
            tooltip: 'Clear History',
            onPressed: _history.isNotEmpty ? _clearHistory : null,
          ),
        ],
      ),
      body: _history.isEmpty
          ? const Center(child: Text('No transfer history yet.'))
          : ListView.builder(
              itemCount: _history.length,
              itemBuilder: (context, index) {
                final entry = _history[index];
                return Card(
                  margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
                  child: ListTile(
                    leading: Icon(entry.direction == 'Sent' ? Icons.upload_rounded : Icons.download_rounded, color: entry.direction == 'Sent' ? Colors.yellow : Colors.white),
                    title: Text(entry.fileName),
                    subtitle: Text('${_formatBytes(entry.fileSize)}\n${entry.direction} • ${entry.peer}\n${entry.dateTime.toLocal()}'),
                    isThreeLine: true,
                  ),
                );
              },
            ),
    );
  }
} 