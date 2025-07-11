import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_displaymode/flutter_displaymode.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:zap_share/Screens/HttpFileShareScreen.dart';
import 'Screens/WindowsFileShareScreen.dart';
import 'Screens/WindowsReceiveScreen.dart';
import 'Screens/AndroidReceiveScreen.dart';
import 'Screens/TransferHistoryScreen.dart';

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
  Map<Permission, PermissionStatus> statuses = await [
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
    requestPermissions();
    clearAppCache();
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'data_rush_transfer',
        channelName: 'Data Rush Transfer',
        channelDescription: 'File transfer is running in the background',
        channelImportance: NotificationChannelImportance.HIGH,
        priority: NotificationPriority.HIGH,
      ), iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false, 
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions( 
        autoRunOnBoot: true, 
        allowWakeLock: true, 
        allowWifiLock: true, eventAction: ForegroundTaskEventAction.once(), 
      ),
    );
    await FlutterDisplayMode.setHighRefreshRate();
  }
  runApp(const DataRushApp());
}

class DataRushApp extends StatelessWidget {
  const DataRushApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
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
        cardTheme: CardTheme(
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
          ? const AndroidNavBar()
          : Platform.isWindows
              ? const WindowsNavBar()
              : HttpFileShareScreen(),
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
    HttpFileShareScreen(),
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

class _WindowsNavBarState extends State<WindowsNavBar> {
  int _selectedIndex = 0;
  final List<Widget> _screens = [
    WindowsFileShareScreen(),
    WindowsReceiveScreen(),
    TransferHistoryScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: _screens[_selectedIndex],
      bottomNavigationBar: Container(
        margin: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.black,
          borderRadius: BorderRadius.circular(20),
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
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _buildDockItem(
                icon: Icons.upload_rounded,
                label: 'Send',
                selected: _selectedIndex == 0,
                onTap: () => setState(() => _selectedIndex = 0),
              ),
              _buildDockItem(
                icon: Icons.download_rounded,
                label: 'Receive',
                selected: _selectedIndex == 1,
                onTap: () => setState(() => _selectedIndex = 1),
              ),
              _buildDockItem(
                icon: Icons.history_rounded,
                label: 'History',
                selected: _selectedIndex == 2,
                onTap: () => setState(() => _selectedIndex = 2),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDockItem({
    required IconData icon,
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
          decoration: BoxDecoration(
            color: selected ? kAccentYellow.withOpacity(0.15) : Colors.transparent,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                color: selected ? kAccentYellow : Colors.white70,
                size: 24,
              ),
              const SizedBox(height: 4),
              Text(
                label,
                style: TextStyle(
                  color: selected ? kAccentYellow : Colors.white70,
                  fontSize: 12,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}