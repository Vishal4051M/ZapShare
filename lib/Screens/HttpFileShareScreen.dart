import 'dart:io';
import 'package:flutter/material.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:saf_stream/saf_stream.dart';
import 'package:saf_util/saf_util.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'dart:convert';

const Color kAndroidAccentYellow = Color(0xFFFFF176); // lighter yellow for Android

class HttpFileShareScreen extends StatefulWidget {
  @override
  _HttpFileShareScreenState createState() => _HttpFileShareScreenState();
}

class _HttpFileShareScreenState extends State<HttpFileShareScreen> {
  final _pageController = PageController();
  final _safUtil = SafUtil();
  List<String> _fileUris = [];
  List<String> _fileNames = [];

  String? _localIp;
  HttpServer? _server;
  bool _isSharing = false;
  final safStream = SafStream();
  bool _loading = false;
  String? initialUri;
  List<String>? mimeTypes;
  bool _multipleFiles = true;

  // Per-file progress and pause state for parallel transfers
  List<ValueNotifier<double>> _progressList = [];
  List<ValueNotifier<bool>> _isPausedList = [];
  List<int> _bytesSentList = [];
  List<int> _fileSizeList = [];

  final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();


  String _ipToCode(String ip) {
    final parts = ip.split('.').map(int.parse).toList();
    if (parts.length != 4) return '';
    int n = (parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3];
    String code = n.toRadixString(36).toUpperCase();
    return code.padLeft(8, '0');
  }

 

  String _getFileExtension(String fileName) {
    final lastDotIndex = fileName.lastIndexOf('.');
    if (lastDotIndex == -1 || lastDotIndex == fileName.length - 1) {
      return ''; // No extension or ends with dot
    }
    return fileName.substring(lastDotIndex + 1);
  }

