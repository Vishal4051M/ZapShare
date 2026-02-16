import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:google_fonts/google_fonts.dart';
import 'dart:io';
import 'dart:async';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:zap_share/services/supabase_service.dart';
import 'package:zap_share/Screens/shared/AvatarPickerScreen.dart';
import 'package:zap_share/widgets/CustomAvatarWidget.dart';
import 'package:zap_share/Screens/auth/LoginScreen.dart';

class DeviceSettingsScreen extends StatefulWidget {
  const DeviceSettingsScreen({super.key});

  @override
  State<DeviceSettingsScreen> createState() => _DeviceSettingsScreenState();
}

class _DeviceSettingsScreenState extends State<DeviceSettingsScreen> {
  final TextEditingController _deviceNameController = TextEditingController();
  String _currentDeviceName = '';
  bool _autoDiscoveryEnabled = true;
  String? _currentAvatar;
  User? _currentUser;
  StreamSubscription<AuthState>? _authSubscription;

  @override
  void initState() {
    super.initState();
    _currentUser = SupabaseService().currentUser;
    _authSubscription = SupabaseService().authStateChanges.listen((data) {
      if (mounted) {
        setState(() {
          _currentUser = data.session?.user;
        });
      }
    });

    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final avatar = prefs.getString('custom_avatar');

    setState(() {
      _currentDeviceName =
          prefs.getString('device_name') ?? _getDefaultDeviceName();
      _deviceNameController.text = _currentDeviceName;
      _autoDiscoveryEnabled = prefs.getBool('auto_discovery_enabled') ?? true;
      _currentAvatar = avatar;
    });
  }

  String _getDefaultDeviceName() {
    if (Platform.isAndroid) return 'Android Device';
    if (Platform.isWindows) return 'Windows PC';
    if (Platform.isIOS) return 'iOS Device';
    if (Platform.isMacOS) return 'Mac';
    return 'ZapShare Device';
  }

