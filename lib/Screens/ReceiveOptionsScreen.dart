import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'AndroidReceiveScreen.dart';
import 'WebReceiveScreen.dart';

class ReceiveOptionsScreen extends StatelessWidget {
  const ReceiveOptionsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            // Header
            Container(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
              child: Row(
                children: [
                  IconButton(
                    icon: Icon(Icons.arrow_back_ios_rounded, color: Colors.white, size: 20),
                    onPressed: () => Navigator.pop(context),
                  ),
                  Expanded(
                    child: Text(
                      'Receive Files',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 28,
                        fontWeight: FontWeight.w300,
                        letterSpacing: -0.5,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                  const SizedBox(width: 48), // Balance the back button
                ],
              ),
            ),
            
            // Description
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                'Choose how you want to receive files',
                style: TextStyle(
                  color: Colors.grey[400],
                  fontSize: 16,
                  fontWeight: FontWeight.w400,
                ),
                textAlign: TextAlign.center,
              ),
            ),
            
            const SizedBox(height: 40),
            
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
                      subtitle: 'Enter a sharing code to download files',
                      description: 'Get files from someone who is sharing using a connection code',
                      onTap: () => _navigateToScreen(context, AndroidReceiveScreen()),
                    ),
                    
                    const SizedBox(height: 16),
                    
                    // Web Receive Option
                    _buildOptionCard(
                      context,
                      icon: Icons.wifi_tethering,
                      title: 'Web Receive',
                      subtitle: 'Start a web server for others to upload files',
                      description: '',
                      onTap: () => _navigateToScreen(context, WebReceiveScreen()),
                    ),
                    
                    const Spacer(),
                    
                    // Quick Tips (match HomeScreen style)
                    Container(
                      margin: const EdgeInsets.symmetric(horizontal: 0),
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: Colors.grey[900],
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: Colors.grey[800]!, width: 1),
                      ),
                      child: Column(
                        children: [
                          Row(
                            children: [
                              Icon(
                                Icons.lightbulb_outline,
                                color: Colors.yellow[300],
                                size: 24,
                              ),
                              const SizedBox(width: 10),
                              Text(
                                'Quick Tips',
                                style: TextStyle(
                                  color: Colors.yellow[300],
                                  fontSize: 18,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          Text(
                            '• Both devices must be on the same WiFi network\n• Long press on images to preview before downloading\n• Connection codes are 8 characters (A-Z, 0-9)',
                            style: TextStyle(
                              color: Colors.grey[400],
                              fontSize: 15,
                              fontWeight: FontWeight.w400,
                              height: 1.5,
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
    );
  }

  Widget _buildOptionCard(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required String description,
    required VoidCallback onTap,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final double tileHeight = 84; // Compact fixed height to prevent overflow
        return Container(
          width: double.infinity,
          constraints: BoxConstraints.tightFor(height: tileHeight),
          decoration: BoxDecoration(
            color: Colors.grey[900],
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: Colors.grey[800]!,
              width: 1,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.1),
                blurRadius: 8,
                offset: const Offset(0, 2),
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
              borderRadius: BorderRadius.circular(16),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: Colors.yellow[300],
                        borderRadius: BorderRadius.circular(12),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.yellow[300]!.withOpacity(0.3),
                            blurRadius: 6,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: Icon(
                        icon,
                        color: Colors.black,
                        size: 22,
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            title,
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 17,
                              fontWeight: FontWeight.w600,
                              letterSpacing: -0.2,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            subtitle,
                            style: TextStyle(
                              color: Colors.grey[400],
                              fontSize: 13,
                              fontWeight: FontWeight.w400,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    Icon(
                      Icons.chevron_right_rounded,
                      color: Colors.grey[600],
                      size: 20,
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  void _navigateToScreen(BuildContext context, Widget targetScreen) {
    Navigator.push(
      context,
      PageRouteBuilder(
        transitionDuration: Duration(milliseconds: 300),
        pageBuilder: (context, animation, secondaryAnimation) => targetScreen,
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          var begin = Offset(1.0, 0.0);
          var end = Offset.zero;
          var curve = Curves.easeInOutCubic;
          
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