  String _getMimeTypeFromExtension(String ext) {
    switch (ext.toLowerCase()) {
      // Images
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'png':
        return 'image/png';
      case 'gif':
        return 'image/gif';
      case 'bmp':
        return 'image/bmp';
      case 'webp':
        return 'image/webp';
      case 'svg':
        return 'image/svg+xml';
      case 'ico':
        return 'image/x-icon';
      case 'tiff':
      case 'tif':
        return 'image/tiff';
      case 'heic':
        return 'image/heic';
      case 'heif':
        return 'image/heif';
      case 'avif':
        return 'image/avif';
      case 'jxl':
        return 'image/jxl';

      // Videos
      case 'mp4':
        return 'video/mp4';
      case 'avi':
        return 'video/x-msvideo';
      case 'mov':
        return 'video/quicktime';
      case 'wmv':
        return 'video/x-ms-wmv';
      case 'flv':
        return 'video/x-flv';
      case 'webm':
        return 'video/webm';
      case 'mkv':
        return 'video/x-matroska';
      case 'm4v':
        return 'video/x-m4v';
      case '3gp':
        return 'video/3gpp';
      case 'ogv':
        return 'video/ogg';
      case 'ts':
        return 'video/mp2t';
      case 'mts':
        return 'video/mp2t';
      case 'm2ts':
        return 'video/mp2t';
      case 'divx':
        return 'video/divx';
      case 'xvid':
        return 'video/xvid';

      // Audio
      case 'mp3':
        return 'audio/mpeg';
      case 'wav':
        return 'audio/wav';
      case 'flac':
        return 'audio/flac';
      case 'aac':
        return 'audio/aac';
      case 'ogg':
        return 'audio/ogg';
      case 'opus':
        return 'audio/opus';
      case 'wma':
        return 'audio/x-ms-wma';
      case 'm4a':
        return 'audio/mp4';
      case 'aiff':
        return 'audio/aiff';
      case 'au':
        return 'audio/basic';
      case 'mid':
      case 'midi':
        return 'audio/midi';
      case 'amr':
        return 'audio/amr';
      case '3ga':
        return 'audio/3gpp';

      // Documents
      case 'pdf':
        return 'application/pdf';
      case 'doc':
        return 'application/msword';
      case 'docx':
        return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
      case 'xls':
        return 'application/vnd.ms-excel';
      case 'xlsx':
        return 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
      case 'ppt':
        return 'application/vnd.ms-powerpoint';
      case 'pptx':
        return 'application/vnd.openxmlformats-officedocument.presentationml.presentation';
      case 'odt':
        return 'application/vnd.oasis.opendocument.text';
      case 'ods':
        return 'application/vnd.oasis.opendocument.spreadsheet';
      case 'odp':
        return 'application/vnd.oasis.opendocument.presentation';
      case 'rtf':
        return 'application/rtf';
      case 'txt':
        return 'text/plain';
      case 'csv':
        return 'text/csv';
      case 'html':
      case 'htm':
        return 'text/html';
      case 'xml':
        return 'application/xml';
      case 'json':
        return 'application/json';
      case 'yaml':
      case 'yml':
        return 'application/x-yaml';

      // Archives
      case 'zip':
        return 'application/zip';
      case 'rar':
        return 'application/vnd.rar';
      case '7z':
        return 'application/x-7z-compressed';
      case 'tar':
        return 'application/x-tar';
      case 'gz':
        return 'application/gzip';
      case 'bz2':
        return 'application/x-bzip2';
      case 'xz':
        return 'application/x-xz';
      case 'lzma':
        return 'application/x-lzma';
      case 'cab':
        return 'application/vnd.ms-cab-compressed';
      case 'iso':
        return 'application/x-iso9660-image';

      // Executables and Packages
      case 'exe':
        return 'application/x-msdownload';
      case 'msi':
        return 'application/x-msi';
      case 'deb':
        return 'application/vnd.debian.binary-package';
      case 'rpm':
        return 'application/x-rpm';
      case 'apk':
        return 'application/vnd.android.package-archive';
      case 'ipa':
        return 'application/octet-stream';
      case 'dmg':
        return 'application/x-apple-diskimage';
      case 'pkg':
        return 'application/vnd.apple.installer+xml';
      case 'app':
        return 'application/x-executable';

      // Programming and Development
      case 'java':
        return 'text/x-java-source';
      case 'class':
        return 'application/java-vm';
      case 'jar':
        return 'application/java-archive';
      case 'py':
        return 'text/x-python';
      case 'pyc':
        return 'application/x-python-code';
      case 'js':
        return 'application/javascript';
      case 'ts':
        return 'application/typescript';
      case 'php':
        return 'application/x-httpd-php';
      case 'rb':
        return 'application/x-ruby';
      case 'cpp':
      case 'cc':
        return 'text/x-c++src';
      case 'c':
        return 'text/x-csrc';
      case 'h':
        return 'text/x-chdr';
      case 'cs':
        return 'text/x-csharp';
      case 'swift':
        return 'text/x-swift';
      case 'kt':
        return 'text/x-kotlin';
      case 'go':
        return 'text/x-go';
      case 'rs':
        return 'text/x-rust';
      case 'scala':
        return 'text/x-scala';
      case 'pl':
        return 'text/x-perl';
      case 'sh':
        return 'application/x-sh';
      case 'bat':
        return 'application/x-msdos-program';
      case 'ps1':
        return 'application/x-powershell';

      // Web and Markup
      case 'css':
        return 'text/css';
      case 'scss':
        return 'text/x-scss';
      case 'sass':
        return 'text/x-sass';
      case 'less':
        return 'text/x-less';
      case 'md':
      case 'markdown':
        return 'text/markdown';
      case 'tex':
        return 'application/x-tex';
      case 'latex':
        return 'application/x-latex';

      // Database
      case 'sql':
        return 'application/sql';
      case 'db':
        return 'application/x-sqlite3';
      case 'sqlite':
        return 'application/x-sqlite3';

      // Fonts
      case 'ttf':
        return 'font/ttf';
      case 'otf':
        return 'font/otf';
      case 'woff':
        return 'font/woff';
      case 'woff2':
        return 'font/woff2';
      case 'eot':
        return 'application/vnd.ms-fontobject';

      // CAD and 3D
      case 'dwg':
        return 'application/acad';
      case 'dxf':
        return 'application/dxf';
      case 'obj':
        return 'text/plain';
      case 'stl':
        return 'application/sla';
      case 'fbx':
        return 'application/octet-stream';
      case 'blend':
        return 'application/x-blender';

      // E-books
      case 'epub':
        return 'application/epub+zip';
      case 'mobi':
        return 'application/x-mobipocket-ebook';
      case 'azw':
        return 'application/vnd.amazon.ebook';
      case 'azw3':
        return 'application/vnd.amazon.ebook';

      // Virtual Machines
      case 'vmdk':
        return 'application/x-vmdk';
      case 'vdi':
        return 'application/x-vdi';
      case 'vhd':
        return 'application/x-vhd';
      case 'ova':
        return 'application/x-ovf';
      case 'ovf':
        return 'application/x-ovf';

      // Configuration and Settings
      case 'ini':
        return 'text/plain';
      case 'conf':
        return 'text/plain';
      case 'cfg':
        return 'text/plain';
      case 'config':
        return 'text/plain';
      case 'env':
        return 'text/plain';
      case 'properties':
        return 'text/plain';

      // Logs
      case 'log':
        return 'text/plain';

      // Certificates and Keys
      case 'pem':
        return 'application/x-pem-file';
      case 'crt':
        return 'application/x-x509-ca-cert';
      case 'key':
        return 'application/x-pkcs8';
      case 'p12':
        return 'application/x-pkcs12';
      case 'pfx':
        return 'application/x-pkcs12';

      // Other Common Types
      case 'torrent':
        return 'application/x-bittorrent';
      case 'ics':
        return 'text/calendar';
      case 'vcf':
        return 'text/vcard';
      case 'ics':
        return 'text/calendar';
      case 'eml':
        return 'message/rfc822';
      case 'msg':
        return 'application/vnd.ms-outlook';

      default:
        return 'application/octet-stream'; // fallback for unknown types
    }
  }

