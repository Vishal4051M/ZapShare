import 'dart:io';

import 'package:flutter/material.dart';
// unused imports removed
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:zap_share/Screens/android/AndroidHomeScreen.dart';
import 'package:zap_share/Screens/android/AndroidHttpFileShareScreen.dart';
import 'package:zap_share/services/device_discovery_service.dart';
import 'package:zap_share/widgets/connection_request_dialog.dart';
import 'Screens/windows/WindowsFileShareScreen.dart';
import 'Screens/windows/WindowsReceiveScreen.dart';
import 'Screens/android/AndroidReceiveScreen.dart';
import 'Screens/shared/TransferHistoryScreen.dart';
import 'Screens/shared/DeviceSettingsScreen.dart';
import 'dart:async';
import 'package:flutter/services.dart';
// shared_preferences removed from main imports (used elsewhere in the app files)

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
  await [
    Permission.storage,
    Permission.location,
    Permission.manageExternalStorage,
    Permission.nearbyWifiDevices,
  ].request();

  // Simple handling: if any required permission is denied, request again or exit.
  // The rest of the app expects permissions to be available on Android.
  return;

}

// Global navigator key used for showing dialogs from non-widget code
final GlobalKey<NavigatorState> _globalNavigatorKey = GlobalKey<NavigatorState>();

// Preserve the public name `navigatorKey` for existing callers.
GlobalKey<NavigatorState> get navigatorKey => _globalNavigatorKey;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ZapShareApp());
}

class ZapShareApp extends StatefulWidget {
  const ZapShareApp({Key? key}) : super(key: key);
  @override
  State<ZapShareApp> createState() => _ZapShareAppState();
}

class _ZapShareAppState extends State<ZapShareApp> {
  late final DeviceDiscoveryService _discoveryService;
  StreamSubscription? _connectionRequestSubscription;

  @override
  void initState() {
    super.initState();
    _discoveryService = DeviceDiscoveryService();
    _initGlobalDeviceDiscovery();
  }

  void _initGlobalDeviceDiscovery() async {
    print('🌐 [Global] Initializing device discovery for global dialog');
    await _discoveryService.initialize();
    await _discoveryService.start();

    _connectionRequestSubscription = _discoveryService.connectionRequestStream.listen((request) {
      print('🔔 [Global] Received connection request from ${request.deviceName}');
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
          onAccept: () async {
            print('✅ [Global] User accepted connection request');
            Navigator.of(dialogContext).pop();

            // Send acceptance response
            await _discoveryService.sendConnectionResponse(request.ipAddress, true);

            // Navigate to receive screen
            if (Platform.isAndroid) {
              // Navigate to AndroidReceiveScreen with the sender's code
              final senderCode = _ipToCode(request.ipAddress);
              navigatorKey.currentState?.pushReplacement(
                MaterialPageRoute(
                  builder: (context) => AndroidReceiveScreen(
                    autoConnectCode: senderCode,
                  ),
                ),
              );
            }

            print('✅ [Global] Redirecting to receive screen');
          },
          onDecline: () async {
            print('❌ [Global] User declined connection request');
            Navigator.of(dialogContext).pop();
            await _discoveryService.sendConnectionResponse(request.ipAddress, false);
          },
        );
      },
    );
  }

  String _ipToCode(String ipAddress) {
    final parts = ipAddress.split('.');
    if (parts.length != 4) return '';
    final n = (int.parse(parts[0]) << 24) |
        (int.parse(parts[1]) << 16) |
        (int.parse(parts[2]) << 8) |
        int.parse(parts[3]);
    return n.toRadixString(36).toUpperCase().padLeft(8, '0');
  }

  @override
  void dispose() {
    _connectionRequestSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: navigatorKey,
      theme: ThemeData(
        brightness: Brightness.dark,
        primaryColor: const Color(0xFFFFD600),
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
          color: const Color(0xFF1A1A1A),
          elevation: 8,
          shadowColor: Colors.black.withOpacity(0.3),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFFFFD600),
            foregroundColor: Colors.black,
            elevation: 4,
            shadowColor: const Color(0xFFFFD600).withOpacity(0.3),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            textStyle: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.5,
            ),
          ),
        ),
        floatingActionButtonTheme: const FloatingActionButtonThemeData(
          backgroundColor: Color(0xFFFFD600),
          foregroundColor: Colors.black,
          elevation: 8,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(16)),
          ),
        ),
        bottomNavigationBarTheme: const BottomNavigationBarThemeData(
          backgroundColor: Color(0xFF1A1A1A),
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
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
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

class _WindowsNavBarState extends State<WindowsNavBar> with SingleTickerProviderStateMixin {
  int _selectedIndex = 0;
  final double _expandedWidth = 180;
  final double _navCollapseThreshold = 900;
  final double _collapsedWidth = 72;
  bool _isCollapsed = false;
  final Duration _animationDuration = Duration(milliseconds: 250);
  final List<Widget> _screens = [
    WindowsFileShareScreen(),
    WindowsReceiveScreen(),
    TransferHistoryScreen(),
    DeviceSettingsScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: ConstrainedBox(
        constraints: BoxConstraints(minWidth: _navCollapseThreshold),
        child: Row(
          children: [
          AnimatedContainer(
            duration: _animationDuration,
            width: _isCollapsed ? _collapsedWidth : _expandedWidth,
            curve: Curves.easeInOut,
            margin: EdgeInsets.zero,
            decoration: BoxDecoration(
              color: Colors.black,
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
                SizedBox(height: 12),
                // Collapse/Expand toggle
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8.0),
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: IconButton(
                      icon: Icon(_isCollapsed ? Icons.chevron_right_rounded : Icons.chevron_left_rounded, color: Colors.white70),
                      onPressed: () => setState(() => _isCollapsed = !_isCollapsed),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
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
                const SizedBox(height: 8),
                _buildNavItem(
                  icon: Icons.settings_rounded,
                  label: 'Settings',
                  selected: _selectedIndex == 3,
                  onTap: () => setState(() => _selectedIndex = 3),
                  collapsed: _isCollapsed,
                ),
                Spacer(),
              ],
            ),
          ),

            Expanded(child: _screens[_selectedIndex]),
          ],
        ), // Row
      ), // ConstrainedBox
    ); // Scaffold
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
        padding: EdgeInsets.symmetric(vertical: 12, horizontal: collapsed ? 0 : 10),
        decoration: BoxDecoration(
          color: selected ? kAccentYellow.withOpacity(0.18) : Colors.transparent,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          mainAxisAlignment: collapsed ? MainAxisAlignment.center : MainAxisAlignment.start,
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