import 'dart:io';
import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:saf_util/saf_util.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:file_picker/file_picker.dart';
import 'package:zap_share/widgets/tv_widgets.dart';
import 'package:zap_share/services/device_discovery_service.dart';
import 'package:zap_share/widgets/CustomAvatarWidget.dart';
import 'package:zap_share/widgets/SearchPulseWidget.dart';

class TvSendScreen extends StatefulWidget {
  const TvSendScreen({super.key});

  @override
  State<TvSendScreen> createState() => _TvSendScreenState();
}

class _TvSendScreenState extends State<TvSendScreen> {
  final SafUtil _safUtil = SafUtil();
  final NetworkInfo _networkInfo = NetworkInfo();
  final DeviceDiscoveryService _discoveryService = DeviceDiscoveryService();
  static const _channel = MethodChannel('zapshare.saf');

  final List<Map<String, String>> _selectedFiles = [];
  String? _serverUrl;
  String? _displayCode;
  bool _isSharing = false;

  List<DiscoveredDevice> _nearbyDevices = [];
  StreamSubscription? _devicesSubscription;
  String? _customAvatar;

  // Per-file transfer progress: fileName -> progress 0.0-1.0
  final Map<String, double> _fileProgress = {};
  // Per-file speed (bytes/s)
  final Map<String, double> _fileSpeed = {};

  @override
  void initState() {
    super.initState();
    _initDiscovery();
    _listenForProgress();
    _loadAvatar();
  }

  Future<void> _loadAvatar() async {
    try {
      final avatar = await CustomAvatarWidget.getEffectiveLocalAvatar();
      if (mounted) {
        setState(() {
          _customAvatar = avatar;
        });
      }
    } catch (_) {}
  }

  Future<void> _initDiscovery() async {
    await _discoveryService.initialize();
    _devicesSubscription = _discoveryService.devicesStream.listen((devices) {
      if (mounted) setState(() => _nearbyDevices = devices);
    });
    await _discoveryService.start();
  }