  String formatBytes(int bytes) {
    if (bytes < 1024) return "$bytes B";
    if (bytes < 1024 * 1024) return "${(bytes / 1024).toStringAsFixed(1)} KB";
    if (bytes < 1024 * 1024 * 1024) return "${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB";
    return "${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB";
  }

  static const MethodChannel _platform = MethodChannel('zapshare.saf');

  @override
  void initState() {
    super.initState();
    _init();
    _initLocalNotifications();
    _listenForSharedFiles();
  }

  void _listenForSharedFiles() {
    _platform.setMethodCallHandler((call) async {
      if (call.method == 'sharedFiles') {
        final List<dynamic> files = call.arguments as List<dynamic>;
        if (files.isNotEmpty) {
          await _handleSharedFiles(files.cast<Map>());
        }
      }
      return null;
    });
  }

  Future<void> _handleSharedFiles(List<Map> files) async {
    setState(() => _loading = true);
    List<String> uris = [];
    List<String> names = [];
    List<int> sizes = [];
    for (final file in files) {
      final uri = file['uri'] as String;
      final name = file['name'] as String? ?? uri.split('/').last;
      int size = 0;
      try {
        size = await getFileSizeFromUri(uri);
      } catch (_) {}
      uris.add(uri);
      names.add(name);
      sizes.add(size);
    }
    setState(() {
      _fileUris = uris;
      _fileNames = names;
      _progressList = List.generate(uris.length, (_) => ValueNotifier(0.0));
      _isPausedList = List.generate(uris.length, (_) => ValueNotifier(false));
      _bytesSentList = List.generate(uris.length, (_) => 0);
      _fileSizeList = sizes;
      _loading = false;
    });
  }

  Future<void> _init() async {
    await _clearCache();
    await _fetchLocalIp();
    _showConnectionTip();
  }

