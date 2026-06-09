import 'dart:io';
import 'dart:async';
import 'package:http/http.dart' as http;

/// Advanced Parallel HTTP Transfer Service
///
/// This service implements multi-stream parallel downloading to dramatically
/// increase file transfer speeds by:
/// 1. Splitting files into chunks
/// 2. Downloading multiple chunks simultaneously
/// 3. Reassembling chunks in correct order
/// 4. Using HTTP Range requests for resumable transfers
class ParallelTransferService {
  // Configuration
  static const int DEFAULT_CHUNK_SIZE =
      4 * 1024 * 1024; // 4MB chunks for maximum speed
  static const int DEFAULT_PARALLEL_STREAMS =
      8; // default parallel connections increased
  static const int MAX_PARALLEL_STREAMS =
      12; // Maximum parallel connections increased
  static const int MIN_FILE_SIZE_FOR_PARALLEL = 1024 * 1024; // 1MB minimum

  final int parallelStreams;
  final int chunkSize;

  ParallelTransferService({
    this.parallelStreams = DEFAULT_PARALLEL_STREAMS,
    this.chunkSize = DEFAULT_CHUNK_SIZE,
  });

  /// Download a file using parallel streams
  ///
  /// [url] - The file URL to download
  /// [savePath] - Where to save the downloaded file
  /// [onProgress] - Callback for progress updates (0.0 to 1.0)
  /// [onSpeedUpdate] - Callback for speed updates in Mbps
  /// [isPaused] - Function to check if download should pause
  Future<void> downloadFile({
    required String url,
    required String savePath,
    Function(double progress)? onProgress,
    Function(double speedMbps)? onSpeedUpdate,
    bool Function()? isPaused,
  }) async {
    // Get file size using HEAD request
    final headResponse = await http.head(Uri.parse(url));
    final contentLength = int.parse(
      headResponse.headers['content-length'] ?? '0',
    );

    if (contentLength == 0) {
      throw Exception('Could not determine file size');
    }

    // Check if server supports range requests
    final acceptRanges = headResponse.headers['accept-ranges'];
    final supportsRanges = acceptRanges == 'bytes';

    // Decide whether to use parallel download
    final useParallel =
        supportsRanges && contentLength >= MIN_FILE_SIZE_FOR_PARALLEL;

    if (!useParallel) {
      // Fall back to single-stream download
      await _downloadSingleStream(
        url: url,
        savePath: savePath,
        contentLength: contentLength,
        onProgress: onProgress,
        onSpeedUpdate: onSpeedUpdate,
        isPaused: isPaused,
      );
      return;
    }

    // Calculate optimal number of streams based on file size
    final optimalStreams = _calculateOptimalStreams(contentLength);
    final actualStreams =
        optimalStreams < parallelStreams ? optimalStreams : parallelStreams;

    print(
      '🚀 Starting parallel download: $actualStreams streams, ${contentLength ~/ (1024 * 1024)} MB',
    );

    // Download using parallel streams
    await _downloadParallelStreams(
      url: url,
      savePath: savePath,
      contentLength: contentLength,
      streams: actualStreams,
      onProgress: onProgress,
      onSpeedUpdate: onSpeedUpdate,
      isPaused: isPaused,
    );
  }

  /// Calculate optimal number of streams based on file size
  int _calculateOptimalStreams(int fileSize) {
    // Very small files (<1MB): single stream
    if (fileSize < 1 * 1024 * 1024) return 1;

    // Small files (<5MB): 2 streams
    if (fileSize < 5 * 1024 * 1024) return 2;

    // Medium files (<20MB): 6 streams (aggressive for responsiveness)
    if (fileSize < 20 * 1024 * 1024) return 6;

    // Large files (<100MB): 8 streams
    if (fileSize < 100 * 1024 * 1024) return 8;

    // Very large files (<500MB): 10 streams
    if (fileSize < 500 * 1024 * 1024) return 10;

    // Extremely large files: max streams
    return MAX_PARALLEL_STREAMS;
  }

