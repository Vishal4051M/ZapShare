import 'dart:convert';
import 'dart:io';
import 'package:shared_preferences/shared_preferences.dart';

class TransferResumeStore {
  static const String _prefix = 'p2p_resume_';

  /// Persists metadata about an ongoing incoming transfer.
  static Future<void> persist({
    required String transferId,
    required String name,
    required int size,
    required int receivedBytes,
    required String partialFilePath,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final data = {
        'transferId': transferId,
        'name': name,
        'size': size,
        'receivedBytes': receivedBytes,
        'partialFilePath': partialFilePath,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      };
      await prefs.setString('$_prefix$transferId', jsonEncode(data));
    } catch (e) {
      print("Error persisting resume metadata: $e");
    }
  }

  /// Retrieves metadata for a specific transfer ID.
  static Future<Map<String, dynamic>?> get(String transferId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final str = prefs.getString('$_prefix$transferId');
      if (str != null) {
        return jsonDecode(str) as Map<String, dynamic>;
      }
    } catch (_) {}
    return null;
  }

  /// Searches for a partial transfer matching transferId or name and size.
  ///
  /// Two-pass: exact transferId always wins over any name+size coincidence,
  /// regardless of key iteration order.
  static Future<Map<String, dynamic>?> findByMatch(
    String name,
    int size, {
    String? transferId,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final keys = prefs.getKeys().where((k) => k.startsWith(_prefix)).toList();

      // Pass 1: exact transferId match only, across all records.
      if (transferId != null) {
        for (final key in keys) {
          final str = prefs.getString(key);
          if (str == null) continue;
          final data = jsonDecode(str) as Map<String, dynamic>;
          if (data['transferId'] == transferId) return data;
        }
      }

      // Pass 2: fall back to name+size only if no exact ID match found above.
      for (final key in keys) {
        final str = prefs.getString(key);
        if (str == null) continue;
        final data = jsonDecode(str) as Map<String, dynamic>;
        if (data['name'] == name && data['size'] == size) return data;
      }
    } catch (_) {}
    return null;
  }

  /// Deletes the metadata record.
  static Future<void> clear(String transferId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('$_prefix$transferId');
    } catch (_) {}
  }

  /// Scans and deletes orphaned partial files and metadata records older than 48 hours.
  static Future<void> cleanupOrphanedFiles() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final keys = prefs.getKeys().where((k) => k.startsWith(_prefix)).toList();
      final now = DateTime.now().millisecondsSinceEpoch;
      const fortyEightHours = 48 * 60 * 60 * 1000;

      for (final key in keys) {
        final str = prefs.getString(key);
        if (str != null) {
          final data = jsonDecode(str) as Map<String, dynamic>;
          final timestamp = data['timestamp'] as int? ?? 0;
          if (now - timestamp > fortyEightHours) {
            // Delete metadata
            await prefs.remove(key);
            // Delete orphaned partial file
            final filePath = data['partialFilePath'] as String?;
            if (filePath != null) {
              final file = File(filePath);
              if (await file.exists()) {
                await file.delete();
                print("Deleted orphaned partial file: $filePath");
              }
            }
          }
        }
      }
    } catch (e) {
      print("Error cleaning up orphaned partial files: $e");
    }
  }
}