  Future<void> _initLocalNotifications() async {
    const AndroidInitializationSettings initializationSettingsAndroid =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    final InitializationSettings initializationSettings = InitializationSettings(
      android: initializationSettingsAndroid,
    );
    await flutterLocalNotificationsPlugin.initialize(
      initializationSettings,
      onDidReceiveNotificationResponse: (NotificationResponse response) {
        final actionId = response.actionId;
        if (actionId == null) return;
        if (actionId.startsWith('pause_')) {
          final idx = int.tryParse(actionId.substring(6));
          if (idx != null && idx < _isPausedList.length) {
            _isPausedList[idx].value = true;
          }
        } else if (actionId.startsWith('resume_')) {
          final idx = int.tryParse(actionId.substring(7));
          if (idx != null && idx < _isPausedList.length) {
            _isPausedList[idx].value = false;
          }
        }
      },
    );
  }

  Future<void> showProgressNotification(int fileIndex, double progress, String fileName, {double speedMbps = 0.0, bool paused = false}) async {
    final percent = (progress * 100).toStringAsFixed(1);
    final body = '$fileName\nProgress: $percent%\nSpeed: ${speedMbps.toStringAsFixed(2)} Mbps';
    final androidPlatformChannelSpecifics = AndroidNotificationDetails(
      'progress_channel_$fileIndex',
      'File Transfer Progress $fileIndex',
      channelDescription: 'Shows the progress of file transfer $fileIndex',
      importance: Importance.max,
      priority: Priority.high,
      showProgress: true,
      maxProgress: 100,
      progress: (progress * 100).toInt(),
      onlyAlertOnce: true,
      styleInformation: BigTextStyleInformation(body),
    );
    final platformChannelSpecifics = NotificationDetails(android: androidPlatformChannelSpecifics);
    await flutterLocalNotificationsPlugin.show(
      1000 + fileIndex,
      'ZapShare Transfer',
      body,
      platformChannelSpecifics,
      payload: 'progress',
    );
  }

  Future<void> cancelProgressNotification(int fileIndex) async {
    await flutterLocalNotificationsPlugin.cancel(1000 + fileIndex);
  }

  final MethodChannel _channel = const MethodChannel('zapshare.saf');

  Future<void> serveSafFile(HttpRequest request, {
    required int fileIndex,
    required String uri,
    required String fileName,
    required int fileSize,
    int chunkSize = 64 * 1024,
  }) async {
    final response = request.response;
    int bytesSent = 0;
    _progressList[fileIndex].value = 0.0;
    _fileSizeList[fileIndex] = fileSize;
    _bytesSentList[fileIndex] = 0;

    DateTime lastUpdate = DateTime.now();
    double lastProgress = 0.0;
    int lastBytes = 0;
    DateTime lastSpeedTime = DateTime.now();
    double speedMbps = 0.0;

    try {
      // Set headers
      response.statusCode = HttpStatus.ok;
      response.headers.set('Content-Length', fileSize.toString());
      response.headers.set('Content-Type', 'application/octet-stream');
      response.headers.set('Content-Disposition', 'attachment; filename="$fileName"');

      // Open stream
      final opened = await MethodChannel('zapshare.saf')
          .invokeMethod<bool>('openReadStream', {'uri': uri});
      if (opened != true) {
        response.statusCode = HttpStatus.internalServerError;
        response.write('Could not open SAF stream.');
        await response.close();
        return;
      }

      // Stream file in chunks
      bool done = false;
      while (!done) {
        // Pause logic
        while (_isPausedList[fileIndex].value) {
          await Future.delayed(Duration(milliseconds: 200));
        }
        try {
          final chunk = await MethodChannel('zapshare.saf')
              .invokeMethod<Uint8List>('readChunk', {'uri': uri, 'size': chunkSize});

          if (chunk == null || chunk.isEmpty) {
            done = true;
          } else {
            response.add(chunk);
            bytesSent += chunk.length;
            _bytesSentList[fileIndex] = bytesSent;
            double progress = bytesSent / fileSize;

            // Speed calculation
            final now = DateTime.now();
            final elapsed = now.difference(lastSpeedTime).inMilliseconds;
            if (elapsed > 0) {
              final bytesDelta = bytesSent - lastBytes;
              speedMbps = (bytesDelta * 8) / (elapsed * 1000); // Mbps
              lastBytes = bytesSent;
              lastSpeedTime = now;
            }

            // Throttle updates: only update if 100ms passed or progress increased by 1%
            if (now.difference(lastUpdate).inMilliseconds > 100 ||
                (progress - lastProgress) > 0.01) {
              _progressList[fileIndex].value = progress;
              await showProgressNotification(
                fileIndex,
                progress,
                fileName,
                speedMbps: speedMbps,
                paused: _isPausedList[fileIndex].value,
              );
              lastUpdate = now;
              lastProgress = progress;
            }
            await response.flush(); // ensures lower memory use
          }
        } catch (e) {
          print('Stream error: $e');
          response.statusCode = HttpStatus.internalServerError;
          break;
        }
      }
    } catch (e) {
      print('Serve file error: $e');
      response.statusCode = HttpStatus.internalServerError;
    } finally {
      await MethodChannel('zapshare.saf')
          .invokeMethod('closeStream', {'uri': uri});
      await response.close();
      // Reset progress
      _progressList[fileIndex].value = 0.0;
      _bytesSentList[fileIndex] = 0;
      _fileSizeList[fileIndex] = 0;
      await cancelProgressNotification(fileIndex);
      // Record transfer history
      try {
        final prefs = await SharedPreferences.getInstance();
        final history = prefs.getStringList('transfer_history') ?? [];
        final entry = {
          'fileName': fileName,
          'fileSize': fileSize,
          'direction': 'Sent',
          'peer': _localIp ?? '',
          'dateTime': DateTime.now().toIso8601String(),
        };
        history.insert(0, jsonEncode(entry));
        if (history.length > 100) history.removeLast();
        await prefs.setStringList('transfer_history', history);
      } catch (_) {}
    }
  }

