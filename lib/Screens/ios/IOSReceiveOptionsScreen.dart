import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:ui';
import 'IOSReceiveScreen.dart';
import 'IOSWebReceiveScreen.dart';

// Modern Color Constants matched with IOSHomeScreen
const Color kZapPrimary = Color(0xFFFFD84D); // Logo Yellow Light
const Color kZapPrimaryDark = Color(0xFFF5C400); // Logo Yellow Dark
const Color kZapBackgroundTop = Color(0xFF0E1116); // Soft Charcoal Top
const Color kZapBackgroundBottom = Color(0xFF07090D); // Soft Charcoal Bottom
const Color kZapSurface = Color(0xFF1C1C1E); 

class IOSReceiveOptionsScreen extends StatelessWidget {
  final VoidCallback? onBack;
  const IOSReceiveOptionsScreen({super.key, this.onBack});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBody: true,
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [kZapBackgroundTop, kZapBackgroundBottom],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
               // Header with Hero
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 24, 24),
                child: Row(
                  children: [
                     Hero(
                       tag: 'receive_fab', 
                       child: Material(
                         color: Colors.transparent,
                         child: Container(
                          decoration: BoxDecoration(
                            color: kZapSurface,
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white.withOpacity(0.1)),
                          ),
                          child: IconButton(
                            icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
                            onPressed: () {
                               if (onBack != null) {
                                  onBack!();
                               } else {
                                  Navigator.pop(context);
                               }
                            },
                          ),
                         ),
                       ),
                     ),
                    const SizedBox(width: 16),
                    const Text(
                      'Receive Files',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                        letterSpacing: -0.5,
                      ),
                    ),
                  ],
                ),
              ),
              
              // Description
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Text(
                  'Choose how you want to receive files from other devices.',
                  style: TextStyle(
                    color: Colors.grey[400],
                    fontSize: 16,
                    height: 1.5,
                    fontWeight: FontWeight.w400,
                  ),
                ),
              ),
              
              const SizedBox(height: 32),
              
              // Options
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Column(
                    children: [
                      // Receive by Code Option (first)
                        _buildOptionCard(
                          context,
                          icon: Icons.tag,
                          title: 'Receive by Code',
                          subtitle: 'Enter an 8-digit key',
                          onTap: () => _navigateToScreen(context, const IOSReceiveScreen()),
                        ),
                      
                      const SizedBox(height: 16),
                      
                      // Web Receive Option
                      _buildOptionCard(
                        context,
                        icon: Icons.wifi_tethering,
                        title: 'Web Receive',
                        subtitle: 'Receive via browser',
                        onTap: () => _navigateToScreen(context, const IOSWebReceiveScreen()),
                      ),
                      
                      const Spacer(),
                      
                      // Quick Tips
                      Container(
                        margin: const EdgeInsets.only(bottom: 24),
                        padding: const EdgeInsets.all(24),
                        decoration: BoxDecoration(
                          color: kZapSurface.withOpacity(0.5),
                          borderRadius: BorderRadius.circular(24),
                          border: Border.all(color: Colors.white.withOpacity(0.08)),
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(24),
                          child: BackdropFilter(
                            filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    const Icon(
                                      Icons.info_outline_rounded,
                                      color: kZapPrimary,
                                      size: 24,
                                    ),
                                    const SizedBox(width: 12),
                                    const Text(
                                      'Good to know',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 16,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 16),
                                Text(
                                  '• Long press on images to preview before downloading\n• Both devices must be on the same WiFi network\n• Connection codes are temporary and secure',
                                  style: TextStyle(
                                    color: Colors.grey[400],
                                    fontSize: 14,
                                    fontWeight: FontWeight.w400,
                                    height: 1.6,
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
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildOptionCard(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            const Color(0xFF1C1C1E).withOpacity(0.9),
            const Color(0xFF1C1C1E).withOpacity(0.6),
          ],
        ),
        border: Border.all(
          color: Colors.white.withOpacity(0.08),
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
             color: Colors.black.withOpacity(0.2),
             blurRadius: 20,
             offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () {
            HapticFeedback.lightImpact();
            onTap();
          },
          borderRadius: BorderRadius.circular(24),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Container(
                  width: 50,
                  height: 50,
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.05),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: Colors.white.withOpacity(0.05)),
                  ),
                  child: Icon(
                    icon,
                    color: kZapPrimary,
                    size: 24,
                  ),
                ),
                const SizedBox(width: 20),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                          letterSpacing: -0.2,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        subtitle,
                        style: TextStyle(
                          color: Colors.grey[500],
                          fontSize: 13,
                          fontWeight: FontWeight.w400,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  Icons.arrow_forward_rounded,
                  color: Colors.grey[700],
                  size: 20,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _navigateToScreen(BuildContext context, Widget targetScreen) {
    Navigator.push(
      context,
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 300),
        pageBuilder: (context, animation, secondaryAnimation) => targetScreen,
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          var begin = const Offset(1.0, 0.0);
          var end = Offset.zero;
          var curve = Curves.fastOutSlowIn;
          
          var tween = Tween(begin: begin, end: end)
              .chain(CurveTween(curve: curve));
          
          return SlideTransition(
            position: animation.drive(tween),
            child: child,
          );
        },
      ),
    );
  }
}
