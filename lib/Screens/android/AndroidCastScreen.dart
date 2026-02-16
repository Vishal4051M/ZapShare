import 'dart:math';
import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:saf_util/saf_util.dart';
import '../../services/device_discovery_service.dart';
import '../../widgets/cast_remote_control.dart';

enum CastMode { video, screenMirror }

class AndroidCastScreen extends StatefulWidget {
  const AndroidCastScreen({super.key});

  @override
  State<AndroidCastScreen> createState() => _AndroidCastScreenState();
}

class _AndroidCastScreenState extends State<AndroidCastScreen>
    with SingleTickerProviderStateMixin {
  final DeviceDiscoveryService _discoveryService = DeviceDiscoveryService();
  final NetworkInfo _networkInfo = NetworkInfo();
  final _safUtil = SafUtil();
  static const _channel = MethodChannel('zapshare.saf');

  List<DiscoveredDevice> _devices = [];
  bool _isScanning = false;

  // Mode toggle
  CastMode _mode = CastMode.video;

  // File details (video cast)
  String? _selectedUri;
  String? _selectedFileName;

  String? _serverUrl;
  bool _isServerRunning = false;

  late AnimationController _scanController;
  StreamSubscription? _devicesSubscription;
  StreamSubscription<CastAck>? _castAckSubscription;

  // Cast session state
  String? _castTargetIp;
  String? _castTargetName;

  // Screen mirror state
  bool _isMirroring = false;
  bool _isMirrorRequesting = false;
  int? _mirrorServerPort;
  String? _mirrorLocalIp;
  String? _mirrorTargetIp;
  String? _mirrorTargetName;
  StreamSubscription<ScreenMirrorControl>? _mirrorControlSubscription;

  @override
  void initState() {
    super.initState();
    _scanController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();

    _initDiscovery();
  }

  Future<void> _initDiscovery() async {
    await _discoveryService.initialize();
    _devicesSubscription = _discoveryService.devicesStream.listen((devices) {
      if (mounted) {
        setState(() {
          _devices = devices;
        });
      }
    });

    // Listen for cast acknowledgements from the receiver
    _castAckSubscription = _discoveryService.castAckStream.listen((ack) {
      if (!mounted) return;
      if (ack.accepted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                const Icon(Icons.check_circle_rounded, color: Colors.black),
                const SizedBox(width: 12),
                Expanded(child: Text('${ack.deviceName} accepted cast',
                  style: const TextStyle(color: Colors.black))),
              ],
            ),
            backgroundColor: const Color(0xFFFFD600),
            behavior: SnackBarBehavior.floating,
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${ack.deviceName} declined cast'),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
          ),
        );
        // Clear cast target since receiver declined
        setState(() {
          _castTargetIp = null;
          _castTargetName = null;
        });
      }
    });

    _startScanning();
  }

  Future<void> _startScanning() async {
    setState(() => _isScanning = true);
    await _discoveryService.start();
  }

  Future<void> _stopScanning() async {
    setState(() => _isScanning = false);
    await _discoveryService.stop();
  }

  Future<void> _pickVideo() async {
    try {
      final result = await _safUtil.pickFiles(
        multiple: false,
        mimeTypes: ['video/*'],
      );

      if (result != null && result.isNotEmpty) {
        final docFile = result.first;

        // Stop previous server if any
        await _stopServer();

        setState(() {
          _selectedUri = docFile.uri;
          _selectedFileName = docFile.name;
        });

        // Start new server
        await _startServer();
      }
    } catch (e) {
      print('Error picking file: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error picking file: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _stopServer() async {
    if (_isServerRunning) {
      try {
        await _channel.invokeMethod('stopVideoServer');
        await _channel.invokeMethod('stopForegroundService');
        setState(() {
          _isServerRunning = false;
          _serverUrl = null;
        });
      } catch (e) {
        print('Error stopping server: $e');
      }
    }
  }

  Future<void> _startServer() async {
    if (_selectedUri == null) return;

    try {
      // Get local IP address
      String? ip = await _networkInfo.getWifiIP();

      if (ip == null) {
        final interfaces = await NetworkInterface.list();
        for (var interface in interfaces) {
          if (interface.name.toLowerCase().contains('loopback')) continue;
          for (var addr in interface.addresses) {
            if (addr.type == InternetAddressType.IPv4 && !addr.isLoopback) {
              ip = addr.address;
              break;
            }
          }
          if (ip != null) break;
        }
      }

      if (ip == null) throw Exception('Could not determine local IP address. Please ensure you are connected to WiFi.');

      // Start Native Foreground Service first
      try {
        await _channel.invokeMethod('startForegroundService', {
          'title': 'Casting Video',
          'content': 'ZapShare is streaming ${_selectedFileName ?? "video"}',
        });
      } catch (e) {
        print('⚠️ Foreground service start warning: $e');
        // Continue anyway - service may already be running
      }

      // Start Native Server with retry
      int? port;
      String lastError = 'Unknown error';
      for (int attempt = 0; attempt < 3; attempt++) {
        try {
          port = await _channel.invokeMethod<int>('startVideoServer', {
            'files': [
              {'uri': _selectedUri!, 'name': _selectedFileName ?? 'video.mp4'},
            ],
          });
          if (port != null && port > 0) break;
        } catch (e) {
          lastError = e.toString();
          print('⚠️ Server start attempt ${attempt + 1} failed: $e');
          if (attempt < 2) {
            // Try stopping any existing server before retry
            try {
              await _channel.invokeMethod('stopVideoServer');
            } catch (_) {}
            await Future.delayed(const Duration(milliseconds: 500));
          }
        }
      }

      if (port == null || port <= 0) throw Exception('Server started but port is invalid. $lastError');

      _serverUrl = 'http://$ip:$port/video/0';
      _isServerRunning = true;

      setState(() {});

      print('🚀 Native Video Server started at $_serverUrl');
    } catch (e) {
      print('❌ Error starting server: $e');
      setState(() {
        _selectedUri = null; // Reset selection on failure
        _isServerRunning = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Could not start server', style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                Text('${e.toString().length > 80 ? '${e.toString().substring(0, 80)}...' : e}',
                  style: const TextStyle(fontSize: 12)),
              ],
            ),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 5),
          ),
        );
      }
    }
  }

  Future<void> _castToDevice(DiscoveredDevice device) async {
    if (_selectedUri == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please select a video first'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    if (!_isServerRunning || _serverUrl == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Server is not running. Try selecting the file again.'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    try {
      // Send Cast URL to the device via Discovery Service
      await _discoveryService.sendCastUrl(device.ipAddress, _serverUrl!, fileName: _selectedFileName);

      if (!mounted) return;

      setState(() {
        _castTargetIp = device.ipAddress;
        _castTargetName = device.deviceName;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const Icon(Icons.cast_connected_rounded, color: Colors.black),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Casting to ${device.deviceName}...',
                  style: GoogleFonts.outfit(color: Colors.black),
                ),
              ),
            ],
          ),
          backgroundColor: const Color(0xFFFFD600),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to cast: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  // ─── Screen Mirror Methods ─────────────────────────────────

  Future<String?> _getLocalIp() async {
    try {
      final ip = await _networkInfo.getWifiIP();
      if (ip != null && ip.isNotEmpty) return ip;
    } catch (_) {}
    try {
      final interfaces = await NetworkInterface.list();
      for (var iface in interfaces) {
        for (var addr in iface.addresses) {
          if (addr.type == InternetAddressType.IPv4 && !addr.isLoopback) {
            return addr.address;
          }
        }
      }
    } catch (_) {}
    return null;
  }

  Future<void> _startScreenMirror(DiscoveredDevice device) async {
    print('\n🪞 ═══════════════════════════════════════════════════');
    print('🪞 [ScreenMirror] START - Target: ${device.deviceName} (${device.ipAddress})');
    print('🪞 [ScreenMirror] Target platform: ${device.platform}');
    print('🪞 [ScreenMirror] Timestamp: ${DateTime.now().toIso8601String()}');
    print('🪞 ═══════════════════════════════════════════════════');
    setState(() => _isMirrorRequesting = true);

    try {
      // Step 1: Stop any existing mirror session first (cleanup)
      print('🪞 [ScreenMirror] Step 1: Stopping any existing mirror session...');
      try {
        await _channel.invokeMethod('stopScreenMirror');
        await Future.delayed(const Duration(milliseconds: 500));
        print('🪞 [ScreenMirror] Step 1: Cleanup done');
      } catch (e) {
        print('🪞 [ScreenMirror] Step 1: No previous session (ignore): $e');
      }

      // Step 2: Request microphone permission (for audio capture)
      print('🪞 [ScreenMirror] Step 2: Requesting microphone permission for audio capture...');
      try {
        final micStatus = await Permission.microphone.request();
        print('🪞 [ScreenMirror] Step 2: Microphone permission = $micStatus');
        if (!micStatus.isGranted) {
          print('🪞 [ScreenMirror] Step 2: Microphone denied - audio will not be shared');
        }
      } catch (e) {
        print('🪞 [ScreenMirror] Step 2: Microphone permission request failed: $e');
      }

      // Step 3: Request screen capture permission
      print('🪞 [ScreenMirror] Step 3: Requesting screen capture permission...');
      bool granted = false;
      try {
        granted = await _channel.invokeMethod('requestScreenCapture');
        print('🪞 [ScreenMirror] Step 3: Permission result = $granted');
      } catch (e) {
        print('❌ [ScreenMirror] Step 3: Screen capture request FAILED: $e');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Screen capture request failed: ${e.toString().contains('SecurityException') ? 'Permission denied by system' : e}'),
              backgroundColor: Colors.red,
              behavior: SnackBarBehavior.floating,
            ),
          );
          setState(() => _isMirrorRequesting = false);
        }
        return;
      }

      if (!granted) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Screen capture permission denied'),
              backgroundColor: Colors.red,
              behavior: SnackBarBehavior.floating,
            ),
          );
          setState(() => _isMirrorRequesting = false);
        }
        return;
      }

      // Step 3: Wait for service and get port (poll with retries, longer timeout)
      print('🪞 [ScreenMirror] Step 3: Polling for screen mirror port (up to 25 attempts)...');
      int port = 0;
      String lastError = 'Server did not start in time';
      for (int attempt = 0; attempt < 25; attempt++) {
        await Future.delayed(const Duration(milliseconds: 500));
        try {
          final result = await _channel.invokeMethod('getScreenMirrorPort');
          print('🪞 [ScreenMirror] Step 3: Attempt $attempt - getScreenMirrorPort returned: $result (type: ${result.runtimeType})');
          if (result is int && result > 0) {
            port = result;
            print('🪞 [ScreenMirror] Step 3: Got valid port = $port on attempt $attempt');
            break;
          }
          // Check if there's an error message from native
          if (result is int && result == -1) {
            lastError = 'Native server returned error code -1';
            print('🪞 [ScreenMirror] Step 3: Native returned -1 error on attempt $attempt');
          }
        } catch (e) {
          lastError = e.toString();
          print('⚠️ [ScreenMirror] Step 3: getScreenMirrorPort attempt $attempt FAILED: $e');
        }
      }
      if (port <= 0) {
        // Try one more time: restart the service and try again
        print('⚠️ [ScreenMirror] Step 3: All 25 attempts failed. Last error: $lastError');
        print('⚠️ [ScreenMirror] Step 3: Retrying - will restart screen mirror service...');
        try {
          await _channel.invokeMethod('stopScreenMirror');
          await Future.delayed(const Duration(milliseconds: 1000));
          print('⚠️ [ScreenMirror] Step 3: Retry - requesting screen capture again...');
          await _channel.invokeMethod('requestScreenCapture');
          await Future.delayed(const Duration(milliseconds: 2000));
          final retryPort = await _channel.invokeMethod('getScreenMirrorPort');
          print('⚠️ [ScreenMirror] Step 3: Retry - getScreenMirrorPort returned: $retryPort');
          if (retryPort is int && retryPort > 0) {
            port = retryPort;
            print('⚠️ [ScreenMirror] Step 3: Retry SUCCESS - port = $port');
          } else {
            print('⚠️ [ScreenMirror] Step 3: Retry FAILED - invalid port: $retryPort');
          }
        } catch (e) {
          lastError = 'Retry also failed: $e';
          print('❌ [ScreenMirror] Step 3: Retry EXCEPTION: $e');
        }
      }
      if (port <= 0) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Failed to start screen mirror server',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  Text('Reason: $lastError',
                    style: const TextStyle(fontSize: 12)),
                  const SizedBox(height: 4),
                  const Text('Try: Restart the app or check if another app is using screen capture',
                    style: TextStyle(fontSize: 11)),
                ],
              ),
              backgroundColor: Colors.red,
              behavior: SnackBarBehavior.floating,
              duration: const Duration(seconds: 6),
            ),
          );
          setState(() => _isMirrorRequesting = false);
        }
        return;
      }

      // Step 4: Get local IP (try multiple methods)
      print('🪞 [ScreenMirror] Step 4: Getting local IP address...');
      final ip = await _getLocalIp();
      print('🪞 [ScreenMirror] Step 4: Local IP = $ip');
      if (ip == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Could not determine local IP address. Make sure you are connected to WiFi.'),
              backgroundColor: Colors.red,
              behavior: SnackBarBehavior.floating,
              duration: Duration(seconds: 4),
            ),
          );
          setState(() => _isMirrorRequesting = false);
        }
        return;
      }

      // Step 5: Verify the server is actually reachable before sending to target
      final streamUrl = 'http://$ip:$port/stream';
      print('🪞 [ScreenMirror] Step 5: Stream URL = $streamUrl');
      print('🪞 [ScreenMirror] Step 5: Verifying server reachability at $ip:$port...');
      bool serverReachable = false;
      try {
        final testSocket = await Socket.connect(ip, port, timeout: const Duration(seconds: 3));
        testSocket.destroy();
        serverReachable = true;
        print('🪞 [ScreenMirror] Step 5: Server IS reachable ✅');
      } catch (e) {
        print('⚠️ [ScreenMirror] Step 5: Server reachability check FAILED: $e');
      }

      if (!serverReachable) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text('Screen mirror server started but is not reachable. Check firewall settings.'),
              backgroundColor: Colors.orange,
              behavior: SnackBarBehavior.floating,
              duration: const Duration(seconds: 4),
            ),
          );
        }
        // Continue anyway - the target device might still be able to reach it
      }

      // Step 6: Send screen mirror request to target device
      print('🪞 [ScreenMirror] Step 6: Sending screen mirror request to ${device.ipAddress}...');
      print('🪞 [ScreenMirror] Step 6: streamUrl=$streamUrl, targetIp=${device.ipAddress}');
      await _discoveryService.sendScreenMirrorRequest(
        device.ipAddress,
        streamUrl,
      );
      print('🪞 [ScreenMirror] Step 6: sendScreenMirrorRequest() completed ✅');

      if (mounted) {
        setState(() {
          _isMirroring = true;
          _isMirrorRequesting = false;
          _mirrorServerPort = port;
          _mirrorLocalIp = ip;
          _mirrorTargetIp = device.ipAddress;
          _mirrorTargetName = device.deviceName;
        });

        // Start listening for remote control commands from the viewer
        _mirrorControlSubscription = _discoveryService.screenMirrorControlStream.listen((control) {
          _handleMirrorControl(control);
        });

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                const Icon(Icons.screen_share_rounded, color: Colors.black),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Screen mirror sent to ${device.deviceName}',
                    style: const TextStyle(color: Colors.black),
                  ),
                ),
              ],
            ),
            backgroundColor: const Color(0xFFFFD600),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } on PlatformException catch (e) {
      print('❌ Platform error starting screen mirror: ${e.code} - ${e.message}');
      if (mounted) {
        String userMessage = 'Screen mirror failed';
        if (e.code == 'PERMISSION_DENIED') {
          userMessage = 'Screen capture permission was denied by the system';
        } else if (e.code == 'SERVICE_ERROR') {
          userMessage = 'Screen capture service failed to start. Try restarting the app.';
        } else if (e.message != null) {
          userMessage = 'Error: ${e.message}';
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(userMessage),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 4),
          ),
        );
        setState(() => _isMirrorRequesting = false);
      }
    } catch (e) {
      print('❌ Error starting screen mirror: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Screen mirror error: ${e.toString().length > 100 ? '${e.toString().substring(0, 100)}...' : e}'),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 4),
          ),
        );
        setState(() => _isMirrorRequesting = false);
      }
    }
  }

  Future<void> _stopScreenMirror() async {
    _mirrorControlSubscription?.cancel();
    _mirrorControlSubscription = null;
    try {
      await _channel.invokeMethod('stopScreenMirror');
    } catch (e) {
      print('Error stopping screen mirror: $e');
    }
    if (mounted) {
      setState(() {
        _isMirroring = false;
        _mirrorServerPort = null;
        _mirrorLocalIp = null;
        _mirrorTargetIp = null;
        _mirrorTargetName = null;
      });
    }
  }

  void _handleMirrorControl(ScreenMirrorControl control) {
    // Forward the control action to the native platform
    _channel.invokeMethod('mirrorControl', {
      'action': control.action,
      if (control.tapX != null) 'tapX': control.tapX,
      if (control.tapY != null) 'tapY': control.tapY,
      if (control.endX != null) 'endX': control.endX,
      if (control.endY != null) 'endY': control.endY,
      if (control.text != null) 'text': control.text,
      if (control.scrollDelta != null) 'scrollDelta': control.scrollDelta,
      if (control.duration != null) 'duration': control.duration,
    });
  }

  @override
  void dispose() {
    _stopServer();
    if (_isMirroring) {
      _channel.invokeMethod('stopScreenMirror');
    }
    _mirrorControlSubscription?.cancel();
    _scanController.dispose();
    _devicesSubscription?.cancel();
    _castAckSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Hero(
      tag: 'cast_card_container',
      child: Material(
        type: MaterialType.transparency,
        child: Scaffold(
          backgroundColor: const Color(0xFFEDEDED),
          appBar: AppBar(
            title: Text(
              'Cast',
              style: GoogleFonts.outfit(
                color: const Color(0xFF2C2C2E),
                fontWeight: FontWeight.w700,
                fontSize: 20,
              ),
            ),
            centerTitle: true,
            backgroundColor: const Color(0xFFEDEDED),
            elevation: 0,
            leading: IconButton(
              icon: const Icon(
                Icons.arrow_back_ios_new_rounded,
                color: Color(0xFF2C2C2E),
              ),
              onPressed: () => Navigator.pop(context),
            ),
            actions: [
              IconButton(
                icon: Icon(
                  _isScanning
                      ? Icons.stop_circle_outlined
                      : Icons.refresh_rounded,
                  color:
                      _isScanning ? Colors.redAccent : const Color(0xFF2C2C2E),
                ),
                tooltip: _isScanning ? 'Stop Scanning' : 'Refresh Devices',
                onPressed: _isScanning ? _stopScanning : _startScanning,
              ),
            ],
          ),
          body: SafeArea(
            child: CustomScrollView(
              slivers: [
                // Mode Toggle
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(24, 8, 24, 4),
                    child: Container(
                      height: 44,
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.06),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: GestureDetector(
                              onTap: () => setState(() => _mode = CastMode.video),
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 200),
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  color: _mode == CastMode.video
                                      ? const Color(0xFF2C2C2E)
                                      : Colors.transparent,
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                margin: const EdgeInsets.all(3),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(
                                      Icons.cast_rounded,
                                      size: 16,
                                      color: _mode == CastMode.video
                                          ? Colors.white
                                          : Colors.grey[600],
                                    ),
                                    const SizedBox(width: 6),
                                    Text(
                                      'Cast Video',
                                      style: GoogleFonts.outfit(
                                        color: _mode == CastMode.video
                                            ? Colors.white
                                            : Colors.grey[600],
                                        fontWeight: FontWeight.w600,
                                        fontSize: 13,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          Expanded(
                            child: GestureDetector(
                              onTap: () => setState(() => _mode = CastMode.screenMirror),
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 200),
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  color: _mode == CastMode.screenMirror
                                      ? const Color(0xFF2C2C2E)
                                      : Colors.transparent,
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                margin: const EdgeInsets.all(3),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(
                                      Icons.screen_share_rounded,
                                      size: 16,
                                      color: _mode == CastMode.screenMirror
                                          ? Colors.white
                                          : Colors.grey[600],
                                    ),
                                    const SizedBox(width: 6),
                                    Text(
                                      'Screen Mirror',
                                      style: GoogleFonts.outfit(
                                        color: _mode == CastMode.screenMirror
                                            ? Colors.white
                                            : Colors.grey[600],
                                        fontWeight: FontWeight.w600,
                                        fontSize: 13,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),

                // Screen Mirror Mode: Active mirroring card
                if (_mode == CastMode.screenMirror && _isMirroring)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
                      child: Container(
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFFD600).withOpacity(0.12),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: const Color(0xFFFFD600).withOpacity(0.3),
                          ),
                        ),
                        child: Column(
                          children: [
                            Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(10),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFFFD600).withOpacity(0.2),
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: const Icon(
                                    Icons.cast_connected_rounded,
                                    color: Color(0xFF2C2C2E),
                                    size: 24,
                                  ),
                                ),
                                const SizedBox(width: 14),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'Screen Mirroring Active',
                                        style: GoogleFonts.outfit(
                                          color: const Color(0xFF2C2C2E),
                                          fontWeight: FontWeight.w700,
                                          fontSize: 15,
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        'Casting to ${_mirrorTargetName ?? 'device'}',
                                        style: GoogleFonts.outfit(
                                          color: Colors.grey[600],
                                          fontSize: 13,
                                        ),
                                      ),
                                      if (_mirrorLocalIp != null && _mirrorServerPort != null)
                                        Text(
                                          '$_mirrorLocalIp:$_mirrorServerPort',
                                          style: GoogleFonts.outfit(
                                            color: Colors.grey[500],
                                            fontSize: 11,
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 14),
                            SizedBox(
                              width: double.infinity,
                              child: ElevatedButton.icon(
                                onPressed: _stopScreenMirror,
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.red.withOpacity(0.12),
                                  foregroundColor: Colors.red,
                                  elevation: 0,
                                  padding: const EdgeInsets.symmetric(vertical: 12),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                    side: BorderSide(color: Colors.red.withOpacity(0.3)),
                                  ),
                                ),
                                icon: const Icon(Icons.stop_rounded, size: 20),
                                label: Text(
                                  'Stop Mirroring',
                                  style: GoogleFonts.outfit(fontWeight: FontWeight.w700),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),

                // Screen Mirror Mode: Instruction banner
                if (_mode == CastMode.screenMirror && !_isMirroring)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
                      child: Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFFD600).withOpacity(0.08),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: const Color(0xFFFFD600).withOpacity(0.2),
                          ),
                        ),
                        child: Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: const Color(0xFFFFD600).withOpacity(0.15),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: const Icon(
                                Icons.screen_share_rounded,
                                color: Color(0xFF2C2C2E),
                                size: 22,
                              ),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Share Your Screen',
                                    style: GoogleFonts.outfit(
                                      color: const Color(0xFF2C2C2E),
                                      fontWeight: FontWeight.w700,
                                      fontSize: 14,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    'Tap a device to mirror your screen in real-time',
                                    style: GoogleFonts.outfit(
                                      color: Colors.grey[600],
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),

                // Video Cast Mode content
                if (_mode == CastMode.video)
                SliverToBoxAdapter(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 1. Video Selection Area
                      Container(
                        padding: const EdgeInsets.all(24),
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.5),
                          border: Border(
                            bottom: BorderSide(
                              color: Colors.black.withOpacity(0.05),
                            ),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'SOURCE MEDIA',
                              style: GoogleFonts.outfit(
                                color: Colors.grey[600],
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 1.2,
                              ),
                            ),
                            const SizedBox(height: 16),
                            GestureDetector(
                              onTap: _pickVideo,
                              child: Container(
                                height: 160,
                                width: double.infinity,
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(24),
                                  border: Border.all(
                                    color:
                                        _selectedUri != null
                                            ? const Color(0xFFFFD600)
                                            : Colors.grey[300]!,
                                    width: 2,
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withOpacity(0.05),
                                      blurRadius: 10,
                                      offset: const Offset(0, 4),
                                    ),
                                  ],
                                ),
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(
                                      _selectedUri != null
                                          ? Icons.movie_creation_rounded
                                          : Icons.add_circle_outline_rounded,
                                      size: 48,
                                      color:
                                          _selectedUri != null
                                              ? const Color(0xFFFFD600)
                                              : Colors.grey[400],
                                    ),
                                    const SizedBox(height: 16),
                                    Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 24,
                                      ),
                                      child: Text(
                                        _selectedFileName ??
                                            'Select Video File',
                                        style: GoogleFonts.outfit(
                                          color:
                                              _selectedUri != null
                                                  ? Colors.black
                                                  : Colors.grey[500],
                                          fontSize: 16,
                                          fontWeight:
                                              _selectedUri != null
                                                  ? FontWeight.w600
                                                  : FontWeight.w500,
                                        ),
                                        textAlign: TextAlign.center,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    if (_selectedUri != null)
                                      Padding(
                                        padding: const EdgeInsets.only(top: 8),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Container(
                                              width: 8,
                                              height: 8,
                                              decoration: const BoxDecoration(
                                                color: Colors.green,
                                                shape: BoxShape.circle,
                                              ),
                                            ),
                                            const SizedBox(width: 8),
                                            Text(
                                              'Ready to cast',
                                              style: GoogleFonts.outfit(
                                                color: Colors.green,
                                                fontSize: 12,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),

                      // 1.5 Streaming URL Display
                      if (_isServerRunning && _serverUrl != null)
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 24,
                            vertical: 12,
                          ),
                          child: Container(
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: const Color(0xFFFFD600).withOpacity(0.1),
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: const Color(0xFFFFD600).withOpacity(0.3),
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    const Icon(
                                      Icons.cast_rounded,
                                      color: Colors.black87,
                                      size: 20,
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                      'Streaming Active',
                                      style: GoogleFonts.outfit(
                                        color: Colors.black87,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 14,
                                      ),
                                    ),
                                    const Spacer(),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 4,
                                      ),
                                      decoration: BoxDecoration(
                                        color: const Color(
                                          0xFFFFD600,
                                        ).withOpacity(0.2),
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      child: Text(
                                        'Background On',
                                        style: GoogleFonts.outfit(
                                          color: Colors.black87,
                                          fontSize: 10,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 12),
                                Container(
                                  padding: const EdgeInsets.all(12),
                                  decoration: BoxDecoration(
                                    color: Colors.white,
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(
                                      color: Colors.grey[200]!,
                                    ),
                                  ),
                                  child: Row(
                                    children: [
                                      const Icon(
                                        Icons.link_rounded,
                                        color: Colors.grey,
                                        size: 18,
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: SelectableText(
                                          _serverUrl!,
                                          style: GoogleFonts.outfit(
                                            color: Colors.black87,
                                            fontSize: 13,
                                            fontWeight: FontWeight.w500,
                                          ),
                                        ),
                                      ),
                                      InkWell(
                                        onTap: () {
                                          Clipboard.setData(
                                            ClipboardData(text: _serverUrl!),
                                          );
                                          ScaffoldMessenger.of(
                                            context,
                                          ).showSnackBar(
                                            const SnackBar(
                                              content: Text(
                                                'Copied to clipboard',
                                              ),
                                              duration: Duration(seconds: 1),
                                            ),
                                          );
                                        },
                                        child: const Padding(
                                          padding: EdgeInsets.all(4.0),
                                          child: Icon(
                                            Icons.copy_rounded,
                                            color: Color(0xFFFFD600),
                                            size: 18,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),

                      // Remote control (shown after casting)
                      if (_castTargetIp != null)
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
                          child: CastRemoteControlWidget(
                            targetDeviceIp: _castTargetIp!,
                            targetDeviceName: _castTargetName ?? 'Device',
                            fileName: _selectedFileName ?? 'Unknown',
                            onDisconnect: () {
                              setState(() {
                                _castTargetIp = null;
                                _castTargetName = null;
                              });
                            },
                          ),
                        ),

                      // 2. Discovery Section Header (video cast)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(24, 24, 24, 12),
                        child: Row(
                          children: [
                            if (_isScanning)
                              Padding(
                                padding: const EdgeInsets.only(right: 12),
                                child: Icon(
                                  Icons.wifi_find_rounded,
                                  color: const Color(0xFF2C2C2E),
                                  size: 18,
                                ),
                              ),
                            Text(
                              'NEARBY DEVICES',
                              style: GoogleFonts.outfit(
                                color: Colors.grey[600],
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 1.2,
                              ),
                            ),
                            const Spacer(),
                            if (_devices.isNotEmpty)
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.black.withOpacity(0.05),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Text(
                                  '${_devices.length} Found',
                                  style: GoogleFonts.outfit(
                                    color: Colors.black87,
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),

                // Screen Mirror Mode: Discovery Header
                if (_mode == CastMode.screenMirror)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(24, 16, 24, 12),
                      child: Row(
                        children: [
                          if (_isScanning)
                            Padding(
                              padding: const EdgeInsets.only(right: 12),
                              child: Icon(
                                Icons.wifi_find_rounded,
                                color: const Color(0xFF2C2C2E),
                                size: 18,
                              ),
                            ),
                          Text(
                            'NEARBY DEVICES',
                            style: GoogleFonts.outfit(
                              color: Colors.grey[600],
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 1.2,
                            ),
                          ),
                          const Spacer(),
                          if (_devices.isNotEmpty)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.black.withOpacity(0.05),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Text(
                                '${_devices.length} Found',
                                style: GoogleFonts.outfit(
                                  color: Colors.black87,
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),

                // 3. Device List
                if (_devices.isEmpty)
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (_isScanning)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 20),
                              child: _RippleEffect(
                                size: 140,
                                color: const Color(0xFFFFD600),
                              ),
                            )
                          else
                            Icon(
                              Icons.search_off_rounded,
                              size: 64,
                              color: Colors.grey[300],
                            ),
                          const SizedBox(height: 24),
                          Text(
                            _isScanning
                                ? 'Scanning for devices...'
                                : 'No devices found',
                            style: GoogleFonts.outfit(
                              color: Colors.grey[500],
                              fontSize: 16,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          if (!_isScanning)
                            Padding(
                              padding: const EdgeInsets.only(top: 16),
                              child: TextButton.icon(
                                onPressed: _startScanning,
                                icon: const Icon(
                                  Icons.refresh_rounded,
                                  color: Color(0xFF2C2C2E),
                                ),
                                label: Text(
                                  'Try Again',
                                  style: GoogleFonts.outfit(
                                    color: const Color(0xFF2C2C2E),
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  )
                else
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 24,
                      vertical: 8,
                    ),
                    sliver: SliverList(
                      delegate: SliverChildBuilderDelegate((context, index) {
                        final device = _devices[index];
                        // Determine icon based on platform
                        IconData platformIcon = Icons.devices_other_rounded;
                        Color platformColor = const Color(0xFF2C2C2E);

                        switch (device.platform.toLowerCase()) {
                          case 'android':
                            platformIcon = Icons.phone_android_rounded;
                            platformColor = Colors.green;
                            break;
                          case 'windows':
                            platformIcon = Icons.desktop_windows_rounded;
                            platformColor = Colors.blue;
                            break;
                          case 'ios':
                          case 'macos':
                            platformIcon = Icons.apple;
                            platformColor = Colors.grey;
                            break;
                          default:
                            platformIcon = Icons.laptop;
                        }

                        return Container(
                          margin: const EdgeInsets.only(bottom: 12),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: Colors.grey[200]!),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.03),
                                blurRadius: 8,
                                offset: const Offset(0, 2),
                              ),
                            ],
                          ),
                          child: Material(
                            color: Colors.transparent,
                            child: InkWell(
                              borderRadius: BorderRadius.circular(20),
                              onTap: () => _mode == CastMode.video
                                  ? _castToDevice(device)
                                  : _startScreenMirror(device),
                              child: Padding(
                                padding: const EdgeInsets.all(16),
                                child: Row(
                                  children: [
                                    Container(
                                      width: 48,
                                      height: 48,
                                      decoration: BoxDecoration(
                                        color: platformColor.withOpacity(0.1),
                                        borderRadius: BorderRadius.circular(14),
                                      ),
                                      child: Icon(
                                        platformIcon,
                                        color: platformColor,
                                        size: 24,
                                      ),
                                    ),
                                    const SizedBox(width: 16),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            device.deviceName,
                                            style: GoogleFonts.outfit(
                                              color: Colors.black,
                                              fontSize: 16,
                                              fontWeight: FontWeight.w600,
                                            ),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                          const SizedBox(height: 4),
                                          Row(
                                            children: [
                                              Text(
                                                device.ipAddress,
                                                style: GoogleFonts.outfit(
                                                  color: Colors.grey[500],
                                                  fontSize: 12,
                                                ),
                                              ),
                                              const SizedBox(width: 8),
                                              if (device.isOnline)
                                                Container(
                                                  width: 6,
                                                  height: 6,
                                                  decoration:
                                                      const BoxDecoration(
                                                        color: Colors.green,
                                                        shape: BoxShape.circle,
                                                      ),
                                                ),
                                            ],
                                          ),
                                        ],
                                      ),
                                    ),
                                    if (_isMirrorRequesting && _mode == CastMode.screenMirror)
                                      const SizedBox(
                                        width: 24,
                                        height: 24,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          color: Color(0xFFFFD600),
                                        ),
                                      )
                                    else if (_mirrorTargetIp == device.ipAddress && _mode == CastMode.screenMirror)
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 14,
                                          vertical: 8,
                                        ),
                                        decoration: BoxDecoration(
                                          color: const Color(0xFFFFD600),
                                          borderRadius: BorderRadius.circular(12),
                                        ),
                                        child: const Icon(
                                          Icons.cast_connected_rounded,
                                          color: Colors.black,
                                          size: 20,
                                        ),
                                      )
                                    else
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 14,
                                          vertical: 8,
                                        ),
                                        decoration: BoxDecoration(
                                          color: const Color(0xFF2C2C2E),
                                          borderRadius: BorderRadius.circular(12),
                                          boxShadow: [
                                            BoxShadow(
                                              color: const Color(
                                                0xFF2C2C2E,
                                              ).withOpacity(0.2),
                                              blurRadius: 8,
                                              offset: const Offset(0, 2),
                                            ),
                                          ],
                                        ),
                                        child: Icon(
                                          _mode == CastMode.video
                                              ? Icons.cast_connected_rounded
                                              : Icons.screen_share_rounded,
                                          color: Colors.white,
                                          size: 20,
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        );
                      }, childCount: _devices.length),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RippleEffect extends StatefulWidget {
  final double size;
  final Color color;

  const _RippleEffect({super.key, this.size = 300, this.color = Colors.black});

  @override
  State<_RippleEffect> createState() => _RippleEffectState();
}

class _RippleEffectState extends State<_RippleEffect>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  // Constants
  static const int _ringCount = 3;
  static const Duration _duration = Duration(milliseconds: 3000);

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: _duration)
      ..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: SizedBox(
        width: widget.size,
        height: widget.size,
        child: AnimatedBuilder(
          animation: _controller,
          builder:
              (_, __) => CustomPaint(
                painter: _PulsePainter(
                  progress: _controller.value,
                  color: widget.color,
                ),
                isComplex: false,
                willChange: true,
              ),
        ),
      ),
    );
  }
}

class _PulsePainter extends CustomPainter {
  final double progress;
  final Color color;

  const _PulsePainter({required this.progress, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxRadius = size.width / 2;

    // 3 rings with phase offset
    for (int i = 0; i < 3; i++) {
      final p = (progress + i / 3) % 1.0;

      // EaseOutCubic inline
      final eased = 1.0 - (1.0 - p) * (1.0 - p) * (1.0 - p);

      // Radius: 20% to 100%
      final radius = maxRadius * (0.2 + eased * 0.8);

      // Opacity: inverse square + edge fade
      final d = (radius / maxRadius).clamp(0.3, 1.0);
      final opacity = ((0.3 / (d * d)) * (1.0 - p * p)).clamp(0.0, 0.35);

      // Stroke: 2.5 → 0.5
      final stroke = 2.5 - eased * 2.0;

      if (opacity > 0.02) {
        canvas.drawCircle(
          center,
          radius,
          Paint()
            ..color = color.withOpacity(opacity)
            ..style = PaintingStyle.stroke
            ..strokeWidth = stroke,
        );
      }
    }

    // Center dot with subtle breathing (derived from main progress)
    final breathe = (0.5 + 0.5 * sin(progress * 2 * 3.14159)).abs();
    final dotR = size.width * 0.05 * (0.9 + breathe * 0.2);

    // Glow
    canvas.drawCircle(
      center,
      dotR * 1.6,
      Paint()
        ..color = color.withOpacity(0.12)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
    );

    // Dot
    canvas.drawCircle(center, dotR, Paint()..color = color.withOpacity(0.3));
  }

  @override
  bool shouldRepaint(_PulsePainter old) => old.progress != progress;
}
