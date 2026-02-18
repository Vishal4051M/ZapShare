import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_displaymode/flutter_displaymode.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:zap_share/Screens/android/AndroidHomeScreen.dart';
import 'package:zap_share/Screens/android/AndroidHttpFileShareScreen.dart';
import 'package:zap_share/services/device_discovery_service.dart';
import 'package:zap_share/services/wifi_direct_service.dart';
import 'package:zap_share/widgets/connection_request_dialog.dart';
import 'Screens/windows/WindowsFileShareScreen.dart';
import 'Screens/windows/WindowsReceiveScreen.dart';
import 'Screens/android/AndroidReceiveScreen.dart';
import 'Screens/ios/IOSHomeScreen.dart';
import 'Screens/ios/IOSReceiveScreen.dart';
import 'Screens/macos/MacOSHomeScreen.dart';
import 'Screens/macos/MacOSReceiveScreen.dart';
import 'Screens/shared/TransferHistoryScreen.dart';
import 'dart:async';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> clearAppCache() async {
  final cacheDir = await getTemporaryDirectory();
  if (cacheDir.existsSync()) {
    for (var entity in cacheDir.listSync()) {
      try {
        entity.deleteSync(recursive: true);
      } catch (e) {
        // Ignore files in use
      }
    }
    print("App cache cleared");
  }
}

Future<void> requestPermissions() async {
  if (!Platform.isAndroid) return;
  Map<Permission, PermissionStatus> statuses =
      await [
        Permission.storage,
        Permission.location,
        Permission.manageExternalStorage,
        Permission.nearbyWifiDevices,
        Permission.audio,
        Permission.videos,
        Permission.notification,
        Permission.manageExternalStorage,
      ].request();

  statuses.forEach((perm, status) {
    if (!status.isGranted) {
      print('Permission denied: $perm');
    }
  });
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isAndroid) {
    // requestPermissions(); // Moved to AppState for sequential execution
    clearAppCache();
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'data_rush_transfer',
        channelName: 'Data Rush Transfer',
        channelDescription: 'File transfer is running in the background',
        channelImportance: NotificationChannelImportance.HIGH,
        priority: NotificationPriority.HIGH,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        autoRunOnBoot: true,
        allowWakeLock: true,
        allowWifiLock: true,
        eventAction: ForegroundTaskEventAction.once(),
      ),
    );
    await FlutterDisplayMode.setHighRefreshRate();
  }
  runApp(const DataRushApp());
}

class DataRushApp extends StatefulWidget {
  const DataRushApp({super.key});

  @override
  State<DataRushApp> createState() => _DataRushAppState();
}

class _DataRushAppState extends State<DataRushApp> {
  final DeviceDiscoveryService _discoveryService = DeviceDiscoveryService();
  StreamSubscription<ConnectionRequest>? _connectionRequestSubscription;
  final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

