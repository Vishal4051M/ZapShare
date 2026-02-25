import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:zap_share/Screens/android/AndroidCastScreen.dart';
import 'package:zap_share/Screens/android/AndroidHttpFileShareScreen.dart';
import 'package:zap_share/Screens/android/AndroidReceiveOptionsScreen.dart';
import 'package:zap_share/Screens/auth/LoginScreen.dart';
import 'package:zap_share/Screens/shared/DeviceSettingsScreen.dart';
import 'package:zap_share/Screens/shared/TransferHistoryScreen.dart';
import 'package:zap_share/blocs/navigation/smooth_page_route.dart';
import 'package:zap_share/services/supabase_service.dart';

class AndroidHomeScreen extends StatefulWidget {
  const AndroidHomeScreen({super.key});

  @override
  _AndroidHomeScreenState createState() => _AndroidHomeScreenState();
}

class _AndroidHomeScreenState extends State<AndroidHomeScreen>
    with WidgetsBindingObserver {
  static const MethodChannel _platform = MethodChannel('zapshare.saf');
  String? _lastClipboardContent;
  bool _isSupabaseInitialized = false;
  bool _showScrollTip = true;

  StreamSubscription<List<Map<String, dynamic>>>? _cloudClipboardSubscription;

  StreamSubscription<AuthState>? _authStateSubscription;
  final FixedExtentScrollController _scrollController =
      FixedExtentScrollController();
  String? _lastCloudContent;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _listenForSharedFiles();
    _checkSupabaseInit();

    // Listen for auth state changes
    _authStateSubscription = SupabaseService().authStateChanges.listen((data) {
      if (mounted) {
        setState(() {});
        _subscribeToCloudClipboard();
      }
    });

    _subscribeToCloudClipboard();
  }

  StreamSubscription<Map<String, dynamic>>? _clipboardInsertSubscription;
  final StreamController<List<Map<String, dynamic>>> _uiStreamController =
      StreamController<List<Map<String, dynamic>>>.broadcast();

  void _subscribeToCloudClipboard() {
    _cloudClipboardSubscription?.cancel();
    _clipboardInsertSubscription?.cancel();

    if (SupabaseService().currentUser == null) return;

    // 1. Subscribe to the LIST (Base Stream)
    // Connecting Supabase stream to our UI controller
    _cloudClipboardSubscription = SupabaseService().getClipboardStream().listen(
      (items) {
        if (!_uiStreamController.isClosed) {
          _uiStreamController.add(items);
        }
      },
    );

    // 2. Subscribe to REALTIME UPDATES for instant background sync
    _clipboardInsertSubscription = SupabaseService()
        .subscribeToClipboardUpdates()
        .listen((newItem) async {
          final content = newItem['content'] as String;
          await _processCloudContent(content);

          // FORCE UI REFRESH
          try {
            final history = await SupabaseService().fetchClipboardHistory();
            if (!_uiStreamController.isClosed) {
              _uiStreamController.add(history);
            }
          } catch (e) {
            // ignore
          }
        });
  }

  Future<void> _processCloudContent(String content) async {
    // If cloud content is different from what we have currently and what we last processed from cloud
    if (content != _lastClipboardContent && content != _lastCloudContent) {
      _lastCloudContent = content;

      // Sync FROM Cloud TO Android Clipboard - DISABLED (User request)
      // await Clipboard.setData(ClipboardData(text: content));

      // Update our local tracker
      _lastClipboardContent = content;

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Clipboard synced from device'),
            duration: Duration(seconds: 1),
            backgroundColor: Color(0xFF1C1C1E),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  Future<void> _checkSupabaseInit() async {
    // We assume init started in main.dart. The service handles safe access.
    // Setting true here ensures the UI shows up.

    // Load scroll tip preference
    final prefs = await SharedPreferences.getInstance();
    final showTip = prefs.getBool('show_scroll_tip') ?? true;

    setState(() {
      _isSupabaseInitialized = true;
      _showScrollTip = showTip;
    });
    // _checkClipboardAndSync(); // Removed auto-sync on open as requested
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cloudClipboardSubscription?.cancel();
    _clipboardInsertSubscription?.cancel();
    _authStateSubscription?.cancel();
    _uiStreamController.close();
    _scrollController.dispose();

    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // _checkClipboardAndSync(); // User requested manual trigger instead of auto-sync
    }
  }

  Future<void> _handlePasteAndSend() async {
    // 1. Get System Clipboard
    ClipboardData? data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;

    if (text != null && text.isNotEmpty) {
      if (SupabaseService().currentUser == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Please login to sync clipboard')),
          );
        }
        return;
      }

      try {
        await SupabaseService().addClipboardItem(text);
        if (mounted) {
          HapticFeedback.lightImpact();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Sent to cloud'),
              backgroundColor: const Color(0xFF00E676),
              behavior: SnackBarBehavior.floating,
              duration: Duration(milliseconds: 1500),
            ),
          );
          // Force refresh the list
          _subscribeToCloudClipboard();
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('Error syncing: $e')));
        }
      }
    } else {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Clipboard is empty')));
      }
    }
  }

  Future<void> _checkClipboardAndSync() async {
    // Legacy auto-sync kept for reference but disabled by caller
    if (!_isSupabaseInitialized) return;

    // 1. Get System Clipboard
    ClipboardData? data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text != null && data!.text!.isNotEmpty) {
      if (_lastClipboardContent != data.text) {
        // New content found on device
        _lastClipboardContent = data.text;

        // Loop protection
        if (_lastCloudContent == data.text) return;

        // Sync to Cloud
        try {
          if (SupabaseService().currentUser != null) {
            await SupabaseService().addClipboardItem(data.text!);
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('Clipboard synced to cloud'),
                  duration: Duration(seconds: 1),
                  backgroundColor: Color(0xFF1C1C1E),
                  behavior: SnackBarBehavior.floating,
                ),
              );
            }
          }
        } catch (e) {
          // likely not logged in or network error, ignore silently or log
          print("Sync skipped: $e");
        }
      }
    }
  }

  Future<void> _copyToClipboard(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    _lastClipboardContent =
        text; // Update local tracker to avoid re-upload loop
    if (mounted) {
      HapticFeedback.lightImpact();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Copied to clipboard',
            style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold),
          ),
          duration: Duration(seconds: 1),
          backgroundColor: Color(0xFFFFD600),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      );
    }
  }

  Widget _buildUserStatus() {
    final user = SupabaseService().currentUser;
    if (user == null) {
      return Container(); // Showing nothing if logged out, or maybe "Not Synced"
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: const Color(0xFF00E676),
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF00E676).withOpacity(0.4),
                blurRadius: 4,
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Text(
          user.email != null && user.email!.length > 15
              ? "${user.email!.substring(0, 15)}..."
              : (user.email ?? "Logged In"),
          style: GoogleFonts.outfit(
            color: Colors.white70,
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(width: 4),
        InkWell(
          onTap: () async {
            await SupabaseService().signOut();
            setState(() {});
          },
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.all(4.0),
            child: const Icon(
              Icons.logout_rounded,
              color: Colors.white38,
              size: 14,
            ),
          ),
        ),
      ],
    );
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
    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;
    final screenWidth = MediaQuery.of(context).size.width;
    final isTV = screenWidth > 1000;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child:
              isLandscape || isTV
                  ? _buildLandscapeLayout()
                  : _buildPortraitLayout(),
        ),
      ),
    );
  }

  Widget _buildPortraitLayout() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 26, 24, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // Header
              _buildHeader(),
              const SizedBox(height: 32),

              // Dashboard Section
              _buildSectionTitle("DASHBOARD"),
              const SizedBox(height: 16),
              // Dashboard - proportional height
              AspectRatio(aspectRatio: 1.0, child: _buildDashboardGrid()),

              const SizedBox(height: 32),

              // Tips Section
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _buildSectionTitle("CLIPBOARD SYNC"),
                  _buildUserStatus(),
                ],
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),

        // Clipboard Sync Card (Expanded to take remaining space)
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
            child: _buildClipboardSection(enableScroll: true),
          ),
        ),
      ],
    );
  }

  Widget _buildLandscapeLayout() {
    return LayoutBuilder(
      builder: (context, constraints) {
        return Row(
          children: [
            // Left Panel - Dashboard
            Expanded(
              flex: 3,
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  border: Border(
                    right: BorderSide(
                      color: Colors.white.withOpacity(0.1),
                      width: 1,
                    ),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildHeader(),
                    const SizedBox(height: 12),
                    _buildSectionTitle("DASHBOARD"),
                    const SizedBox(height: 12),
                    Expanded(
                      child: LayoutBuilder(
                        builder: (context, dashConstraints) {
                          return SizedBox(
                            height: dashConstraints.maxHeight,
                            child: _buildDashboardGrid(),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
            // Right Panel - Tips
            Expanded(
              flex: 2,
              child: Container(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 48), // Align with left panel
                    _buildSectionTitle("CLIPBOARD SYNC"),
                    const SizedBox(height: 12),
                    Expanded(child: _buildClipboardSection(enableScroll: true)),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildSectionTitle(String title) {
    return Text(
      title,
      style: GoogleFonts.outfit(
        color: Colors.grey[300],
        fontSize: 12,
        fontWeight: FontWeight.w800,
        letterSpacing: 1.2,
      ),
    );
  }

  Widget _buildHeader() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Row(
          children: [
            // Logo
            Container(
              height: 48,
              width: 48,
              decoration: BoxDecoration(shape: BoxShape.circle),
              child: ClipOval(
                child: Image.asset(
                  'assets/images/logo.png',
                  fit: BoxFit.cover,
                  errorBuilder: (context, error, stackTrace) {
                    return Container(
                      color: const Color(0xFF1C1C1E),
                      child: const Icon(
                        Icons.bolt_rounded,
                        color: Color(0xFFFFD600),
                        size: 28,
                      ),
                    );
                  },
                ),
              ),
            ),
            const SizedBox(width: 16),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                RichText(
                  text: TextSpan(
                    children: [
                      TextSpan(
                        text: "Zap",
                        style: GoogleFonts.outfit(
                          color: const Color(0xFFFFD600),
                          fontSize: 26,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.5,
                        ),
                      ),
                      TextSpan(
                        text: "Share",
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
          ],
        ),
        Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: const Color(0xFF1C1C1E),
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white.withOpacity(0.05)),
          ),
          child: IconButton(
            icon: const Icon(
              Icons.settings_outlined,
              color: Colors.white,
              size: 22,
            ),
            onPressed: () {
              Navigator.push(
                context,
                PageRouteBuilder(
                  pageBuilder:
                      (context, animation, secondaryAnimation) =>
                          const DeviceSettingsScreen(),
                  transitionsBuilder: (
                    context,
                    animation,
                    secondaryAnimation,
                    child,
                  ) {
                    const begin = Offset(1.0, 0.0);
                    const end = Offset.zero;
                    const curve = Curves.easeInOut;
                    var tween = Tween(
                      begin: begin,
                      end: end,
                    ).chain(CurveTween(curve: curve));
                    var offsetAnimation = animation.drive(tween);
                    return SlideTransition(
                      position: offsetAnimation,
                      child: child,
                    );
                  },
                  transitionDuration: const Duration(milliseconds: 300),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildDashboardGrid() {
    // 2x2 Grid with equal-sized tiles
    return Column(
      children: [
        // Top Row: Send & Receive
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Send Card
              Expanded(
                child: Hero(
                  tag: 'send_card_container',
                  createRectTween: (begin, end) {
                    return RectTween(begin: begin, end: end);
                  },
                  child: _buildCard(
                    title: "Send",
                    subtitle: "Share Files",
                    icon: Icons.arrow_upward_rounded,
                    backgroundColor: const Color(0xFFF5C400),
                    textColor: Colors.black,
                    iconBgColor: Colors.black.withOpacity(0.1),
                    iconColor: Colors.black,
                    onTap: () => _navigateToScreen(0),
                    isMainFeature: true,
                    context: context,
                  ),
                ),
              ),
              const SizedBox(width: 16),
              // Receive Card
              Expanded(
                child: Hero(
                  tag: 'receive_card_container',
                  createRectTween: (begin, end) {
                    return RectTween(begin: begin, end: end);
                  },
                  child: _buildCard(
                    title: "Receive",
                    subtitle: "Get Files",
                    icon: Icons.arrow_downward_rounded,
                    backgroundColor: const Color(0xFF1C1C1E),
                    textColor: Colors.white,
                    iconBgColor: Colors.white.withOpacity(0.1),
                    iconColor: const Color(0xFFFFD600),
                    onTap: () => _navigateToScreen(1),
                    context: context,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        // Bottom Row: History & Cast
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // History Card
              Expanded(
                child: Hero(
                  tag: 'history_card_container',
                  createRectTween: (begin, end) {
                    return RectTween(begin: begin, end: end);
                  },
                  child: _buildCard(
                    title: "History",
                    subtitle: "Recent",
                    icon: Icons.history_rounded,
                    backgroundColor: const Color(0xFF1C1C1E),
                    textColor: Colors.white,
                    iconBgColor: Colors.white.withOpacity(0.1),
                    iconColor: const Color(0xFFFFD600),
                    onTap: () => _navigateToScreen(2),
                    context: context,
                  ),
                ),
              ),
              const SizedBox(width: 16),
              // Cast Card (New Feature) - Soft off-white theme
              Expanded(
                child: Hero(
                  tag: 'cast_card_container',
                  createRectTween: (begin, end) {
                    return RectTween(begin: begin, end: end);
                  },
                  child: _buildCard(
                    title: "Cast",
                    subtitle: "Stream Media",
                    icon: Icons.cast_rounded,
                    backgroundColor: const Color(0xFFEDEDED),
                    textColor: const Color(0xFF2C2C2E),
                    iconBgColor: Colors.black.withOpacity(0.08),
                    iconColor: Colors.black,
                    onTap: () => _navigateToScreen(3),
                    context: context,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildCard({
    required String title,
    required String subtitle,
    required IconData icon,
    required Color backgroundColor,
    required Color textColor,
    required Color iconBgColor,
    required Color iconColor,
    required VoidCallback onTap,
    bool isMainFeature = false,
    required BuildContext context,
  }) {
    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;
    final isTV = MediaQuery.of(context).size.width > 1000;
    final isCompact = isLandscape || isTV;

    return Container(
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(32),
        // Elevated Effect with glow for all cards
        boxShadow: null,
        gradient:
            isMainFeature
                ? LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    const Color(0xFFFFD84D), // Yellow at top-left
                    const Color(0xFFF5C400), // Dark yellow at bottom-right
                  ],
                )
                : backgroundColor == Colors.white ||
                    backgroundColor == const Color(0xFFF5F5F7) ||
                    backgroundColor == const Color(0xFFEDEDED)
                ? LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    const Color(0xFFF0F0F0), // Lighter grey at top
                    const Color(0xFFE5E5E5), // Slightly darker grey at bottom
                  ],
                )
                : LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    const Color(0xFF2C2C2E), // Slightly lighter top-left
                    const Color(0xFF1C1C1E), // Darker bottom-right
                  ],
                ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(32),
        child: Stack(
          children: [
            // Background Pattern (Large Faded Icon)
            Positioned(
              bottom: -30,
              right: -30,
              child:
                  title == "Receive"
                      ? Opacity(
                        opacity: 0.1,
                        child: ColorFiltered(
                          colorFilter: const ColorFilter.matrix(<double>[
                            0.2126,
                            0.7152,
                            0.0722,
                            0,
                            0,
                            0.2126,
                            0.7152,
                            0.0722,
                            0,
                            0,
                            0.2126,
                            0.7152,
                            0.0722,
                            0,
                            0,
                            0,
                            0,
                            0,
                            1,
                            0,
                          ]),
                          child: const Text(
                            "📂",
                            style: TextStyle(fontSize: 100),
                          ),
                        ),
                      )
                      : title == "Send"
                      ? _RippleEffect(
                        key: const ValueKey('home_radar'),
                        size: 120,
                        color: Colors.black,
                      )
                      : Icon(
                        icon,
                        size: 120,
                        color:
                            isMainFeature
                                ? Colors.black.withOpacity(
                                  0.1,
                                ) // Subtle black on yellow
                                : backgroundColor == Colors.white ||
                                    backgroundColor ==
                                        const Color(0xFFF5F5F7) ||
                                    backgroundColor == const Color(0xFFEDEDED)
                                ? Colors.black.withOpacity(
                                  0.08,
                                ) // More visible black on white/off-white
                                : Colors.white.withOpacity(
                                  0.05,
                                ), // Subtle white on dark
                      ),
            ),

            // Content
            Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: () {
                  HapticFeedback.mediumImpact();
                  onTap();
                },
                child: Padding(
                  padding: EdgeInsets.all(isCompact ? 12.0 : 16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    mainAxisSize: MainAxisSize.max,
                    children: [
                      Align(
                        alignment: Alignment.topLeft,
                        child: Container(
                          padding: EdgeInsets.all(isCompact ? 8.0 : 10.0),
                          decoration: BoxDecoration(
                            color: iconBgColor,
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            icon,
                            color: iconColor,
                            size: isCompact ? 22 : 26,
                          ),
                        ),
                      ),
                      Flexible(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              title,
                              style: GoogleFonts.outfit(
                                color: textColor,
                                fontSize: isCompact ? 18 : 20,
                                fontWeight: FontWeight.w800,
                                letterSpacing: -0.5,
                                height: 1.1,
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            SizedBox(height: isCompact ? 3 : 4),
                            Text(
                              subtitle,
                              style: GoogleFonts.outfit(
                                color: textColor.withOpacity(0.7),
                                fontSize: isCompact ? 13 : 15,
                                fontWeight: FontWeight.w500,
                                height: 1.2,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
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
    );
  }

  Widget _buildClipboardSection({bool enableScroll = false}) {
    if (!_isSupabaseInitialized) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xFF1C1C1E).withOpacity(0.4),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.white.withOpacity(0.05)),
        ),
        child: Center(
          child: Text(
            "Service Unavailable",
            style: GoogleFonts.outfit(color: Colors.white),
          ),
        ),
      );
    }

    final user = SupabaseService().currentUser;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1C1C1E), // Matches Receive Card (Dark) - Opaque
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withOpacity(0.05)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // User status moved to header to save space
          // Row(children: [Icon(cloud)...]) removed
          if (user == null) ...[
            Text(
              "Login to sync your clipboard history across all your devices seamlessly.",
              style: GoogleFonts.outfit(
                color: Colors.grey[400],
                fontSize: 15,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton(
                onPressed: () async {
                  await Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const LoginScreen()),
                  );
                  if (mounted) setState(() {});
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFFFD600),
                  foregroundColor: Colors.black,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                child: Text(
                  "Login / Sign Up",
                  style: GoogleFonts.outfit(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
              ),
            ),
          ] else ...[
            // Manual Sync Button
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _handlePasteAndSend,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFFFD600),
                  foregroundColor: Colors.black,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(30),
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                icon: const Icon(Icons.content_paste_rounded, size: 18),
                label: Text(
                  "Paste & Send from Clipboard",
                  style: GoogleFonts.outfit(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            // Quick Copy from Cloud (Stream)
            // Use Expanded only if scrolling is enabled to fill the remaining space
            Expanded(
              flex: enableScroll ? 1 : 0,
              child: StreamBuilder<List<Map<String, dynamic>>>(
                stream: _uiStreamController.stream,
                builder: (context, snapshot) {
                  if (snapshot.hasError) {
                    return const Text(
                      "Error loading history",
                      style: TextStyle(color: Colors.red),
                    );
                  }
                  if (!snapshot.hasData) {
                    return const Center(
                      child: CircularProgressIndicator(strokeWidth: 2),
                    );
                  }

                  final items = snapshot.data!;
                  if (items.isEmpty) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 20),
                      child: Center(
                        child: Text(
                          "No clipboard history yet",
                          style: GoogleFonts.outfit(color: Colors.grey[500]),
                        ),
                      ),
                    );
                  }

                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 8,
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              "Recent Clips",
                              style: GoogleFonts.outfit(
                                color: Colors.white54,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                letterSpacing: 0.5,
                              ),
                            ),
                            InkWell(
                              onTap: () async {
                                HapticFeedback.lightImpact();
                                // Force refresh
                                try {
                                  final history =
                                      await SupabaseService()
                                          .fetchClipboardHistory();
                                  if (!_uiStreamController.isClosed) {
                                    _uiStreamController.add(history);
                                  }
                                  if (mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Text('Refreshed'),
                                        duration: Duration(milliseconds: 500),
                                        width: 100,
                                        behavior: SnackBarBehavior.floating,
                                        backgroundColor: Color(0xFF2C2C2E),
                                      ),
                                    );
                                  }
                                } catch (e) {
                                  // ignore
                                }
                              },
                              borderRadius: BorderRadius.circular(12),
                              child: Padding(
                                padding: const EdgeInsets.all(4.0),
                                child: Icon(
                                  Icons.refresh_rounded,
                                  color: Colors.white38,
                                  size: 14,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: Stack(
                          children: [
                            ShaderMask(
                              shaderCallback:
                                  (rect) => LinearGradient(
                                    begin: Alignment.topCenter,
                                    end: Alignment.bottomCenter,
                                    colors: [
                                      Colors.transparent,
                                      Colors.black,
                                      Colors.black,
                                      Colors.transparent,
                                    ],
                                    stops: [0.0, 0.05, 0.95, 1.0],
                                  ).createShader(rect),
                              blendMode: BlendMode.dstIn,
                              child: ListWheelScrollView.useDelegate(
                                controller: _scrollController,
                                itemExtent: 75,
                                diameterRatio: 1.5,
                                perspective: 0.003,
                                physics: const FixedExtentScrollPhysics(),
                                onSelectedItemChanged: (index) async {
                                  HapticFeedback.selectionClick();
                                  // Hide tip after first scroll
                                  if (_showScrollTip) {
                                    setState(() => _showScrollTip = false);
                                    final prefs =
                                        await SharedPreferences.getInstance();
                                    await prefs.setBool(
                                      'show_scroll_tip',
                                      false,
                                    );
                                  }
                                },
                                childDelegate: ListWheelChildBuilderDelegate(
                                  childCount: items.length,
                                  builder: (context, index) {
                                    final item = items[index];
                                    final content = item['content'] as String;
                                    var timeStr = item['created_at'].toString();
                                    if (!timeStr.endsWith('Z') &&
                                        !timeStr.contains('+')) {
                                      timeStr += 'Z';
                                    }
                                    final time =
                                        DateTime.tryParse(timeStr)?.toLocal();

                                    String timeLabel = "";
                                    if (time != null) {
                                      final now = DateTime.now();
                                      final isToday =
                                          now.year == time.year &&
                                          now.month == time.month &&
                                          now.day == time.day;
                                      final isYesterday =
                                          now.year == time.year &&
                                          now.month == time.month &&
                                          now.day == time.day + 1;
                                      final hourMin =
                                          "${time.hour > 12 ? time.hour - 12 : (time.hour == 0 ? 12 : time.hour)}:${time.minute.toString().padLeft(2, '0')} ${time.hour >= 12 ? 'PM' : 'AM'}";

                                      if (isToday) {
                                        timeLabel = hourMin;
                                      } else if (isYesterday) {
                                        timeLabel = "Yesterday, $hourMin";
                                      } else {
                                        // Simple date format dd/mm
                                        timeLabel =
                                            "${time.day}/${time.month} $hourMin";
                                      }
                                    }

                                    return Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 4,
                                      ),
                                      child: Material(
                                        color: Colors.transparent,
                                        child: InkWell(
                                          onTap:
                                              () => _copyToClipboard(content),
                                          borderRadius: BorderRadius.circular(
                                            16,
                                          ),
                                          child: Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 16,
                                              vertical: 8,
                                            ),
                                            decoration: BoxDecoration(
                                              color: const Color(0xFF0F0F0F),
                                              borderRadius:
                                                  BorderRadius.circular(16),
                                              border: Border.all(
                                                color: Colors.white.withOpacity(
                                                  0.08,
                                                ),
                                                width: 1,
                                              ),
                                            ),
                                            child: Row(
                                              children: [
                                                Container(
                                                  padding: const EdgeInsets.all(
                                                    10,
                                                  ),
                                                  decoration: BoxDecoration(
                                                    color: const Color(
                                                      0xFF1C1C1E,
                                                    ),
                                                    shape: BoxShape.circle,
                                                  ),
                                                  child: const Icon(
                                                    Icons.copy_rounded,
                                                    color: Color(0xFFFFD600),
                                                    size: 16,
                                                  ),
                                                ),
                                                const SizedBox(width: 16),
                                                Expanded(
                                                  child: Column(
                                                    mainAxisAlignment:
                                                        MainAxisAlignment
                                                            .center,
                                                    crossAxisAlignment:
                                                        CrossAxisAlignment
                                                            .start,
                                                    children: [
                                                      Text(
                                                        content,
                                                        maxLines: 1,
                                                        overflow:
                                                            TextOverflow
                                                                .ellipsis,
                                                        style:
                                                            GoogleFonts.outfit(
                                                              color:
                                                                  Colors.white,
                                                              fontSize: 15,
                                                              fontWeight:
                                                                  FontWeight
                                                                      .w500,
                                                            ),
                                                      ),
                                                      if (time != null) ...[
                                                        const SizedBox(
                                                          height: 4,
                                                        ),
                                                        Text(
                                                          timeLabel,
                                                          style:
                                                              GoogleFonts.robotoMono(
                                                                color:
                                                                    Colors
                                                                        .white38,
                                                                fontSize: 11,
                                                              ),
                                                        ),
                                                      ],
                                                    ],
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      ),
                                    );
                                  },
                                ),
                              ),
                            ),
                            // Dismissible Scroll Tip
                            if (_showScrollTip)
                              Positioned(
                                bottom: 8,
                                left: 0,
                                right: 0,
                                child: Center(
                                  child: GestureDetector(
                                    onTap: () async {
                                      setState(() => _showScrollTip = false);
                                      final prefs =
                                          await SharedPreferences.getInstance();
                                      await prefs.setBool(
                                        'show_scroll_tip',
                                        false,
                                      );
                                      HapticFeedback.lightImpact();
                                    },
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 16,
                                        vertical: 8,
                                      ),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFFFFD600),
                                        borderRadius: BorderRadius.circular(20),
                                        boxShadow: [
                                          BoxShadow(
                                            color: const Color(
                                              0xFFFFD600,
                                            ).withOpacity(0.3),
                                            blurRadius: 8,
                                            spreadRadius: 1,
                                          ),
                                        ],
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(
                                            Icons.swipe_vertical_rounded,
                                            color: Colors.black,
                                            size: 16,
                                          ),
                                          const SizedBox(width: 8),
                                          Text(
                                            'Scroll for history',
                                            style: GoogleFonts.outfit(
                                              color: Colors.black,
                                              fontSize: 13,
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          Icon(
                                            Icons.close_rounded,
                                            color: Colors.black54,
                                            size: 14,
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.lock_rounded, size: 11, color: Colors.white24),
                const SizedBox(width: 5),
                Text(
                  'End-to-End Encrypted',
                  style: GoogleFonts.robotoMono(
                    color: Colors.white24,
                    fontSize: 9,
                    fontWeight: FontWeight.w500,
                    letterSpacing: 0.5,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  void _navigateToScreen(int index) {
    Widget targetScreen;

    if (index == 0) {
      targetScreen = AndroidHttpFileShareScreen();
    } else if (index == 1) {
      targetScreen = AndroidReceiveOptionsScreen();
    } else if (index == 2) {
      targetScreen = TransferHistoryScreen();
    } else if (index == 3) {
      targetScreen = const AndroidCastScreen();
    } else {
      return;
    }

    HapticFeedback.lightImpact();

    // Use SmoothPageRoute with fade - screens handle their own Hero animations
    Navigator.push(
      context,
      SmoothPageRoute.fade(
        page: targetScreen,
        duration: const Duration(milliseconds: 500),
        reverseDuration: const Duration(milliseconds: 400),
      ),
    );
  }
}

// Physics-based Pulse Effect
// Optimized: const constructor, minimal rebuilds, static math functions
class _RippleEffect extends StatefulWidget {
  final double size;
  final Color color;

  const _RippleEffect({super.key, this.size = 300, this.color = Colors.black});

  @override
  State<_RippleEffect> createState() => _RippleEffectState();
}

class _RippleEffectState extends State<_RippleEffect>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  // Constants
  static const int _ringCount = 3;
  static const Duration _duration = Duration(milliseconds: 3000);

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: _duration)
      ..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: SizedBox(
        width: widget.size,
        height: widget.size,
        child: AnimatedBuilder(
          animation: _controller,
          builder:
              (_, __) => CustomPaint(
                painter: _PulsePainter(
                  progress: _controller.value,
                  color: widget.color,
                ),
                isComplex: false,
                willChange: true,
              ),
        ),
      ),
    );
  }
}

// Minimal CustomPainter - all math inlined, no function references
class _PulsePainter extends CustomPainter {
  final double progress;
  final Color color;

  const _PulsePainter({required this.progress, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxRadius = size.width / 2;

    // 3 rings with phase offset
    for (int i = 0; i < 3; i++) {
      final p = (progress + i / 3) % 1.0;

      // EaseOutCubic inline
      final eased = 1.0 - (1.0 - p) * (1.0 - p) * (1.0 - p);

      // Radius: 20% to 100%
      final radius = maxRadius * (0.2 + eased * 0.8);

      // Opacity: inverse square + edge fade
      final d = (radius / maxRadius).clamp(0.3, 1.0);
      final opacity = ((0.3 / (d * d)) * (1.0 - p * p)).clamp(0.0, 0.35);

      // Stroke: 2.5 → 0.5
      final stroke = 2.5 - eased * 2.0;

      if (opacity > 0.02) {
        canvas.drawCircle(
          center,
          radius,
          Paint()
            ..color = color.withOpacity(opacity)
            ..style = PaintingStyle.stroke
            ..strokeWidth = stroke,
        );
      }
    }

    // Center dot with subtle breathing (derived from main progress)
    final breathe = (0.5 + 0.5 * sin(progress * 2 * 3.14159)).abs();
    final dotR = size.width * 0.05 * (0.9 + breathe * 0.2);

    // Glow
    canvas.drawCircle(
      center,
      dotR * 1.6,
      Paint()
        ..color = color.withOpacity(0.12)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
    );

    // Dot
    canvas.drawCircle(center, dotR, Paint()..color = color.withOpacity(0.3));
  }

  @override
  bool shouldRepaint(_PulsePainter old) => old.progress != progress;
}
