import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:http/http.dart' as http;
import 'dart:io';
import 'dart:convert';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../services/device_discovery_service.dart';

// Modern Color Constants
// Modern Color Constants
const Color kZapPrimary = Color(0xFFFFD84D); 
const Color kZapPrimaryDark = Color(0xFFF5C400);
const Color kZapSurface = Color(0xFF1C1C1E); 
const Color kZapBackgroundTop = Color(0xFF0E1116);
const Color kZapBackgroundBottom = Color(0xFF07090D);

class IOSReceiveScreen extends StatefulWidget {
  final List<String>? filterFiles;
  final String? destinationPath;
  final String? connectionIp; // Direct IP override

  const IOSReceiveScreen({
     super.key, 
     this.filterFiles,
     this.destinationPath,
     this.connectionIp,
  });

  @override
  State<IOSReceiveScreen> createState() => _IOSReceiveScreenState();
}

class _IOSReceiveScreenState extends State<IOSReceiveScreen> {
  final TextEditingController _codeController = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  
  bool _isScanning = false;
  final MobileScannerController _scannerController = MobileScannerController();

  void _onScan(BarcodeCapture capture) {
    if (!_isScanning) return;
    
    final List<Barcode> barcodes = capture.barcodes;
    for (final barcode in barcodes) {
      if (barcode.rawValue != null) {
        final code = barcode.rawValue!;
        // Simple validation for 8 chars alphanumeric
        if (code.length == 8 && RegExp(r'^[A-Z0-9]+$').hasMatch(code)) {
             HapticFeedback.mediumImpact();
             setState(() { 
                _isScanning = false;
                _codeController.text = code;
             });
             _startDownload(code: code);
             break; 
        }
      }
    }
  }
  
  List<Map<String, dynamic>> _downloadHistory = [];
  bool _downloading = false;
  bool _isSelecting = false; // New state for selection mode
  String _statusMessage = "";
  double _overallProgress = 0.0;
  String _currentFileName = "";
  String _speedText = "";
  int _receivedFiles = 0;
  int _totalFiles = 0;
  
  // Selection Mode Data
  List<Map<String, dynamic>> _availableFiles = [];
  Set<int> _selectedIndices = {};
  String? _connectedServerIp;
  String? _connectedDeviceName;
  
  @override
  void initState() {
     super.initState();
     _loadHistory();
     // Ensure device name is loaded
     DeviceDiscoveryService().initialize();
     
     if (widget.connectionIp != null) {
        // Direct Connection mode
        WidgetsBinding.instance.addPostFrameCallback((_) {
           _startDownload(ipOverride: widget.connectionIp);
        });
     } else {
        Future.delayed(const Duration(milliseconds: 500), () {
           if (mounted) _focusNode.requestFocus();
        });
     }

  }

  @override
  void dispose() {
    _codeController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  String _ipToCode(String ip) {
    if (ip.isEmpty) return '';
    try {
      final parts = ip.split('.').map(int.parse).toList();
      if (parts.length != 4) return '';
      int n = (parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3];
      String code = n.toRadixString(36).toUpperCase();
      return code.padLeft(8, '0');
    } catch (e) {
      return '';
    }
  }

  Future<void> _loadHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final history = prefs.getStringList('transfer_history') ?? [];
    setState(() {
      _downloadHistory = history.map((e) => jsonDecode(e) as Map<String, dynamic>).toList();
    });
  }

