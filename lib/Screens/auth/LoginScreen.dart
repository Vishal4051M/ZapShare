import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:zap_share/services/firebase_service.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  bool _isLoading = false;
  String? _errorMessage;
  StreamSubscription<AuthState>? _authSubscription;

  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _nameController = TextEditingController();
  bool _showFallbackForm = false;

  @override
  void initState() {
    super.initState();
    _authSubscription = FirebaseService().authStateChanges.listen((data) {
      if (data.session != null && mounted) {
        // Debug: Print all user metadata after login
        final user = data.session?.user;
        if (user != null) {
          print('🔐 ========== LOGIN DEBUG ==========');
          print('📧 Email: ${user.email}');
          print('🆔 User ID: ${user.id}');
          print('📋 Raw Metadata:');
          if (user.userMetadata != null) {
            user.userMetadata!.forEach((key, value) {
              print('   $key: $value');
            });
          } else {
            print('   ⚠️ No metadata available!');
          }
          print('==========================================');
        }
        Navigator.of(context).pop();
      }
    });
  }

  @override
  void dispose() {
    _authSubscription?.cancel();
    _emailController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 12.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(20),
                decoration: const BoxDecoration(
                  color: Color(0xFF1C1C1E),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.cloud_sync_rounded,
                  size: 60,
                  color: Color(0xFFFFD600),
                ),
              ),
              const SizedBox(height: 24),
              Text(
                "Welcome to ZapShare",
                style: GoogleFonts.outfit(
                  color: Colors.white,
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              Text(
                "Sign in to sync your clipboard history and share files across your devices instantly.",
                style: GoogleFonts.outfit(
                  color: Colors.grey[400],
                  fontSize: 15,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 36),

              if (_errorMessage != null) ...[
                Text(
                  _errorMessage!,
                  style: GoogleFonts.outfit(
                    color: Colors.redAccent,
                    fontSize: 14,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
              ],

              // Google Sign-In — uses loopback OAuth on Windows,
              // native Google Sign-In on Android / iOS.
              SizedBox(
                width: double.infinity,
                height: 56,
                child: OutlinedButton.icon(
                  onPressed:
                      _isLoading
                          ? null
                          : () async {
                            setState(() {
                              _isLoading = true;
                              _errorMessage = null;
                            });
                            try {
                              final bool isDesktop =
                                  !kIsWeb &&
                                  (Platform.isWindows ||
                                      Platform.isLinux ||
                                      Platform.isMacOS);

                              final success =
                                  isDesktop
                                      ? await FirebaseService()
                                          .signInWithGoogleDesktop()
                                      : await FirebaseService()
                                          .signInWithGoogle();

                              if (!success && mounted) {
                                setState(() {
                                  _errorMessage =
                                      isDesktop
                                          ? "Google Sign-In requires a Desktop OAuth Client ID. "
                                              "See firebase_service.dart for setup. "
                                              "Use the Email option below in the meantime."
                                          : "Google Sign-In was cancelled or failed. "
                                              "Use the Email option below.";
                                  _showFallbackForm = true;
                                });
                              }
                            } catch (e) {
                              if (mounted) {
                                setState(() {
                                  _errorMessage = e.toString();
                                  _showFallbackForm = true;
                                });
                              }
                            } finally {
                              if (mounted) setState(() => _isLoading = false);
                            }
                          },
                  icon: Image.asset(
                    'assets/images/google_logo.png',
                    height: 24,
                    errorBuilder:
                        (c, e, s) =>
                            const Icon(Icons.login, color: Colors.white),
                  ),
                  label: Text(
                    "Sign in with Google",
                    style: GoogleFonts.outfit(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(color: Colors.white.withOpacity(0.2)),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    backgroundColor: const Color(0xFF1C1C1E),
                  ),
                ),
              ),

              const SizedBox(height: 24),

              Row(
                children: [
                  Expanded(
                    child: Divider(color: Colors.white.withOpacity(0.1)),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Text(
                      "OR",
                      style: GoogleFonts.outfit(
                        color: Colors.grey[600],
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Divider(color: Colors.white.withOpacity(0.1)),
                  ),
                ],
              ),

              const SizedBox(height: 16),

              if (!_showFallbackForm)
                TextButton(
                  onPressed: () => setState(() => _showFallbackForm = true),
                  child: Text(
                    "Sign in with Email / Custom ID instead",
                    style: GoogleFonts.outfit(
                      color: const Color(0xFFFFD600),
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                )
              else
                Form(
                  key: _formKey,
                  child: Column(
                    children: [
                      TextFormField(
                        controller: _emailController,
                        style: GoogleFonts.outfit(color: Colors.white),
                        decoration: InputDecoration(
                          hintText: "Enter your Gmail address",
                          hintStyle: GoogleFonts.outfit(
                            color: Colors.grey[600],
                          ),
                          prefixIcon: const Icon(
                            Icons.email_outlined,
                            color: Colors.grey,
                          ),
                          filled: true,
                          fillColor: const Color(0xFF1C1C1E),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(16),
                            borderSide: BorderSide.none,
                          ),
                        ),
                        validator: (value) {
                          if (value == null || value.trim().isEmpty) {
                            return "Email is required";
                          }
                          if (!value.contains('@')) {
                            return "Please enter a valid email address";
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _nameController,
                        style: GoogleFonts.outfit(color: Colors.white),
                        decoration: InputDecoration(
                          hintText: "Enter display name",
                          hintStyle: GoogleFonts.outfit(
                            color: Colors.grey[600],
                          ),
                          prefixIcon: const Icon(
                            Icons.person_outline,
                            color: Colors.grey,
                          ),
                          filled: true,
                          fillColor: const Color(0xFF1C1C1E),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(16),
                            borderSide: BorderSide.none,
                          ),
                        ),
                        validator: (value) {
                          if (value == null || value.trim().isEmpty) {
                            return "Display name is required";
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 24),
                      SizedBox(
                        width: double.infinity,
                        height: 52,
                        child: ElevatedButton(
                          onPressed:
                              _isLoading
                                  ? null
                                  : () async {
                                    if (_formKey.currentState!.validate()) {
                                      setState(() {
                                        _isLoading = true;
                                        _errorMessage = null;
                                      });
                                      try {
                                        await FirebaseService().signInWithEmail(
                                          _emailController.text,
                                          _nameController.text,
                                        );
                                      } catch (e) {
                                        if (mounted) {
                                          setState(
                                            () => _errorMessage = e.toString(),
                                          );
                                        }
                                      } finally {
                                        if (mounted)
                                          setState(() => _isLoading = false);
                                      }
                                    }
                                  },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFFFFD600),
                            foregroundColor: Colors.black,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                          ),
                          child: Text(
                            "Continue",
                            style: GoogleFonts.outfit(
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 24),
              if (_isLoading && !_showFallbackForm)
                const CircularProgressIndicator(color: Color(0xFFFFD600)),
            ],
          ),
        ),
      ),
    );
  }
}
