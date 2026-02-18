import 'dart:io';
import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'dart:convert';
import 'package:path_provider/path_provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../services/device_discovery_service.dart';
import '../../widgets/connection_request_dialog.dart';
import 'IOSReceiveScreen.dart';

// Modern Color Constants
// Modern Color Constants
const Color kZapPrimary = Color(0xFFFFD84D); // Logo Yellow Light
const Color kZapPrimaryDark = Color(0xFFF5C400); // Logo Yellow Dark
const Color kZapSurface = Color(0xFF1C1C1E); 
const Color kZapBackgroundTop = Color(0xFF0E1116);
const Color kZapBackgroundBottom = Color(0xFF07090D);

class IOSFileShareScreen extends StatefulWidget {
  final VoidCallback? onBack;
  const IOSFileShareScreen({super.key, this.onBack});

  @override
  State<IOSFileShareScreen> createState() => _IOSFileShareScreenState();
}

class _IOSFileShareScreenState extends State<IOSFileShareScreen> with TickerProviderStateMixin {
  List<PlatformFile> _files = [];
  bool _loading = false;
  HttpServer? _server;
  String? _localIp;
  bool _isSharing = false;
  List<double> _progressList = []; 
  List<bool> _isPausedList = [];
  List<bool> _completedFiles = [];
  String? _displayCode;
  
  // Device Discovery
  final DeviceDiscoveryService _discoveryService = DeviceDiscoveryService();
  List<DiscoveredDevice> _nearbyDevices = [];
  StreamSubscription? _devicesSubscription;
  StreamSubscription? _connectionRequestSubscription;
  StreamSubscription? _connectionResponseSubscription;
  String? _pendingRequestDeviceIp;
  Timer? _requestTimeoutTimer;
  DiscoveredDevice? _pendingDevice;
  Set<String> _processedRequests = {}; 
  Map<String, DateTime> _lastRequestTime = {};

  // Animation Controllers
  late AnimationController _radarController;
  final DraggableScrollableController _dragController = DraggableScrollableController();

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

  Future<void> _saveHistory(String fileName, String path, int fileSize, String peerIp, String? peerDeviceName) async {
    final prefs = await SharedPreferences.getInstance();
    final history = prefs.getStringList('transfer_history') ?? [];
    
    final entry = {
      'fileName': fileName,
      'fileSize': fileSize,
      'direction': 'Sent',
      'peer': peerIp,
      'peerDeviceName': peerDeviceName, 
      'dateTime': DateTime.now().toIso8601String(),
      'fileLocation': path,
    };
    
    history.insert(0, jsonEncode(entry));
    await prefs.setStringList('transfer_history', history);
  }

