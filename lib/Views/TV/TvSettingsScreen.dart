import 'dart:io';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:zap_share/widgets/tv_widgets.dart';
import 'package:zap_share/services/device_discovery_service.dart';
import 'package:package_info_plus/package_info_plus.dart';

class TvSettingsScreen extends StatefulWidget {
  const TvSettingsScreen({super.key});

  @override
  State<TvSettingsScreen> createState() => _TvSettingsScreenState();
}

class _TvSettingsScreenState extends State<TvSettingsScreen> {
  final DeviceDiscoveryService _discoveryService = DeviceDiscoveryService();
  final TextEditingController _nameController = TextEditingController();
  final NetworkInfo _networkInfo = NetworkInfo();

  String _deviceName = 'TV Device';
  String _selectedEmoji = '🦊';
  bool _autoDiscoveryEnabled = true;
  String? _localIp;
  String _appVersion = '';
  String _buildNumber = '';

  final List<String> _emojis = [
    '🦊', '🦁', '🐼', '🐨', '🐙', '🦖', '🚀', '🛸',
    '⚡', '🤖', '🎮', '🪐', '🍩', '🥑', '👻', '🎃'
  ];

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final ip = await _networkInfo.getWifiIP();
    PackageInfo info;
    try {
      info = await PackageInfo.fromPlatform();
    } catch (_) {
      info = PackageInfo(appName: 'ZapShare', packageName: '', version: '1.0.0', buildNumber: '1');
    }
    if (mounted) {
      setState(() {
        _deviceName = prefs.getString('device_name') ?? 'TV Device';
        _nameController.text = _deviceName;
        _selectedEmoji = prefs.getString('custom_avatar') ?? '🦊';
        _autoDiscoveryEnabled = prefs.getBool('auto_discovery_enabled') ?? true;
        _localIp = ip ?? 'N/A';
        _appVersion = info.version;
        _buildNumber = info.buildNumber;
      });
    }
  }

  Future<void> _saveDeviceName(String name) async {
    if (name.trim().isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('device_name', name.trim());
    await _discoveryService.setDeviceName(name.trim());
    setState(() => _deviceName = name.trim());
  }

  Future<void> _saveEmoji(String emoji) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('custom_avatar', emoji);
    await prefs.setString('p2p_avatar_mode', 'emoji');
    setState(() => _selectedEmoji = emoji);
  }

  Future<void> _toggleAutoDiscovery(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('auto_discovery_enabled', value);
    setState(() => _autoDiscoveryEnabled = value);
    if (value) {
      await _discoveryService.start();
    } else {
      await _discoveryService.stop();
    }
  }

  void _showEditNameDialog() {
    final controller = TextEditingController(text: _deviceName);
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1C1C1E),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: Text(
            'Edit Device Name',
            style: GoogleFonts.outfit(color: Colors.white, fontWeight: FontWeight.bold),
          ),
          content: TextField(
            controller: controller,
            autofocus: true,
            style: GoogleFonts.outfit(color: Colors.white),
            decoration: InputDecoration(
              hintText: 'Enter name',
              hintStyle: GoogleFonts.outfit(color: Colors.white24),
              enabledBorder: const UnderlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
              focusedBorder: const UnderlineInputBorder(borderSide: BorderSide(color: Color(0xFFFFD600))),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text('Cancel', style: GoogleFonts.outfit(color: Colors.white38)),
            ),
            TextButton(
              onPressed: () {
                _saveDeviceName(controller.text);
                Navigator.of(context).pop();
              },
              child: Text('Save', style: GoogleFonts.outfit(color: const Color(0xFFFFD600), fontWeight: FontWeight.bold)),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFF0E0E10), Color(0xFF08080A)],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 48.0, vertical: 24.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ── Android-style header ──
                Row(
                  children: [
                    Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: const Color(0xFF1C1C1E),
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
                      ),
                      child: TVFocusableButton(
                        borderRadius: BorderRadius.circular(24),
                        padding: EdgeInsets.zero,
                        onPressed: () => Navigator.of(context).pop(),
                        child: const Icon(Icons.arrow_back_ios_new_rounded, color: Colors.white, size: 20),
                      ),
                    ),
                    const SizedBox(width: 16),
                    RichText(
                      text: TextSpan(
                        children: [
                          TextSpan(
                            text: 'TV ',
                            style: GoogleFonts.outfit(
                              color: const Color(0xFFFFD600),
                              fontSize: 26,
                              fontWeight: FontWeight.w800,
                              letterSpacing: -0.5,
                            ),
                          ),
                          TextSpan(
                            text: 'Settings',
                            style: GoogleFonts.outfit(
                              color: Colors.white,
                              fontSize: 26,
                              fontWeight: FontWeight.bold,
                              letterSpacing: -0.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // ─── Left Column: Device Name + Connectivity ──────────────
                      Expanded(
                flex: 2,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildSectionLabel('DEVICE IDENTITY'),
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1C1C1E),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _selectedEmoji,
                            style: const TextStyle(fontSize: 40),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            _deviceName,
                            style: GoogleFonts.outfit(
                              color: Colors.white,
                              fontSize: 26,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 16),
                          TVFocusableButton(
                            onPressed: _showEditNameDialog,
                            autofocus: true,
                            backgroundColor: const Color(0xFFFFD600),
                            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                            borderRadius: BorderRadius.circular(14),
                            child: Text(
                              'Rename Device',
                              style: GoogleFonts.outfit(
                                color: Colors.black,
                                fontWeight: FontWeight.bold,
                                fontSize: 15,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 28),
                    _buildSectionLabel('CONNECTIVITY'),
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1C1C1E),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
                      ),
                      child: Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: const Color(0xFFFFD600).withValues(alpha: 0.1),
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(Icons.wifi_tethering_rounded, color: Color(0xFFFFD600), size: 20),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Auto Discovery',
                                  style: GoogleFonts.outfit(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600),
                                ),
                                Text(
                                  'Broadcast this TV to nearby devices',
                                  style: GoogleFonts.outfit(color: Colors.white38, fontSize: 12),
                                ),
                              ],
                            ),
                          ),
                          TVFocusableButton(
                            onPressed: () => _toggleAutoDiscovery(!_autoDiscoveryEnabled),
                            backgroundColor: _autoDiscoveryEnabled ? const Color(0xFFFFD600) : const Color(0xFF2C2C2E),
                            focusColor: const Color(0xFFFFD600),
                            borderRadius: BorderRadius.circular(10),
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                            child: Text(
                              _autoDiscoveryEnabled ? 'ON' : 'OFF',
                              style: GoogleFonts.outfit(
                                color: _autoDiscoveryEnabled ? Colors.black : Colors.white,
                                fontWeight: FontWeight.bold,
                                fontSize: 13,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 28),
                    _buildSectionLabel('SYSTEM INFO'),
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1C1C1E),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
                      ),
                      child: Column(
                        children: [
                          _buildInfoRow(Icons.network_wifi_3_bar_rounded, 'Local IP', _localIp ?? 'N/A'),
                          _buildInfoDivider(),
                          _buildInfoRow(Icons.tv_rounded, 'Platform', Platform.operatingSystem.toUpperCase()),
                          _buildInfoDivider(),
                          _buildInfoRow(Icons.apps_rounded, 'App Version', '$_appVersion ($_buildNumber)'),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 48),

              // ─── Right Column: Avatar Emoji Picker ────────────────────
              Expanded(
                flex: 3,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        _buildSectionLabel('CHOOSE AVATAR EMOJI'),
                        const Spacer(),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                          decoration: BoxDecoration(
                            color: const Color(0xFFFFD600).withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                'Current: ',
                                style: GoogleFonts.outfit(color: Colors.white38, fontSize: 13),
                              ),
                              Text(
                                _selectedEmoji,
                                style: const TextStyle(fontSize: 18),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Expanded(
                      child: GridView.builder(
                        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 4,
                          crossAxisSpacing: 12,
                          mainAxisSpacing: 12,
                          childAspectRatio: 1.4,
                        ),
                        itemCount: _emojis.length,
                        itemBuilder: (context, index) {
                          final emoji = _emojis[index];
                          final isSelected = emoji == _selectedEmoji;
                          return TVFocusableCard(
                            onPressed: () => _saveEmoji(emoji),
                            backgroundColor: isSelected
                                ? const Color(0xFFFFD600).withValues(alpha: 0.12)
                                : const Color(0xFF1C1C1E),
                            focusColor: const Color(0xFFFFD600),
                            child: Center(
                              child: Stack(
                                alignment: Alignment.center,
                                children: [
                                  Text(emoji, style: const TextStyle(fontSize: 32)),
                                  if (isSelected)
                                    Positioned(
                                      bottom: 4,
                                      right: 4,
                                      child: Container(
                                        padding: const EdgeInsets.all(2),
                                        decoration: const BoxDecoration(
                                          color: Color(0xFFFFD600),
                                          shape: BoxShape.circle,
                                        ),
                                        child: const Icon(Icons.check, size: 10, color: Colors.black),
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
            ],
          ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSectionLabel(String text) => Text(
        text,
        style: GoogleFonts.outfit(
          color: Colors.white38,
          fontSize: 12,
          fontWeight: FontWeight.w800,
          letterSpacing: 1.8,
        ),
      );

  Widget _buildInfoRow(IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Icon(icon, color: Colors.white38, size: 16),
          const SizedBox(width: 10),
          Text(label, style: GoogleFonts.outfit(color: Colors.white54, fontSize: 13)),
          const Spacer(),
          Text(
            value,
            style: GoogleFonts.robotoMono(color: const Color(0xFFFFD600), fontSize: 13, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoDivider() => Container(height: 1, color: Colors.white.withValues(alpha: 0.04));
}