  Future<void> _clearCache() async {
    final dir = await getTemporaryDirectory();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  }

  Future<void> _fetchLocalIp() async {
    final info = NetworkInfo();
    final ip = await info.getWifiIP();
    setState(() => _localIp = ip);
  }

  Future<void> _showConnectionTip() async {
    final prefs = await SharedPreferences.getInstance();
    final showTip = prefs.getBool('showConnectionTip') ?? true;
    if (!showTip) return;

    bool dontShowAgain = false;
    await Future.delayed(Duration(milliseconds: 500));
    showDialog(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          backgroundColor: Colors.yellow.shade50,
          title: Text("Connection Tip", style: TextStyle(color: Colors.black)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text("Ensure devices are on the same network or hotspot.",
                  style: TextStyle(color: Colors.black)),
              Row(
                children: [
                  Checkbox(
                    value: dontShowAgain,
                    activeColor: Colors.white,
                    checkColor: Colors.black,
                    onChanged: (val) =>
                        setState(() => dontShowAgain = val ?? false),
                  ),
                  Text("Don't show again", style: TextStyle(color: Colors.black)),
                ],
              )
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                if (dontShowAgain) prefs.setBool('showConnectionTip', false);
                Navigator.of(context).pop();
              },
              child: Text("Got it!", style: TextStyle(color: Colors.black)),
            )
          ],
        ),
      ),
    );
  }

  Future<int> getFileSizeFromUri(String uri) async {
    final size = await const MethodChannel('zapshare.saf')
        .invokeMethod<int>('getFileSize', {'uri': uri});
    if (size == null) throw Exception('Could not get file size for $uri');
    return size;
  }

  Future<void> _selectFiles() async {
    setState(() => _loading = true);

    final result = await _safUtil.pickFiles(
      multiple: _multipleFiles,
      mimeTypes: mimeTypes,
      initialUri: initialUri,
    );

    if (result != null) {
      List<String> uris = [];
      List<String> names = [];
      List<int> sizes = [];
      for (final docFile in result) {
        uris.add(docFile.uri);
        names.add(docFile.name);
        try {
          final size = await getFileSizeFromUri(docFile.uri);
          sizes.add(size);
        } catch (_) {
          sizes.add(0);
        }
      }
      setState(() {
        _fileUris = uris;
        _fileNames = names;
        _progressList = List.generate(uris.length, (_) => ValueNotifier(0.0));
        _isPausedList = List.generate(uris.length, (_) => ValueNotifier(false));
        _bytesSentList = List.generate(uris.length, (_) => 0);
        _fileSizeList = sizes;
        _loading = false;
      });
    } else {
      setState(() => _loading = false);
    }
  }

  String? _displayCode;

  Future<void> _startServer() async {
    if (_fileUris.isEmpty) return;
    await FlutterForegroundTask.startService(
      notificationTitle: "ZapShare Transfer",
      notificationText: "Sharing file(s)...",
    );
    await _server?.close(force: true);
    _server = await HttpServer.bind(InternetAddress.anyIPv4, 8080);
    // Generate 8-char code for sharing (just IP)
    final codeForUser = _ipToCode(_localIp ?? '');
    setState(() {
      _displayCode = codeForUser;
    });
    _server!.listen((HttpRequest request) async {
      final path = request.uri.path;
      if (path == '/list') {
        // Serve file list as JSON
        final list = List.generate(_fileNames.length, (i) => {
          'index': i,
          'name': _fileNames[i],
          'size': _fileSizeList.length > i ? _fileSizeList[i] : 0,
        });
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(list));
        await request.response.close();
        return;
      }
      final segments = request.uri.pathSegments;
      if (segments.length == 2 && segments[0] == 'file') {
        final index = int.tryParse(segments[1]);
        if (index == null || index >= _fileUris.length) {
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
          return;
        }
        final uri = _fileUris[index];
        final name = _fileNames[index];
        final fileSize = _fileSizeList.length > index ? _fileSizeList[index] : 0;
        final ext = _getFileExtension(name).toLowerCase();
        final mimeType = _getMimeTypeFromExtension(ext);
        try {
          request.response.headers.contentType = ContentType.parse(mimeType);
          request.response.headers.set(
            'Content-Disposition',
            'attachment; filename="$name"',
          );
          await serveSafFile(
            request,
            fileIndex: index,
            uri: uri,
            fileName: name,
            fileSize: fileSize,
          );
        } catch (e) {
          print('Error streaming file: $e');
          request.response.statusCode = HttpStatus.internalServerError;
          await request.response.close();
        }
        return;
      }
      // 404 for other paths
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
    });
    setState(() => _isSharing = true);
  }

  Future<void> _stopServer() async {
    setState(() => _loading = true);
    await _server?.close(force: true);
    await FlutterForegroundTask.stopService();
    setState(() {
      _isSharing = false;
      _loading = false;
    });
  }


  Future<String?> pickFolderSAF() async {
    final uri = await _channel.invokeMethod<String>('pickFolder');
    return uri;
  }

  Future<List<Map<String, String>>> listFilesInFolderSAF(String folderUri) async {
    final jsonString = await _channel.invokeMethod<String>('listFilesInFolder', {'folderUri': folderUri});
    if (jsonString == null) return [];
    final List<dynamic> decoded = jsonDecode(jsonString);
    return decoded.cast<Map<String, dynamic>>().map((e) => {
      'uri': e['uri'] as String,
      'name': e['name'] as String,
    }).toList();
  }

  Future<String?> zipFilesToCache(List<String> uris, List<String> names, String zipName) async {
    const channel = MethodChannel('zapshare.saf');
    return await channel.invokeMethod<String>('zipFilesToCache', {
      'uris': uris,
      'names': names,
      'zipName': zipName,
    });
  }

  Future<void> _pickFolder() async {
    final folderUri = await pickFolderSAF();
    if (folderUri != null) {
      final files = await listFilesInFolderSAF(folderUri);
      if (files.isNotEmpty) {
        List<String> uris = [];
        List<String> names = [];
        List<int> sizes = [];
        for (final f in files) {
          uris.add(f['uri']!);
          names.add(f['name']!);
          try {
            final size = await getFileSizeFromUri(f['uri']!);
            sizes.add(size);
          } catch (_) {
            sizes.add(0);
          }
        }
        setState(() {
          _fileUris = uris;
          _fileNames = names;
          _progressList = List.generate(uris.length, (_) => ValueNotifier(0.0));
          _isPausedList = List.generate(uris.length, (_) => ValueNotifier(false));
          _bytesSentList = List.generate(uris.length, (_) => 0);
          _fileSizeList = sizes;
        });
      }
    }
  }

  @override
  void dispose() {
    _server?.close(force: true);
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text("ZapShare"),
        backgroundColor: Colors.black,
      ),
      body: Center(
        child: _loading
            ? CircularProgressIndicator(color: kAndroidAccentYellow)
            : _fileUris.isEmpty
                ? Text("No file selected", style: TextStyle(color: Colors.white))
                : Column(
                    mainAxisAlignment: MainAxisAlignment.start,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      if (_displayCode != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 32, bottom: 12),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              SelectableText(
                                _displayCode!,
                                style: TextStyle(fontSize: 32, color: kAndroidAccentYellow, fontWeight: FontWeight.bold, letterSpacing: 2, shadows: [Shadow(color: Colors.black26, blurRadius: 6)]),
                              ),
                              IconButton(
                                icon: Icon(Icons.copy, color: Colors.white),
                                tooltip: "Copy Code",
                                onPressed: () {
                                  Clipboard.setData(ClipboardData(text: _displayCode!));
                                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Code copied!",selectionColor: Colors.black,),backgroundColor: Colors.yellowAccent,));
                                },
                              ),
                            ],
                          ),
                        ),
                      if (_displayCode != null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 16),
                          child: Text(
                            "Share this code with the receiver.",
                            style: TextStyle(fontSize: 15, color: Colors.black87),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      Expanded(
                        child: ListView.builder(
                          itemCount: _fileNames.length,
                          itemBuilder: (context, index) {
                            return Card(
                              margin: const EdgeInsets.symmetric(vertical: 8, horizontal: 24),
                              child: ListTile(
                                title: Text(_fileNames[index], style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                                subtitle: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(formatBytes(_fileSizeList.length > index ? _fileSizeList[index] : 0), style: const TextStyle(fontSize: 12)),
                                    if (_isSharing)
                                      Padding(
                                        padding: const EdgeInsets.only(top: 6),
                                        child: ValueListenableBuilder<double>(
                                          valueListenable: _progressList[index],
                                          builder: (context, value, _) => LinearProgressIndicator(
                                            value: value,
                                            backgroundColor: Colors.white,
                                            color: Colors.yellow,
                                          ),
                                        ),
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
      floatingActionButton: Padding(
        padding: const EdgeInsets.only(bottom: 28, right: 12),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            FloatingActionButton(
              onPressed: _selectFiles,
              backgroundColor: kAndroidAccentYellow,
              tooltip: "Pick Files",
              child: Icon(Icons.attach_file_rounded, color: Colors.black, size: 28, shadows: [Shadow(color: kAndroidAccentYellow.withOpacity(0.4), blurRadius: 8)]),
              elevation: 6,
            ),
            SizedBox(height: 12),
            FloatingActionButton(
              onPressed: _pickFolder,
              backgroundColor: kAndroidAccentYellow,
              tooltip: "Pick Folder",
              child: Icon(Icons.folder, color: Colors.black, size: 28, shadows: [Shadow(color: kAndroidAccentYellow.withOpacity(0.4), blurRadius: 8)]),
              elevation: 6,
            ),
            SizedBox(height: 12),
            FloatingActionButton(
              onPressed: (_fileUris.isEmpty || _loading)
                  ? null
                  : _isSharing
                      ? _stopServer
                      : _startServer,
              backgroundColor: _fileUris.isEmpty
                  ? Colors.grey
                  : _isSharing
                      ? Colors.red
                      : kAndroidAccentYellow,
              tooltip: _isSharing ? "Stop Sharing" : "Send Files",
              child: Icon(_isSharing ? Icons.stop_circle_rounded : Icons.send_rounded, color: Colors.black, size: 28, shadows: [Shadow(color: kAndroidAccentYellow.withOpacity(0.4), blurRadius: 8)]),
              elevation: 6,
            ),
          ],
        ),
      ),
    );
  }
}