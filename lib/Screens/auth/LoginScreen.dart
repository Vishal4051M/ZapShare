import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:zap_share/services/supabase_service.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  bool _isLoading = false;
  String? _errorMessage;
  StreamSubscription<AuthState>? _authSubscription;

  @override
  void initState() {
    super.initState();
    _authSubscription = SupabaseService().authStateChanges.listen((data) {
      if (data.session != null && mounted) {
        // Debug: Print all user metadata after login
        final user = data.session?.user;
        if (user != null) {
          print('🔐 ========== GOOGLE LOGIN DEBUG ==========');
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
        // User logged in successfully via Google deep link
        Navigator.of(context).pop();
      }
    });
  }

  @override
  void dispose() {
    _authSubscription?.cancel();
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
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Logo or Icon could go here
              Container(
                padding: EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: Color(0xFF1C1C1E),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.cloud_sync_rounded,
                  size: 60,
                  color: Color(0xFFFFD600),
                ),
              ),
              const SizedBox(height: 32),
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
                "Sign in to sync your clipboard history across all your devices instantly.",
                style: GoogleFonts.outfit(
                  color: Colors.grey[400],
                  fontSize: 16,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 48),

              if (_errorMessage != null) ...[
                Text(
                  _errorMessage!,
                  style: GoogleFonts.outfit(
                    color: Colors.redAccent,
                    fontSize: 14,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
              ],

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
                              await SupabaseService().signInWithGoogle();
                              // Note: OAuth flow might redirect out of app, so navigation happens on resume/callback
                              // But for now we assume success if it returns without error or handle deep link separately
                            } catch (e) {
                              if (mounted)
                                setState(() => _errorMessage = e.toString());
                            } finally {
                              if (mounted) setState(() => _isLoading = false);
                            }
                          },
                  icon: Image.asset(
                    'assets/images/google_logo.png',
                    height: 24,
                    errorBuilder:
                        (c, e, s) => Icon(Icons.login, color: Colors.white),
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
                    backgroundColor: Color(0xFF1C1C1E),
                  ),
                ),
              ),
              const SizedBox(height: 24),
              if (_isLoading)
                const CircularProgressIndicator(color: Color(0xFFFFD600)),
            ],
          ),
        ),
      ),
    );
  }
}
