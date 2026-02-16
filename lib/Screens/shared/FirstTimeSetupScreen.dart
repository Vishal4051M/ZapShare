import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zap_share/Screens/auth/LoginScreen.dart';
import 'package:zap_share/Screens/shared/AvatarPickerScreen.dart';
import 'package:zap_share/services/supabase_service.dart';
import 'package:zap_share/widgets/CustomAvatarWidget.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class FirstTimeSetupScreen extends StatefulWidget {
  final VoidCallback onSetupComplete;

  const FirstTimeSetupScreen({super.key, required this.onSetupComplete});

  @override
  State<FirstTimeSetupScreen> createState() => _FirstTimeSetupScreenState();
}

class _FirstTimeSetupScreenState extends State<FirstTimeSetupScreen> {
  final TextEditingController _nameController = TextEditingController();
  final FocusNode _nameNode = FocusNode();
  String _selectedAvatar = 'face_1';
  bool _isLoading = false;
  User? _currentUser;

  @override
  void initState() {
    super.initState();
    // Check if user is already logged in (unlikely for fresh install, but possible)
    _currentUser = SupabaseService().currentUser;
    if (_currentUser != null) {
      _nameController.text = _currentUser!.userMetadata?['full_name'] ?? 'User';
    }
  }

  Future<void> _handleComplete() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Please enter a device name',
            style: GoogleFonts.outfit(color: Colors.white),
          ),
          backgroundColor: Colors.redAccent,
          behavior: SnackBarBehavior.floating,
        ),
      );
      _nameNode.requestFocus();
      return;
    }

    setState(() => _isLoading = true);

    // Save locally
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('device_name', name);
    await prefs.setString('custom_avatar', _selectedAvatar);
    await prefs.setBool('first_run_complete', true);

    // Sync with Supabase if logged in
    if (_currentUser != null) {
      try {
        await SupabaseService().updateUserProfile(avatarUrl: _selectedAvatar);
        // Note: Device name is usually local, but we could sync it if we had a field.
        // For now just avatar.
      } catch (e) {
        print('Error syncing profile: $e');
      }
    }

    if (mounted) {
      setState(() => _isLoading = false);
      widget.onSetupComplete();
    }
  }

  Future<void> _signInWithGoogle() async {
    // Navigate to Login Screen which handles the auth flow
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const LoginScreen()),
    );

    // Refresh state after return
    final user = SupabaseService().currentUser;
    if (user != null && mounted) {
      setState(() {
        _currentUser = user;
        // Pre-fill name if empty
        if (_nameController.text.isEmpty) {
          _nameController.text = user.userMetadata?['full_name'] ?? '';
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: CustomScrollView(
          slivers: [
            SliverFillRemaining(
              hasScrollBody: false,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
              const SizedBox(height: 20),
              // Header
              Text(
                "Welcome to ZapShare",
                style: GoogleFonts.outfit(
                  color: Colors.white,
                  fontSize: 32,
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                "Set up your profile to start sharing",
                style: GoogleFonts.outfit(
                  color: const Color(0xFF9E9E9E),
                  fontSize: 16,
                  height: 1.4,
                  letterSpacing: 0.2,
                ),
                textAlign: TextAlign.center,
              ),

              const SizedBox(height: 48),

              // Avatar Selection
              Center(
                child: GestureDetector(
                  onTap: () async {
                    final result = await Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder:
                            (context) => AvatarPickerScreen(
                              currentAvatar: _selectedAvatar,
                            ),
                      ),
                    );
                    if (result != null && mounted) {
                      setState(() => _selectedAvatar = result);
                    }
                  },
                  child: Stack(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(4),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: const Color(0xFFFFD600),
                            width: 2,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: const Color(0xFFFFD600).withOpacity(0.2),
                              blurRadius: 20,
                              spreadRadius: 5,
                            ),
                          ],
                        ),
                        child: CustomAvatarWidget(
                          avatarId: _selectedAvatar,
                          size: 100,
                          useBackground: true,
                        ),
                      ),
                      Positioned(
                        bottom: 0,
                        right: 0,
                        child: Container(
                          padding: const EdgeInsets.all(8),
                          decoration: const BoxDecoration(
                            color: Color(0xFFFFD600),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.edit_rounded,
                            color: Colors.black,
                            size: 16,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 16),
              Center(
                child: Text(
                  "Tap to change avatar",
                  style: GoogleFonts.outfit(
                    color: const Color(0xFF757575),
                    fontSize: 13,
                    height: 1.5,
                    letterSpacing: 0.3,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),

              const SizedBox(height: 40),

              // Sign In Section (Optional)
              if (_currentUser == null) ...[
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1C1C1E),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: Colors.white10),
                  ),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          const Icon(
                            Icons.cloud_sync_rounded,
                            color: Color(0xFFFFD600),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  "Sync Clipboard & History",
                                  style: GoogleFonts.outfit(
                                    color: Colors.white,
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                Text(
                                  "Sign in to access features across devices",
                                  style: GoogleFonts.outfit(
                                    color: const Color(0xFF9E9E9E),
                                    fontSize: 13,
                                    height: 1.5,
                                    letterSpacing: 0.2,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          onPressed: _signInWithGoogle,
                          icon: const Icon(Icons.login_rounded, size: 20),
                          label: const Text("Sign In with Google"),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.white,
                            foregroundColor: Colors.black,
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 32),
              ] else ...[
                // User is signed in display
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1C1C1E),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: const Color(0xFFFFD600).withOpacity(0.3),
                    ),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.check_circle_rounded,
                        color: Color(0xFFFFD600),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          "Signed in as ${_currentUser?.email}",
                          style: GoogleFonts.outfit(
                            color: const Color(0xFFB3B3B3),
                            fontSize: 14,
                            height: 1.4,
                            letterSpacing: 0.2,
                            fontWeight: FontWeight.w500,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 32),
              ],

              // Name Input
              Text(
                "DISPLAY NAME",
                style: GoogleFonts.outfit(
                  color: const Color(0xFF9E9E9E),
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1.5,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _nameController,
                focusNode: _nameNode,
                style: GoogleFonts.outfit(color: Colors.white, fontSize: 18),
                cursorColor: const Color(0xFFFFD600),
                decoration: InputDecoration(
                  hintText: "Enter your name",
                  hintStyle: GoogleFonts.outfit(
                    color: const Color(0xFF616161),
                    fontSize: 18,
                    height: 1.4,
                    letterSpacing: 0.2,
                  ),
                  filled: true,
                  fillColor: const Color(0xFF1C1C1E),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide: BorderSide.none,
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide: const BorderSide(color: Color(0xFFFFD600)),
                  ),
                  contentPadding: const EdgeInsets.all(20),
                  prefixIcon: Icon(
                    Icons.badge_rounded,
                    color:
                        _nameNode.hasFocus
                            ? const Color(0xFFFFD600)
                            : Colors.grey[600],
                  ),
                ),
              ),

              const Spacer(),

              // Continue Button
              SizedBox(
                width: double.infinity,
                height: 56,
                child: ElevatedButton(
                  onPressed: _isLoading ? null : _handleComplete,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFFFD600),
                    foregroundColor: Colors.black,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    elevation: 0,
                  ),
                  child:
                      _isLoading
                          ? const SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(
                              color: Colors.black,
                              strokeWidth: 2,
                            ),
                          )
                          : Text(
                            _currentUser == null
                                ? "Continue as Guest"
                                : "Continue",
                            style: GoogleFonts.outfit(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                ),
              ),
              if (_currentUser == null) ...[
                const SizedBox(height: 16),
                TextButton(
                  onPressed:
                      _handleComplete, // Same completion logic, just explicitly skipping intent
                  child: Text(
                    "Skip Sign In",
                    style: GoogleFonts.outfit(
                      color: const Color(0xFF9E9E9E),
                      fontSize: 14,
                      height: 1.4,
                      letterSpacing: 0.3,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
