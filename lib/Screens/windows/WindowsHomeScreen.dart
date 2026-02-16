import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:zap_share/Screens/shared/TransferHistoryScreen.dart';
import 'package:zap_share/Screens/shared/DeviceSettingsScreen.dart';
import 'package:zap_share/Screens/windows/WindowsFileShareScreen.dart';
import 'package:zap_share/Screens/windows/WindowsReceiveScreen.dart';
import 'package:zap_share/Screens/windows/WindowsCastScreen.dart';
import 'package:zap_share/blocs/navigation/smooth_page_route.dart';
import 'dart:math';

import '../../services/device_discovery_service.dart';

import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:zap_share/services/supabase_service.dart';
import 'package:zap_share/Screens/auth/LoginScreen.dart';
import 'package:window_manager/window_manager.dart';
import 'dart:async';

class WindowsHomeScreen extends StatefulWidget {
  const WindowsHomeScreen({super.key});

  @override
  _WindowsHomeScreenState createState() => _WindowsHomeScreenState();
}

class _WindowsHomeScreenState extends State<WindowsHomeScreen>
    with WindowListener {
  final DeviceDiscoveryService _discoveryService = DeviceDiscoveryService();
  bool _isSupabaseInitialized = false;
  String? _lastClipboardContent;
  Timer? _clipboardPollingTimer;
  StreamSubscription<AuthState>? _authStateSubscription;
  StreamSubscription<List<Map<String, dynamic>>>? _cloudClipboardSubscription;
  String? _lastCloudContent;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    // Ensure discovery is active when we land on Home
    _ensureDiscoveryStarted();
    _checkSupabaseInit();

    // Listen for auth state changes (e.g. login success)
    _authStateSubscription = SupabaseService().authStateChanges.listen((data) {
      if (mounted) {
        setState(() {});
        _subscribeToCloudClipboard();
      }
    });

    _subscribeToCloudClipboard();

    // Start local clipboard polling to detect copies made OUTSIDE the app (background)
    // This is efficient (local only) and necessary for "instant" background sync on Windows
    _clipboardPollingTimer = Timer.periodic(const Duration(seconds: 1), (
      timer,
    ) {
      _checkClipboardAndSync();
    });
  }

  // We need distinct subscriptions for the logic (realtime inserts) and the UI (list stream)
  final StreamController<List<Map<String, dynamic>>> _uiStreamController =
      StreamController<List<Map<String, dynamic>>>.broadcast();
  StreamSubscription<Map<String, dynamic>>? _clipboardInsertSubscription;

  void _subscribeToCloudClipboard() {
    _cloudClipboardSubscription?.cancel();
    _clipboardInsertSubscription?.cancel();

    // Only subscribe if we are logged in
    final service = SupabaseService();
    if (service.currentUser == null) return;

    // 1. Subscribe to the LIST (Base Stream)
    // This connects the Supabase stream to our UI controller
    _cloudClipboardSubscription = service.getClipboardStream().listen((items) {
      if (!_uiStreamController.isClosed) {
        _uiStreamController.add(items);
      }
      if (items.isNotEmpty) {
        _initialSyncCheck(items.first);
      }
    });

    // 2. Subscribe to UPDATE EVENTS (Fast Push)
    // This is the efficient "Push" notification for updates
    _clipboardInsertSubscription = service.subscribeToClipboardUpdates().listen(
      (newItem) async {
        final content = newItem['content'] as String;

        // 1. Process sync logic (Background Clipboard Copy)
        await _processCloudClipboardContent(content);

        // 2. FORCE UI REFRESH
        // Retrieve the latest full list to ensure the UI is perfect
        try {
          final history = await service.fetchClipboardHistory();
          if (!_uiStreamController.isClosed) {
            _uiStreamController.add(history);
          }
        } catch (e) {
          // ignore fetch error
        }
      },
    );
  }

  void _initialSyncCheck(Map<String, dynamic> latestItem) {
    if (_lastCloudContent == null) {
      // Only run this on first streaming load
      final content = latestItem['content'] as String;
      _processCloudClipboardContent(content);
    }
  }

  Future<void> _processCloudClipboardContent(String content) async {
    // Logic to determine if we should sync TO device:
    // Sync if content is different from what's currently on the clipboard
    // OR if we haven't tracked it as the last cloud content yet.

    // Check current clipboard first to avoid overwriting user's local copy if they just copied it
    // But here we are processing an INCOMING cloud item, so we generally want to overwrite
    // unless it's the exact same string we just sent.

    if (content != _lastClipboardContent) {
      // Sync FROM Cloud TO Windows Clipboard (works in background if app is minimized)
      await Clipboard.setData(ClipboardData(text: content));

      // Update our local tracker
      _lastClipboardContent = content;
      _lastCloudContent = content; // Mark as processed

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Clipboard synced from device'),
            duration: Duration(seconds: 1),
            behavior: SnackBarBehavior.floating,
            width: 300,
          ),
        );
      }
    } else {
      // Even if it matches, ensure our tracking var is up to date
      _lastCloudContent = content;
    }
  }

  Future<void> _checkSupabaseInit() async {
    // We assume init started in main.dart.
    setState(() {
      _isSupabaseInitialized = true;
    });
    _checkClipboardAndSync();
  }

  void _ensureDiscoveryStarted() async {
    try {
      await _discoveryService.initialize();
      if (mounted) {
        await _discoveryService.start();
      }
    } catch (e) {
      print("Error ensuring discovery in Home: $e");
    }
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    _clipboardPollingTimer?.cancel();
    _authStateSubscription?.cancel();
    _cloudClipboardSubscription?.cancel();
    _clipboardInsertSubscription?.cancel();
    _uiStreamController.close();
    super.dispose();
  }

  @override
  void onWindowFocus() {
    // Also check immediately when window gets focus
    _checkClipboardAndSync();
  }

  Future<void> _checkClipboardAndSync() async {
    // This method is called every 1 second by the timer
    if (!_isSupabaseInitialized) return;

    try {
      // 1. Get current System Clipboard
      ClipboardData? data = await Clipboard.getData(Clipboard.kTextPlain);
      final currentText = data?.text;

      if (currentText != null && currentText.isNotEmpty) {
        // Check if this is new content generated LOCALLY on the PC
        if (currentText != _lastClipboardContent) {
          // CRITICAL LOOP PROTECTION:
          // If the current clipboard content matches what we just received from the cloud,
          // it means this change was triggered by US (the app) writing to the clipboard.
          // In that case, we MUST NOT send it back to the cloud.
          if (currentText == _lastCloudContent) {
            // Just update local tracker so we don't check this again
            _lastClipboardContent = currentText;
            return;
          }

          // New Local Copy Detected!
          _lastClipboardContent = currentText;

          if (kDebugMode) {
            print(
              "New local copy detected (Background/Foreground): ${currentText.substring(0, min(10, currentText.length))}...",
            );
          }

          // Sync to Cloud
          final user = SupabaseService().currentUser;
          if (user != null) {
            try {
              await SupabaseService().addClipboardItem(currentText);
              // Mark this as known cloud content immediately so we don't process the echo
              _lastCloudContent = currentText;

              if (mounted) {
                ScaffoldMessenger.of(context).clearSnackBars();
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Clipboard synced to cloud'),
                    duration: Duration(milliseconds: 1000),
                    width: 250,
                    behavior: SnackBarBehavior.floating,
                    backgroundColor: Color(0xFF2C2C2E),
                  ),
                );
              }
            } catch (e) {
              if (kDebugMode) print("Sync Error: $e");
            }
          }
        }
      }
    } catch (e) {
      // Clipboard access might fail on some platforms/settings
    }
  }

  Future<void> _copyToClipboard(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    _lastClipboardContent = text; // Update local tracker
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Copied to clipboard'),
          duration: Duration(seconds: 1),
          behavior: SnackBarBehavior.floating,
          width: 300,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(child: _buildLandscapeLayout()),
      ),
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
            // Right Panel - Clipboard Sync
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
                    Expanded(
                      child: SingleChildScrollView(
                        child: _buildClipboardSection(),
                      ),
                    ),
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
                MaterialPageRoute(
                  builder: (context) => const DeviceSettingsScreen(),
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
    // For Windows, we're always in landscape mode with the home screen layout
    return Container(
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(32),
        // Elevated Effect with glow for all cards
        boxShadow:
            isMainFeature
                ? [
                  // Main feature (Yellow card) - Simple shadow without glow
                  BoxShadow(
                    color: Colors.black.withOpacity(0.15),
                    blurRadius: 20,
                    offset: const Offset(0, 10),
                    spreadRadius: -2,
                  ),
                ]
                : [], // No shadow for other cards
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
                  padding: EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    mainAxisSize: MainAxisSize.max,
                    children: [
                      Align(
                        alignment: Alignment.topLeft,
                        child: Container(
                          padding: EdgeInsets.all(10.0),
                          decoration: BoxDecoration(
                            color: iconBgColor,
                            shape: BoxShape.circle,
                          ),
                          child: Icon(icon, color: iconColor, size: 26),
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
                                fontSize: 20,
                                fontWeight: FontWeight.w800,
                                letterSpacing: -0.5,
                                height: 1.1,
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            SizedBox(height: 4),
                            Text(
                              subtitle,
                              style: GoogleFonts.outfit(
                                color: textColor.withOpacity(0.7),
                                fontSize: 15,
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

  Widget _buildClipboardSection() {
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
    final themeColor = const Color(0xFFFFD600);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1C1C1E).withOpacity(0.4),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withOpacity(0.05)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // User status removed from card body (should be in header if possible, or just removed)
          const SizedBox(height: 8),

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
              height: 44,
              child: ElevatedButton(
                onPressed: () async {
                  await Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const LoginScreen()),
                  );
                  if (mounted) setState(() {});
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: themeColor,
                  foregroundColor: Colors.black,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: Text(
                  "Login / Sign Up",
                  style: GoogleFonts.outfit(
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                ),
              ),
            ),
          ] else ...[
            // Recent Clips Header
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
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
                      final service = SupabaseService();
                      if (service.currentUser != null) {
                        try {
                          final history = await service.fetchClipboardHistory();
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
            // Quick Copy from Cloud (Stream)
            StreamBuilder<List<Map<String, dynamic>>>(
              stream: _uiStreamController.stream,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return Text(
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

                // Windows: Normal List View
                return ListView.separated(
                  padding: EdgeInsets.zero,
                  shrinkWrap: true,
                  physics:
                      const NeverScrollableScrollPhysics(), // Let the parent scroll
                  itemCount: items.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final item = items[index];
                    final content = item['content'] as String;
                    final time =
                        DateTime.tryParse(
                          item['created_at'].toString(),
                        )?.toLocal();

                    return Container(
                      margin: const EdgeInsets.symmetric(horizontal: 4),
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          onTap: () {
                            _copyToClipboard(content);
                          },
                          borderRadius: BorderRadius.circular(16),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 20,
                              vertical: 16,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(
                                0xFF2C2C2E,
                              ), // Slightly lighter dark
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: Colors.white.withOpacity(0.1),
                                width: 1,
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withOpacity(0.3),
                                  blurRadius: 10,
                                  offset: const Offset(0, 4),
                                ),
                              ],
                            ),
                            child: Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(12),
                                  decoration: BoxDecoration(
                                    color: const Color(
                                      0xFFFFD600,
                                    ), // Solid Yellow
                                    shape: BoxShape.circle,
                                  ),
                                  child: const Icon(
                                    Icons.copy_rounded,
                                    color: Colors.black,
                                    size: 18,
                                  ),
                                ),
                                const SizedBox(width: 16),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        content,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: GoogleFonts.outfit(
                                          color: Colors.white,
                                          fontSize: 16,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                      if (time != null) ...[
                                        const SizedBox(height: 6),
                                        Row(
                                          children: [
                                            Icon(
                                              Icons.access_time_rounded,
                                              size: 12,
                                              color: Colors.white38,
                                            ),
                                            SizedBox(width: 4),
                                            Text(
                                              "${time.hour > 12 ? time.hour - 12 : (time.hour == 0 ? 12 : time.hour)}:${time.minute.toString().padLeft(2, '0')} ${time.hour >= 12 ? 'PM' : 'AM'}",
                                              style: GoogleFonts.robotoMono(
                                                color: Colors.white54,
                                                fontSize: 11,
                                                fontWeight: FontWeight.w500,
                                              ),
                                            ),
                                          ],
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
                );
              },
            ),
          ],
        ],
      ),
    );
  }

  void _navigateToScreen(int index) {
    Widget targetScreen;

    if (index == 0) {
      targetScreen = WindowsFileShareScreen();
    } else if (index == 1) {
      targetScreen = WindowsReceiveScreen();
    } else if (index == 2) {
      targetScreen = TransferHistoryScreen();
    } else if (index == 3) {
      targetScreen = const WindowsCastScreen();
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
    final breathe = (0.5 + 0.5 * 0.5 * sin(progress * 2 * 3.14159)).abs();
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