  @override
  void initState() {
    super.initState();
    // Delay startup until after first frame so navigator/context exist.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // Ensure permissions are granted before starting services
      if (Platform.isAndroid) {
        await requestPermissions();
      }

      // Ask for device name on first install before initializing discovery service
      await _ensureDeviceName();
      _initGlobalDeviceDiscovery();
    });
  }

  Future<void> _ensureDeviceName() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final existing = prefs.getString('device_name');
      if (existing != null && existing.trim().isNotEmpty) return;

      final nameController = TextEditingController();
      // Remove auto-focus initially to prevent keyboard from jarringly popping up immediately
      final focusNode = FocusNode(); 

      // Wait briefly to ensure context is ready
      BuildContext? dialogContext = navigatorKey.currentContext;
      int attempts = 0;
      while (dialogContext == null && attempts < 10) {
        await Future.delayed(const Duration(milliseconds: 100));
        dialogContext = navigatorKey.currentContext;
        attempts++;
      }
      if (dialogContext == null) return;

      // Define colors locally for this dialog since they might not be globally exported yet
      const kZapPrimary = Color(0xFFFFD600);
      const kZapSurface = Color(0xFF1C1C1E);
      const kZapBackground = Color(0xFF000000);

      await showGeneralDialog(
        context: dialogContext,
        barrierDismissible: false,
        barrierColor: kZapBackground,
        pageBuilder: (context, animation, secondaryAnimation) {
          return Scaffold(
            backgroundColor: kZapBackground,
            body: SafeArea(
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      // Logo / Icon
                      Container(
                        width: 100,
                        height: 100,
                        decoration: BoxDecoration(
                          color: kZapPrimary.withOpacity(0.1),
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: kZapPrimary.withOpacity(0.2),
                              blurRadius: 40,
                              spreadRadius: 10,
                            )
                          ],
                          border: Border.all(color: kZapPrimary.withOpacity(0.5)),
                        ),
                        child: Icon(
                          Platform.isIOS ? Icons.apple_rounded : Icons.android_rounded,
                          size: 48,
                          color: kZapPrimary,
                        ),
                      ),
                      const SizedBox(height: 40),

                      // Welcome Text
                      const Text(
                        "Welcome to ZapShare",
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 28,
                          fontWeight: FontWeight.bold,
                          letterSpacing: -0.5,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        "Let's get you set up. choose a name so others can recognize you.",
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.6),
                          fontSize: 16,
                          height: 1.5,
                        ),
                      ),
                      const SizedBox(height: 40),

                      // Input Field
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            "DEVICE NAME",
                            style: TextStyle(
                              color: kZapPrimary,
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 2,
                            ),
                          ),
                          const SizedBox(height: 12),
                          Container(
                            decoration: BoxDecoration(
                              color: kZapSurface,
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(color: Colors.white.withOpacity(0.1)),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withOpacity(0.5),
                                  blurRadius: 20,
                                  offset: const Offset(0, 10),
                                ),
                              ],
                            ),
                            child: TextField(
                              controller: nameController,
                              focusNode: focusNode,
                              cursorColor: kZapPrimary,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 18,
                                fontWeight: FontWeight.w600,
                              ),
                              textCapitalization: TextCapitalization.words,
                              decoration: InputDecoration(
                                hintText: Platform.isIOS ? "Vijageesh's iPhone" : "My Device",
                                hintStyle: TextStyle(color: Colors.white.withOpacity(0.2)),
                                border: InputBorder.none,
                                contentPadding: const EdgeInsets.all(20),
                                prefixIcon: Icon(Icons.edit_rounded, color: Colors.white.withOpacity(0.4)),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 40),

                      // Continue Button
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          onPressed: () async {
                            final v = nameController.text.trim();
                             if (v.isEmpty) {
                                // Shake animation or error feedback could go here
                                return;
                             }
                            await prefs.setString('device_name', v);
                            Navigator.of(context).pop();
                          },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: kZapPrimary,
                            foregroundColor: Colors.black,
                            padding: const EdgeInsets.symmetric(vertical: 20),
                            elevation: 0,
                            shadowColor: kZapPrimary.withOpacity(0.5),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                          ),
                          child: const Text(
                            "Get Started",
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
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
    } catch (e) {
      print('Error ensuring device name: $e');
    }
  }

  void _initGlobalDeviceDiscovery() async {
    print('🌐 [Global] Initializing device discovery for global dialog');
    await _discoveryService.initialize();
    await _discoveryService.start();

    // Initialize Wi-Fi Direct on Android
    if (Platform.isAndroid) {
      print('📡 [Global] Initializing Wi-Fi Direct...');
      final wifiDirect = WiFiDirectService();
      final initialized = await wifiDirect.initialize();

      if (initialized) {
        print('✅ [Global] Wi-Fi Direct initialized successfully');
        // Start peer discovery
        final discoveryStarted = await wifiDirect.startPeerDiscovery();
        if (discoveryStarted) {
          print('✅ [Global] Wi-Fi Direct peer discovery started');
        } else {
          print('⚠️  [Global] Failed to start Wi-Fi Direct peer discovery');
        }
      } else {
        print('⚠️  [Global] Failed to initialize Wi-Fi Direct');
      }
    }

    _connectionRequestSubscription = _discoveryService.connectionRequestStream
        .listen((request) {
          print(
            '🔔 [Global] Received connection request from ${request.deviceName}',
          );
          _showGlobalConnectionRequestDialog(request);
        });
  }

  void _showGlobalConnectionRequestDialog(ConnectionRequest request) {
    final context = navigatorKey.currentContext;
    if (context == null) {
      print('❌ [Global] No context available to show dialog');
      return;
    }

    print('🚀 [Global] Showing connection request dialog globally');

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return ConnectionRequestDialog(
          request: request,
          onAccept: (files, path) async {
            // Global dialog acceptance logic (simplified for now)
            Navigator.of(dialogContext).pop();
            final service = DeviceDiscoveryService(); 
            // Note: In global context we might not have the logic to start download immediately 
            // unless we refactor. For now, just send response.
             await service.sendConnectionResponse(request.ipAddress, true);

            // Navigate to receive screen
            final senderCode = _ipToCode(request.ipAddress);
            
            if (Platform.isAndroid) {
              navigatorKey.currentState?.pushReplacement(
                MaterialPageRoute(
                  builder:
                      (context) =>
                          AndroidReceiveScreen(autoConnectCode: senderCode),
                ),
              );
            } else if (Platform.isMacOS) {
               navigatorKey.currentState?.push(
                 MaterialPageRoute(builder: (_) => MacOSReceiveScreen(autoStartCode: senderCode))
               );
            } else if (Platform.isIOS) {
               navigatorKey.currentState?.push(
                 MaterialPageRoute(
                   builder: (_) => IOSReceiveScreen(
                     filterFiles: files,
                     destinationPath: path,
                   ),
                 ),
               );
            } else if (Platform.isWindows) {
                // WindowsReceiveScreen might generally use manual entry, but adding here if updated later
                navigatorKey.currentState?.push(
                 MaterialPageRoute(builder: (_) => const WindowsReceiveScreen())
               );
            }

            print('✅ [Global] Redirecting to receive screen');
          },
          onDecline: () async {
            print('❌ [Global] User declined connection request');
            Navigator.of(dialogContext).pop();
            await _discoveryService.sendConnectionResponse(
              request.ipAddress,
              false,
            );
          },
        );
      },
    );
  }

  String _ipToCode(String ipAddress) {
    final parts = ipAddress.split('.');
    if (parts.length != 4) return '';
    final n =
        (int.parse(parts[0]) << 24) |
        (int.parse(parts[1]) << 16) |
        (int.parse(parts[2]) << 8) |
        int.parse(parts[3]);
    return n.toRadixString(36).toUpperCase().padLeft(8, '0');
  }

  @override
  void dispose() {
    _connectionRequestSubscription?.cancel();
    // Keep discovery service running - it should run for the entire app lifecycle
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: navigatorKey,
      theme: ThemeData(
        brightness: Brightness.dark,
        primaryColor: const Color(0xFFFFD600), // Premium Yellow
        scaffoldBackgroundColor: Colors.black,
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.black,
          elevation: 0,
          centerTitle: true,
          titleTextStyle: TextStyle(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.5,
          ),
        ),
        cardTheme: CardThemeData(
          color: const Color(0xFF1C1C1E), // kZapSurface
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
          ),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFFFFD600),
            foregroundColor: Colors.black,
            elevation: 0,
            shadowColor: const Color(0xFFFFD600).withOpacity(0.3),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            textStyle: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.5,
            ),
          ),
        ),
        floatingActionButtonTheme: const FloatingActionButtonThemeData(
          backgroundColor: Color(0xFFFFD600),
          foregroundColor: Colors.black,
          elevation: 4,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(20)),
          ),
        ),
        bottomNavigationBarTheme: const BottomNavigationBarThemeData(
          backgroundColor: Color(0xFF1C1C1E),
          selectedItemColor: Color(0xFFFFD600),
          unselectedItemColor: Colors.white70,
          type: BottomNavigationBarType.fixed,
          elevation: 8,
        ),
        textTheme: const TextTheme(
          headlineLarge: TextStyle(
            color: Colors.white,
            fontSize: 32,
            fontWeight: FontWeight.bold,
            letterSpacing: -0.5,
          ),
          headlineMedium: TextStyle(
            color: Colors.white,
            fontSize: 24,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.25,
          ),
          titleLarge: TextStyle(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.w600,
            letterSpacing: 0,
          ),
          titleMedium: TextStyle(
            color: Colors.white,
            fontSize: 16,
            fontWeight: FontWeight.w500,
            letterSpacing: 0.15,
          ),
          bodyLarge: TextStyle(
            color: Colors.white,
            fontSize: 16,
            fontWeight: FontWeight.normal,
            letterSpacing: 0.5,
          ),
          bodyMedium: TextStyle(
            color: Colors.white70,
            fontSize: 14,
            fontWeight: FontWeight.normal,
            letterSpacing: 0.25,
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFF2A2A2A),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: Colors.white.withOpacity(0.1)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: Color(0xFFFFD600), width: 2),
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 16,
          ),
          hintStyle: TextStyle(
            color: Colors.white.withOpacity(0.5),
            fontSize: 16,
          ),
        ),
      ),
      home: Platform.isAndroid
          ? const AndroidHomeScreen()
          : Platform.isWindows
              ? const WindowsNavBar()
              : Platform.isIOS
                  ? const IOSHomeScreen()
                  : Platform.isMacOS
                      ? const IOSHomeScreen() // Temporarily showing iOS screen on macOS for testing
                      : AndroidHttpFileShareScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class AndroidNavBar extends StatefulWidget {
  const AndroidNavBar({super.key});
  @override
  State<AndroidNavBar> createState() => _AndroidNavBarState();
}