  @override
  void initState() {
    super.initState();
    _fetchLocalIp();
    _initDeviceDiscovery();
    
    _radarController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 4),
    )..repeat();
  }
  
  @override
  void dispose() {
    _stopServer();
    _devicesSubscription?.cancel();
    _connectionRequestSubscription?.cancel();
    _connectionResponseSubscription?.cancel();
    _requestTimeoutTimer?.cancel();
    _radarController.dispose();
    super.dispose();
  }

  void _initDeviceDiscovery() async {
    await _discoveryService.initialize();
    await _discoveryService.start();
    
    _devicesSubscription = _discoveryService.devicesStream.listen((devices) {
      if (mounted) {
        setState(() {
          _nearbyDevices = devices.where((d) => d.isOnline).toList();
        });
      }
    });
    
    _connectionRequestSubscription = _discoveryService.connectionRequestStream.listen(
      (request) {
        if (mounted) {
          final now = DateTime.now();
          final lastTime = _lastRequestTime[request.ipAddress];
          if (lastTime != null && now.difference(lastTime).inSeconds < 30) return;
          _lastRequestTime[request.ipAddress] = now;
          _showConnectionRequestDialog(request);
        }
      },
    );
    
    _connectionResponseSubscription = _discoveryService.connectionResponseStream.listen((response) {
      if (mounted && _pendingRequestDeviceIp != null) {
        _requestTimeoutTimer?.cancel();
        _requestTimeoutTimer = null;
        
        if (response.accepted) {
          _startSharingToDevice(_pendingRequestDeviceIp!);
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Connection request was declined'), backgroundColor: Colors.red),
          );
        }
        setState(() {
          _pendingRequestDeviceIp = null;
          _pendingDevice = null;
        });
      }
    });
  }

  void _showConnectionRequestDialog(ConnectionRequest request) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return ConnectionRequestDialog(
          request: request,
          onAccept: (selectedFiles, savePath) async {
            Navigator.of(dialogContext).pop();
            _processedRequests.add(request.ipAddress);
            await _discoveryService.sendConnectionResponse(request.ipAddress, true);
            
            if (mounted) {
               // Auto-connect to the sender using their IP directly (more robust)
               Navigator.of(context).push(MaterialPageRoute(builder: (ctx) => IOSReceiveScreen(
                  filterFiles: selectedFiles,
                  destinationPath: savePath,
                  connectionIp: request.ipAddress, // Correct direct IP
               )));
            }
            Future.delayed(const Duration(seconds: 60), () {
              _processedRequests.remove(request.ipAddress);
            });
          },
          onDecline: () async {
            Navigator.of(dialogContext).pop();
            _processedRequests.add(request.ipAddress);
            await _discoveryService.sendConnectionResponse(request.ipAddress, false);
            Future.delayed(const Duration(seconds: 30), () {
              _processedRequests.remove(request.ipAddress);
            });
          },
        );
      },
    );
  }

  Future<void> _fetchLocalIp() async {
    try {
      final interfaces = await NetworkInterface.list(includeLinkLocal: false, type: InternetAddressType.IPv4);
      String? bestIp;
      for (final interface in interfaces) {
        for (final addr in interface.addresses) {
          final ip = addr.address;
          if (ip == '127.0.0.1' || ip == 'localhost') continue;
           if (!ip.startsWith('127.') && !ip.startsWith('169.254.')) {
              bestIp ??= ip;
              if (ip.startsWith('192.168.') || ip.startsWith('10.')) {
                 bestIp = ip;
                 break; 
              }
           }
        }
        if (bestIp != null && (bestIp.startsWith('192.168.') || bestIp.startsWith('10.'))) break;
      }
      if (bestIp != null) {
        setState(() {
          _localIp = bestIp;
          _displayCode = _ipToCode(bestIp!);
        });
      }
    } catch (e) {
      print('Error getting IP: $e');
    }
  }

  Future<void> _refreshIp() async {
    setState(() => _loading = true);
    await _fetchLocalIp();
    await _discoveryService.stop();
    await _discoveryService.start();
    setState(() => _loading = false);
  }

  Future<void> _selectFiles() async {
    HapticFeedback.mediumImpact();
    setState(() => _loading = true);
    try {
      final result = await FilePicker.platform.pickFiles(allowMultiple: true);
      if (result != null) {
        setState(() {
          _files.addAll(result.files);
          _progressList.addAll(List.filled(result.files.length, 0.0));
          _isPausedList.addAll(List.filled(result.files.length, false));
          _completedFiles.addAll(List.filled(result.files.length, false));
          if (_localIp != null) _displayCode = _ipToCode(_localIp!);
        });
        // Auto expand sheet if files added
        if (_dragController.isAttached) {
             _dragController.animateTo(
               0.5, 
               duration: const Duration(milliseconds: 300), 
               curve: Curves.easeOut
             );
        }
      }
    } catch (e) {
      print("Error picking files: $e");
    }
    setState(() => _loading = false);
  }

  Future<void> _startServer() async {
    if (_files.isEmpty) return;
    HapticFeedback.mediumImpact();
    await _server?.close(force: true);
    
    try {
      _server = await HttpServer.bind(InternetAddress.anyIPv4, 8080);
      setState(() => _isSharing = true);
      
      final myDeviceName = _discoveryService.myDeviceName ?? 'Unknown Device';
      
      _server!.listen((HttpRequest request) async {
        final path = request.uri.path;
        request.response.headers.add('Access-Control-Allow-Origin', '*');
        
        if (request.method == 'OPTIONS') {
           request.response.statusCode = HttpStatus.ok;
           await request.response.close();
           return;
        }
        
        if (path == '/list') {
          final list = List.generate(_files.length, (i) => {
            'index': i,
            'name': _files[i].name,
            'size': _files[i].size,
          });
          request.response.headers.contentType = ContentType.json;
          // Send my device name in header so client knows who I am (Base64 encoded for safety)
          request.response.headers.add('X-Device-Name', base64Encode(utf8.encode(myDeviceName)));
          request.response.write(jsonEncode(list));
          await request.response.close();
          return;
        }

        if (path == '/connection-request' && request.method == 'POST') {
             try {
                final content = await utf8.decoder.bind(request).join();
                final data = jsonDecode(content);
                // Just ack
                request.response.statusCode = HttpStatus.serviceUnavailable;
                await request.response.close();
             } catch(e) {
                request.response.statusCode = HttpStatus.badRequest;
                await request.response.close();
             }
             return;
        }
        
        final segments = request.uri.pathSegments;
        if (segments.length == 2 && segments[0] == 'file') {
          final index = int.tryParse(segments[1]);
          if (index == null || index >= _files.length) {
              request.response.statusCode = HttpStatus.notFound;
              await request.response.close();
              return;
          }
          final file = _files[index];
          final filePath = file.path;
          if (filePath == null || !await File(filePath).exists()) {
             request.response.statusCode = HttpStatus.notFound;
             await request.response.close();
             return;
          }

          final fileToSend = File(filePath);
          final fileSize = await fileToSend.length();
          request.response.headers.contentType = ContentType.binary;
          request.response.headers.set('Content-Disposition', 'attachment; filename="${file.name}"');
          request.response.headers.set('Content-Length', fileSize.toString());
          
          // Get peer device name from request headers
          String? peerDeviceName = request.headers.value('X-Device-Name');
          if (peerDeviceName != null) {
              try {
                 peerDeviceName = utf8.decode(base64Decode(peerDeviceName));
              } catch (e) {
                 // Fallback if not encoded or legacy
              }
          }
          
          int sent = 0;
          try {
            await fileToSend.openRead().forEach((chunk) {
              request.response.add(chunk);
              sent += chunk.length;
              if (mounted) {
                setState(() => _progressList[index] = sent / fileSize);
              }
            });
            await request.response.close();
            if (mounted) {
                setState(() {
                  _progressList[index] = 1.0;
                  _completedFiles[index] = true;
                });
                await _saveHistory(
                  file.name, 
                  file.path ?? '', 
                  fileSize, 
                  request.connectionInfo?.remoteAddress.address ?? 'Unknown',
                  peerDeviceName
                );
            }
          } catch (e) {
             print("Error streaming file: $e");
          }
          return;
        }
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
      });
    } catch (e) {
      print("Error starting server: $e");
      setState(() => _isSharing = false);
    }
  }

  Future<void> _stopServer() async {
    HapticFeedback.mediumImpact();
    await _server?.close(force: true);
    setState(() => _isSharing = false);
  }

   Future<void> _sendConnectionRequest(DiscoveredDevice device) async {
    if (_files.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select files first'), backgroundColor: Colors.orange),
      );
      // Open sheet to prompt selection
      if (_dragController.isAttached) {
          _dragController.animateTo(0.5, duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
      }
      return;
    }

    setState(() {
      _pendingRequestDeviceIp = device.ipAddress;
      _pendingDevice = device;
    });
    
    await _startServer();
    
    final totalSize = _files.fold<int>(0, (sum, file) => sum + (file.size));
    final fileNames = _files.map((f) => f.name).toList();
    final filePaths = _files.map((f) => f.path ?? '').where((p) => p.isNotEmpty).toList(); // Extract paths
    
    await _discoveryService.sendConnectionRequest(
      device.ipAddress,
      fileNames,
      totalSize,
      filePaths: filePaths,
    );
    
    _requestTimeoutTimer = Timer(const Duration(seconds: 30), () {
      if (mounted && _pendingRequestDeviceIp != null) {
        setState(() {
          _pendingRequestDeviceIp = null;
          _pendingDevice = null;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Connection request timed out'), backgroundColor: Colors.orange),
        );
      }
    });
  }
  
  void _startSharingToDevice(String deviceIp) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Sharing files...'), backgroundColor: Colors.green),
    );
  }

  void _showQrDialog() {
      if (_displayCode == null || _localIp == null) return;
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: Colors.grey[900],
          title: const Text('Connect via QR Code', style: TextStyle(color: Colors.white)),
          content: SizedBox(
            width: 200,
            height: 200,
            child: Center(
              child: QrImageView(
                data: _localIp!, // Just IP for now, or JSON including code
                version: QrVersions.auto,
                size: 200.0,
                backgroundColor: Colors.white,
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close', style: TextStyle(color: kZapPrimary)),
            )
          ],
        ),
      );
  }

  void _deleteFile(int index) {
      if (index < 0 || index >= _files.length) return;
      HapticFeedback.mediumImpact();
      setState(() {
          _files.removeAt(index);
          _progressList.removeAt(index);
          _isPausedList.removeAt(index);
          _completedFiles.removeAt(index);
      });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBody: true,
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
           // 1. Full Screen Radar (Background Layer)
           Positioned.fill(
             child: _buildRadarView(),
           ),

           // 2. Header Layer (Top)
           Positioned(
             top: 0, left: 0, right: 0,
             child: SafeArea(
               child: Padding(
                 padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                 child: Row(
                   mainAxisAlignment: MainAxisAlignment.spaceBetween,
                   children: [
                      Hero(
                        tag: 'send_fab', 
                        child: Material(
                          color: Colors.transparent,
                          child: Container(
                           decoration: BoxDecoration(
                             color: Colors.black.withOpacity(0.2), // Subtle bg
                             shape: BoxShape.circle,
                           ),
                           child: IconButton(
                             icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
                             onPressed: () {
                               if (widget.onBack != null) {
                                  widget.onBack!();
                               } else {
                                  Navigator.pop(context);
                               }
                             },
                           ),
                          ),
                        ),
                      ),
                      
                      Row(
                        children: [
                          IconButton(
                             icon: _loading 
                               ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                               : const Icon(Icons.refresh_rounded, color: Colors.white),
                             onPressed: _refreshIp,
                             tooltip: "Refresh Radar",
                          ),
                          const SizedBox(width: 8),
                          IconButton(
                            icon: const Icon(Icons.qr_code_rounded, color: Colors.white),
                            onPressed: _showQrDialog,
                          ),
                        ],
                      ),
                   ],
                 ),
               ),
             ),
           ),

           // 3. Draggable File Sheet (Bottom Layer)
           DraggableScrollableSheet(
             controller: _dragController,
             initialChildSize: 0.15, 
             minChildSize: 0.15, 
             maxChildSize: 0.85,
             builder: (context, scrollController) {
                return Container(
                  decoration: BoxDecoration(
                    color: kZapSurface,
                    borderRadius: const BorderRadius.vertical(top: Radius.circular(30)),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.5),
                        blurRadius: 20,
                        offset: const Offset(0, -5),
                      )
                    ],
                  ),
                  child: ListView(
                    controller: scrollController,
                    padding: EdgeInsets.zero,
                    children: [
                       // Drag Handle Area
                       Center(
                         child: Container(
                           margin: const EdgeInsets.only(top: 12, bottom: 8),
                           width: 40, height: 4,
                           decoration: BoxDecoration(color: Colors.grey[600], borderRadius: BorderRadius.circular(2)),
                         ),
                       ),
                       
                       // Header
                       Padding(
                         padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                         child: Row(
                           mainAxisAlignment: MainAxisAlignment.spaceBetween,
                           children: [
                             Text(
                               _files.isEmpty ? 'Select Files' : 'Files (${_files.length})',
                               style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                             ),
                             TextButton.icon(
                                onPressed: _selectFiles,
                                icon: const Icon(Icons.add_rounded, size: 18, color: kZapPrimary),
                                label: const Text("Add", style: TextStyle(color: kZapPrimary)),
                             )
                           ],
                         ),
                       ),

                       // File List or Empty State
                       if (_files.isEmpty)
                          _buildEmptyState()
                       else
                          ..._files.asMap().entries.map((entry) {
                              final index = entry.key;
                              final file = entry.value;
                              return Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 6),
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: Colors.white.withOpacity(0.05),
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                  child: ListTile(
                                    leading: _buildFileIcon(file.extension ?? ''),
                                    title: Text(
                                      file.name,
                                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    subtitle: Text(
                                      '${(file.size / 1024 / 1024).toStringAsFixed(2)} MB',
                                      style: TextStyle(color: Colors.grey[500], fontSize: 12),
                                    ),
                                    trailing: IconButton(
                                      icon: const Icon(Icons.close_rounded, color: Colors.grey, size: 18),
                                      onPressed: () => _deleteFile(index),
                                    ),
                                  ),
                                ),
                              );
                          }),
                       
                       // Bottom Action Button
                       if (_files.isNotEmpty)
                         Padding(
                           padding: const EdgeInsets.all(24),
                           child: _buildActionButtons(),
                         ),
                        
                        // Extra padding for safe area
                        SizedBox(height: MediaQuery.of(context).padding.bottom + 20),
                    ],
                  ),
                );
             },
           ),
        ],
      ),
      ),
    );
  }

  Widget _buildRadarView() {
    return Stack(
      alignment: Alignment.center,
      children: [
        // Radar Circles
        ...List.generate(3, (index) {
          return AnimatedBuilder(
            animation: _radarController,
            builder: (context, child) {
              double opacity = (1.0 - (index * 0.3)) * (0.5 + 0.5 * sin(_radarController.value * 2 * pi));
              return Container(
                width: 150.0 + (index * 120), // Larger circles
                height: 150.0 + (index * 120),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: kZapPrimary.withOpacity(0.1)),
                  color: index == 0 ? kZapPrimary.withOpacity(0.02) : Colors.transparent,
                ),
              );
            },
          );
        }),

        // Center Ripple
        Container(
          width: 100, height: 100,
          decoration: BoxDecoration(
            color: kZapPrimary.withOpacity(0.1),
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: kZapPrimary.withOpacity(0.1),
                blurRadius: 40,
                spreadRadius: 10,
              )
            ]
          ),
          child: const Icon(Icons.radar_rounded, color: kZapPrimary, size: 50),
        ),
        
        // Nearby Devices (Randomly Positioned on Orbit for demo)
        ..._nearbyDevices.asMap().entries.map((entry) {
            final idx = entry.key;
            final device = entry.value;
            // Simple positioning logic
            final angle = (idx * (2 * pi / (_nearbyDevices.isEmpty ? 1 : _nearbyDevices.length))) - (pi/2);
            final radius = 140.0;
            return Transform.translate(
               offset: Offset(radius * cos(angle), radius * sin(angle)),
               child: _buildDeviceAvatar(device),
            );
        }),
        
         Positioned(
            bottom: 156, 
            child: Column(
              children: [
                Text(
                  _nearbyDevices.isEmpty ? "Scanning for devices..." : "Found ${_nearbyDevices.length} nearby",
                  style: TextStyle(color: kZapPrimary.withOpacity(0.8), fontSize: 12, letterSpacing: 1),
                ),
                
                if (_displayCode != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: Column(
                      children: [
                        Text("CONNECTION CODE", style: TextStyle(color: Colors.white.withOpacity(0.5), fontSize: 10, letterSpacing: 1.5, fontWeight: FontWeight.bold)),
                        const SizedBox(height: 8),
                        GestureDetector(
                          onTap: () {
                             Clipboard.setData(ClipboardData(text: _displayCode!));
                             HapticFeedback.mediumImpact();
                             ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Code copied!"), duration: Duration(seconds: 1)));
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                            decoration: BoxDecoration(
                              color: Colors.black.withOpacity(0.6),
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(color: kZapPrimary.withOpacity(0.5), width: 1.5),
                              boxShadow: [
                                BoxShadow(color: kZapPrimary.withOpacity(0.1), blurRadius: 10, spreadRadius: 0)
                              ]
                            ),
                            child: Text(
                              _displayCode!,
                              style: const TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.bold, letterSpacing: 6, fontFamily: 'monospace'),
                            ),
                          ),
                        ),
                         const SizedBox(height: 8),
                         if (_localIp != null)
                             Text("IP: $_localIp", style: TextStyle(color: Colors.grey[800], fontSize: 10)),
                      ],
                    ),
                  ),
              ],
            ),
         ),
      ],
    );
  }
  
  Widget _buildDeviceAvatar(DiscoveredDevice device) {
     return GestureDetector(
       onTap: () => _sendConnectionRequest(device),
       child: Column(
         mainAxisSize: MainAxisSize.min,
         children: [
            Container(
               width: 70, height: 70,
               decoration: BoxDecoration(
                  color: kZapSurface,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white.withOpacity(0.1)),
                  boxShadow: [
                     BoxShadow(
                        color: kZapPrimary.withOpacity(0.3),
                        blurRadius: 20,
                        spreadRadius: 2,
                     )
                  ]
               ),
               child: Center(
                  child: Text(
                     device.deviceName.substring(0, 1).toUpperCase(),
                     style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 28),
                  ),
               ),
            ),
            const SizedBox(height: 8),
            Container(
               padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
               decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.6),
                  borderRadius: BorderRadius.circular(8)
               ),
               child: Text(
                  device.deviceName, 
                  style: const TextStyle(color: Colors.white, fontSize: 10),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
               ),
            )
         ],
       ),
     );
  }

  Widget _buildEmptyState() {
    return Padding(
      padding: const EdgeInsets.only(top: 40),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.arrow_upward_rounded, size: 32, color: Colors.grey[800]),
            const SizedBox(height: 16),
            Text(
              'Pull up or tap Add to select files',
              style: TextStyle(color: Colors.grey[600], fontSize: 14),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFileList(ScrollController controller) {
    return ListView.builder(
      controller: controller,
      itemCount: _files.length,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      itemBuilder: (context, index) {
        final file = _files[index];
        final progress = _progressList[index];
        
        return Container(
          margin: const EdgeInsets.only(bottom: 12),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.05),
            borderRadius: BorderRadius.circular(16),
          ),
          child: ListTile(
            leading: _buildFileIcon(file.extension ?? ''),
            title: Text(
              file.name,
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              '${(file.size / 1024 / 1024).toStringAsFixed(2)} MB',
              style: TextStyle(color: Colors.grey[500], fontSize: 12),
            ),
            trailing: IconButton(
              icon: const Icon(Icons.close_rounded, color: Colors.grey, size: 18),
              onPressed: () => _deleteFile(index),
            ),
          ),
        );
      },
    );
  }

  Widget _buildFileIcon(String extension) {
    IconData icon;
    Color color;
    switch (extension.toLowerCase()) {
      case 'jpg':
      case 'jpeg':
      case 'png':
        icon = Icons.image_rounded;
        color = Colors.purpleAccent;
        break;
      case 'pdf':
        icon = Icons.picture_as_pdf_rounded;
        color = Colors.redAccent;
        break;
      case 'mp4':
      case 'mov':
        icon = Icons.videocam_rounded;
        color = Colors.orangeAccent;
        break;
      case 'mp3':
      case 'wav':
        icon = Icons.music_note_rounded;
        color = Colors.blueAccent;
        break;
      default:
        icon = Icons.insert_drive_file_rounded;
        color = kZapPrimary;
    }
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: color.withOpacity(0.2),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Icon(icon, color: color, size: 20),
    );
  }

  Widget _buildActionButtons() {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        onPressed: _files.isEmpty ? null : (_isSharing ? _stopServer : _startServer),
        style: ElevatedButton.styleFrom(
          backgroundColor: kZapPrimary,
          foregroundColor: Colors.black,
          padding: const EdgeInsets.symmetric(vertical: 16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          elevation: 0,
        ),
        child: Text(
           _isSharing ? "Stop Sharing" : "Ready to Send",
           style: const TextStyle(fontWeight: FontWeight.bold)
        ),
      ),
    );
  }
}