  /// Single stream download (fallback)
  Future<void> _downloadSingleStream({
    required String url,
    required String savePath,
    required int contentLength,
    Function(double progress)? onProgress,
    Function(double speedMbps)? onSpeedUpdate,
    bool Function()? isPaused,
  }) async {
    final file = File(savePath);
    final sink = file.openWrite();

    final client = http.Client();
    final request = http.Request('GET', Uri.parse(url));
    final response = await client.send(request);

    int received = 0;
    DateTime lastUpdate = DateTime.now();
    DateTime lastSpeedTime = DateTime.now();
    int lastBytes = 0;

    await for (var chunk in response.stream) {
      // Handle pause
      while (isPaused?.call() ?? false) {
        await Future.delayed(Duration(milliseconds: 100));
      }

      sink.add(chunk);
      received += chunk.length;

      // Update progress and speed
      final now = DateTime.now();
      if (now.difference(lastUpdate).inMilliseconds > 100) {
        final progress = received / contentLength;
        onProgress?.call(progress);

        final elapsed = now.difference(lastSpeedTime).inMilliseconds;
        if (elapsed > 0) {
          final bytesDelta = received - lastBytes;
          final speedMbps = (bytesDelta * 8) / (elapsed * 1000);
          onSpeedUpdate?.call(speedMbps);
          lastBytes = received;
          lastSpeedTime = now;
        }

        lastUpdate = now;
      }
    }

    await sink.flush();
    await sink.close();
    client.close();
  }

  /// Parallel streams download
  Future<void> _downloadParallelStreams({
    required String url,
    required String savePath,
    required int contentLength,
    required int streams,
    Function(double progress)? onProgress,
    Function(double speedMbps)? onSpeedUpdate,
    bool Function()? isPaused,
  }) async {
    // 1. Create the final file and pre-allocate its size
    final finalFile = File(savePath);

    // Ensure parent directory exists
    final parentDir = finalFile.parent;
    if (!await parentDir.exists()) {
      await parentDir.create(recursive: true);
    }

    // Pre-allocate file size by writing a single byte at the end
    // This is faster than writing zeroes and ensures space is available
    final raf = await finalFile.open(mode: FileMode.write);
    await raf.truncate(contentLength);
    await raf.close();

    // Calculate chunk ranges for each stream
    final chunkSize = (contentLength / streams).ceil();
    final ranges = <Map<String, int>>[];

    for (int i = 0; i < streams; i++) {
      final start = i * chunkSize;
      if (start >= contentLength) break; // Fewer streams needed for small files

      final end =
          (start + chunkSize - 1) < contentLength
              ? (start + chunkSize - 1)
              : contentLength - 1;

      ranges.add({'start': start, 'end': end, 'size': end - start + 1});
    }

    final actualStreams = ranges.length;
    print(
      '📊 Chunk ranges: ${ranges.map((r) => '${r["start"]}-${r["end"]}').join(", ")}',
    );

    // Track progress for each stream
    final streamProgress = List<int>.filled(actualStreams, 0);
    final streamSpeeds = List<double>.filled(actualStreams, 0.0);
    DateTime lastUpdate = DateTime.now();

    try {
      // Download all chunks in parallel
      await Future.wait(
        List.generate(actualStreams, (index) async {
          final range = ranges[index];
          final start = range['start']!;
          final end = range['end']!;

          // Each stream uses its own RandomAccessFile handle to the same file
          // This allows concurrent writing to different offsets
          final fileHandle = await finalFile.open(mode: FileMode.writeOnly);

          try {
            await _downloadChunk(
              url: url,
              start: start,
              end: end,
              file: fileHandle,
              onProgress: (bytesReceived, speed) {
                streamProgress[index] = bytesReceived;
                streamSpeeds[index] = speed;

                // Calculate overall progress
                final now = DateTime.now();
                if (now.difference(lastUpdate).inMilliseconds > 100) {
                  final totalReceived = streamProgress.reduce((a, b) => a + b);
                  final downloadProgress = (totalReceived / contentLength);
                  onProgress?.call(downloadProgress);

                  // Calculate combined speed
                  final totalSpeed = streamSpeeds.reduce((a, b) => a + b);
                  onSpeedUpdate?.call(totalSpeed);

                  lastUpdate = now;
                }
              },
              isPaused: isPaused,
            );
          } finally {
            await fileHandle.flush();
            await fileHandle.close();
          }
        }),
      );

      onProgress?.call(1.0); // Complete
      print('✅ Parallel download complete!');
    } catch (e) {
      print('❌ Parallel download failed: $e');
      rethrow;
    }
  }

