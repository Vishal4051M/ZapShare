import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:file_picker/file_picker.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:flutter/services.dart';
import 'dart:convert';
import '../../services/device_discovery_service.dart';
import '../../widgets/connection_request_dialog.dart';
import 'MacOSReceiveScreen.dart';

const Color kAccentYellow = Color(0xFFFFD600);

class MacOSFileShareScreen extends StatefulWidget {
  const MacOSFileShareScreen({super.key});
  @override
  State<MacOSFileShareScreen> createState() => _MacOSFileShareScreenState();
}

class _MacOSFileShareScreenState extends State<MacOSFileShareScreen> {
  List<PlatformFile> _files = [];
  bool _loading = false;
  HttpServer? _server;
  String? _localIp;
  bool _isSharing = false;
  List<double> _progressList = [];
  String? _displayCode;
  
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

  // Bottom Sheet State
  double _dragExtent = 0.15;
  final double _minExtent = 0.15;
  final double _maxExtent = 0.75;

  String _ipToCode(String ip) {
    final parts = ip.split('.').map(int.parse).toList();
    if (parts.length != 4) return '';
    int n = (parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3];
    String code = n.toRadixString(36).toUpperCase();
    return code.padLeft(8, '0');
  }

  @override
  void initState() {
    super.initState();
    _fetchLocalIp();
    _initDeviceDiscovery();
  }
  
  @override
  void dispose() {
    _stopServer();
    _devicesSubscription?.cancel();
    _connectionRequestSubscription?.cancel();
    _connectionResponseSubscription?.cancel();
    _requestTimeoutTimer?.cancel();
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

    _connectionRequestSubscription = _discoveryService.connectionRequestStream.listen((request) {
        if (mounted) {
           final now = DateTime.now();
           final lastTime = _lastRequestTime[request.ipAddress];
           if (lastTime != null && now.difference(lastTime).inSeconds < 30) return;
           
           _lastRequestTime[request.ipAddress] = now;
           _showConnectionRequestDialog(request);
        }
    });

    _connectionResponseSubscription = _discoveryService.connectionResponseStream.listen((response) {
       if (mounted && _pendingRequestDeviceIp != null) {
          _requestTimeoutTimer?.cancel();
          _requestTimeoutTimer = null;
          if (response.accepted) {
             ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Accepted! Sharing files...'), backgroundColor: Colors.green));
          } else {
             ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Declined.'), backgroundColor: Colors.red));
          }
           _pendingRequestDeviceIp = null;
           _pendingDevice = null;
       }
    });
  }

