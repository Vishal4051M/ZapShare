import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zap_share/Screens/auth/LoginScreen.dart';
import 'package:zap_share/Screens/shared/AvatarPickerScreen.dart';
import 'package:zap_share/services/firebase_service.dart';
import 'package:zap_share/widgets/CustomAvatarWidget.dart';
import 'package:zap_share/widgets/tv_widgets.dart';

class FirstTimeSetupScreen extends StatefulWidget {
  final VoidCallback onSetupComplete;

  const FirstTimeSetupScreen({super.key, required this.onSetupComplete});

  @override
  State<FirstTimeSetupScreen> createState() => _FirstTimeSetupScreenState();
}

class _FirstTimeSetupScreenState extends State<FirstTimeSetupScreen> {
  final TextEditingController _nameController = TextEditingController();
  final FocusNode _nameNode = FocusNode();
  bool _isNameFocused = false;

  final TextEditingController _usernameController = TextEditingController();
  final FocusNode _usernameNode = FocusNode();
  bool _isUsernameFocused = false;

  String _selectedAvatar = 'face_1';
  bool _isLoading = false;
  User? _currentUser;

  @override
  void initState() {
    super.initState();
    // Check if user is already logged in (unlikely for fresh install, but possible)
    _currentUser = FirebaseService().currentUser;
    if (_currentUser != null) {
      _nameController.text = _currentUser!.userMetadata?['full_name'] ?? 'User';
      _usernameController.text =
          _currentUser!.email?.split('@').first.replaceAll('.', '_') ?? '';
      final googlePhoto = _currentUser!.userMetadata?['picture'] ?? '';
      if (googlePhoto.isNotEmpty) {
        _selectedAvatar = googlePhoto;
      }
    }
    _nameNode.addListener(_onNameFocusChange);
    _usernameNode.addListener(_onUsernameFocusChange);
    _loadExistingProfile();
  }

  Future<void> _loadExistingProfile() async {
    final user = FirebaseService().currentUser;
    if (user != null) {
      setState(() => _isLoading = true);
      try {
        final currentFirebaseUid = FirebaseService().firebaseUid;
        if (currentFirebaseUid != null) {
          final profile = await FirebaseService().getUserProfileByUid(
            currentFirebaseUid,
          );
          if (profile != null && mounted) {
            setState(() {
              _nameController.text =
                  profile['fullName'] ?? _nameController.text;
              _usernameController.text =
                  profile['username'] ?? _usernameController.text;
              final avatar = profile['avatarUrl'] ?? '';
              if (avatar.isNotEmpty) {
                _selectedAvatar = avatar;
              }
            });
          }
        }
      } catch (e) {
        print("Error loading existing profile: $e");
      } finally {
        if (mounted) {
          setState(() => _isLoading = false);
        }
      }
    }
  }

  @override
  void dispose() {
    _nameNode.removeListener(_onNameFocusChange);
    _usernameNode.removeListener(_onUsernameFocusChange);
    _nameNode.dispose();
    _usernameNode.dispose();
    _nameController.dispose();
    _usernameController.dispose();
    super.dispose();
  }

  void _onNameFocusChange() {
    if (!mounted) return;
    setState(() {
      _isNameFocused = _nameNode.hasFocus;
    });
  }

