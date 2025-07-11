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
        primaryColor: Colors.yellow,
        scaffoldBackgroundColor: Colors.black,
        bottomNavigationBarTheme: const BottomNavigationBarThemeData(
          backgroundColor: Colors.black,
          selectedItemColor: Colors.yellow,
          unselectedItemColor: Colors.white,
        ),
      ),
      home: Platform.isAndroid
          ? const AndroidNavBar()
          : Platform.isWindows
              ? const WindowsNavBar()
              :  HttpFileShareScreen(),
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
      body: Row(
        children: [
          Container(
            width: 60,
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.10),
              borderRadius: const BorderRadius.only(
                topRight: Radius.circular(18),
                bottomRight: Radius.circular(18),
              ),
            ),
            margin: const EdgeInsets.symmetric(vertical: 24, horizontal: 8),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.start,
              children: [
                const SizedBox(height: 12),
                _VSCodeSidebarButton(
                  icon: Icons.upload_rounded,
                  tooltip: 'Send',
                  selected: _selectedIndex == 0,
                  onTap: () => setState(() => _selectedIndex = 0),
                ),
                _VSCodeSidebarButton(
                  icon: Icons.download_rounded,
                  tooltip: 'Receive',
                  selected: _selectedIndex == 1,
                  onTap: () => setState(() => _selectedIndex = 1),
                ),
                _VSCodeSidebarButton(
                  icon: Icons.history_rounded,
                  tooltip: 'History',
                  selected: _selectedIndex == 2,
                  onTap: () => setState(() => _selectedIndex = 2),
                ),
                const Spacer(),
              ],
            ),
          ),
          Expanded(child: _screens[_selectedIndex]),
        ],
      ),
    );
  }
}

class _VSCodeSidebarButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final bool selected;
  final VoidCallback onTap;
  const _VSCodeSidebarButton({required this.icon, required this.tooltip, required this.selected, required this.onTap});
  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      verticalOffset: 0,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          width: 48,
          height: 48,
          margin: const EdgeInsets.symmetric(vertical: 6),
          decoration: BoxDecoration(
            color: selected ? Colors.yellow.withOpacity(0.18) : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
            border: selected
                ? Border(
                    left: BorderSide(color: Colors.yellow, width: 4),
                  )
                : null,
          ),
          child: Icon(icon, color: selected ? Colors.yellow : Colors.white, size: 28),
        ),
      ),
    );
  }
}