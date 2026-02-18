
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;
import 'dart:io';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';

class MacOSReceiveScreen extends StatefulWidget {
  final String? autoStartCode;
  const MacOSReceiveScreen({super.key, this.autoStartCode});
  @override
  State<MacOSReceiveScreen> createState() => _MacOSReceiveScreenState();
}

class _MacOSReceiveScreenState extends State<MacOSReceiveScreen> {
  final TextEditingController _codeController = TextEditingController();
  String? _saveFolder;
  bool _downloading = false;
  String _status = "";
  double _overallProgress = 0.0;
  String _currentFileName = "";
  String _speedText = "";
  int _receivedFiles = 0;
  int _totalFiles = 0;

  @override
  void initState() {
    super.initState();
    _getDefaultSaveDir().then((_) {
      if (widget.autoStartCode != null) {
        _codeController.text = widget.autoStartCode!;
        _startDownload(widget.autoStartCode!);
      }
    });
  }
  
  Future<void> _getDefaultSaveDir() async {
     try {
        final dl = await getDownloadsDirectory();
        setState(() => _saveFolder = dl?.path);
     } catch(_) {}
  }

  Future<void> _pickSaveFolder() async {
     String? path = await FilePicker.platform.getDirectoryPath();
     if (path != null) setState(() => _saveFolder = path);
  }