  Future<void> _startDownload({String? code, String? ipOverride}) async {
     HapticFeedback.mediumImpact();
     _focusNode.unfocus(); 
     
     setState(() {
       _downloading = true; // Show loading state temporarily
       _statusMessage = "Connecting...";
       _overallProgress = 0.0;
     });
     
     String? serverIp;
     
     if (ipOverride != null) {
        serverIp = ipOverride;
        // Visual feedback: Show the code corresponding to this IP
        _codeController.text = _ipToCode(serverIp); 
        print("🚀 [IOSReceiveScreen] Using direct connection IP: $serverIp (Code: ${_codeController.text})");
     } else {
       try {
          final codeClean = code?.trim().toUpperCase() ?? '';
          if (codeClean.length < 4) throw Exception("Invalid code");
          
          final n = int.parse(codeClean, radix: 36);
          serverIp = '${(n >> 24) & 0xFF}.${(n >> 16) & 0xFF}.${(n >> 8) & 0xFF}.${n & 0xFF}';
          print("🚀 [IOSReceiveScreen] Decoded code '$codeClean' to IP: $serverIp");
       } catch(e) {
         print("❌ [IOSReceiveScreen] Code decoding failed: $e");
         HapticFeedback.heavyImpact();
         setState(() {
           _statusMessage = "Invalid Code";
           _downloading = false;
         });
         return;
       }
     }

     try {
       final listUrl = Uri.parse('http://$serverIp:8080/list');
       final response = await http.get(listUrl).timeout(const Duration(seconds: 10));
       if (response.statusCode != 200) throw Exception("Could not fetch file list");
       
       // Get Sender's Device Name
       String? senderDeviceName = response.headers['x-device-name'];
       if (senderDeviceName != null) {
          try {
             senderDeviceName = utf8.decode(base64Decode(senderDeviceName));
          } catch (e) {
             // Fallback
          }
       }
       print("Rx: Sender Device Name: $senderDeviceName");
       
       List<dynamic> rawFiles = jsonDecode(response.body);
       List<Map<String, dynamic>> allFiles = [];
       for(int i=0; i<rawFiles.length; i++) {
           var item = rawFiles[i];
           if (item is Map<String, dynamic>) {
              if (!item.containsKey('index')) {
                  item['index'] = i;
              }
              allFiles.add(item);
           }
       }

       // Auto-filter if widget.filterFiles is set (Legacy/Automation support)
       if (widget.filterFiles != null && widget.filterFiles!.isNotEmpty) {
           final filtered = allFiles.where((f) => widget.filterFiles!.contains(f['name'])).toList();
           _executeDownload(filtered, serverIp!, senderDeviceName);
           return;
       }

       // Go to Selection Mode
       setState(() {
          _availableFiles = allFiles;
          _selectedIndices = List.generate(allFiles.length, (i) => i).toSet(); // Select all by default
          _connectedServerIp = serverIp;
          _connectedDeviceName = senderDeviceName;
          _isSelecting = true;
          _downloading = false; // Loading done, now selecting
          _statusMessage = ""; 
       });

     } catch (e) {
        _handleError(e);
     }
  }

