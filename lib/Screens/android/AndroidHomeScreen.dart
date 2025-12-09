import 'package:zap_share/Screens/android/AndroidReceiveOptionsScreen.dart';
import 'package:zap_share/Screens/android/AndroidHttpFileShareScreen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:zap_share/Screens/shared/TransferHistoryScreen.dart';
import 'package:zap_share/Screens/shared/DeviceSettingsScreen.dart';

class AndroidHomeScreen extends StatefulWidget {
  const AndroidHomeScreen({super.key});

  @override
  _AndroidHomeScreenState createState() => _AndroidHomeScreenState();
}

class _AndroidHomeScreenState extends State<AndroidHomeScreen> {
  static const MethodChannel _platform = MethodChannel('zapshare.saf');

  @override
  void initState() {
    super.initState();
    _listenForSharedFiles();
  }

  void _listenForSharedFiles() {
    _platform.setMethodCallHandler((call) async {
      if (call.method == 'sharedFiles') {
        final List<dynamic> files = call.arguments as List<dynamic>;
        if (files.isNotEmpty && mounted) {
          print(
            '📁 [HomeScreen] Received shared files: ${files.length} files, navigating to send screen',
          );
          // Navigate to send screen with the files
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(
              builder:
                  (context) => AndroidHttpFileShareScreen(
                    initialSharedFiles: files.cast<Map<dynamic, dynamic>>(),
                  ),
            ),
          );
        }
      }
      return null;
    });
  }

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
              child: Column(
                children: [
                  // Use a Stack so the title stays visually centered while the
                  // settings icon sits on the right edge.
                  Stack(
                    children: [
                      // Centered title/subtitle
                      Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              "ZapShare",
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 28,
                                fontWeight: FontWeight.w300,
                                letterSpacing: -0.5,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              "Share files instantly",
                              style: TextStyle(
                                color: Colors.grey[400],
                                fontSize: 15,
                                fontWeight: FontWeight.w400,
                              ),
                            ),
                          ],
                        ),
                      ),

                      // Settings icon aligned to the right
                      Positioned(
                        right: 0,
                        top: 0,
                        child: IconButton(
                          icon: Icon(
                            Icons.settings_outlined,
                            color: Colors.grey[400],
                          ),
                          onPressed: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder:
                                    (context) => const DeviceSettingsScreen(),
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            // Main content
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Column(
                  children: [
                    // Send files card
                    _buildActionCard(
                      icon: Icons.upload_rounded,
                      title: "Send Files",
                      subtitle: "Share files with others",
                      onTap: () => _navigateToScreen(0),
                    ),

                    const SizedBox(height: 16),

                    // Receive files card
                    _buildActionCard(
                      icon: Icons.download_rounded,
                      title: "Receive Files",
                      subtitle: "Get files from others",
                      onTap: () => _navigateToScreen(1),
                    ),

                    const SizedBox(height: 16),

                    // History card
                    _buildActionCard(
                      icon: Icons.history_rounded,
                      title: "Transfer History",
                      subtitle: "View past transfers",
                      onTap: () => _navigateToScreen(2),
                    ),
                  ],
                ),
              ),
            ),

            // Bottom spacing
            const SizedBox(height: 24),

            // Helpful hints section
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 24),
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
                    '• Long press on images to preview before downloading\n• Both devices must be on the same WiFi network\n• Connection codes are 8 characters (A-Z, 0-9)',
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

            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  Widget _buildActionCard({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.grey[900],
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey[800]!, width: 1),
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
            padding: const EdgeInsets.all(20),
            child: Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
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
                  child: Icon(icon, color: Colors.black, size: 24),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
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
                          color: Colors.grey[400],
                          fontSize: 13,
                          fontWeight: FontWeight.w400,
                        ),
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
  }

  void _navigateToScreen(int index) {
    Widget targetScreen;
    if (index == 0) {
      targetScreen = AndroidHttpFileShareScreen();
    } else if (index == 1) {
      targetScreen = AndroidReceiveOptionsScreen();
    } else {
      targetScreen = TransferHistoryScreen();
    }

    Navigator.push(
      context,
      PageRouteBuilder(
        transitionDuration: Duration(milliseconds: 300),
        pageBuilder: (context, animation, secondaryAnimation) => targetScreen,
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          var begin = Offset(1.0, 0.0);
          var end = Offset.zero;
          var curve = Curves.easeInOutCubic;

          var tween = Tween(
            begin: begin,
            end: end,
          ).chain(CurveTween(curve: curve));

          return SlideTransition(
            position: animation.drive(tween),
            child: child,
          );
        },
      ),
    );
  }
}