  /// Download a single chunk with range request
  Future<void> _downloadChunk({
    required String url,
    required int start,
    required int end,
    required RandomAccessFile file,
    required Function(int bytesReceived, double speedMbps) onProgress,
    bool Function()? isPaused,
  }) async {
    final client = http.Client();

    try {
      final request = http.Request('GET', Uri.parse(url));
      request.headers['Range'] = 'bytes=$start-$end';

      final response = await client.send(request);

      if (response.statusCode != 206 && response.statusCode != 200) {
        throw Exception('Range request failed: ${response.statusCode}');
      }

      int received = 0;
      DateTime lastSpeedTime = DateTime.now();
      int lastBytes = 0;

      await for (var chunk in response.stream) {
        // Handle pause
        while (isPaused?.call() ?? false) {
          await Future.delayed(Duration(milliseconds: 100));
        }

        await file.setPosition(start + received);
        await file.writeFrom(chunk);
        received += chunk.length;

        // Calculate speed
        final now = DateTime.now();
        final elapsed = now.difference(lastSpeedTime).inMilliseconds;
        double speedMbps = 0.0;

        if (elapsed > 0) {
          final bytesDelta = received - lastBytes;
          speedMbps = (bytesDelta * 8) / (elapsed * 1000);
          lastBytes = received;
          lastSpeedTime = now;
        }

        onProgress(received, speedMbps);
      }
    } finally {
      client.close();
    }
  }

  /// Upload a file using parallel streams
  ///
  /// Note: Server must support chunked uploads or multipart uploads
  /// This is more complex and depends on server implementation
  Future<void> uploadFile({
    required String url,
    required String filePath,
    Function(double progress)? onProgress,
    Function(double speedMbps)? onSpeedUpdate,
    bool Function()? isPaused,
  }) async {
    final file = File(filePath);
    final fileSize = await file.length();

    // For now, use single-stream upload
    // Parallel upload would require server-side support for chunked uploads
    await _uploadSingleStream(
      url: url,
      filePath: filePath,
      fileSize: fileSize,
      onProgress: onProgress,
      onSpeedUpdate: onSpeedUpdate,
      isPaused: isPaused,
    );
  }

  /// Single stream upload (current implementation)
  Future<void> _uploadSingleStream({
    required String url,
    required String filePath,
    required int fileSize,
    Function(double progress)? onProgress,
    Function(double speedMbps)? onSpeedUpdate,
    bool Function()? isPaused,
  }) async {
    // This would integrate with your existing serveSafFile logic
    // For now, this is a placeholder
    throw UnimplementedError('Upload not yet implemented in parallel service');
  }
}

/// Extension methods for easier integration
extension ParallelTransferExtension on File {
  /// Download this file using parallel streams
  Future<void> downloadFromUrlParallel(
    String url, {
    int parallelStreams = ParallelTransferService.DEFAULT_PARALLEL_STREAMS,
    Function(double progress)? onProgress,
    Function(double speedMbps)? onSpeedUpdate,
    bool Function()? isPaused,
  }) async {
    final service = ParallelTransferService(parallelStreams: parallelStreams);
    await service.downloadFile(
      url: url,
      savePath: path,
      onProgress: onProgress,
      onSpeedUpdate: onSpeedUpdate,
      isPaused: isPaused,
    );
  }
}