  void _listenForProgress() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'fileTransferProgress' && mounted) {
        final args = call.arguments as Map;
        final name = args['fileName'] as String? ?? '';
        final progress = (args['progress'] as num?)?.toDouble() ?? 0.0;
        final speed = (args['speed'] as num?)?.toDouble() ?? 0.0;
        setState(() {
          _fileProgress[name] = progress;
          _fileSpeed[name] = speed;
        });
      }
    });
  }

  String _ipToCode(String ip, int port) {
    try {
      final parts = ip.split('.').map(int.parse).toList();
      if (parts.length != 4) return '';
      int ipNum = (parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3];
      String ipCode = ipNum.toRadixString(36).toUpperCase().padLeft(8, '0');
      String portCode = port.toRadixString(36).toUpperCase().padLeft(3, '0');
      return ipCode + portCode;
    } catch (_) {
      return '';
    }
  }

  Future<void> _pickFiles() async {
    try {
      // Use standard FilePicker since Android TV often does not have SAF document picker app installed
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        type: FileType.any,
      );
      if (result != null && result.files.isNotEmpty) {
        setState(() {
          for (var file in result.files) {
            if (file.path != null) {
              final uri = Uri.file(file.path!).toString();
              if (!_selectedFiles.any((f) => f['uri'] == uri)) {
                _selectedFiles.add({'uri': uri, 'name': file.name});
              }
            }
          }
          _isSharing = false;
          _serverUrl = null;
        });
        await _startTvServer();
      }
    } catch (e) {
      // Fallback to safUtil if FilePicker fails
      try {
        final result = await _safUtil.pickFiles(multiple: true, mimeTypes: ['*/*']);
        if (result != null && result.isNotEmpty) {
          setState(() {
            for (var doc in result) {
              if (!_selectedFiles.any((f) => f['uri'] == doc.uri)) {
                _selectedFiles.add({'uri': doc.uri, 'name': doc.name});
              }
            }
            _isSharing = false;
            _serverUrl = null;
          });
          await _startTvServer();
        }
      } catch (safError) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error picking files: $safError'), backgroundColor: Colors.red),
          );
        }
      }
    }
  }

  Future<void> _startTvServer() async {
    if (_selectedFiles.isEmpty) return;
    try {
      String? ip = await _networkInfo.getWifiIP();
      if (ip == null) {
        final interfaces = await NetworkInterface.list();
        for (var iface in interfaces) {
          if (iface.name.toLowerCase().contains('loopback')) continue;
          for (var addr in iface.addresses) {
            if (addr.type == InternetAddressType.IPv4 && !addr.isLoopback) {
              ip = addr.address;
              break;
            }
          }
          if (ip != null) break;
        }
      }
      if (ip == null) throw Exception('Could not determine local IP address.');

      try { await _channel.invokeMethod('stopVideoServer'); } catch (_) {}

      final filesList = _selectedFiles.map((f) => {'uri': f['uri']!, 'name': f['name']!}).toList();
      final port = await _channel.invokeMethod<int>('startVideoServer', {'files': filesList});

      if (port == null || port <= 0) throw Exception('Invalid server port');
      setState(() {
        _serverUrl = 'http://$ip:$port/video/0';
        _displayCode = _ipToCode(ip!, port);
        _isSharing = true;
        _fileProgress.clear();
        _fileSpeed.clear();
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to host files: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _stopSharing() async {
    try {
      await _channel.invokeMethod('stopVideoServer');
      setState(() {
        _isSharing = false;
        _serverUrl = null;
        _displayCode = null;
        _selectedFiles.clear();
        _fileProgress.clear();
        _fileSpeed.clear();
      });
    } catch (e) {
      debugPrint('Error stopping server: $e');
    }
  }

  void _removeFile(int index) async {
    final removedName = _selectedFiles[index]['name'] ?? '';
    setState(() {
      _selectedFiles.removeAt(index);
      _fileProgress.remove(removedName);
      _fileSpeed.remove(removedName);
    });
    if (_selectedFiles.isEmpty) {
      await _stopSharing();
    } else if (_isSharing) {
      await _startTvServer();
    }
  }

  IconData _fileTypeIcon(String fileName) {
    final ext = fileName.split('.').last.toLowerCase();
    if (['mp4', 'mkv', 'avi', 'mov', 'webm', 'flv'].contains(ext)) return Icons.movie_rounded;
    if (['mp3', 'flac', 'aac', 'wav', 'ogg', 'm4a'].contains(ext)) return Icons.music_note_rounded;
    if (['jpg', 'jpeg', 'png', 'gif', 'bmp', 'webp', 'heic'].contains(ext)) return Icons.image_rounded;
    if (['pdf'].contains(ext)) return Icons.picture_as_pdf_rounded;
    if (['zip', 'rar', '7z', 'tar', 'gz'].contains(ext)) return Icons.folder_zip_rounded;
    if (['doc', 'docx', 'odt'].contains(ext)) return Icons.description_rounded;
    if (['xls', 'xlsx', 'ods', 'csv'].contains(ext)) return Icons.table_chart_rounded;
    if (['ppt', 'pptx', 'odp'].contains(ext)) return Icons.slideshow_rounded;
    if (['apk'].contains(ext)) return Icons.android_rounded;
    return Icons.insert_drive_file_rounded;
  }

  String _formatSpeed(double bytesPerSec) {
    if (bytesPerSec <= 0) return '';
    if (bytesPerSec < 1024) return '${bytesPerSec.toStringAsFixed(0)} B/s';
    if (bytesPerSec < 1024 * 1024) return '${(bytesPerSec / 1024).toStringAsFixed(1)} KB/s';
    return '${(bytesPerSec / (1024 * 1024)).toStringAsFixed(1)} MB/s';
  }

  @override
  void dispose() {
    _devicesSubscription?.cancel();
    _channel.invokeMethod('stopVideoServer');
    super.dispose();
  }

  void _showQrDialog() {
    if (_serverUrl == null) return;
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1C1C1E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Scan to Download',
              style: GoogleFonts.outfit(
                color: const Color(0xFFFFD600),
                fontSize: 22,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.5,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Point your phone camera at this code',
              style: GoogleFonts.outfit(
                color: Colors.grey[600],
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 28),
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: const Color(0xFFFFD600),
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFFFFD600).withOpacity(0.3),
                    blurRadius: 25,
                    offset: const Offset(0, 10),
                  ),
                ],
              ),
              child: QrImageView(
                data: _serverUrl!,
                version: QrVersions.auto,
                size: 200.0,
                backgroundColor: const Color(0xFFFFD600),
                eyeStyle: const QrEyeStyle(
                  eyeShape: QrEyeShape.square,
                  color: Colors.black,
                ),
                dataModuleStyle: const QrDataModuleStyle(
                  dataModuleShape: QrDataModuleShape.square,
                  color: Colors.black,
                ),
              ),
            ),
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.05),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: const Color(0xFFFFD600).withOpacity(0.2),
                ),
              ),
              child: Text(
                _serverUrl!,
                style: GoogleFonts.robotoMono(
                  color: const Color(0xFFFFD600),
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: TVFocusableButton(
                onPressed: () => Navigator.pop(context),
                backgroundColor: const Color(0xFFFFD600),
                borderRadius: BorderRadius.circular(12),
                padding: const EdgeInsets.symmetric(vertical: 14),
                child: Text(
                  'Close',
                  style: GoogleFonts.outfit(
                    color: Colors.black,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: Colors.transparent,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.black.withOpacity(0.12)),
                ),
                child: TVFocusableButton(
                  borderRadius: BorderRadius.circular(24),
                  padding: EdgeInsets.zero,
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Icon(
                    Icons.arrow_back_ios_new_rounded,
                    color: Colors.black,
                    size: 20,
                  ),
                ),
              ),
              Expanded(
                child: Text(
                  'Send Files',
                  style: GoogleFonts.outfit(
                    color: Colors.black,
                    fontSize: 24,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.5,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
              const SizedBox(width: 48),
            ],
          ),
          if (_isSharing && _displayCode != null) ...[
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  decoration: BoxDecoration(
                    color: Colors.black,
                    borderRadius: BorderRadius.circular(30),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.2),
                        blurRadius: 10,
                        offset: const Offset(0, 4),
                      ),
                    ],
                    border: Border.all(color: Colors.white.withOpacity(0.1)),
                  ),
                  child: Text(
                    'Code: $_displayCode',
                    style: GoogleFonts.outfit(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.0,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Container(
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.black,
                  ),
                  child: TVFocusableButton(
                    borderRadius: BorderRadius.circular(24),
                    padding: const EdgeInsets.all(12),
                    onPressed: _showQrDialog,
                    child: const Icon(
                      Icons.qr_code_rounded,
                      color: Colors.white,
                      size: 24,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildDiscoveryBackground() {
    final screenWidth = MediaQuery.of(context).size.width;
    
    // Scale pulse size based on screen width
    final double pulseSize = (screenWidth * 0.45).clamp(280.0, 360.0);
    const double pulseTop = 110.0;

    final List<Widget> deviceNodes = [];
    final int totalCount = _nearbyDevices.length;
    const int maxVisibleDevices = 8;
    final int visibleCount = totalCount.clamp(0, maxVisibleDevices);
    final double deviceScale = totalCount <= 4 ? 1.0 : (totalCount <= 6 ? 0.9 : 0.8);
    final double deviceNodeSize = 60.0 * deviceScale;
    final double pulseRadius = pulseSize / 2;
    const double orbitPadding = 24.0;
    final double orbitRadius = pulseRadius - (deviceNodeSize / 2) - orbitPadding;
    const double startAngle = -3.14159 / 2;

    for (int i = 0; i < visibleCount; i++) {
      final double angle = startAngle + (2 * 3.14159 * i / visibleCount);
      final double offsetX = orbitRadius * cos(angle);
      final double offsetY = orbitRadius * sin(angle);

      deviceNodes.add(
        Transform.translate(
          offset: Offset(offsetX, offsetY),
          child: Transform.scale(
            scale: deviceScale,
            child: _buildDeviceNode(_nearbyDevices[i]),
          ),
        ),
      );
    }

    return Stack(
      alignment: Alignment.center,
      children: [
        Positioned(
          top: pulseTop,
          child: Center(
            child: SizedBox(
              width: pulseSize,
              height: pulseSize,
              child: SearchPulseWidget(
                key: const ValueKey('pulse_effect_stable'),
                size: pulseSize,
                color: Colors.black,
              ),
            ),
          ),
        ),
        Positioned(
          top: pulseTop,
          child: Center(
            child: SizedBox(
              width: pulseSize,
              height: pulseSize,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  CustomAvatarWidget(
                    avatarId: _customAvatar,
                    size: 60,
                    useBackground: true,
                    showBorder: true,
                    borderColor: const Color(0xFFFFD600).withOpacity(0.5),
                  ),
                  ...deviceNodes,
                ],
              ),
            ),
          ),
        ),
        Positioned(
          top: pulseTop + pulseSize + 12,
          child: Center(
            child: _buildDiscoveryStatusLabel(totalCount),
          ),
        ),
      ],
    );
  }

  Widget _buildDeviceNode(DiscoveredDevice device) {
    String name = device.deviceName;
    String? platform = device.platform;
    String? avatarUrl = device.avatarUrl;
    String displayName = device.userName ?? name;

    return Material(
      color: Colors.transparent,
      child: TVFocusableButton(
        borderRadius: BorderRadius.circular(16),
        padding: EdgeInsets.zero,
        onPressed: () {
          if (_displayCode != null) {
            showDialog(
              context: context,
              builder: (context) => AlertDialog(
                backgroundColor: const Color(0xFF1C1C1E),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
                title: Row(
                  children: [
                    CustomAvatarWidget(avatarId: device.avatarUrl, size: 36),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Share with ${device.deviceName}',
                        style: GoogleFonts.outfit(color: Colors.white, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
                ),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Ask them to enter this code:',
                      style: GoogleFonts.outfit(color: Colors.white60, fontSize: 14),
                    ),
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFFD600).withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: const Color(0xFFFFD600).withValues(alpha: 0.3)),
                      ),
                      child: Text(
                        _displayCode!,
                        style: GoogleFonts.outfit(
                          color: Colors.white,
                          fontSize: 28,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 4.0,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'IP: ${device.ipAddress}',
                      style: GoogleFonts.robotoMono(color: Colors.white38, fontSize: 12),
                    ),
                  ],
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text('Close', style: GoogleFonts.outfit(color: const Color(0xFFFFD600))),
                  ),
                ],
              ),
            );
          } else {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Select files first to generate a code.')),
            );
          }
        },
        child: Padding(
          padding: const EdgeInsets.all(4.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: const Color(0xFF1C1C1E),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: Colors.white.withOpacity(0.15),
                    width: 1.5,
                  ),
                ),
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    if (avatarUrl != null)
                      Builder(
                        builder: (context) {
                          bool isUrl = avatarUrl.startsWith('http') || avatarUrl.startsWith('https');
                          bool isCustomAvatar = CustomAvatarWidget.avatars.any((a) => a['id'] == avatarUrl);

                          if (isUrl) {
                            return ClipOval(
                              child: Image.network(
                                avatarUrl,
                                width: 56,
                                height: 56,
                                fit: BoxFit.cover,
                                errorBuilder: (c, e, s) => Icon(
                                  _getDeviceIcon(name, platform: platform),
                                  color: Colors.white,
                                  size: 24,
                                ),
                              ),
                            );
                          } else if (isCustomAvatar) {
                            return CustomAvatarWidget(
                              avatarId: avatarUrl,
                              size: 56,
                              useBackground: true,
                            );
                          } else {
                            return Center(
                              child: Text(
                                avatarUrl,
                                style: const TextStyle(fontSize: 24, color: Colors.white),
                              ),
                            );
                          }
                        },
                      )
                    else
                      Icon(
                        _getDeviceIcon(name, platform: platform),
                        color: Colors.white,
                        size: 24,
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 4),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.6),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  displayName.length > 10 ? '${displayName.substring(0, 8)}...' : displayName,
                  style: GoogleFonts.outfit(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  IconData _getDeviceIcon(String name, {String? platform}) {
    if (platform != null) {
      final p = platform.toLowerCase();
      if (p.contains('ios') || p.contains('iphone') || p.contains('ipad')) {
        return Icons.phone_iphone_rounded;
      } else if (p.contains('mac')) {
        return Icons.laptop_mac_rounded;
      } else if (p.contains('android')) {
        return Icons.phone_android_rounded;
      } else if (p.contains('windows') || p.contains('pc')) {
        return Icons.desktop_windows_rounded;
      }
    }
    name = name.toLowerCase();
    if (name.contains('iphone') || name.contains('ipad') || name.contains('ios')) {
      return Icons.phone_iphone_rounded;
    } else if (name.contains('mac') || name.contains('apple')) {
      return Icons.laptop_mac_rounded;
    } else if (name.contains('windows') || name.contains('pc') || name.contains('desktop')) {
      return Icons.desktop_windows_rounded;
    } else if (name.contains('android') || name.contains('phone') || name.contains('pixel') || name.contains('samsung')) {
      return Icons.phone_android_rounded;
    }
    return Icons.devices_other_rounded;
  }

  Widget _buildDiscoveryStatusLabel(int deviceCount) {
    String text;
    IconData icon;
    if (deviceCount > 0) {
      text = '$deviceCount device${deviceCount > 1 ? 's' : ''} nearby';
      icon = Icons.check_circle_outline_rounded;
    } else {
      text = 'Scanning for nearby devices...';
      icon = Icons.radar_rounded;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.6),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white70, size: 14),
          const SizedBox(width: 6),
          Text(
            text,
            style: GoogleFonts.outfit(
              color: Colors.white70,
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5C400),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFFFFD84D), Color(0xFFF5C400)],
          ),
        ),
        child: SafeArea(
          child: Row(
            children: [
              // Left Panel: Pulse and Header (Yellow Background Area)
              Expanded(
                flex: 5,
                child: Stack(
                  children: [
                    _buildDiscoveryBackground(),
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      child: _buildHeader(),
                    ),
                  ],
                ),
              ),
              // Right Panel: Files List and Controls (Dark Background Area)
              Expanded(
                flex: 4,
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.black,
                    border: Border(
                      left: BorderSide(
                        color: Colors.white.withOpacity(0.1),
                      ),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(24, 24, 24, 12),
                        child: Text(
                          'Files',
                          style: GoogleFonts.outfit(
                            color: Colors.white,
                            fontSize: 24,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            TVFocusableButton(
                              onPressed: _pickFiles,
                              autofocus: !_isSharing,
                              backgroundColor: const Color(0xFFFFD600),
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                              borderRadius: BorderRadius.circular(12),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(Icons.add_circle_outline_rounded, color: Colors.black, size: 18),
                                  const SizedBox(width: 6),
                                  Text(
                                    _selectedFiles.isEmpty ? 'Select Files' : 'Add Files',
                                    style: GoogleFonts.outfit(color: Colors.black, fontWeight: FontWeight.bold, fontSize: 13),
                                  ),
                                ],
                              ),
                            ),
                            if (_isSharing)
                              TVFocusableButton(
                                onPressed: _stopSharing,
                                backgroundColor: Colors.red.withValues(alpha: 0.2),
                                focusColor: Colors.red,
                                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                                borderRadius: BorderRadius.circular(12),
                                child: Text(
                                  'Stop Sharing',
                                  style: GoogleFonts.outfit(color: Colors.redAccent, fontWeight: FontWeight.bold, fontSize: 13),
                                ),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                      Expanded(
                        child: _selectedFiles.isEmpty
                            ? Center(
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(Icons.upload_file_rounded, size: 64, color: Colors.white.withValues(alpha: 0.08)),
                                    const SizedBox(height: 16),
                                    Text(
                                      'No files selected.\nAdd files to start sharing.',
                                      textAlign: TextAlign.center,
                                      style: GoogleFonts.outfit(color: Colors.white38, fontSize: 15),
                                    ),
                                  ],
                                ),
                              )
                            : ListView.builder(
                                padding: const EdgeInsets.symmetric(horizontal: 24),
                                itemCount: _selectedFiles.length,
                                itemBuilder: (context, index) {
                                  final file = _selectedFiles[index];
                                  final name = file['name'] ?? 'file';
                                  final progress = _fileProgress[name];
                                  final speed = _fileSpeed[name] ?? 0.0;
                                  final isTransferring = progress != null && progress > 0 && progress < 1.0;
                                  final isDone = progress != null && progress >= 1.0;

                                  return Padding(
                                    padding: const EdgeInsets.only(bottom: 12),
                                    child: TVFocusableCard(
                                      borderRadius: BorderRadius.circular(16),
                                      backgroundColor: isDone
                                          ? const Color(0xFF00E676).withValues(alpha: 0.06)
                                          : isTransferring
                                              ? const Color(0xFFFFD600).withValues(alpha: 0.06)
                                              : const Color(0xFF1C1C1E),
                                      focusColor: Colors.redAccent,
                                      onPressed: isTransferring ? null : () => _removeFile(index),
                                      child: Padding(
                                        padding: const EdgeInsets.all(14),
                                        child: Column(
                                          children: [
                                            Row(
                                              children: [
                                                Container(
                                                  padding: const EdgeInsets.all(8),
                                                  decoration: BoxDecoration(
                                                    color: isDone
                                                        ? const Color(0xFF00E676).withValues(alpha: 0.15)
                                                        : const Color(0xFFFFD600).withValues(alpha: 0.15),
                                                    shape: BoxShape.circle,
                                                  ),
                                                  child: Icon(
                                                    isDone ? Icons.check_circle_rounded : _fileTypeIcon(name),
                                                    color: isDone ? const Color(0xFF00E676) : const Color(0xFFFFD600),
                                                    size: 20,
                                                  ),
                                                ),
                                                const SizedBox(width: 12),
                                                Expanded(
                                                  child: Column(
                                                    crossAxisAlignment: CrossAxisAlignment.start,
                                                    children: [
                                                      Text(
                                                        name,
                                                        style: GoogleFonts.outfit(
                                                          color: Colors.white,
                                                          fontWeight: FontWeight.w600,
                                                        ),
                                                        maxLines: 1,
                                                        overflow: TextOverflow.ellipsis,
                                                      ),
                                                      if (isTransferring)
                                                        Text(
                                                          '${(progress * 100).toStringAsFixed(0)}%  •  ${_formatSpeed(speed)}',
                                                          style: const TextStyle(color: Color(0xFFFFD600), fontSize: 11),
                                                        )
                                                      else if (isDone)
                                                        const Text('Transfer complete ✓', style: TextStyle(color: Color(0xFF00E676), fontSize: 11))
                                                      else
                                                        const Text('Click to remove file', style: TextStyle(color: Colors.white38, fontSize: 11)),
                                                    ],
                                                  ),
                                                ),
                                                if (!isTransferring)
                                                  const Icon(Icons.delete_outline_rounded, color: Colors.white38, size: 20),
                                              ],
                                            ),
                                            if (isTransferring) ...[
                                              const SizedBox(height: 10),
                                              ClipRRect(
                                                borderRadius: BorderRadius.circular(4),
                                                child: LinearProgressIndicator(
                                                  value: progress,
                                                  minHeight: 4,
                                                  backgroundColor: Colors.white12,
                                                  valueColor: const AlwaysStoppedAnimation(Color(0xFFFFD600)),
                                                ),
                                              ),
                                            ],
                                          ],
                                        ),
                                      ),
                                    ),
                                  );
                                },
                              ),
                      ),
                      const SizedBox(height: 20),
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
}
