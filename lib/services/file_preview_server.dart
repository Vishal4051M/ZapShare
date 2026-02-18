import 'dart:io';
import 'dart:async';

class FilePreviewServer {
  HttpServer? _server;
  final Map<String, String> _filePaths = {}; // fileName -> absolutePath
  int _port = 0;

  int get port => _port;

  /// Start the server on an available port
  Future<void> start() async {
    if (_server != null) return;

    try {
      _server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      _port = _server!.port;
      print('🚀 Preview Server running on port $_port');

      _server!.listen(_handleRequest);
    } catch (e) {
      print('❌ Failed to start Preview Server: $e');
    }
  }

  void stop() {
    _server?.close();
    _server = null;
    _filePaths.clear();
    print('🛑 Preview Server stopped');
  }

  void registerFiles(List<String> paths) {
    _filePaths.clear();
    for (final path in paths) {
      final name = path.split('/').last;
      _filePaths[name] = path;
    }
  }

  void _handleRequest(HttpRequest request) async {
    final path = request.uri.path; // "/preview/filename.jpg"
    
    // Simple robust parsing
    // Expected format: /filename.ext
    if (path.length <= 1) {
      request.response.statusCode = HttpStatus.notFound;
      request.response.close();
      return;
    }

    final requestedName = Uri.decodeComponent(path.substring(1)); // Remove leading /
    print('🔎 Preview requested for: $requestedName');

    if (_filePaths.containsKey(requestedName)) {
      final filePath = _filePaths[requestedName]!;
      final file = File(filePath);
      
      if (await file.exists()) {
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.set("Connection", "close");
        
        // Helper to setup content type
        if (filePath.endsWith('.jpg') || filePath.endsWith('.jpeg')) {
          request.response.headers.contentType = ContentType('image', 'jpeg');
        } else if (filePath.endsWith('.png')) {
          request.response.headers.contentType = ContentType('image', 'png');
        } else if (filePath.endsWith('.pdf')) {
          request.response.headers.contentType = ContentType('application', 'pdf');
        } else if (filePath.endsWith('.mp4')) {
          request.response.headers.contentType = ContentType('video', 'mp4');
        } else if (filePath.endsWith('.mov')) {
          request.response.headers.contentType = ContentType('video', 'quicktime');
        } else if (filePath.endsWith('.avi')) {
          request.response.headers.contentType = ContentType('video', 'x-msvideo');
        } else if (filePath.endsWith('.mkv')) {
          request.response.headers.contentType = ContentType('video', 'x-matroska');
        } else if (filePath.endsWith('.mp3')) {
          request.response.headers.contentType = ContentType('audio', 'mpeg');
        } else if (filePath.endsWith('.wav')) {
          request.response.headers.contentType = ContentType('audio', 'wav');
        } else if (filePath.endsWith('.m4a')) {
          request.response.headers.contentType = ContentType('audio', 'mp4');
        }
        
        request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');

        final length = await file.length();
        final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
        
        if (rangeHeader != null) {
          try {
            final parts = rangeHeader.split('=');
            if (parts.length == 2 && 'bytes' == parts[0]) {
               final range = parts[1].split('-');
               final start = int.parse(range[0]);
               int? end;
               if (range.length > 1 && range[1].isNotEmpty) {
                 end = int.parse(range[1]);
               }
               
               // Default end to end of file
               end = end ?? length - 1;
               
               if (start >= length) {
                  request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
                  request.response.close();
                  return;
               }
               
               // Clamp end
               if (end > length - 1) end = length - 1;
               
               request.response.statusCode = HttpStatus.partialContent;
               request.response.headers.set(HttpHeaders.contentRangeHeader, 'bytes $start-$end/$length');
               request.response.headers.contentLength = end - start + 1;
               
               await file.openRead(start, end + 1).pipe(request.response);
               return;
            }
          } catch (e) {
            print('⚠️ Error parsing range header: $e. Falling back to full content.');
          }
        }
        
        // Fallback or no range: send full file
        request.response.headers.contentLength = length;
        await file.openRead().pipe(request.response);
      } else {
        request.response.statusCode = HttpStatus.notFound;
        request.response.close();
      }
    } else {
      request.response.statusCode = HttpStatus.notFound;
      request.response.close();
    }
  }
}