  Future<void> _startDownload(String code) async {
     if (_saveFolder == null) {
        await _pickSaveFolder();
        if (_saveFolder == null) return;
     }
     
     setState(() { 
       _downloading = true; 
       _status = "Connecting..."; 
       _overallProgress = 0.0;
       _receivedFiles = 0;
       _totalFiles = 0;
       _speedText = "";
     });
     
     try {
       final n = int.tryParse(code, radix: 36);
       if (n == null) throw "Invalid Code";
       final ip = '${(n >> 24) & 0xFF}.${(n >> 16) & 0xFF}.${(n >> 8) & 0xFF}.${n & 0xFF}';
       
       // List
       final listResp = await http.get(Uri.parse('http://$ip:8080/list'));
       if (listResp.statusCode != 200) throw "Connection failed";
       
       final List<dynamic> files = jsonDecode(listResp.body);
       setState(() => _totalFiles = files.length);
       
       int totalBytesReceived = 0;
       int totalBytesExpected = files.fold(0, (sum, f) => sum + (f['size'] as int));
       final stopwatch = Stopwatch()..start();
       
       for (int i=0; i<files.length; i++) {
          final f = files[i];
          setState(() { 
             _currentFileName = f['name'];
             _status = "Receiving file ${i+1} of ${files.length}"; 
          });
          
          final req = await http.Client().send(http.Request('GET', Uri.parse('http://$ip:8080/file/${f['index']}')));
          final file = File('$_saveFolder/${f['name']}');
          final sink = file.openWrite();
          
          await for (final chunk in req.stream) {
             sink.add(chunk);
             totalBytesReceived += chunk.length;
             
             // Update progress periodically
             if (stopwatch.elapsedMilliseconds > 500) {
                final speed = (totalBytesReceived / 1024 / 1024) / (stopwatch.elapsedMilliseconds / 1000); // MB/s
                setState(() {
                   _overallProgress = totalBytesExpected > 0 ? totalBytesReceived / totalBytesExpected : 0.0;
                   _speedText = "${speed.toStringAsFixed(1)} MB/s";
                });
             }
          }
          await sink.close();
          setState(() => _receivedFiles++);
       }
       
       stopwatch.stop();
       setState(() { 
          _status = "Completed!"; 
          _overallProgress = 1.0; 
          _downloading = false;
          _currentFileName = "All files received successfully";
       });
     } catch (e) {
       setState(() { 
          _status = "Error"; 
          _currentFileName = e.toString();
          _downloading = false; 
       });
     }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
       backgroundColor: Colors.black,
       body: Center(
         child: Container(
           constraints: const BoxConstraints(maxWidth: 600),
           padding: const EdgeInsets.all(40),
           decoration: BoxDecoration(
             color: const Color(0xFF1E1E1E), 
             borderRadius: BorderRadius.circular(24),
             border: Border.all(color: Colors.white.withOpacity(0.1)),
             boxShadow: [
                BoxShadow(color: Colors.black.withOpacity(0.5), blurRadius: 40, offset: const Offset(0, 20))
             ]
           ),
           child: Column(
             mainAxisSize: MainAxisSize.min,
             children: [
                const Icon(Icons.download_rounded, size: 64, color: Color(0xFFFFD600)),
                const SizedBox(height: 24),
                const Text("Receive Files", style: TextStyle(color: Colors.white, fontSize: 32, fontWeight: FontWeight.bold, letterSpacing: -0.5)),
                const SizedBox(height: 8),
                Text("Enter the code displayed on the sending device", style: TextStyle(color: Colors.white.withOpacity(0.5), fontSize: 16)),
                const SizedBox(height: 40),
                
                // Code Input
                Container(
                   padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
                   decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.3),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: Colors.white.withOpacity(0.1))
                   ),
                   child: TextField(
                      controller: _codeController,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 32, color: Colors.white, letterSpacing: 4, fontWeight: FontWeight.bold),
                      decoration: const InputDecoration(
                         border: InputBorder.none,
                         hintText: "CODE",
                         hintStyle: TextStyle(color: Colors.white24)
                      ),
                   ),
                ),
                
                const SizedBox(height: 24),
                
                // Save Path
                 InkWell(
                   onTap: _pickSaveFolder,
                   borderRadius: BorderRadius.circular(12),
                   child: Container(
                     padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                     decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.05),
                        borderRadius: BorderRadius.circular(12),
                     ),
                     child: Row(
                        children: [
                          const Icon(Icons.folder_open_rounded, color: Color(0xFFFFD600), size: 20),
                          const SizedBox(width: 12),
                          Expanded(child: Text(_saveFolder ?? 'Select Save Location', style: TextStyle(color: Colors.white.withOpacity(0.8), fontSize: 14), overflow: TextOverflow.ellipsis)),
                          const Icon(Icons.edit, color: Colors.white24, size: 16),
                        ],
                     ),
                   ),
                 ),

                if (_downloading || _overallProgress > 0) ...[
                   const SizedBox(height: 48),
                   Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                         Expanded(
                           child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                 Text(_status, style: const TextStyle(color: Color(0xFFFFD600), fontWeight: FontWeight.bold, fontSize: 14)),
                                 const SizedBox(height: 4),
                                 Text(_currentFileName, style: TextStyle(color: Colors.white.withOpacity(0.7), fontSize: 13), overflow: TextOverflow.ellipsis),
                              ],
                           ),
                         ),
                         const SizedBox(width: 16),
                         Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                               Text("${(_overallProgress * 100).toInt()}%", style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 20)),
                               Text(_speedText, style: TextStyle(color: Colors.white.withOpacity(0.5), fontSize: 12)),
                            ],
                         ),
                      ],
                   ),
                   const SizedBox(height: 12),
                   ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                         value: _overallProgress, 
                         backgroundColor: Colors.white.withOpacity(0.1),
                         color: const Color(0xFFFFD600),
                         minHeight: 8,
                      ),
                   ),
                ],
                
                const SizedBox(height: 48),
                SizedBox(
                   width: double.infinity,
                   height: 56,
                   child: ElevatedButton(
                      onPressed: _downloading ? null : () => _startDownload(_codeController.text.trim()),
                      style: ElevatedButton.styleFrom(
                         backgroundColor: const Color(0xFFFFD600),
                         foregroundColor: Colors.black,
                         elevation: 0,
                         shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      ),
                      child: _downloading 
                        ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black)) 
                        : const Text("Receive Files", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                   ),
                )
             ],
           ),
         ),
       ),
    );
  }
}
