import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:io';

// Modern Color Constants
// Modern Color Constants
const Color kZapPrimary = Color(0xFFFFD84D); // Logo Yellow Light
const Color kZapPrimaryDark = Color(0xFFF5C400); // Logo Yellow Dark
const Color kZapSurface = Color(0xFF1C1C1E); 
const Color kZapBackgroundTop = Color(0xFF0E1116);
const Color kZapBackgroundBottom = Color(0xFF07090D); 

class DeviceSettingsScreen extends StatefulWidget {
  const DeviceSettingsScreen({super.key});

  @override
  State<DeviceSettingsScreen> createState() => _DeviceSettingsScreenState();
}

class _DeviceSettingsScreenState extends State<DeviceSettingsScreen> {
  final TextEditingController _deviceNameController = TextEditingController();
  String _currentDeviceName = '';
  bool _autoDiscoveryEnabled = true;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _currentDeviceName = prefs.getString('device_name') ?? _getDefaultDeviceName();
      _deviceNameController.text = _currentDeviceName;
      _autoDiscoveryEnabled = prefs.getBool('auto_discovery_enabled') ?? true;
    });
  }

  String _getDefaultDeviceName() {
    if (Platform.isAndroid) {
      return 'Android Device';
    } else if (Platform.isWindows) {
      return 'Windows PC';
    } else if (Platform.isIOS) {
      return 'iOS Device';
    } else if (Platform.isMacOS) {
      return 'Mac';
    } else {
      return 'ZapShare Device';
    }
  }

  Future<void> _saveDeviceName() async {
    final newName = _deviceNameController.text.trim();
    if (newName.isEmpty) {
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('device_name', newName);
    
    setState(() {
      _currentDeviceName = newName;
    });

    try {
      FocusScope.of(context).unfocus();
      await Future.delayed(const Duration(milliseconds: 120));
    } catch (_) {}

    Navigator.pop(context);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text("Device name updated"),
        backgroundColor: kZapSurface,
        behavior: SnackBarBehavior.floating,
      )
    );
  }

  Future<void> _toggleAutoDiscovery(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('auto_discovery_enabled', value);
    
    setState(() {
      _autoDiscoveryEnabled = value;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text(
          'Settings',
          style: TextStyle(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.bold,
          ),
        ),
        centerTitle: true,
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [kZapBackgroundTop, kZapBackgroundBottom],
          ),
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 120, 24, 24), // Adjust padding for AppBar
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Device Name Section
            const Text(
              'DEVICE IDENTITY',
              style: TextStyle(
                color: Colors.grey,
                fontSize: 12,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.2,
              ),
            ),
            const SizedBox(height: 16),
            
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: kZapSurface,
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: Colors.white.withOpacity(0.05)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Theme(
                    data: Theme.of(context).copyWith(
                      textSelectionTheme: TextSelectionThemeData(
                        cursorColor: kZapPrimary,
                        selectionHandleColor: kZapPrimary,
                        selectionColor: kZapPrimary.withOpacity(0.2),
                      ),
                    ),
                    child: TextField(
                      controller: _deviceNameController,
                      cursorColor: kZapPrimary,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                      decoration: InputDecoration(
                        labelText: 'Device Name',
                        labelStyle: TextStyle(color: Colors.grey[500]),
                        enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.grey[800]!)),
                        focusedBorder: const UnderlineInputBorder(borderSide: BorderSide(color: kZapPrimary)),
                        contentPadding: const EdgeInsets.symmetric(vertical: 8),
                      ),
                      maxLength: 30,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Visible to other devices nearby',
                    style: TextStyle(
                      color: Colors.grey[600],
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _saveDeviceName,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: kZapPrimary,
                        foregroundColor: Colors.black,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                      child: const Text(
                        'Save Changes',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 32),

            // Discovery Settings
            const Text(
              'NETWORK',
              style: TextStyle(
                color: Colors.grey,
                fontSize: 12,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.2,
              ),
            ),
            const SizedBox(height: 16),

            Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              decoration: BoxDecoration(
                color: kZapSurface,
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: Colors.white.withOpacity(0.05)),
              ),
              child: SwitchListTile(
                 activeColor: kZapPrimary,
                 activeTrackColor: kZapPrimary.withOpacity(0.2),
                 inactiveThumbColor: Colors.grey[400],
                 inactiveTrackColor: Colors.grey[800],
                 contentPadding: EdgeInsets.zero,
                 title: const Text("Auto-Discovery", style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                 subtitle: Text("Find devices automatically on WiFi", style: TextStyle(color: Colors.grey[500], fontSize: 13)),
                 value: _autoDiscoveryEnabled, 
                 onChanged: _toggleAutoDiscovery
              ),
            ),

            const SizedBox(height: 32),

            // Platform Info
            const Text(
              'ABOUT',
              style: TextStyle(
                color: Colors.grey,
                fontSize: 12,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.2,
              ),
            ),
            const SizedBox(height: 16),

            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: kZapSurface,
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: Colors.white.withOpacity(0.05)),
              ),
              child: Column(
                children: [
                  _buildInfoRow('Platform', _getPlatformName(), Icons.phone_iphone_rounded),
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: Divider(color: Colors.white.withOpacity(0.05), height: 1),
                  ),
                  _buildInfoRow('App Version', '1.0.0 (Beta)', Icons.info_outline_rounded),
                ],
              ),
            ),

            const SizedBox(height: 24),
          ],
        ),
      ),
      ),
    );
  }

  Widget _buildInfoRow(String label, String value, IconData icon) {
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.05),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, color: Colors.grey[400], size: 20),
        ),
        const SizedBox(width: 16),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: TextStyle(
                color: Colors.grey[500],
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              value,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ],
    );
  }

  String _getPlatformName() {
    if (Platform.isAndroid) return 'Android';
    if (Platform.isWindows) return 'Windows';
    if (Platform.isIOS) return 'iOS';
    if (Platform.isMacOS) return 'macOS';
    if (Platform.isLinux) return 'Linux';
    return 'Unknown';
  }

  @override
  void dispose() {
    _deviceNameController.dispose();
    super.dispose();
  }
}