  Future<void> _executeDownload(List<Map<String, dynamic>> filesToDownload, String serverIp, String? senderDeviceName) async {
       setState(() {
          _isSelecting = false;
          _downloading = true;
          _totalFiles = filesToDownload.length;
          _statusMessage = "Found $_totalFiles files";
          _receivedFiles = 0;
       });

       Directory saveDir;
       if (widget.destinationPath != null) {
           saveDir = Directory(widget.destinationPath!);
       } else {
           final docDir = await getApplicationDocumentsDirectory();
           saveDir = Directory('${docDir.path}/ZapShare_Received');
       }
       
       if (!await saveDir.exists()) {
         await saveDir.create(recursive: true);
       }
       
       int totalBytesReceived = 0;
       int totalBytesExpected = filesToDownload.fold(0, (sum, f) => (sum + (f['size'] as int)).toInt()); // Cast to int explicitly
       final stopwatch = Stopwatch()..start();
       
       final myDeviceName = DeviceDiscoveryService().myDeviceName ?? 'Unknown Device';

      try {
       for (int i = 0; i < filesToDownload.length; i++) {
         final f = filesToDownload[i];
         final name = f['name'];
         
         setState(() {
           _currentFileName = name;
           _statusMessage = "Receiving ${i+1} of ${_totalFiles}";
         });

         final fileUrl = Uri.parse('http://$serverIp:8080/file/${f['index']}');
         
         final request = http.Request('GET', fileUrl);
         // Send my name to sender (Base64 encoded)
         request.headers['X-Device-Name'] = base64Encode(utf8.encode(myDeviceName));
         
         final fileReq = await http.Client().send(request);
         
         if (fileReq.statusCode != 200) {
            throw Exception("Failed to download $name (Status: ${fileReq.statusCode})");
         }

         String finalPath = '${saveDir.path}/$name';
         int count = 1;
         while(await File(finalPath).exists()) {
             final parts = name.split('.');
             if (parts.length > 1) {
                 final ext = parts.last;
                 final base = parts.sublist(0, parts.length-1).join('.');
                 finalPath = '${saveDir.path}/${base}_$count.$ext';
             } else {
                 finalPath = '${saveDir.path}/${name}_$count';
             }
             count++;
         }
         
         final saveFile = File(finalPath);
         final sink = saveFile.openWrite();
         
         await for (final chunk in fileReq.stream) {
             sink.add(chunk);
             totalBytesReceived += chunk.length;
             
             if (stopwatch.elapsedMilliseconds > 200) {
                final speed = (totalBytesReceived / 1024 / 1024) / (stopwatch.elapsedMilliseconds / 1000);
                setState(() {
                   _overallProgress = totalBytesExpected > 0 ? totalBytesReceived / totalBytesExpected : 0.0;
                   _speedText = "${speed.toStringAsFixed(1)} MB/s";
                });
             }
         }
         await sink.close();
         await _saveHistory(name, saveFile.path, f['size'] as int, serverIp, senderDeviceName);
         setState(() => _receivedFiles++);
       }
       
       stopwatch.stop();
       HapticFeedback.mediumImpact();
       setState(() {
         _statusMessage = "Completed!";
         _overallProgress = 1.0;
         _downloading = false;
         _currentFileName = "Saved to ${saveDir.path.split('/').last}";
         _codeController.clear();
       });
       
      } catch(e) {
          _handleError(e);
      }
  }

  void _handleError(dynamic e) {
         HapticFeedback.heavyImpact();
          var msg = e.toString().split('] ').last;
          if (msg.contains("Time") || msg.contains("timed out")) {
              msg = "Connection timed out. Check if devices are on same Wi-Fi.";
          } else if (msg.contains("Connection closed")) {
              msg = "Sender disconnected. Check if sender app is open.";
          }
          setState(() {
            _statusMessage = "Error: $msg"; 
            _downloading = false;
            _isSelecting = false;
          });
  }

  void _confirmSelection() {
     if (_selectedIndices.isEmpty) return;
     
     final filesToDownload = _availableFiles
        .where((f) => _selectedIndices.contains(f['index'] ?? _availableFiles.indexOf(f)))
        .toList();
        
     _executeDownload(filesToDownload, _connectedServerIp!, _connectedDeviceName);
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return "$bytes B";
    if (bytes < 1024 * 1024) return "${(bytes / 1024).toStringAsFixed(1)} KB";
    if (bytes < 1024 * 1024 * 1024) return "${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB";
    return "${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB";
  }