  void _showConnectionRequestDialog(ConnectionRequest request) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => ConnectionRequestDialog(
         request: request,
         onAccept: (files, path) async {
            Navigator.pop(context);
            _processedRequests.add(request.ipAddress);
            await _discoveryService.sendConnectionResponse(request.ipAddress, true);
            Navigator.push(context, MaterialPageRoute(builder: (_) => const MacOSReceiveScreen()));
            Future.delayed(const Duration(seconds: 60), () => _processedRequests.remove(request.ipAddress));
         },
         onDecline: () async {
            Navigator.pop(context);
            _processedRequests.add(request.ipAddress);
            await _discoveryService.sendConnectionResponse(request.ipAddress, false);
            Future.delayed(const Duration(seconds: 30), () => _processedRequests.remove(request.ipAddress));
         },
      ),
    );
  }

  Future<void> _fetchLocalIp() async {
     try {
       final interfaces = await NetworkInterface.list(includeLinkLocal: false, type: InternetAddressType.IPv4);
       String? bestIp;
       for (var i in interfaces) {
         for (var addr in i.addresses) {
            String ip = addr.address;
            if (ip == '127.0.0.1' || ip == 'localhost') continue;
            bestIp ??= ip;
            if (ip.startsWith('192.168.') || ip.startsWith('10.')) bestIp = ip;
         }
       }
       if (bestIp != null) {
         setState(() {
           _localIp = bestIp;
           _displayCode = _ipToCode(bestIp!);
         });
       }
     } catch (e) { print(e); }
  }

  Future<void> _pickFiles() async {
     setState(() => _loading = true);
     final res = await FilePicker.platform.pickFiles(allowMultiple: true);
     if (res != null) {
        setState(() {
          _files.addAll(res.files);
          _progressList.addAll(List.filled(res.files.length, 0.0));
        });
        // Auto-expand to show files if hidden
        if (_dragExtent < 0.45) {
          setState(() => _dragExtent = 0.45);
        }
     }
     setState(() => _loading = false);
  }

  Future<void> _startServer() async {
     if (_files.isEmpty) return;
     await _server?.close(force: true);
     _server = await HttpServer.bind(InternetAddress.anyIPv4, 8080);
     setState(() => _isSharing = true);
     
     _server!.listen((HttpRequest req) async {
        if (req.uri.path == '/list') {
           req.response.headers.contentType = ContentType.json;
           req.response.write(jsonEncode(List.generate(_files.length, (i) => {
             'index': i, 'name': _files[i].name, 'size': _files[i].size
           })));
           await req.response.close();
           return;
        }
        
        if (req.uri.pathSegments.length == 2 && req.uri.pathSegments[0] == 'file') {
           int idx = int.tryParse(req.uri.pathSegments[1]) ?? -1;
           if (idx >= 0 && idx < _files.length) {
              final f = File(_files[idx].path!);
              final len = await f.length();
              req.response.headers.contentType = ContentType.binary;
              req.response.headers.set('Content-Disposition', 'attachment; filename="${_files[idx].name}"');
              req.response.headers.set('Content-Length', len.toString());
              await f.openRead().pipe(req.response);
              return;
           }
        }
        req.response.statusCode = 404;
        await req.response.close();
     });
  }

  Future<void> _stopServer() async {
    await _server?.close(force: true);
    setState(() => _isSharing = false);
  }
  
  Future<void> _sendConnectionRequest(DiscoveredDevice device) async {
     if (_files.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Pick files first')));
        return;
     }
     setState(() {
       _pendingRequestDeviceIp = device.ipAddress;
       _pendingDevice = device;
     });
     
     await _startServer();
     
     final totalSize = _files.fold<int>(0, (s, f) => s + f.size);
     await _discoveryService.sendConnectionRequest(device.ipAddress, _files.map((f) => f.name).toList(), totalSize);
     
     _requestTimeoutTimer = Timer(const Duration(seconds: 30), () {
        if (mounted && _pendingRequestDeviceIp != null) {
           setState(() {
             _pendingDevice = null;
             _pendingRequestDeviceIp = null;
           });
           ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Timed out')));
        }
     });
  }

  void _handleDragUpdate(DragUpdateDetails details) {
    final screenHeight = MediaQuery.of(context).size.height;
    setState(() {
      double newHeight = (screenHeight * _dragExtent) - details.delta.dy;
      _dragExtent = (newHeight / screenHeight).clamp(_minExtent, _maxExtent);
    });
  }

  void _handleDragEnd(DragEndDetails details) {
    double velocity = details.primaryVelocity ?? 0;
    double target;
    if (velocity < -500) {
       target = _maxExtent;
    } else if (velocity > 500) {
       target = _minExtent;
    } else {
       double distMin = (_dragExtent - _minExtent).abs();
       double distMax = (_dragExtent - _maxExtent).abs();
       target = (distMin < distMax) ? _minExtent : _maxExtent;
    }
    setState(() => _dragExtent = target);
  }

  @override
  Widget build(BuildContext context) {
    final screenHeight = MediaQuery.of(context).size.height;
    
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // Main Content Area
          Positioned.fill(
            bottom: screenHeight * _dragExtent, // No overlap to prevent covering content
            child: Padding(
              padding: const EdgeInsets.all(32.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // Scanning Animation
                  Container(
                    width: 200,
                    height: 200,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(
                        colors: [
                          kAccentYellow.withOpacity(0.3),
                          kAccentYellow.withOpacity(0.1),
                          Colors.transparent,
                        ],
                      ),
                    ),
                    child: Center(
                      child: Container(
                        width: 80,
                        height: 80,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: kAccentYellow,
                          boxShadow: [
                            BoxShadow(
                              color: kAccentYellow.withOpacity(0.5),
                              blurRadius: 40,
                              spreadRadius: 10,
                            ),
                          ],
                        ),
                        child: const Icon(
                          Icons.radar,
                          color: Colors.black,
                          size: 40,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 40),
                  const Text(
                    "Scanning for devices...",
                    style: TextStyle(
                      color: kAccentYellow,
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 32),
                  // Connection Code
                  Column(
                    children: [
                      const Text(
                        "CONNECTION CODE",
                        style: TextStyle(
                          color: Colors.grey,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 1.5,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.05),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: Colors.white.withOpacity(0.1),
                          ),
                        ),
                        child: Text(
                          _displayCode ?? "........",
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 4,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ),
                      if (_localIp != null) ...[
                        const SizedBox(height: 8),
                        Text(
                          "IP: $_localIp",
                          style: TextStyle(
                            color: Colors.grey.withOpacity(0.6),
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ),
          
          // Custom Resizable Bottom Panel
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: screenHeight * _dragExtent,
            child: Container(
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  color: const Color(0xFF2B2B2B),
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(24),
                    topRight: Radius.circular(24),
                  ),
                  border: Border.all(
                    color: Colors.white.withOpacity(0.1),
                    width: 1,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.5),
                      blurRadius: 20,
                      offset: const Offset(0, -5),
                    ),
                  ],
                ),
                child: Column(
                  children: [
                    // Header Area (Visual + Drag)
                    GestureDetector(
                      onVerticalDragUpdate: _handleDragUpdate,
                      onVerticalDragEnd: _handleDragEnd,
                      behavior: HitTestBehavior.translucent,
                      child: MouseRegion(
                        cursor: SystemMouseCursors.resizeUpDown,
                        child: Container(
                          width: double.infinity,
                          color: const Color(0xFF2B2B2B), 
                          child: Column(
                            children: [
                              // Drag Handle
                              Padding(
                                padding: const EdgeInsets.only(top: 12, bottom: 4),
                                child: Container(
                                  width: 40,
                                  height: 4,
                                  decoration: BoxDecoration(
                                    color: Colors.white.withOpacity(0.3),
                                    borderRadius: BorderRadius.circular(2),
                                  ),
                                ),
                              ),
                              // Header Content
                              Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    Row(
                                      children: [
                                        const Icon(Icons.folder_copy_rounded, color: Colors.white70, size: 20),
                                        const SizedBox(width: 8),
                                        // Make text click toggle
                                        GestureDetector(
                                          onTap: () {
                                             setState(() {
                                                _dragExtent = (_dragExtent < 0.3) ? _maxExtent : _minExtent;
                                             });
                                          },
                                          child: const Text(
                                            "Select Files",
                                            style: TextStyle(
                                              color: Colors.white,
                                              fontSize: 16,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                    // Add Button
                                    GestureDetector(
                                      onTap: _pickFiles,
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                        decoration: BoxDecoration(
                                           color: kAccentYellow.withOpacity(0.2),
                                           borderRadius: BorderRadius.circular(16),
                                        ),
                                        child: Row(children: [
                                           const Icon(Icons.add, color: kAccentYellow, size: 16),
                                           const SizedBox(width: 4),
                                           const Text("Add", style: TextStyle(color: kAccentYellow, fontWeight: FontWeight.bold, fontSize: 12)),
                                        ]),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const Divider(color: Colors.white12, height: 1),
                            ],
                          ),
                        ),
                      ),
                    ),
        
                    // Content List
                    Expanded(
                      child: (_files.isEmpty && _nearbyDevices.isEmpty)
                          ? GestureDetector(
                              onVerticalDragUpdate: _handleDragUpdate,
                              onVerticalDragEnd: _handleDragEnd,
                              behavior: HitTestBehavior.translucent,
                              child: Center(
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(
                                      Icons.radar,
                                      size: 64,
                                      color: Colors.white.withOpacity(0.2),
                                    ),
                                    const SizedBox(height: 16),
                                    Text(
                                      "Searching for devices...",
                                      style: TextStyle(
                                        color: Colors.white.withOpacity(0.5),
                                        fontSize: 16,
                                      ),
                                    ),
                                    const SizedBox(height: 8),
                                    TextButton.icon(
                                      onPressed: _pickFiles,
                                      icon: const Icon(Icons.add_circle_outline, color: kAccentYellow),
                                      label: const Text(
                                        "Add files to share",
                                        style: TextStyle(color: kAccentYellow),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            )
                          : ListView.builder(
                              // physics removed to allow parent gesture detector to handle insufficient content cases
                              padding: const EdgeInsets.only(bottom: 20),
                              itemCount: _files.length + (_nearbyDevices.isNotEmpty ? 1 : 0),
                              itemBuilder: (context, index) {
                                if (_nearbyDevices.isNotEmpty && index == 0) {
                                  return Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                       const Padding(
                                        padding: EdgeInsets.fromLTRB(24, 16, 24, 8),
                                        child: Text(
                                          "SEND TO",
                                          style: TextStyle(
                                            color: Colors.grey,
                                            fontSize: 11,
                                            fontWeight: FontWeight.w600,
                                            letterSpacing: 1.2,
                                          ),
                                        ),
                                      ),
                                      SizedBox(
                                        height: 140, // Increased height to prevent overlap
                                        child: ListView.builder(
                                          scrollDirection: Axis.horizontal,
                                          padding: const EdgeInsets.symmetric(horizontal: 16),
                                          itemCount: _nearbyDevices.length,
                                          itemBuilder: (context, deviceIndex) {
                                            final device = _nearbyDevices[deviceIndex];
                                            final isPending = _pendingDevice?.ipAddress == device.ipAddress;
                                            return Padding(
                                              padding: const EdgeInsets.all(8.0),
                                              child: MouseRegion(
                                                cursor: SystemMouseCursors.click,
                                                child: GestureDetector(
                                                  onTap: () => _sendConnectionRequest(device),
                                                  child: Container(
                                                    width: 120,
                                                    padding: const EdgeInsets.all(12),
                                                    decoration: BoxDecoration(
                                                      color: isPending 
                                                          ? kAccentYellow.withOpacity(0.2)
                                                          : Colors.white.withOpacity(0.05),
                                                      borderRadius: BorderRadius.circular(12),
                                                      border: Border.all(
                                                        color: isPending 
                                                            ? kAccentYellow 
                                                            : Colors.white.withOpacity(0.1),
                                                      ),
                                                    ),
                                                    child: Column(
                                                      mainAxisAlignment: MainAxisAlignment.center,
                                                      children: [
                                                        Icon(
                                                          Icons.computer,
                                                          color: isPending ? kAccentYellow : Colors.white70,
                                                          size: 32,
                                                        ),
                                                        const SizedBox(height: 12),
                                                        Text(
                                                          device.deviceName,
                                                          style: TextStyle(
                                                            color: isPending ? kAccentYellow : Colors.white,
                                                            fontSize: 12,
                                                            fontWeight: FontWeight.w500,
                                                          ),
                                                          textAlign: TextAlign.center,
                                                          maxLines: 2,
                                                          overflow: TextOverflow.ellipsis,
                                                        ),
                                                      ],
                                                    ),
                                                  ),
                                                ),
                                              ),
                                            );
                                          },
                                        ),
                                      ),
                                      if (_files.isNotEmpty)
                                        const Padding(
                                          padding: EdgeInsets.fromLTRB(24, 16, 24, 8),
                                          child: Text(
                                            "FILES",
                                            style: TextStyle(
                                              color: Colors.grey,
                                              fontSize: 11,
                                              fontWeight: FontWeight.w600,
                                              letterSpacing: 1.2,
                                            ),
                                          ),
                                        ),
                                    ],
                                  );
                                }
                                
                                final fileIndex = _nearbyDevices.isNotEmpty ? index - 1 : index;
                                // Handle case where we have devices but no files (index 0 is devices, index 1 would be invalid if files empty)
                                if (fileIndex >= _files.length) return const SizedBox.shrink();

                                final file = _files[fileIndex];
                                final fileSizeMB = (file.size / (1024 * 1024)).toStringAsFixed(2);
                                
                                return Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                                  child: Container(
                                    decoration: BoxDecoration(
                                      color: Colors.white.withOpacity(0.03),
                                      borderRadius: BorderRadius.circular(12),
                                      border: Border.all(
                                        color: Colors.white.withOpacity(0.05),
                                      ),
                                    ),
                                    child: ListTile(
                                      leading: Container(
                                        padding: const EdgeInsets.all(8),
                                        decoration: BoxDecoration(
                                          color: kAccentYellow.withOpacity(0.1),
                                          borderRadius: BorderRadius.circular(8),
                                        ),
                                        child: const Icon(
                                          Icons.insert_drive_file,
                                          color: kAccentYellow,
                                          size: 24,
                                        ),
                                      ),
                                      title: Text(
                                        file.name,
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontWeight: FontWeight.w500,
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      subtitle: Text(
                                        "$fileSizeMB MB",
                                        style: const TextStyle(
                                          color: Colors.grey,
                                          fontSize: 12,
                                        ),
                                      ),
                                      trailing: MouseRegion(
                                        cursor: SystemMouseCursors.click,
                                        child: IconButton(
                                          icon: const Icon(Icons.close, color: Colors.red),
                                          onPressed: () {
                                            setState(() => _files.removeAt(fileIndex));
                                          },
                                        ),
                                      ),
                                    ),
                                  ),
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
            ),

        ],
      ),
    );
  }
}
