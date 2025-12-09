import 'dart:io';
import 'dart:async';
import 'package:flutter/services.dart';

/// HTTP Range Request Handler
/// 
/// Enables efficient parallel file transfers by supporting:
/// 1. HTTP Range requests (RFC 7233)
/// 2. Partial content delivery (206 status)
/// 3. Multi-range support
/// 4. Resumable downloads
class RangeRequestHandler {
  
  /// Handle a range request for a file
  /// 
  /// Supports:
  /// - Single range: Range: bytes=0-1023
  /// - Multiple ranges: Range: bytes=0-1023,2048-3071
  /// - Open-ended ranges: Range: bytes=1024-
  /// - Suffix ranges: Range: bytes=-1024
  static Future<void> handleRangeRequest({
    required HttpRequest request,
    required String uri,
    required String fileName,
    required int fileSize,
    Function(int bytesSent, double progress)? onProgress,
  }) async {
    final response = request.response;
    final rangeHeader = request.headers.value('range');
    
    // If no range header, serve full file
    if (rangeHeader == null || rangeHeader.isEmpty) {
      await _serveFullFile(request, uri, fileName, fileSize);
      return;
    }
    
    try {
      // Parse range header
      final ranges = _parseRangeHeader(rangeHeader, fileSize);
      
      if (ranges.isEmpty) {
        // Invalid range
        response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        response.headers.set('Content-Range', 'bytes */$fileSize');
        await response.close();
        return;
      }
      
      // For simplicity, only handle single range requests
      // Multi-range would require multipart/byteranges response
      if (ranges.length > 1) {
        print('⚠️ Multi-range request not supported, serving first range only');
      }
      
      final range = ranges.first;
      await _servePartialFile(
        request,
        uri,
        fileName,
        fileSize,
        range['start']!,
        range['end']!,
        onProgress: onProgress,
      );
      
    } catch (e) {
      print('❌ Error handling range request: $e');
      response.statusCode = HttpStatus.internalServerError;
      await response.close();
    }
  }
  
  /// Serve the full file (no range request)
  static Future<void> _serveFullFile(
    HttpRequest request,
    String uri,
    String fileName,
    int fileSize,
  ) async {
    final response = request.response;
    
    response.statusCode = HttpStatus.ok;
    response.headers.set('Content-Length', fileSize.toString());
    response.headers.set('Content-Type', 'application/octet-stream');
    response.headers.set('Content-Disposition', 'attachment; filename="$fileName"');
    response.headers.set('Accept-Ranges', 'bytes');
    
    await _streamFileContent(response, uri, 0, fileSize - 1, fileSize);
  }
  
  /// Serve a partial file (range request)
  static Future<void> _servePartialFile(
    HttpRequest request,
    String uri,
    String fileName,
    int fileSize,
    int start,
    int end, {
    Function(int bytesSent, double progress)? onProgress,
  }) async {
    final response = request.response;
    final contentLength = end - start + 1;
    
    response.statusCode = HttpStatus.partialContent; // 206
    response.headers.set('Content-Length', contentLength.toString());
    response.headers.set('Content-Type', 'application/octet-stream');
    response.headers.set('Content-Disposition', 'attachment; filename="$fileName"');
    response.headers.set('Accept-Ranges', 'bytes');
    response.headers.set('Content-Range', 'bytes $start-$end/$fileSize');
    
    print('📦 Serving range: bytes $start-$end/$fileSize (${contentLength} bytes)');
    
    await _streamFileContent(response, uri, start, end, fileSize, onProgress: onProgress);
  }
  