class _AndroidNavBarState extends State<AndroidNavBar> {
  int _selectedIndex = 0;
  final List<Widget> _screens = [
    AndroidHttpFileShareScreen(),
    AndroidReceiveScreen(),
    TransferHistoryScreen(),
  ];
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: _screens[_selectedIndex],
      bottomNavigationBar: Padding(
        padding: const EdgeInsets.only(bottom: 18, left: 16, right: 16),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(32),
          child: Container(
            color: Colors.white.withOpacity(0.12),
            child: BottomNavigationBar(
              type: BottomNavigationBarType.fixed,
              backgroundColor: Colors.transparent,
              elevation: 0,
              selectedItemColor: Colors.white,
              unselectedItemColor: Colors.white70,
              showSelectedLabels: true,
              showUnselectedLabels: true,
              currentIndex: _selectedIndex,
              onTap: (index) => setState(() => _selectedIndex = index),
              items: const [
                BottomNavigationBarItem(
                  icon: Icon(Icons.upload_rounded),
                  label: 'Send',
                ),
                BottomNavigationBarItem(
                  icon: Icon(Icons.download_rounded),
                  label: 'Receive',
                ),
                BottomNavigationBarItem(
                  icon: Icon(Icons.history_rounded),
                  label: 'History',
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class WindowsNavBar extends StatefulWidget {
  const WindowsNavBar({super.key});
  @override
  State<WindowsNavBar> createState() => _WindowsNavBarState();
}

class _WindowsNavBarState extends State<WindowsNavBar>
    with SingleTickerProviderStateMixin {
  int _selectedIndex = 0;
  bool _isCollapsed = false;
  final double _collapsedWidth = 64;
  final double _expandedWidth = 180;
  final Duration _animationDuration = Duration(milliseconds: 250);
  final List<Widget> _screens = [
    WindowsFileShareScreen(),
    WindowsReceiveScreen(),
    TransferHistoryScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Row(
            children: [
              AnimatedContainer(
                duration: _animationDuration,
                width: _isCollapsed ? _collapsedWidth : _expandedWidth,
                curve: Curves.easeInOut,
                margin: EdgeInsets.only(left: 0, top: 0, bottom: 0, right: 0),
                decoration: BoxDecoration(
                  color: const Color(0xFF23272F).withOpacity(0.95),
                  borderRadius: BorderRadius.only(
                    topRight: Radius.circular(24),
                    bottomRight: Radius.circular(24),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.25),
                      blurRadius: 24,
                      offset: Offset(4, 8),
                    ),
                  ],
                ),
                child: Column(
                  children: [
                    SizedBox(height: 24),
                    IconButton(
                      icon: Icon(
                        _isCollapsed ? Icons.chevron_right : Icons.chevron_left,
                        color: Colors.white70,
                      ),
                      tooltip:
                          _isCollapsed
                              ? 'Expand Navigation'
                              : 'Collapse Navigation',
                      onPressed: () {
                        setState(() {
                          _isCollapsed = !_isCollapsed;
                        });
                      },
                    ),
                    const SizedBox(height: 12),
                    _buildNavItem(
                      icon: Icons.upload_rounded,
                      label: 'Send',
                      selected: _selectedIndex == 0,
                      onTap: () => setState(() => _selectedIndex = 0),
                      collapsed: _isCollapsed,
                    ),
                    _buildNavItem(
                      icon: Icons.download_rounded,
                      label: 'Receive',
                      selected: _selectedIndex == 1,
                      onTap: () => setState(() => _selectedIndex = 1),
                      collapsed: _isCollapsed,
                    ),
                    _buildNavItem(
                      icon: Icons.history_rounded,
                      label: 'History',
                      selected: _selectedIndex == 2,
                      onTap: () => setState(() => _selectedIndex = 2),
                      collapsed: _isCollapsed,
                    ),
                    Spacer(),
                  ],
                ),
              ),
              Expanded(child: _screens[_selectedIndex]),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildNavItem({
    required IconData icon,
    required String label,
    required bool selected,
    required VoidCallback onTap,
    required bool collapsed,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: AnimatedContainer(
        duration: _animationDuration,
        margin: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
        padding: EdgeInsets.symmetric(
          vertical: 12,
          horizontal: collapsed ? 0 : 10,
        ),
        decoration: BoxDecoration(
          color:
              selected ? kAccentYellow.withOpacity(0.18) : Colors.transparent,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          mainAxisAlignment:
              collapsed ? MainAxisAlignment.center : MainAxisAlignment.start,
          children: [
            Icon(
              icon,
              color: selected ? kAccentYellow : Colors.white70,
              size: 28,
            ),
            if (!collapsed) ...[
              const SizedBox(width: 18),
              Text(
                label,
                style: TextStyle(
                  color: selected ? kAccentYellow : Colors.white70,
                  fontSize: 16,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