  void _onUsernameFocusChange() {
    if (!mounted) return;
    setState(() {
      _isUsernameFocused = _usernameNode.hasFocus;
    });
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

    final username = _usernameController.text.trim().toLowerCase();
    if (_currentUser != null && username.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Please enter a unique username',
            style: GoogleFonts.outfit(color: Colors.white),
          ),
          backgroundColor: Colors.redAccent,
          behavior: SnackBarBehavior.floating,
        ),
      );
      _usernameNode.requestFocus();
      return;
    }

    setState(() => _isLoading = true);

    // Save locally & database
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('device_name', name);
    await prefs.setString('custom_avatar', _selectedAvatar);
    await prefs.setString('username', username);
    await prefs.setBool('first_run_complete', true);

    // Sync with Supabase if logged in
    if (_currentUser != null) {
      try {
        final currentFirebaseUid = FirebaseService().firebaseUid;
        final available = await FirebaseService().isUsernameAvailable(username);
        if (!available) {
          final existingUid = await FirebaseService().getUidFromUsernameOrEmail(
            username,
          );
          if (existingUid != null && existingUid != currentFirebaseUid) {
            setState(() => _isLoading = false);
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  'Username is already taken!',
                  style: GoogleFonts.outfit(color: Colors.white),
                ),
                backgroundColor: Colors.redAccent,
                behavior: SnackBarBehavior.floating,
              ),
            );
            return;
          }
        }
        await FirebaseService().saveUserProfile(
          username: username,
          fullName: name,
          avatarUrl: _selectedAvatar,
        );
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
    final user = FirebaseService().currentUser;
    if (user != null && mounted) {
      final googlePhoto = user.userMetadata?['picture'] ?? '';
      final defaultUsername =
          user.email?.split('@').first.replaceAll('.', '_') ?? '';
      setState(() {
        _currentUser = user;
        // Pre-fill name if empty
        if (_nameController.text.isEmpty) {
          _nameController.text = user.userMetadata?['full_name'] ?? '';
        }
        if (_usernameController.text.isEmpty) {
          _usernameController.text = defaultUsername;
        }
        if (googlePhoto.isNotEmpty) {
          _selectedAvatar = googlePhoto;
        }
      });
      await _loadExistingProfile();
    }
  }

  Future<void> _openAvatarPicker() async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder:
            (context) => AvatarPickerScreen(currentAvatar: _selectedAvatar),
      ),
    );
    if (result != null && mounted) {
      setState(() => _selectedAvatar = result);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isTV = TVHelper.isTV(context);
    final showSignIn = !isTV && _currentUser == null;
    final showSignedInInfo = !isTV && _currentUser != null;
    final continueLabel =
        _currentUser == null
            ? (isTV ? 'Continue' : 'Continue as Guest')
            : 'Continue';
    final avatarHint =
        isTV ? 'Press OK to change avatar' : 'Tap to change avatar';

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: FocusTraversalGroup(
          policy: OrderedTraversalPolicy(),
          child: CustomScrollView(
            slivers: [
              SliverFillRemaining(
                hasScrollBody: false,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 40,
                  ),
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
                        child: FocusTraversalOrder(
                          order: const NumericFocusOrder(1.0),
                          child:
                              isTV
                                  ? TVFocusableButton(
                                    autofocus: true,
                                    onPressed: _openAvatarPicker,
                                    padding: EdgeInsets.zero,
                                    borderRadius: BorderRadius.circular(60),
                                    backgroundColor: Colors.transparent,
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
                                                color: const Color(
                                                  0xFFFFD600,
                                                ).withOpacity(0.2),
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
                                  )
                                  : GestureDetector(
                                    onTap: _openAvatarPicker,
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
                                                color: const Color(
                                                  0xFFFFD600,
                                                ).withOpacity(0.2),
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
                      ),

                      const SizedBox(height: 16),
                      Center(
                        child: Text(
                          avatarHint,
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
                      if (showSignIn) ...[
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
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
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
                                  icon: const Icon(
                                    Icons.login_rounded,
                                    size: 20,
                                  ),
                                  label: const Text("Sign In with Google"),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: Colors.white,
                                    foregroundColor: Colors.black,
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 12,
                                    ),
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
                      ] else if (showSignedInInfo) ...[
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
                      FocusTraversalOrder(
                        order: const NumericFocusOrder(2.0),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 160),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(16),
                            boxShadow:
                                _isNameFocused
                                    ? [
                                      BoxShadow(
                                        color: const Color(
                                          0xFFFFD600,
                                        ).withOpacity(0.4),
                                        blurRadius: 16,
                                        spreadRadius: 2,
                                      ),
                                      BoxShadow(
                                        color: const Color(
                                          0xFFFFD600,
                                        ).withOpacity(0.18),
                                        blurRadius: 32,
                                        spreadRadius: 6,
                                      ),
                                    ]
                                    : null,
                          ),
                          child: TextField(
                            controller: _nameController,
                            focusNode: _nameNode,
                            style: GoogleFonts.outfit(
                              color: Colors.white,
                              fontSize: 18,
                            ),
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
                                borderSide: const BorderSide(
                                  color: Color(0xFFFFD600),
                                ),
                              ),
                              contentPadding: const EdgeInsets.all(20),
                              prefixIcon: Icon(
                                Icons.badge_rounded,
                                color:
                                    _isNameFocused
                                        ? const Color(0xFFFFD600)
                                        : Colors.grey[600],
                              ),
                            ),
                          ),
                        ),
                      ),

                      if (_currentUser != null) ...[
                        const SizedBox(height: 24),
                        Text(
                          "UNIQUE USERNAME",
                          style: GoogleFonts.outfit(
                            color: const Color(0xFF9E9E9E),
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 1.5,
                            height: 1.5,
                          ),
                        ),
                        const SizedBox(height: 8),
                        FocusTraversalOrder(
                          order: const NumericFocusOrder(2.5),
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 160),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(16),
                              boxShadow:
                                  _isUsernameFocused
                                      ? [
                                        BoxShadow(
                                          color: const Color(
                                            0xFFFFD600,
                                          ).withOpacity(0.4),
                                          blurRadius: 16,
                                          spreadRadius: 2,
                                        ),
                                        BoxShadow(
                                          color: const Color(
                                            0xFFFFD600,
                                          ).withOpacity(0.18),
                                          blurRadius: 32,
                                          spreadRadius: 6,
                                        ),
                                      ]
                                      : null,
                            ),
                            child: TextField(
                              controller: _usernameController,
                              focusNode: _usernameNode,
                              style: GoogleFonts.outfit(
                                color: Colors.white,
                                fontSize: 18,
                              ),
                              cursorColor: const Color(0xFFFFD600),
                              decoration: InputDecoration(
                                hintText: "Choose a unique username",
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
                                  borderSide: const BorderSide(
                                    color: Color(0xFFFFD600),
                                  ),
                                ),
                                contentPadding: const EdgeInsets.all(20),
                                prefixIcon: Icon(
                                  Icons.alternate_email_rounded,
                                  color:
                                      _isUsernameFocused
                                          ? const Color(0xFFFFD600)
                                          : Colors.grey[600],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],

                      const Spacer(),

                      // Continue Button
                      FocusTraversalOrder(
                        order: const NumericFocusOrder(3.0),
                        child: SizedBox(
                          width: double.infinity,
                          height: 56,
                          child:
                              isTV
                                  ? TVFocusableButton(
                                    onPressed:
                                        _isLoading ? null : _handleComplete,
                                    backgroundColor: const Color(0xFFFFD600),
                                    borderRadius: BorderRadius.circular(16),
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 16,
                                    ),
                                    child: Center(
                                      child:
                                          _isLoading
                                              ? const SizedBox(
                                                width: 24,
                                                height: 24,
                                                child:
                                                    CircularProgressIndicator(
                                                      color: Colors.black,
                                                      strokeWidth: 2,
                                                    ),
                                              )
                                              : Text(
                                                continueLabel,
                                                style: GoogleFonts.outfit(
                                                  fontSize: 18,
                                                  fontWeight: FontWeight.bold,
                                                  color: Colors.black,
                                                ),
                                              ),
                                    ),
                                  )
                                  : ElevatedButton(
                                    onPressed:
                                        _isLoading ? null : _handleComplete,
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
                                              continueLabel,
                                              style: GoogleFonts.outfit(
                                                fontSize: 18,
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                  ),
                        ),
                      ),
                      if (!isTV && _currentUser == null) ...[
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
      ),
    );
  }
}