  Future<void> _toggleAutoDiscovery(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('auto_discovery_enabled', value);
    setState(() => _autoDiscoveryEnabled = value);
    HapticFeedback.selectionClick();
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Theme(
        data: Theme.of(context).copyWith(
          // Yellow ink drop / ripple effect
          splashColor: const Color(0xFFFFD600).withOpacity(0.1),
          highlightColor: const Color(0xFFFFD600).withOpacity(0.05),
          textSelectionTheme: TextSelectionThemeData(
            cursorColor: const Color(0xFFFFD600),
            selectionColor: const Color(0xFFFFD600).withOpacity(0.3),
            selectionHandleColor: const Color(0xFFFFD600),
          ),
        ),
        child: GestureDetector(
          onTap: () => FocusScope.of(context).unfocus(),
          child: Scaffold(
            backgroundColor: Colors.black,
            body: SafeArea(
              child: Column(
                children: [
                  _buildHeader(),
                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      physics: const BouncingScrollPhysics(),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const SizedBox(height: 10),

                          _buildProfileSection(),

                          const SizedBox(height: 30),
                          _buildSectionHeader('DEVICE IDENTITY'),
                          const SizedBox(height: 12),
                          _buildDeviceNameCard(),

                          const SizedBox(height: 30),
                          _buildSectionHeader('CONNECTIVITY'),
                          const SizedBox(height: 12),
                          _buildDiscoveryCard(),

                          const SizedBox(height: 30),
                          _buildSectionHeader('SYSTEM INFO'),
                          const SizedBox(height: 12),
                          _buildInfoCard(),

                          const SizedBox(height: 40),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Row(
        children: [
          CircleAvatar(
            radius: 24,
            backgroundColor: Colors.white.withOpacity(0.08),
            child: IconButton(
              icon: const Icon(
                Icons.arrow_back_ios_new_rounded,
                color: Colors.white,
                size: 20,
              ),
              onPressed: () => Navigator.pop(context),
            ),
          ),
          const SizedBox(width: 16),
          Text(
            'Settings',
            style: GoogleFonts.outfit(
              color: Colors.white,
              fontSize: 32,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Text(
        title,
        style: GoogleFonts.outfit(
          color: Colors.grey[600],
          fontSize: 14, // Increased from 13 to fix pixelation
          fontWeight: FontWeight.w600,
          letterSpacing: 1.2,
        ),
      ),
    );
  }

  Widget _buildProfileSection() {
    return FutureBuilder<Map<String, dynamic>?>(
      future: SupabaseService().getUserProfile(),
      builder: (context, snapshot) {
        final profile = snapshot.data;
        final avatarUrl =
            profile?['avatar_url'] ?? _currentUser?.userMetadata?['picture'];
        final userName =
            profile?['full_name'] ??
            _currentUser?.userMetadata?['full_name'] ??
            'Guest User';
        final email = _currentUser?.email;

        return Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: const Color(0xFF1C1C1E).withOpacity(0.8),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: Colors.white.withOpacity(0.08)),
          ),
          child: Column(
            children: [
              Row(
                children: [
                  GestureDetector(
                    onTap: () async {
                      final result = await Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder:
                              (context) => AvatarPickerScreen(
                                currentAvatar: _currentAvatar ?? avatarUrl,
                              ),
                        ),
                      );
                      if (result != null && mounted) {
                        setState(() => _currentAvatar = result);
                        final prefs = await SharedPreferences.getInstance();
                        await prefs.setString('custom_avatar', result);
                      }
                    },
                    child: Stack(
                      children: [
                        CustomAvatarWidget(
                          avatarId: _currentAvatar ?? avatarUrl,
                          size: 70,
                          useBackground: true, // Ensuring premium bubble look
                        ),
                        Positioned(
                          bottom: 0,
                          right: 0,
                          child: Container(
                            padding: const EdgeInsets.all(6),
                            decoration: BoxDecoration(
                              color: const Color(0xFFFFD600),
                              shape: BoxShape.circle,
                              border: Border.all(color: Colors.black, width: 2),
                            ),
                            child: const Icon(
                              Icons.edit,
                              size: 12,
                              color: Colors.black,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          userName,
                          style: GoogleFonts.outfit(
                            color: Colors.white,
                            fontSize: 22,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          email ?? 'Not Signed In',
                          style: GoogleFonts.outfit(
                            color: Colors.grey[400],
                            fontSize: 15,
                            fontWeight:
                                FontWeight
                                    .w500, // Fixed pixelation by increasing weight
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              if (_currentUser != null) ...[
                const SizedBox(height: 20),
                Container(height: 1, color: Colors.white.withOpacity(0.05)),
                const SizedBox(height: 16),

                const SizedBox(height: 16),

                // Logout Button
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: () async {
                      // Show confirmation dialog
                      final confirmed = await showDialog<bool>(
                        context: context,
                        builder:
                            (context) => AlertDialog(
                              backgroundColor: const Color(0xFF1C1C1E),
                              title: Text(
                                'Sign Out',
                                style: GoogleFonts.outfit(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              content: Text(
                                'Are you sure you want to sign out?',
                                style: GoogleFonts.outfit(
                                  color: Colors.grey[400],
                                ),
                              ),
                              actions: [
                                TextButton(
                                  onPressed:
                                      () => Navigator.pop(context, false),
                                  child: Text(
                                    'Cancel',
                                    style: GoogleFonts.outfit(
                                      color: Colors.grey[400],
                                    ),
                                  ),
                                ),
                                ElevatedButton(
                                  onPressed: () => Navigator.pop(context, true),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: Colors.red,
                                    foregroundColor: Colors.white,
                                  ),
                                  child: Text(
                                    'Sign Out',
                                    style: GoogleFonts.outfit(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                      );

                      if (confirmed == true) {
                        try {
                          await SupabaseService().signOut();
                          if (mounted) {
                            setState(() {
                              _currentUser = null;
                            });
                            // Show success message
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  'Signed out successfully',
                                  style: GoogleFonts.outfit(),
                                ),
                                backgroundColor: Colors.green,
                              ),
                            );
                          }
                        } catch (e) {
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  'Error signing out: $e',
                                  style: GoogleFonts.outfit(),
                                ),
                                backgroundColor: Colors.red,
                              ),
                            );
                          }
                        }
                      }
                    },
                    icon: const Icon(Icons.logout_rounded, size: 20),
                    label: Text(
                      'Sign Out',
                      style: GoogleFonts.outfit(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.red.withOpacity(0.1),
                      foregroundColor: Colors.red,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                        side: BorderSide(color: Colors.red.withOpacity(0.3)),
                      ),
                    ),
                  ),
                ),
              ] else ...[
                // Sign In Button (when not logged in)
                const SizedBox(height: 20),
                Container(height: 1, color: Colors.white.withOpacity(0.05)),
                const SizedBox(height: 16),

                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => const LoginScreen(),
                        ),
                      ).then((_) {
                        // Refresh the UI after returning from login
                        setState(() {
                          _currentUser = SupabaseService().currentUser;
                        });
                      });
                    },
                    icon: const Icon(Icons.login_rounded, size: 20),
                    label: Text(
                      'Sign In with Google',
                      style: GoogleFonts.outfit(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFFFD600),
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _buildDeviceNameCard() {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1C1C1E).withOpacity(0.8),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.white.withOpacity(0.08)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: TextField(
        controller: _deviceNameController,
        style: GoogleFonts.outfit(
          color: Colors.white,
          fontSize: 16,
          fontWeight: FontWeight.w500,
        ),
        cursorColor: const Color(0xFFFFD600), // Yellow cursor
        decoration: InputDecoration(
          labelText: 'Device Name',
          labelStyle: GoogleFonts.outfit(
            color: Colors.grey[500],
            fontSize: 15,
            fontWeight: FontWeight.w500, // Fixed: w400 -> w500
          ),
          prefixIcon: const Icon(
            Icons.devices_rounded,
            color: Color(0xFFFFD600),
            size: 22,
          ),
          border: InputBorder.none, // Clean look, no underline
          suffixIcon: IconButton(
            icon: const Icon(
              Icons.check_circle_rounded,
              color: Color(0xFFFFD600),
            ),
            onPressed: () {
              FocusScope.of(context).unfocus();
              _saveDeviceName();
            },
          ),
        ),
        onSubmitted: (_) => _saveDeviceName(),
      ),
    );
  }

  Widget _buildDiscoveryCard() {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1C1C1E).withOpacity(0.8),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.white.withOpacity(0.08)),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        leading: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: const Color(0xFFFFD600).withOpacity(0.15),
            shape: BoxShape.circle,
          ),
          child: const Icon(
            Icons.radar_rounded,
            color: Color(0xFFFFD600),
            size: 22,
          ),
        ),
        title: Text(
          'Auto-Discovery',
          style: GoogleFonts.outfit(
            color: Colors.white,
            fontWeight: FontWeight.w600,
            fontSize: 16,
          ),
        ),
        subtitle: Text(
          'Allow nearby devices to find you',
          style: GoogleFonts.outfit(
            color: Colors.grey[500],
            fontSize: 14, // Increased size
            fontWeight: FontWeight.w500, // Fixed font weight
          ),
        ), // Fixed font weight
        trailing: Switch(
          value: _autoDiscoveryEnabled,
          onChanged: _toggleAutoDiscovery,
          activeColor: Colors.black, // Black dot
          activeTrackColor: const Color(0xFFFFD600), // Yellow background
          inactiveThumbColor: Colors.grey[400],
          inactiveTrackColor: Colors.white.withOpacity(0.1),
          trackOutlineColor: MaterialStateProperty.all(Colors.transparent),
        ),
      ),
    );
  }

  Widget _buildInfoCard() {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1C1C1E).withOpacity(0.8),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.white.withOpacity(0.08)),
      ),
      child: Column(
        children: [
          _buildInfoTile(
            'Platform',
            _getPlatformName(),
            Icons.phone_android_rounded,
          ),
          Divider(
            color: Colors.white.withOpacity(0.05),
            height: 1,
            indent: 20,
            endIndent: 20,
          ),
          _buildInfoTile('App Version', '1.0.0', Icons.info_outline_rounded),
        ],
      ),
    );
  }

  Widget _buildInfoTile(String title, String value, IconData icon) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
      leading: Icon(icon, color: Colors.grey[500], size: 20),
      title: Text(
        title,
        style: GoogleFonts.outfit(
          color: Colors.grey[400],
          fontSize: 15, // Increased size
          fontWeight: FontWeight.w500,
        ),
      ),
      trailing: Text(
        value,
        style: GoogleFonts.outfit(
          color: Colors.white,
          fontWeight: FontWeight.w600,
          fontSize: 15,
        ),
      ),
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

  Future<void> _saveDeviceName({bool manual = true}) async {
    final newName = _deviceNameController.text.trim();
    if (newName.isEmpty && manual) return;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('device_name', newName);

    setState(() => _currentDeviceName = newName);

    if (manual) {
      HapticFeedback.mediumImpact();
      if (mounted) Navigator.pop(context);
    }
  }

  @override
  void dispose() {
    _authSubscription?.cancel();
    _deviceNameController.dispose();
    super.dispose();
  }
}