  void _showPreview(Map<String, dynamic> file) {
     HapticFeedback.selectionClick();
     showDialog(
       context: context,
       builder: (context) => AlertDialog(
          backgroundColor: kZapSurface,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          title: Text("File Preview", style: TextStyle(color: Colors.white)),
          content: Column(
             mainAxisSize: MainAxisSize.min,
             children: [
                Icon(Icons.insert_drive_file_rounded, size: 64, color: kZapPrimary),
                SizedBox(height: 16),
                Text(file['name'], style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16), textAlign: TextAlign.center),
                SizedBox(height: 8),
                Text("Size: ${_formatSize(file['size'])}", style: TextStyle(color: Colors.grey), textAlign: TextAlign.center),
                SizedBox(height: 8),
                Text("Long press on file name works!", style: TextStyle(color: kZapPrimary.withOpacity(0.5), fontSize: 12), textAlign: TextAlign.center),
             ],
          ),
          actions: [
             TextButton(
               onPressed: () => Navigator.pop(context),
               child: Text("Close", style: TextStyle(color: kZapPrimary)),
             )
          ],
       )
     );
  }

  Future<void> _saveHistory(String fileName, String path, int fileSize, String peerIp, String? peerDeviceName) async {
    final prefs = await SharedPreferences.getInstance();
    final history = prefs.getStringList('transfer_history') ?? [];
    
    final entry = {
      'fileName': fileName,
      'fileSize': fileSize,
      'direction': 'Received',
      'peer': peerIp,
      'peerDeviceName': peerDeviceName, 
      'dateTime': DateTime.now().toIso8601String(),
      'fileLocation': path,
    };
    
    history.insert(0, jsonEncode(entry));
    await prefs.setStringList('transfer_history', history);
    _loadHistory();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBody: true,
      resizeToAvoidBottomInset: true, // Allow keyboard to push up content
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [kZapBackgroundTop, kZapBackgroundBottom],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
            // Header with Back Button
             Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 24, 0),
              child: Row(
                children: [
                  Container(
                    decoration: BoxDecoration(
                      color: kZapSurface,
                      shape: BoxShape.circle,
                    ),
                    child: IconButton(
                      icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Text(
                    _isSelecting ? "Select Files" : (_downloading ? "Receiving..." : 'Enter Code'),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),

            if (_isSelecting)
               Expanded(
                 child: _buildSelectionScreen(),
               )
            else if (_isScanning)
               Expanded(
                 child: Stack(
                   children: [
                      MobileScanner(
                        controller: _scannerController,
                        onDetect: _onScan,
                      ),
                      // Overlay
                      Center(
                        child: Container(
                          width: 250,
                          height: 250,
                          decoration: BoxDecoration(
                            border: Border.all(color: kZapPrimary, width: 2),
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                      ),
                      Positioned(
                        bottom: 40,
                        left: 0,
                        right: 0,
                        child: Center(
                           child: IconButton(
                              icon: const Icon(Icons.close, color: Colors.white, size: 40),
                              onPressed: () => setState(() => _isScanning = false),
                           ),
                        ),
                      ),
                   ],
                 ),
               )
            else if (_statusMessage.startsWith("Error"))
               Expanded(child: Center(child: Padding(padding: EdgeInsets.all(24),
                  child: Text(_statusMessage, style: TextStyle(color: Colors.red), textAlign: TextAlign.center))))
            else
               Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                     const Spacer(),
                     
                     if (!_downloading && !_isSelecting && !_statusMessage.startsWith("Completed"))
                       GestureDetector(
                         onTap: () {
                            _focusNode.requestFocus();
                            HapticFeedback.lightImpact();
                         },
                         child: _buildCodeDisplay()
                       ),

                     // Scan Button
                     if (!_downloading && !_statusMessage.startsWith("Completed"))
                        Padding(
                          padding: const EdgeInsets.only(top: 24),
                          child: TextButton.icon(
                             onPressed: () {
                                setState(() => _isScanning = true);
                             },
                             icon: const Icon(Icons.qr_code_scanner, color: kZapPrimary),
                             label: const Text("Scan QR Code", style: TextStyle(color: kZapPrimary)),
                          ),
                        ),
                     
                     // "Verify & Receive" Button 
                     if (!_downloading && !_statusMessage.startsWith("Completed"))
                        Padding(
                          padding: const EdgeInsets.only(top: 32),
                          child: SizedBox(
                            width: double.infinity,
                            child: ElevatedButton(
                              onPressed: _codeController.text.length >= 4 
                                 ? () => _startDownload(code: _codeController.text) 
                                 : null,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: kZapPrimary,
                                foregroundColor: Colors.black,
                                padding: const EdgeInsets.symmetric(vertical: 16),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                                disabledBackgroundColor: kZapSurface,
                                disabledForegroundColor: Colors.grey,
                              ),
                              child: const Text("Verify & Receive", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                            ),
                          ),
                        ),
                     
                     // Hidden TextField 
                     Opacity(
                       opacity: 0, 
                       child: SizedBox(
                         height: 0, width: 0,
                         child: TextField(
                           controller: _codeController,
                           focusNode: _focusNode,
                           keyboardType: TextInputType.text, // Alphanumeric
                           textCapitalization: TextCapitalization.characters,
                           autocorrect: false,
                           enableSuggestions: false,
                           onChanged: (val) {
                               setState(() {
                                 _codeController.text = val.toUpperCase();
                                 _codeController.selection = TextSelection.fromPosition(TextPosition(offset: _codeController.text.length));
                               });
                           },
                           onSubmitted: (val) {
                               if (val.length >= 4) _startDownload(code: val);
                           },
                         ),
                       ),
                     ),
                     
                     const Spacer(),
                     
                     // Status/Progress
                     if (_downloading || _statusMessage.isNotEmpty)
                        _buildProgressSection()
                     else
                        const SizedBox(height: 100), // Placeholder for keyboard space

                     const SizedBox(height: 16),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
      ),
    );
  }

  Widget _buildCodeDisplay() {
     return Column(
       children: [
         Text(
           "ENTER 8-CHARACTER CODE",
           style: TextStyle(
             color: kZapPrimary,
             fontSize: 12,
             fontWeight: FontWeight.bold,
             letterSpacing: 2,
           ),
         ),
         const SizedBox(height: 24),
         Row(
           mainAxisAlignment: MainAxisAlignment.center,
           children: List.generate(8, (index) {
              final text = _codeController.text;
              final digit = index < text.length ? text[index] : "";
              final isFocused = index == text.length;
              return Container(
                width: 32,
                height: 48,
                margin: const EdgeInsets.symmetric(horizontal: 4),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: kZapSurface,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: digit.isNotEmpty ? kZapPrimary : (isFocused ? Colors.white.withOpacity(0.5) : Colors.transparent),
                    width: digit.isNotEmpty ? 1.5 : 1,
                  ),
                  boxShadow: [
                    if (digit.isNotEmpty)
                      BoxShadow(color: kZapPrimary.withOpacity(0.2), blurRadius: 8, spreadRadius: 0)
                  ]
                ),
                child: Text(
                  digit,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    fontFamily: 'monospace'
                  ),
                ),
              );
           }),
         ),
       ],
     );
  }

  Widget _buildProgressSection() {
     return Container(
        padding: const EdgeInsets.all(24),
        width: double.infinity,
        decoration: BoxDecoration(
           color: kZapSurface,
           borderRadius: BorderRadius.circular(24),
           border: Border.all(color: Colors.white.withOpacity(0.05)),
        ),
        child: Column(
           children: [
              Container(
                 width: 60, height: 60,
                 decoration: BoxDecoration(
                    color: kZapPrimary.withOpacity(0.1),
                    shape: BoxShape.circle,
                 ),
                 child: const Icon(Icons.download_rounded, color: kZapPrimary, size: 30),
              ),
              const SizedBox(height: 20),
              Text(_statusMessage, style: TextStyle(color: _statusMessage.startsWith("Error") ? Colors.red : Colors.white, fontSize: 16, fontWeight: FontWeight.bold), textAlign: TextAlign.center),
              const SizedBox(height: 6),
              if (_currentFileName.isNotEmpty && !_statusMessage.startsWith("Error"))
                 Text(_currentFileName, style: TextStyle(color: kZapPrimary, fontSize: 12), textAlign: TextAlign.center, maxLines: 1, overflow: TextOverflow.ellipsis),
              
              const SizedBox(height: 24),
              
              LinearProgressIndicator(
                 value: _overallProgress,
                 backgroundColor: Colors.black,
                 color: kZapPrimary,
                 minHeight: 8,
                 borderRadius: BorderRadius.circular(4),
              ),
              const SizedBox(height: 12),
              
              Row(
                 mainAxisAlignment: MainAxisAlignment.spaceBetween,
                 children: [
                    Text("${(_overallProgress * 100).toInt()}%", style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                    Text(_speedText, style: TextStyle(color: Colors.grey[500], fontSize: 12)),
                 ],
              ),

              const SizedBox(height: 20),
                if (!_downloading || _overallProgress >= 1.0 || _statusMessage.startsWith("Error"))
                 Row(
                   mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                   children: [
                     TextButton(
                       onPressed: () {
                          setState(() {
                             _downloading = false;
                             _codeController.clear();
                             _overallProgress = 0.0;
                             _statusMessage = ""; // Hide the card
                          });
                          _focusNode.requestFocus();
                       },
                       style: TextButton.styleFrom(
                         padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                       ),
                       child: const Text("Enter New Code", style: TextStyle(color: Colors.white70)),
                     ),
                     ElevatedButton(
                       onPressed: () => Navigator.pop(context),
                       style: ElevatedButton.styleFrom(
                         backgroundColor: kZapPrimary,
                         foregroundColor: Colors.black,
                         elevation: 0,
                         padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 12),
                         shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                       ),
                       child: const Text("Done", style: TextStyle(fontWeight: FontWeight.bold)),
                     ),
                   ],
                 ),
           ],
        ),
     );
  }
  Widget _buildSelectionScreen() {
      return Column(
         children: [
             Padding(
                padding: EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                child: Text(
                   "Showing ${_availableFiles.length} files from ${_connectedDeviceName ?? 'Connected Device'}",
                   style: TextStyle(color: Colors.grey[400]),
                ),
             ),
             Expanded(
                child: ListView.builder(
                   itemCount: _availableFiles.length,
                   padding: EdgeInsets.symmetric(horizontal: 16),
                   itemBuilder: (context, index) {
                      final file = _availableFiles[index];
                      final isSelected = _selectedIndices.contains(file['index'] ?? index);
                      
                      return Container(
                         margin: EdgeInsets.only(bottom: 12),
                         decoration: BoxDecoration(
                            color: kZapSurface,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: isSelected ? kZapPrimary : Colors.transparent, width: 1.5),
                         ),
                         child: InkWell(
                            borderRadius: BorderRadius.circular(16),
                            onTap: () {
                               HapticFeedback.lightImpact();
                               setState(() {
                                  int idx = file['index'] ?? index;
                                  if (isSelected) _selectedIndices.remove(idx);
                                  else _selectedIndices.add(idx);
                               });
                            },
                            onLongPress: () {
                               _showPreview(file);
                            },
                            child: Padding(
                               padding: EdgeInsets.all(16),
                               child: Row(
                                  children: [
                                     Icon(Icons.description, color: isSelected ? kZapPrimary : Colors.grey, size: 32),
                                     SizedBox(width: 16),
                                     Expanded(
                                        child: Column(
                                           crossAxisAlignment: CrossAxisAlignment.start,
                                           children: [
                                              Text(file['name'], style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold), maxLines: 1, overflow: TextOverflow.ellipsis),
                                              Text(_formatSize(file['size']), style: TextStyle(color: Colors.grey[500], fontSize: 12)),
                                           ],
                                        ),
                                     ),
                                     if (isSelected)
                                        Icon(Icons.check_circle, color: kZapPrimary),
                                     if (!isSelected)
                                        Icon(Icons.circle_outlined, color: Colors.grey),
                                  ],
                               ),
                            ),
                         ),
                      );
                   },
                ),
             ),
             Container(
                padding: EdgeInsets.all(24),
                decoration: BoxDecoration(
                   color: kZapSurface,
                   borderRadius: BorderRadius.vertical(top: Radius.circular(32)),
                ),
                child: Column(
                   children: [
                      Row(
                         mainAxisAlignment: MainAxisAlignment.spaceBetween,
                         children: [
                            TextButton(
                               onPressed: () {
                                  setState(() {
                                      _isSelecting = false;
                                      _codeController.clear();
                                      _statusMessage = "";
                                  });
                               },
                               child: Text("Cancel", style: TextStyle(color: Colors.white70)),
                            ),
                            Text("${_selectedIndices.length} selected", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                         ],
                      ),
                      SizedBox(height: 16),
                      SizedBox(
                         width: double.infinity,
                         child: ElevatedButton(
                            onPressed: _selectedIndices.isNotEmpty ? _confirmSelection : null,
                            style: ElevatedButton.styleFrom(
                               backgroundColor: kZapPrimary,
                               foregroundColor: Colors.black,
                               padding: EdgeInsets.symmetric(vertical: 16),
                               shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                            ),
                            child: Text("Accept & Download", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                         ),
                      ),
                   ],
                ),
             ),
         ],
      );
  }
}