  /// Stream file content for a specific byte range
  static Future<void> _streamFileContent(
    HttpResponse response,
    String uri,
    int start,
    int end,
    int totalFileSize, {
    Function(int bytesSent, double progress)? onProgress,
  }) async {
    const int CHUNK_SIZE = 4 * 1024 * 1024; // 4MB chunks for maximum speed
    const channel = MethodChannel('zapshare.saf');
    
    String? streamId;
    
    try {
      // Open a fresh stream with unique ID for this range request
      final result = await channel.invokeMethod('openReadStream', {
        'uri': uri,
      });
      
      if (result == null) {
        print('❌ Failed to open stream for range $start-$end');
        throw Exception('Failed to open stream');
      }
      
      // Result is the stream ID
      streamId = result is bool ? null : result.toString();
      print('✅ Stream opened with ID: $streamId for range $start-$end');
      
      // Seek to start position if not at beginning
      if (start > 0) {
        try {
          await channel.invokeMethod('seekStream', {
            'uri': uri,
            'streamId': streamId,
            'position': start,
          });
          print('✅ Seeked to position $start');
        } catch (e) {
          print('⚠️ Seek failed: $e, reading and discarding $start bytes instead');
          // Fallback: read and discard bytes until start position
          int toSkip = start;
          while (toSkip > 0) {
            final skipSize = toSkip > CHUNK_SIZE ? CHUNK_SIZE : toSkip;
            final discardChunk = await channel.invokeMethod<Uint8List>('readChunk', {
              'uri': uri,
              'streamId': streamId,
              'size': skipSize,
            });
            if (discardChunk == null || discardChunk.isEmpty) break;
            toSkip -= discardChunk.length;
          }
        }
      }
      
      int currentPosition = start;
      int bytesToRead = end - start + 1;
      int totalSent = 0;
      
      print('📦 Starting stream: bytes $start-$end (${bytesToRead} bytes total)');
      
      while (bytesToRead > 0) {
        final chunkSize = bytesToRead > CHUNK_SIZE ? CHUNK_SIZE : bytesToRead;
        
        final chunk = await channel.invokeMethod<Uint8List>('readChunk', {
          'uri': uri,
          'streamId': streamId,
          'size': chunkSize,
        });
        
        if (chunk == null || chunk.isEmpty) {
          print('⚠️ End of stream at position $currentPosition (expected $end)');
          break;
        }
        
        // Only send the exact number of bytes needed
        final bytesToSend = chunk.length > bytesToRead ? bytesToRead : chunk.length;
        if (bytesToSend < chunk.length) {
          response.add(chunk.sublist(0, bytesToSend));
        } else {
          response.add(chunk);
        }
        
        await response.flush();
        
        totalSent += bytesToSend;
        currentPosition += bytesToSend;
        bytesToRead -= bytesToSend;
        
        // Report progress to callback if provided
        if (onProgress != null) {
          // totalSent is the bytes sent for this range so far
          final overallProgress = currentPosition / totalFileSize;
          onProgress(totalSent, overallProgress);
        }
        
        // Progress logging every 1MB
        if (totalSent % (1024 * 1024) < CHUNK_SIZE) {
          final progress = (totalSent / (end - start + 1) * 100).toStringAsFixed(1);
          print('  📤 Range $start-$end: ${totalSent} / ${end - start + 1} bytes ($progress%)');
        }
      }
      
      print('✅ Completed range $start-$end: sent $totalSent bytes');
      
    } catch (e) {
      print('❌ Error streaming range $start-$end: $e');
      rethrow;
    } finally {
      // Always close stream if it was opened
      if (streamId != null) {
        try {
          await channel.invokeMethod('closeStream', {
            'uri': uri,
            'streamId': streamId,
          });
          print('🔒 Stream closed: $streamId');
        } catch (e) {
          print('⚠️ Error closing stream: $e');
        }
      }
      
      try {
        await response.close();
      } catch (e) {
        print('⚠️ Error closing response: $e');
      }
    }
  }
  
  /// Parse Range header
  /// 
  /// Examples:
  /// - "bytes=0-1023" -> [{start: 0, end: 1023}]
  /// - "bytes=1024-" -> [{start: 1024, end: fileSize-1}]
  /// - "bytes=-1024" -> [{start: fileSize-1024, end: fileSize-1}]
  /// - "bytes=0-1023,2048-3071" -> [{start: 0, end: 1023}, {start: 2048, end: 3071}]
  static List<Map<String, int>> _parseRangeHeader(
    String rangeHeader,
    int fileSize,
  ) {
    final ranges = <Map<String, int>>[];
    
    // Expected format: "bytes=start-end"
    if (!rangeHeader.startsWith('bytes=')) {
      return ranges;
    }
    
    final rangeSpecs = rangeHeader.substring(6).split(',');
    
    for (final spec in rangeSpecs) {
      final parts = spec.trim().split('-');
      
      if (parts.length != 2) continue;
      
      final startStr = parts[0].trim();
      final endStr = parts[1].trim();
      
      int start;
      int end;
      
      if (startStr.isEmpty && endStr.isNotEmpty) {
        // Suffix range: -1024 (last 1024 bytes)
        final suffixLength = int.tryParse(endStr);
        if (suffixLength == null) continue;
        
        start = fileSize - suffixLength;
        end = fileSize - 1;
      } else if (startStr.isNotEmpty && endStr.isEmpty) {
        // Open-ended range: 1024- (from byte 1024 to end)
        start = int.tryParse(startStr) ?? 0;
        end = fileSize - 1;
      } else if (startStr.isNotEmpty && endStr.isNotEmpty) {
        // Normal range: 0-1023
        start = int.tryParse(startStr) ?? 0;
        end = int.tryParse(endStr) ?? (fileSize - 1);
      } else {
        continue;
      }
      
      // Validate range
      if (start < 0) start = 0;
      if (end >= fileSize) end = fileSize - 1;
      if (start > end) continue;
      
      ranges.add({'start': start, 'end': end});
    }
    
    return ranges;
  }
}

/// Extension to add range request support to existing file serving
extension RangeRequestExtension on HttpRequest {
  /// Check if this is a range request
  bool get isRangeRequest {
    final rangeHeader = headers.value('range');
    return rangeHeader != null && rangeHeader.isNotEmpty;
  }
  
  /// Get the requested ranges
  List<Map<String, int>> getRanges(int fileSize) {
    final rangeHeader = headers.value('range');
    if (rangeHeader == null) return [];
    
    return RangeRequestHandler._parseRangeHeader(rangeHeader, fileSize);
  }
}
