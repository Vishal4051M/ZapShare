// import 'dart:core';
// import 'dart:io';
// import 'dart:convert';

// import 'package:flutter/foundation.dart';
// import 'Screens/shared/audio_receiver_screen.dart';
// import 'blocs/navigation/smooth_page_route.dart';
// import 'package:flutter/material.dart';
// import 'package:flutter_dotenv/flutter_dotenv.dart';
// import 'package:flutter_displaymode/flutter_displaymode.dart';
// import 'package:flutter_foreground_task/flutter_foreground_task.dart';
// import 'package:path_provider/path_provider.dart';
// import 'package:permission_handler/permission_handler.dart';
// import 'package:zap_share/Screens/android/AndroidHomeScreen.dart';
// import 'package:zap_share/Screens/android/AndroidHttpFileShareScreen.dart';
// import 'package:zap_share/services/device_discovery_service.dart';
// // import 'package:zap_share/services/wifi_direct_service.dart'; // REMOVED: Using Bluetooth + Hotspot
// import 'package:zap_share/widgets/connection_request_dialog.dart';
// import 'package:tray_manager/tray_manager.dart';
// import 'package:window_manager/window_manager.dart';
// import 'package:zap_share/services/supabase_service.dart';
// import 'Screens/windows/WindowsFileShareScreen.dart';
// import 'Screens/windows/WindowsCastScreen.dart';
// import 'Screens/windows/WindowsReceiveScreen.dart';
// import 'Screens/windows/WindowsHomeScreen.dart';
// import 'Screens/linux/LinuxHomeScreen.dart';
// import 'Screens/linux/LinuxReceiveScreen.dart';
// import 'Screens/android/AndroidReceiveScreen.dart';
// import 'Screens/shared/TransferHistoryScreen.dart';
// import 'dart:async';
// import 'package:flutter/services.dart';
// import 'package:shared_preferences/shared_preferences.dart';
// import 'package:app_links/app_links.dart';
// import 'package:supabase_flutter/supabase_flutter.dart';
// import 'package:media_kit/media_kit.dart';
// import 'package:google_fonts/google_fonts.dart';

// import 'package:zap_share/Screens/shared/FirstTimeSetupScreen.dart';
// import 'package:zap_share/Screens/shared/VideoPlayerScreen.dart';
// import 'package:zap_share/Screens/shared/NativeVideoPlayerScreen.dart';
// import 'package:zap_share/Screens/shared/ScreenMirrorViewerScreen.dart';

// const Color kAccentYellow = Color(0xFFFFD600);

// Future<void> clearAppCache() async {
//   final cacheDir = await getTemporaryDirectory();
//   if (cacheDir.existsSync()) {
//     for (var entity in cacheDir.listSync()) {
//       try {
//         entity.deleteSync(recursive: true);
//       } catch (e) {
//         // Ignore files in use
//       }
//     }
//     print("App cache cleared");
//   }
// }

// Future<void> requestPermissions() async {
//   if (!Platform.isAndroid) return;
//   Map<Permission, PermissionStatus> statuses =
//       await [
//         Permission.storage,
//         Permission.location,
//         Permission.manageExternalStorage,
//         Permission.nearbyWifiDevices,
//         Permission.bluetooth,
//         Permission.bluetoothScan,
//         Permission.bluetoothAdvertise,
//         Permission.bluetoothConnect,
//         Permission.audio,
//         Permission.videos,
//         Permission.notification,
//         Permission.manageExternalStorage,
//       ].request();

//   statuses.forEach((perm, status) {
//     if (!status.isGranted) {
//       print('Permission denied: $perm');
//     }
//   });
// }

// void main(List<String> args) async {
//   debugPrint('🏁 [Main] App starting with args: $args');
//   WidgetsFlutterBinding.ensureInitialized();
//   if (Platform.isWindows ||
//       Platform.isLinux ||
//       Platform.isMacOS ||
//       Platform.isAndroid) {
//     MediaKit.ensureInitialized();
//   }
//   try {
//     await dotenv.load(fileName: ".env");
//   } catch (e) {
//     print("Warning: .env file not found or invalid. Using defaults.");
//   }
//   if (Platform.isAndroid) {
//     // requestPermissions(); // Moved to AppState for sequential execution
//     clearAppCache();
//     FlutterForegroundTask.init(
//       androidNotificationOptions: AndroidNotificationOptions(
//         channelId: 'zapshare_transfer_channel_v2',
//         channelName: 'ZapShare Transfer',
//         channelDescription: 'File transfer is running in the background',
//         channelImportance: NotificationChannelImportance.HIGH,
//         priority: NotificationPriority.HIGH,
//       ),
//       iosNotificationOptions: const IOSNotificationOptions(
//         showNotification: false,
//         playSound: false,
//       ),
//       foregroundTaskOptions: ForegroundTaskOptions(
//         autoRunOnBoot: true,
//         allowWakeLock: true,
//         allowWifiLock: true,
//         eventAction: ForegroundTaskEventAction.once(),
//       ),
//     );
//     await FlutterDisplayMode.setHighRefreshRate();
//   }

//   if (Platform.isWindows || Platform.isLinux) {
//     await windowManager.ensureInitialized();
//     bool isMirror = args.contains('--mirror');
//     WindowOptions windowOptions = WindowOptions(
//       size: isMirror ? const Size(400, 800) : const Size(900, 650),
//       minimumSize: isMirror ? const Size(200, 400) : const Size(800, 600),
//       center: true,
//       backgroundColor: Colors.transparent,
//       skipTaskbar: false,
//       titleBarStyle: isMirror ? TitleBarStyle.hidden : TitleBarStyle.normal,
//     );
//     windowManager.waitUntilReadyToShow(windowOptions, () async {
//       if (isMirror) {
//         await windowManager.setResizable(false);
//       }
//       await windowManager.show();
//       await windowManager.focus();
//     });
//   }

//   // Initialize Supabase
//   try {
//     await SupabaseService().initialize();
//     print('✅ Supabase Initialized');
//   } catch (e) {
//     print('❌ Failed to initialize Supabase: $e');
//   }

//   // Pre-fetch initial shared files for seamless cold start
//   List<Map>? initialShareFiles;
//   if (Platform.isAndroid) {
//     try {
//       const platform = MethodChannel('zapshare.saf');
//       final String? jsonStr = await platform.invokeMethod<String>(
//         'getInitialSharedFiles',
//       );
//       if (jsonStr != null && jsonStr.isNotEmpty) {
//         final List<dynamic> decoded = json.decode(jsonStr);
//         initialShareFiles = decoded.cast<Map>();
//         print(
//           '📂 [Main] Cold start with ${initialShareFiles.length} shared files',
//         );
//       }
//     } catch (e) {
//       print('⚠️ Failed to pre-fetch share files: $e');
//     }
//   }

//   runApp(DataRushApp(launchArgs: args, initialShareFiles: initialShareFiles));
// }

// class DataRushApp extends StatefulWidget {
//   final List<String>? launchArgs;
//   final List<Map>? initialShareFiles;
//   const DataRushApp({super.key, this.launchArgs, this.initialShareFiles});

//   @override
//   State<DataRushApp> createState() => _DataRushAppState();
// }

// class _DataRushAppState extends State<DataRushApp>
//     with WindowListener, TrayListener, WidgetsBindingObserver {
//   final DeviceDiscoveryService _discoveryService = DeviceDiscoveryService();
//   StreamSubscription<ConnectionRequest>? _connectionRequestSubscription;
//   StreamSubscription<CastRequest>? _castRequestSubscription;
//   StreamSubscription<ScreenMirrorRequest>? _screenMirrorSubscription;
//   StreamSubscription<AudioOffer>? _audioOfferSubscription;
//   final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();
//   bool? _isFirstRun; // Null initially to show loading/splash
//   final List<ConnectionRequest> _pendingConnectionRequests = [];
//   final List<AudioOffer> _pendingAudioOffers = [];
//   bool _isShowingGlobalConnectionRequest = false;
//   bool _isShowingGlobalAudioOffer = false;
//   bool _pendingRequestFlushScheduled = false;

//   @override
//   void initState() {
//     super.initState();
//     _checkFirstRun();
//     // Delay startup until after first frame so navigator/context exist.
//     WidgetsBinding.instance.addPostFrameCallback((_) async {
//       // Ensure permissions are granted before starting services
//       if (Platform.isAndroid) {
//         await requestPermissions();
//       }

//       // Expect existing logic to handle window/tray
//       if (Platform.isWindows) {
//         windowManager.addListener(this);
//         if (!_isMirrorMode()) {
//           trayManager.addListener(this);
//           await _initSystemTray();
//         }
//         await _registerContextMenu();
//         await windowManager.setPreventClose(true);
//       }

//       // We wait for _checkFirstRun to complete in its own future,
//       // so we don't need to block here. The UI will update when valid.

//       _initGlobalDeviceDiscovery();
//       _initDeepLinks();
//       _initGlobalShareListener(); // Add global share listener here
//       WidgetsBinding.instance.addObserver(this);
//     });
//   }

//   void _initDeepLinks() {
//     final _appLinks = AppLinks();

//     // Check initial link if app was started by the link
//     _appLinks.getInitialLink().then((uri) {
//       if (uri != null) {
//         _handleDeepLink(uri);
//       }
//     });

//     _appLinks.uriLinkStream.listen((uri) {
//       _handleDeepLink(uri);
//     });

//     // Windows-specific: Listen for deep links from other instances via method channel
//     if (Platform.isWindows) {
//       const MethodChannel('zapshare/deeplink').setMethodCallHandler((
//         call,
//       ) async {
//         if (call.method == 'onDeepLink') {
//           final String url = call.arguments as String;
//           print('📨 Received deep link from another instance: $url');

//           // Parse the URL and handle it
//           try {
//             final uri = Uri.parse(url);
//             _handleDeepLink(uri);
//           } catch (e) {
//             print('❌ Error parsing deep link URL: $e');
//           }
//         }
//       });
//     }
//   }

//   void _handleDeepLink(Uri uri) async {
//     print("🔗 Deep link received: $uri");
//     print("   Scheme: ${uri.scheme}");
//     print("   Host: ${uri.host}");
//     print("   Path: ${uri.path}");
//     print("   Fragment: ${uri.fragment}");
//     print("   Query: ${uri.query}");
//     print("   Full URL: ${uri.toString()}");

//     if (uri.scheme == 'io.supabase.zapshare' && uri.host == 'login-callback') {
//       try {
//         // Let Supabase handle the OAuth callback
//         // The full URI needs to be passed including fragment/query params
//         print("🔄 Processing Supabase OAuth callback...");
//         await Supabase.instance.client.auth.getSessionFromUrl(uri);
//         print("✅ Supabase Auth callback processed successfully");

//         // Check if we have a session now
//         final session = Supabase.instance.client.auth.currentSession;
//         if (session != null) {
//           print("✅ User is now logged in: ${session.user.email}");
//         } else {
//           print("⚠️ No session found after processing callback");
//         }
//       } catch (e) {
//         print("❌ Error handling deep link session: $e");
//         print("   Stack trace: ${StackTrace.current}");
//       }
//     } else {
//       print("⚠️ Deep link does not match expected pattern");
//     }
//   }

//   // Track processed share intents to avoid duplicates between cold/warm start
//   final Set<String> _processedShareUris = {};

//   void _initGlobalShareListener() {
//     if (!Platform.isAndroid) return;
//     const platform = MethodChannel('zapshare.saf');

//     // Warm start listener - handles shares while app is already in memory
//     platform.setMethodCallHandler((call) async {
//       print('🚀 [Global Channel] Received platform call: ${call.method}');
//       if (call.method == 'sharedFiles') {
//         final List<dynamic> decoded = call.arguments as List<dynamic>;
//         print(
//           '📁 [Global] Received ${decoded.length} shared files from MethodChannel',
//         );
//         final files = decoded.cast<Map>();

//         // Filter out already processed URIs to avoid duplicates
//         final newFiles =
//             files
//                 .where((f) => !_processedShareUris.contains(f['uri']))
//                 .toList();

//         if (newFiles.isNotEmpty) {
//           newFiles.forEach((f) => _processedShareUris.add(f['uri'].toString()));
//           _navigateToShareScreen(newFiles);
//         }
//       }
//       return null;
//     });
//   }

//   void _navigateToShareScreen(List<Map> sharedFiles) async {
//     print(
//       '🚀 [Global] Requesting navigation to share screen (${sharedFiles.length} files)',
//     );

//     // Safety check: wait for navigator state if app is still starting up
//     int retries = 0;
//     while (navigatorKey.currentState == null && retries < 20) {
//       print("⏳ Navigator not ready yet, waiting... ($retries)");
//       await Future.delayed(const Duration(milliseconds: 500));
//       retries++;
//     }

//     if (navigatorKey.currentState != null) {
//       print("✅ Navigating now!");
//       navigatorKey.currentState!.pushAndRemoveUntil(
//         MaterialPageRoute(
//           builder:
//               (context) =>
//                   AndroidHttpFileShareScreen(initialSharedFiles: sharedFiles),
//         ),
//         (route) => route.isFirst,
//       );
//     } else {
//       print("❌ CRITICAL: Navigator state remains null after retries!");
//     }
//   }

//   Future<void> _checkFirstRun() async {
//     final prefs = await SharedPreferences.getInstance();
//     final isDone = prefs.getBool('first_run_complete') ?? false;
//     if (mounted) {
//       setState(() {
//         _isFirstRun = !isDone;
//       });
//     }
//   }

//   Future<void> _ensureDeviceName() async {
//     if (_isFirstRun == true) return; // Skip if in first set-up mode
//     try {
//       final prefs = await SharedPreferences.getInstance();
//       final existing = prefs.getString('device_name');
//       if (existing != null && existing.trim().isNotEmpty) return;

//       final nameController = TextEditingController();
//       final focusNode = FocusNode();

//       // Wait briefly for navigator context to be available (should be after first frame)
//       BuildContext? dialogContext = navigatorKey.currentContext;
//       int attempts = 0;
//       while (dialogContext == null && attempts < 10) {
//         await Future.delayed(const Duration(milliseconds: 100));
//         dialogContext = navigatorKey.currentContext;
//         attempts++;
//       }
//       if (dialogContext == null) return;

//       await showDialog<void>(
//         context: dialogContext,
//         barrierDismissible: false,
//         builder: (context) {
//           return AlertDialog(
//             backgroundColor: Colors.grey[900],
//             title: const Text(
//               'Set device name',
//               style: TextStyle(color: Colors.white),
//             ),
//             content: Column(
//               mainAxisSize: MainAxisSize.min,
//               children: [
//                 const Text(
//                   'Please enter a name for this device. This will be shown to other devices when sharing.',
//                   style: TextStyle(color: Colors.white70, fontSize: 13),
//                 ),
//                 const SizedBox(height: 12),
//                 Theme(
//                   data: Theme.of(context).copyWith(
//                     textSelectionTheme: TextSelectionThemeData(
//                       cursorColor: Colors.yellow[300],
//                       selectionHandleColor: Colors.yellow[300],
//                       selectionColor: Colors.yellow[100],
//                     ),
//                   ),
//                   child: TextField(
//                     controller: nameController,
//                     focusNode: focusNode,
//                     autofocus: true,
//                     cursorColor: Colors.yellow[300],
//                     textCapitalization: TextCapitalization.words,
//                     inputFormatters: [
//                       // Allow letters, numbers, spaces and basic punctuation
//                       FilteringTextInputFormatter.allow(RegExp(r"[\w\-\.\s']")),
//                       LengthLimitingTextInputFormatter(30),
//                     ],
//                     style: const TextStyle(color: Colors.white),
//                     decoration: InputDecoration(
//                       hintText: 'My phone',
//                       hintStyle: TextStyle(color: Colors.white24),
//                     ),
//                   ),
//                 ),
//               ],
//             ),
//             actions: [
//               TextButton(
//                 onPressed: () async {
//                   final v = nameController.text.trim();
//                   if (v.isEmpty) return; // keep dialog open until valid
//                   await prefs.setString('device_name', v);
//                   Navigator.of(context).pop();
//                 },
//                 child: const Text(
//                   'Save',
//                   style: TextStyle(color: Colors.yellow),
//                 ),
//               ),
//             ],
//           );
//         },
//       );
//       // give focus/keyboard a moment
//       await Future.delayed(const Duration(milliseconds: 200));
//     } catch (e) {
//       print('Error ensuring device name: $e');
//     }
//   }

//   void _initGlobalDeviceDiscovery() async {
//     print('🌐 [Global] Initializing device discovery for global dialog');
//     await _discoveryService.initialize();
//     await _discoveryService.start();

//     _connectionRequestSubscription = _discoveryService.connectionRequestStream
//         .listen((request) {
//           print(
//             '🔔 [Global] Received connection request from ${request.deviceName}',
//           );
//           _showGlobalConnectionRequestDialog(request);
//         });

//     _castRequestSubscription = _discoveryService.castRequestStream.listen((
//       request,
//     ) {
//       print('🔔 [Global] Received cast request');
//       _showGlobalCastRequestDialog(request);
//     });

//     _screenMirrorSubscription = _discoveryService.screenMirrorRequestStream
//         .listen((request) {
//           print('\n🔔🔔🔔 [Global] ═══════════════════════════════════════');
//           print('🔔 [Global] RECEIVED SCREEN MIRROR REQUEST!');
//           print('🔔 [Global]   deviceName: ${request.deviceName}');
//           print('🔔 [Global]   deviceId: ${request.deviceId}');
//           print('🔔 [Global]   streamUrl: ${request.streamUrl}');
//           print('🔔 [Global]   senderIp: ${request.senderIp}');
//           print('🔔 [Global]   timestamp: ${request.timestamp}');
//           print('🔔 [Global] ═══════════════════════════════════════');
//           _showScreenMirrorDialog(request);
//         });
//     print(
//       '🔔 [Global] Screen mirror subscription ACTIVE - listening for incoming requests',
//     );

//     // FIX: Listen for incoming control commands and forward to native Android
//     _discoveryService.screenMirrorControlStream.listen((control) {
//       if (Platform.isAndroid) {
//         print('📱 [Global] Forwarding control to native: ${control.action}');
//         const MethodChannel('zapshare.saf').invokeMethod('mirrorControl', {
//           'action': control.action,
//           'tapX': control.tapX,
//           'tapY': control.tapY,
//           'endX': control.endX,
//           'endY': control.endY,
//           'text': control.text,
//           'scrollDelta': control.scrollDelta,
//           'duration': control.duration,
//         });
//       }
//     });

//     _audioOfferSubscription = _discoveryService.audioOfferStream.listen((
//       offer,
//     ) {
//       print('🔔 [Global] Received Audio Share offer from ${offer.deviceName}');
//       _showGlobalAudioShareDialog(offer);
//     });

//     _schedulePendingRequestFlush();
//   }

//   void _schedulePendingRequestFlush() {
//     if (_pendingRequestFlushScheduled) return;
//     _pendingRequestFlushScheduled = true;
//     WidgetsBinding.instance.addPostFrameCallback((_) {
//       _pendingRequestFlushScheduled = false;
//       _flushPendingRequests();
//     });
//   }

//   void _flushPendingRequests() {
//     if (!mounted) return;
//     final context = navigatorKey.currentContext;
//     if (context == null) return;

//     if (!_isShowingGlobalConnectionRequest &&
//         _pendingConnectionRequests.isNotEmpty) {
//       final request = _pendingConnectionRequests.removeAt(0);
//       _presentGlobalConnectionRequestDialog(request);
//       return;
//     }

//     if (!_isShowingGlobalAudioOffer && _pendingAudioOffers.isNotEmpty) {
//       final offer = _pendingAudioOffers.removeAt(0);
//       _presentGlobalAudioShareDialog(offer);
//     }
//   }

//   void _showGlobalConnectionRequestDialog(ConnectionRequest request) {
//     final context = navigatorKey.currentContext;
//     if (context == null) {
//       print('⚠️ [Global] No context available yet; queuing connection request');
//       _pendingConnectionRequests.add(request);
//       _schedulePendingRequestFlush();
//       return;
//     }

//     if (_isShowingGlobalConnectionRequest) {
//       _pendingConnectionRequests.add(request);
//       return;
//     }

//     _presentGlobalConnectionRequestDialog(request);
//   }

//   void _presentGlobalConnectionRequestDialog(ConnectionRequest request) {
//     final context = navigatorKey.currentContext;
//     if (context == null) {
//       _pendingConnectionRequests.add(request);
//       _schedulePendingRequestFlush();
//       return;
//     }

//     _isShowingGlobalConnectionRequest = true;

//     // Bring window to foreground on Windows if minimized/hidden
//     // Bring window to foreground on Windows/Linux if minimized/hidden
//     if (Platform.isWindows || Platform.isLinux) {
//       windowManager.show();
//       windowManager.focus();
//       windowManager.setAlwaysOnTop(true);
//       // Remove always on top after a brief moment so it doesn't stay on top
//       Future.delayed(const Duration(milliseconds: 500), () {
//         windowManager.setAlwaysOnTop(false);
//       });
//     }

//     print('🚀 [Global] Showing connection request dialog globally');

//     showDialog(
//       context: context,
//       barrierDismissible: false,
//       builder: (dialogContext) {
//         return ConnectionRequestDialog(
//           request: request,
//           onAccept: () async {
//             print('✅ [Global] User accepted connection request');
//             Navigator.of(dialogContext).pop();

//             // Send acceptance response
//             await _discoveryService.sendConnectionResponse(
//               request.ipAddress,
//               true,
//             );
//             _discoveryService.pauseDiscovery();

//             // Navigate to receive screen
//             if (Platform.isAndroid) {
//               // Navigate to AndroidReceiveScreen with the sender's code
//               final senderCode = _ipToCode(
//                 request.ipAddress,
//                 port: request.port,
//               );
//               navigatorKey.currentState?.pushReplacement(
//                 MaterialPageRoute(
//                   builder:
//                       (context) => AndroidReceiveScreen(
//                         autoConnectCode: senderCode,
//                         useTcp:
//                             true, // Always use TCP for app-to-app dialog accept
//                       ),
//                 ),
//               );
//             } else if (Platform.isWindows) {
//               // For Windows, we are likely inside WindowsHomeScreen which manages screens.
//               // However, since this is a global dialog, we need to push the Receive Screen
//               // or signal the WindowsHomeScreen to switch tabs.
//               // Pushing a new route stack is safer for now to ensure visibility.
//               final senderCode = _ipToCode(
//                 request.ipAddress,
//                 port: request.port,
//               );
//               navigatorKey.currentState?.push(
//                 MaterialPageRoute(
//                   builder:
//                       (context) =>
//                           WindowsReceiveScreen(autoConnectCode: senderCode),
//                 ),
//               );
//             } else if (Platform.isLinux) {
//               print('🚀 [Global] Linux detected, preparing redirection');
//               final senderCode = _ipToCode(
//                 request.ipAddress,
//                 port: request.port,
//               );
//               print('🚀 [Global] Code generated: $senderCode');
//               final navState = navigatorKey.currentState;
//               if (navState != null) {
//                 print('🚀 [Global] Navigating to LinuxReceiveScreen');
//                 navState.push(
//                   MaterialPageRoute(
//                     builder:
//                         (context) =>
//                             LinuxReceiveScreen(autoConnectCode: senderCode),
//                   ),
//                 );
//               } else {
//                 print('❌ [Global] navigatorKey.currentState is NULL!');
//               }
//             } else {
//               print(
//                 'ℹ️ [Global] Unsupported platform for specialized receive screen: ${Platform.operatingSystem}. Falling back to AndroidReceiveScreen.',
//               );
//               final senderCode = _ipToCode(
//                 request.ipAddress,
//                 port: request.port,
//               );
//               navigatorKey.currentState?.push(
//                 MaterialPageRoute(
//                   builder:
//                       (context) => AndroidReceiveScreen(
//                         autoConnectCode: senderCode,
//                         useTcp: true,
//                       ),
//                 ),
//               );
//             }

//             print(
//               '✅ [Global] Accepted connection from ${request.deviceName} (${request.ipAddress})',
//             );
//           },
//           onDecline: () async {
//             print('❌ [Global] User declined connection request');
//             Navigator.of(dialogContext).pop();
//             await _discoveryService.sendConnectionResponse(
//               request.ipAddress,
//               false,
//             );
//           },
//         );
//       },
//     ).whenComplete(() {
//       _isShowingGlobalConnectionRequest = false;
//       _schedulePendingRequestFlush();
//     });
//   }

//   void _showGlobalCastRequestDialog(CastRequest request) {
//     // Retry getting context if null (can happen during screen transitions)
//     BuildContext? context = navigatorKey.currentContext;
//     if (context == null) {
//       print('⚠️ [Cast] Context is null, retrying in 500ms...');
//       Future.delayed(const Duration(milliseconds: 500), () {
//         final retryContext = navigatorKey.currentContext;
//         if (retryContext != null) {
//           _showCastDialogWithContext(retryContext, request);
//         } else {
//           print('❌ [Cast] Context still null after retry, cannot show dialog');
//         }
//       });
//       return;
//     }
//     _showCastDialogWithContext(context, request);
//   }

//   void _showGlobalAudioShareDialog(AudioOffer offer) {
//     BuildContext? context = navigatorKey.currentContext;
//     if (context == null) {
//       _pendingAudioOffers.add(offer);
//       _schedulePendingRequestFlush();
//       return;
//     }

//     if (_isShowingGlobalAudioOffer) {
//       _pendingAudioOffers.add(offer);
//       return;
//     }

//     _presentGlobalAudioShareDialog(offer);
//   }

//   void _presentGlobalAudioShareDialog(AudioOffer offer) {
//     final context = navigatorKey.currentContext;
//     if (context == null) {
//       _pendingAudioOffers.add(offer);
//       _schedulePendingRequestFlush();
//       return;
//     }

//     _isShowingGlobalAudioOffer = true;

//     if (Platform.isWindows) {
//       windowManager.show();
//       windowManager.focus();
//     }

//     showGeneralDialog(
//       context: context,
//       barrierDismissible: false,
//       barrierLabel: 'Audio Share',
//       barrierColor: Colors.black.withOpacity(0.6),
//       transitionDuration: const Duration(milliseconds: 280),
//       transitionBuilder: (dialogContext, animation, secondaryAnimation, child) {
//         final curved = CurvedAnimation(
//           parent: animation,
//           curve: const Cubic(0.2, 0.8, 0.2, 1.0),
//           reverseCurve: Curves.easeInCubic,
//         );
//         return FadeTransition(
//           opacity: curved,
//           child: ScaleTransition(
//             scale: Tween<double>(begin: 0.95, end: 1.0).animate(curved),
//             child: child,
//           ),
//         );
//       },
//       pageBuilder: (dialogContext, animation, secondaryAnimation) {
//         return Center(
//           child: AlertDialog(
//             backgroundColor: const Color(0xFF1C1C1E),
//             shape: RoundedRectangleBorder(
//               borderRadius: BorderRadius.circular(20),
//               side: BorderSide(color: const Color(0xFFFFD600).withOpacity(0.3)),
//             ),
//             title: Row(
//               children: [
//                 Container(
//                   padding: const EdgeInsets.all(8),
//                   decoration: BoxDecoration(
//                     color: const Color(0xFFFFD600).withOpacity(0.15),
//                     shape: BoxShape.circle,
//                   ),
//                   child: const Icon(
//                     Icons.waves_rounded,
//                     color: Color(0xFFFFD600),
//                     size: 24,
//                   ),
//                 ),
//                 const SizedBox(width: 12),
//                 const Text(
//                   'Audio Share',
//                   style: TextStyle(
//                     color: Colors.white,
//                     fontWeight: FontWeight.bold,
//                   ),
//                 ),
//               ],
//             ),
//             content: Text(
//               '${offer.deviceName} wants to share low-latency audio with you. Accept?',
//               style: const TextStyle(color: Colors.white70),
//             ),
//             actions: [
//               TextButton(
//                 onPressed: () => Navigator.pop(dialogContext),
//                 child: const Text(
//                   'DECLINE',
//                   style: TextStyle(color: Colors.white38),
//                 ),
//               ),
//               ElevatedButton(
//                 style: ElevatedButton.styleFrom(
//                   backgroundColor: const Color(0xFFFFD600),
//                   foregroundColor: Colors.black,
//                   shape: RoundedRectangleBorder(
//                     borderRadius: BorderRadius.circular(12),
//                   ),
//                 ),
//                 onPressed: () async {
//                   Navigator.pop(dialogContext);

//                   final isLanAudio = offer.sdp.startsWith(
//                     'LAN_AUDIO_STREAM_PORT:',
//                   );
//                   int? lanAudioPort;
//                   int? lanAudioCushion;
//                   if (isLanAudio) {
//                     final parts = offer.sdp
//                         .replaceFirst('LAN_AUDIO_STREAM_PORT:', '')
//                         .split(';');
//                     lanAudioPort = int.tryParse(parts.first) ?? 50005;
//                     for (final part in parts) {
//                       if (part.startsWith('cushion=')) {
//                         lanAudioCushion = int.tryParse(
//                           part.replaceFirst('cushion=', ''),
//                         );
//                       }
//                     }
//                   } else if (!offer.sdp.startsWith('HTTP_AUDIO_STREAM_URL:')) {
//                     _discoveryService.processIncomingAudioOffer(offer);
//                   }

//                   // If it's LAN Audio, start native receiver
//                   if (lanAudioPort != null && Platform.isAndroid) {
//                     _discoveryService.startLanAudioReceiver(
//                       port: lanAudioPort,
//                       cushionMs: lanAudioCushion ?? 20,
//                     );
//                   }

//                   // Navigate to the receiver screen so user has visual feedback
//                   Navigator.of(context).push(
//                     SmoothPageRoute.fade(
//                       page: AudioReceiverScreen(
//                         senderName: offer.deviceName,
//                         senderIp: offer.senderIp,
//                         useLanAudio: isLanAudio,
//                       ),
//                     ),
//                   );
//                 },
//                 child: const Text(
//                   'ACCEPT',
//                   style: TextStyle(fontWeight: FontWeight.bold),
//                 ),
//               ),
//             ],
//           ),
//         );
//       },
//     ).whenComplete(() {
//       _isShowingGlobalAudioOffer = false;
//       _schedulePendingRequestFlush();
//     });
//   }

//   void _showCastDialogWithContext(BuildContext context, CastRequest request) {
//     // Bring window to foreground on Windows if minimized/hidden
//     if (Platform.isWindows) {
//       windowManager.show();
//       windowManager.focus();
//       windowManager.setAlwaysOnTop(true);
//       // Remove always on top after a brief moment so it doesn't stay on top
//       Future.delayed(const Duration(milliseconds: 500), () {
//         windowManager.setAlwaysOnTop(false);
//       });
//     }

//     final displayFileName = request.fileName ?? _extractFileName(request.url);

//     showDialog(
//       context: context,
//       barrierDismissible: false,
//       builder: (dialogContext) {
//         return AlertDialog(
//           backgroundColor: const Color(0xFF1A1A1A),
//           shape: RoundedRectangleBorder(
//             borderRadius: BorderRadius.circular(20),
//             side: BorderSide(color: const Color(0xFFFFD600).withOpacity(0.2)),
//           ),
//           title: Row(
//             children: [
//               Container(
//                 padding: const EdgeInsets.all(8),
//                 decoration: BoxDecoration(
//                   color: const Color(0xFFFFD600).withOpacity(0.15),
//                   borderRadius: BorderRadius.circular(10),
//                 ),
//                 child: const Icon(
//                   Icons.cast_rounded,
//                   color: Color(0xFFFFD600),
//                   size: 22,
//                 ),
//               ),
//               const SizedBox(width: 12),
//               const Text(
//                 'Cast Request',
//                 style: TextStyle(
//                   color: Colors.white,
//                   fontSize: 18,
//                   fontWeight: FontWeight.w700,
//                 ),
//               ),
//             ],
//           ),
//           content: Column(
//             mainAxisSize: MainAxisSize.min,
//             crossAxisAlignment: CrossAxisAlignment.start,
//             children: [
//               // Sender info
//               Container(
//                 padding: const EdgeInsets.all(12),
//                 decoration: BoxDecoration(
//                   color: Colors.white.withOpacity(0.05),
//                   borderRadius: BorderRadius.circular(12),
//                 ),
//                 child: Row(
//                   children: [
//                     const Icon(
//                       Icons.person_rounded,
//                       color: Color(0xFFFFD600),
//                       size: 20,
//                     ),
//                     const SizedBox(width: 10),
//                     Expanded(
//                       child: Column(
//                         crossAxisAlignment: CrossAxisAlignment.start,
//                         children: [
//                           const Text(
//                             'From',
//                             style: TextStyle(
//                               color: Colors.white54,
//                               fontSize: 11,
//                             ),
//                           ),
//                           const SizedBox(height: 2),
//                           Text(
//                             request.deviceName,
//                             style: const TextStyle(
//                               color: Color(0xFFFFD600),
//                               fontWeight: FontWeight.w700,
//                               fontSize: 16,
//                             ),
//                           ),
//                         ],
//                       ),
//                     ),
//                   ],
//                 ),
//               ),
//               const SizedBox(height: 12),
//               // File info
//               Container(
//                 padding: const EdgeInsets.all(12),
//                 decoration: BoxDecoration(
//                   color: Colors.white.withOpacity(0.05),
//                   borderRadius: BorderRadius.circular(12),
//                 ),
//                 child: Row(
//                   children: [
//                     const Icon(
//                       Icons.movie_rounded,
//                       color: Colors.white70,
//                       size: 20,
//                     ),
//                     const SizedBox(width: 10),
//                     Expanded(
//                       child: Column(
//                         crossAxisAlignment: CrossAxisAlignment.start,
//                         children: [
//                           const Text(
//                             'File',
//                             style: TextStyle(
//                               color: Colors.white54,
//                               fontSize: 11,
//                             ),
//                           ),
//                           const SizedBox(height: 2),
//                           Text(
//                             displayFileName,
//                             style: const TextStyle(
//                               color: Colors.white,
//                               fontWeight: FontWeight.w600,
//                               fontSize: 14,
//                             ),
//                             maxLines: 2,
//                             overflow: TextOverflow.ellipsis,
//                           ),
//                         ],
//                       ),
//                     ),
//                   ],
//                 ),
//               ),
//               const SizedBox(height: 16),
//               const Text(
//                 'Do you want to play this video?',
//                 style: TextStyle(color: Colors.white70, fontSize: 13),
//               ),
//             ],
//           ),
//           actions: [
//             TextButton(
//               onPressed: () {
//                 Navigator.of(dialogContext).pop();
//                 // Send decline acknowledgement to sender
//                 _discoveryService.sendCastAck(request.senderIp, false);
//               },
//               child: const Text('Decline', style: TextStyle(color: Colors.red)),
//             ),
//             ElevatedButton.icon(
//               onPressed: () {
//                 Navigator.of(dialogContext).pop();
//                 // Send accept acknowledgement to sender
//                 _discoveryService.sendCastAck(request.senderIp, true);
//                 // Play with built-in video player
//                 final navContext = navigatorKey.currentContext;
//                 if (navContext != null) {
//                   Navigator.of(navContext).push(
//                     MaterialPageRoute(
//                       builder:
//                           (_) =>
//                               Platform.isAndroid
//                                   ? NativeVideoPlayerScreen(
//                                     videoSource: request.url,
//                                     title: displayFileName,
//                                     subtitlePath: request.subtitleUrl,
//                                     castControllerIp: request.senderIp,
//                                   )
//                                   : VideoPlayerScreen(
//                                     videoSource: request.url,
//                                     title: displayFileName,
//                                     castControllerIp: request.senderIp,
//                                     subtitlePath: request.subtitleUrl,
//                                     duration:
//                                         request.duration != null &&
//                                                 request.duration! > 0
//                                             ? Duration(
//                                               seconds:
//                                                   request.duration!.toInt(),
//                                             )
//                                             : null,
//                                   ),
//                     ),
//                   );
//                 }
//               },
//               style: ElevatedButton.styleFrom(
//                 backgroundColor: const Color(0xFFFFD600),
//                 foregroundColor: Colors.black,
//                 padding: const EdgeInsets.symmetric(
//                   horizontal: 20,
//                   vertical: 10,
//                 ),
//                 shape: RoundedRectangleBorder(
//                   borderRadius: BorderRadius.circular(12),
//                 ),
//               ),
//               icon: const Icon(Icons.play_arrow_rounded, size: 20),
//               label: const Text(
//                 'Play',
//                 style: TextStyle(fontWeight: FontWeight.w700),
//               ),
//             ),
//           ],
//         );
//       },
//     );
//   }

//   String _extractFileName(String url) {
//     try {
//       final uri = Uri.parse(url);
//       final path = uri.pathSegments.isNotEmpty ? uri.pathSegments.last : '';
//       if (path.isNotEmpty && path.contains('.')) return path;
//     } catch (_) {}
//     return 'Cast Video';
//   }

//   void _showScreenMirrorDialog(ScreenMirrorRequest request) {
//     print(
//       '🪞 [Global] _showScreenMirrorDialog called for ${request.deviceName}',
//     );
//     BuildContext? context = navigatorKey.currentContext;
//     print(
//       '🪞 [Global]   navigatorKey.currentContext is ${context == null ? "NULL" : "available"}',
//     );
//     if (context == null) {
//       print('🪞 [Global]   Context null, retrying in 500ms...');
//       Future.delayed(const Duration(milliseconds: 500), () {
//         final retryContext = navigatorKey.currentContext;
//         print(
//           '🪞 [Global]   Retry context is ${retryContext == null ? "NULL" : "available"}',
//         );
//         if (retryContext != null) {
//           _showScreenMirrorDialogWithContext(retryContext, request);
//         } else {
//           print(
//             '❌ [Global]   Retry also failed - no context available to show screen mirror dialog!',
//           );
//         }
//       });
//       return;
//     }
//     _showScreenMirrorDialogWithContext(context, request);
//   }

//   void _showScreenMirrorDialogWithContext(
//     BuildContext context,
//     ScreenMirrorRequest request,
//   ) {
//     // Bring window to foreground on Windows
//     if (Platform.isWindows) {
//       windowManager.show();
//       windowManager.focus();
//       windowManager.setAlwaysOnTop(true);
//       Future.delayed(const Duration(milliseconds: 500), () {
//         windowManager.setAlwaysOnTop(false);
//       });
//     }

//     showDialog(
//       context: context,
//       barrierDismissible: false,
//       builder: (dialogContext) {
//         return AlertDialog(
//           backgroundColor: const Color(0xFF1A1A1A),
//           shape: RoundedRectangleBorder(
//             borderRadius: BorderRadius.circular(20),
//             side: BorderSide(color: const Color(0xFFFFD600).withOpacity(0.2)),
//           ),
//           title: Row(
//             children: [
//               Container(
//                 padding: const EdgeInsets.all(8),
//                 decoration: BoxDecoration(
//                   color: const Color(0xFFFFD600).withOpacity(0.15),
//                   borderRadius: BorderRadius.circular(10),
//                 ),
//                 child: const Icon(
//                   Icons.screen_share_rounded,
//                   color: Color(0xFFFFD600),
//                   size: 22,
//                 ),
//               ),
//               const SizedBox(width: 12),
//               const Expanded(
//                 child: Text(
//                   'Screen Mirror',
//                   style: TextStyle(
//                     color: Colors.white,
//                     fontSize: 18,
//                     fontWeight: FontWeight.w700,
//                   ),
//                 ),
//               ),
//             ],
//           ),
//           content: Column(
//             mainAxisSize: MainAxisSize.min,
//             crossAxisAlignment: CrossAxisAlignment.start,
//             children: [
//               Container(
//                 padding: const EdgeInsets.all(12),
//                 decoration: BoxDecoration(
//                   color: Colors.white.withOpacity(0.05),
//                   borderRadius: BorderRadius.circular(12),
//                 ),
//                 child: Row(
//                   children: [
//                     const Icon(
//                       Icons.phone_android_rounded,
//                       color: Color(0xFFFFD600),
//                       size: 20,
//                     ),
//                     const SizedBox(width: 10),
//                     Expanded(
//                       child: Column(
//                         crossAxisAlignment: CrossAxisAlignment.start,
//                         children: [
//                           const Text(
//                             'From',
//                             style: TextStyle(
//                               color: Colors.white54,
//                               fontSize: 11,
//                             ),
//                           ),
//                           const SizedBox(height: 2),
//                           Text(
//                             request.deviceName,
//                             style: const TextStyle(
//                               color: Color(0xFFFFD600),
//                               fontWeight: FontWeight.w700,
//                               fontSize: 16,
//                             ),
//                           ),
//                         ],
//                       ),
//                     ),
//                   ],
//                 ),
//               ),
//               const SizedBox(height: 16),
//               const Text(
//                 'This device wants to share its screen with you.',
//                 style: TextStyle(color: Colors.white70, fontSize: 13),
//               ),
//             ],
//           ),
//           actions: [
//             TextButton(
//               onPressed: () {
//                 Navigator.of(dialogContext).pop();
//               },
//               child: const Text('Decline', style: TextStyle(color: Colors.red)),
//             ),
//             ElevatedButton.icon(
//               onPressed: () {
//                 Navigator.of(dialogContext).pop();

//                 final navContext = navigatorKey.currentContext;
//                 if (navContext != null) {
//                   Navigator.of(navContext).push(
//                     MaterialPageRoute(
//                       builder:
//                           (_) => ScreenMirrorViewerScreen(
//                             streamUrl: request.streamUrl,
//                             deviceName: request.deviceName,
//                             senderIp: request.senderIp,
//                             isSeparateWindow: false,
//                             initialWidth: request.width,
//                             initialHeight: request.height,
//                           ),
//                     ),
//                   );
//                 }
//               },
//               style: ElevatedButton.styleFrom(
//                 backgroundColor: const Color(0xFFFFD600),
//                 foregroundColor: Colors.black,
//                 padding: const EdgeInsets.symmetric(
//                   horizontal: 20,
//                   vertical: 10,
//                 ),
//                 shape: RoundedRectangleBorder(
//                   borderRadius: BorderRadius.circular(12),
//                 ),
//               ),
//               icon: const Icon(Icons.screen_share_rounded, size: 20),
//               label: const Text(
//                 'View',
//                 style: TextStyle(fontWeight: FontWeight.w700),
//               ),
//             ),
//           ],
//         );
//       },
//     );
//   }

//   String _ipToCode(String ipAddress, {int port = 8080}) {
//     final parts = ipAddress.split('.');
//     if (parts.length != 4) return '';
//     final n =
//         (int.parse(parts[0]) << 24) |
//         (int.parse(parts[1]) << 16) |
//         (int.parse(parts[2]) << 8) |
//         int.parse(parts[3]);
//     String ipCode = n.toRadixString(36).toUpperCase().padLeft(8, '0');
//     String portCode = port.toRadixString(36).toUpperCase().padLeft(3, '0');
//     return ipCode + portCode;
//   }

//   @override
//   void didChangeAppLifecycleState(AppLifecycleState state) {
//     if (state == AppLifecycleState.detached) {
//       print('🛑 [App] Lifecycle DETACHED - Stopping all services');
//       _discoveryService.stop();
//       if (Platform.isAndroid) {
//         FlutterForegroundTask.stopService();
//       }
//     }
//   }

//   @override
//   void dispose() {
//     WidgetsBinding.instance.removeObserver(this);
//     _discoveryService.stop();
//     if (Platform.isAndroid) {
//       FlutterForegroundTask.stopService();
//     }
//     if (Platform.isWindows) {
//       windowManager.removeListener(this);
//       trayManager.removeListener(this);
//     }
//     _connectionRequestSubscription?.cancel();
//     _castRequestSubscription?.cancel();
//     _screenMirrorSubscription?.cancel();
//     _audioOfferSubscription?.cancel();
//     // Keep discovery service running - it should run for the entire app lifecycle
//     super.dispose();
//   }

//   Future<void> _initSystemTray() async {
//     await trayManager.setIcon(
//       Platform.isWindows
//           ? 'assets/images/tray_icon.ico'
//           : 'assets/images/logo.png',
//     );

//     // Set tooltip
//     await trayManager.setToolTip('ZapShare - Fast File Sharing');

//     Menu menu = Menu(
//       items: [
//         MenuItem(key: 'show_window', label: 'Show ZapShare'),
//         MenuItem.separator(),
//         MenuItem(key: 'exit_app', label: 'Exit'),
//       ],
//     );
//     await trayManager.setContextMenu(menu);
//   }

//   Future<void> _registerContextMenu() async {
//     // Only for Windows
//     if (!Platform.isWindows) return;

//     try {
//       final String exePath = Platform.resolvedExecutable;
//       // Register "ZapShare" in Context Menu
//       // HKCU\Software\Classes\*\shell\ZapShare
//       await Process.run('reg', [
//         'add',
//         'HKCU\\Software\\Classes\\*\\shell\\ZapShare',
//         '/ve',
//         '/d',
//         'Share with ZapShare',
//         '/f',
//       ]);
//       await Process.run('reg', [
//         'add',
//         'HKCU\\Software\\Classes\\*\\shell\\ZapShare',
//         '/v',
//         'Icon',
//         '/d',
//         '"$exePath"',
//         '/f',
//       ]);

//       // Command to run
//       // HKCU\Software\Classes\*\shell\ZapShare\command
//       // "path/to/exe" "%1"
//       await Process.run('reg', [
//         'add',
//         'HKCU\\Software\\Classes\\*\\shell\\ZapShare\\command',
//         '/ve',
//         '/d',
//         '"$exePath" "%1"',
//         '/f',
//       ]);

//       print('✅ Context menu registered');
//     } catch (e) {
//       print('❌ Failed to register context menu: $e');
//     }
//   }

//   @override
//   void onWindowClose() async {
//     bool _isPreventClose = await windowManager.isPreventClose();
//     if (_isPreventClose) {
//       windowManager.hide();
//     }
//   }

//   @override
//   void onTrayIconMouseDown() {
//     windowManager.show();
//     windowManager.focus();
//   }

//   @override
//   void onTrayIconRightMouseDown() {
//     trayManager.popUpContextMenu();
//   }

//   @override
//   void onTrayMenuItemClick(MenuItem menuItem) {
//     if (menuItem.key == 'show_window') {
//       windowManager.show();
//       windowManager.focus();
//     } else if (menuItem.key == 'exit_app') {
//       exit(0);
//     }
//   }

//   @override
//   Widget build(BuildContext context) {
//     if (_isFirstRun == null) {
//       return Container(color: Colors.black);
//     }
//     return MaterialApp(
//       navigatorKey: navigatorKey,
//       theme: ThemeData(
//         brightness: Brightness.dark,
//         primaryColor: const Color(0xFFFFD600),
//         scaffoldBackgroundColor: Colors.transparent,
//         appBarTheme: const AppBarTheme(
//           backgroundColor: Colors.black,
//           elevation: 0,
//           centerTitle: true,
//           titleTextStyle: TextStyle(
//             color: Colors.white,
//             fontSize: 20,
//             fontWeight: FontWeight.w600,
//             letterSpacing: 0.5,
//           ),
//         ),
//         cardTheme: CardThemeData(
//           color: const Color(0xFF1A1A1A),
//           elevation: 8,
//           shadowColor: Colors.black.withOpacity(0.3),
//           shape: RoundedRectangleBorder(
//             borderRadius: BorderRadius.circular(16),
//           ),
//         ),
//         elevatedButtonTheme: ElevatedButtonThemeData(
//           style: ElevatedButton.styleFrom(
//             backgroundColor: const Color(0xFFFFD600),
//             foregroundColor: Colors.black,
//             elevation: 4,
//             shadowColor: const Color(0xFFFFD600).withOpacity(0.3),
//             shape: RoundedRectangleBorder(
//               borderRadius: BorderRadius.circular(12),
//             ),
//             padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
//             textStyle: const TextStyle(
//               fontSize: 16,
//               fontWeight: FontWeight.w600,
//               letterSpacing: 0.5,
//             ),
//           ),
//         ),
//         floatingActionButtonTheme: const FloatingActionButtonThemeData(
//           backgroundColor: Color(0xFFFFD600),
//           foregroundColor: Colors.black,
//           elevation: 8,
//           shape: RoundedRectangleBorder(
//             borderRadius: BorderRadius.all(Radius.circular(16)),
//           ),
//         ),
//         bottomNavigationBarTheme: const BottomNavigationBarThemeData(
//           backgroundColor: Color(0xFF1A1A1A),
//           selectedItemColor: Color(0xFFFFD600),
//           unselectedItemColor: Colors.white70,
//           type: BottomNavigationBarType.fixed,
//           elevation: 8,
//         ),
//         textTheme: const TextTheme(
//           headlineLarge: TextStyle(
//             color: Colors.white,
//             fontSize: 32,
//             fontWeight: FontWeight.bold,
//             letterSpacing: -0.5,
//           ),
//           headlineMedium: TextStyle(
//             color: Colors.white,
//             fontSize: 24,
//             fontWeight: FontWeight.w600,
//             letterSpacing: -0.25,
//           ),
//           titleLarge: TextStyle(
//             color: Colors.white,
//             fontSize: 20,
//             fontWeight: FontWeight.w600,
//             letterSpacing: 0,
//           ),
//           titleMedium: TextStyle(
//             color: Colors.white,
//             fontSize: 16,
//             fontWeight: FontWeight.w500,
//             letterSpacing: 0.15,
//           ),
//           bodyLarge: TextStyle(
//             color: Colors.white,
//             fontSize: 16,
//             fontWeight: FontWeight.normal,
//             letterSpacing: 0.5,
//           ),
//           bodyMedium: TextStyle(
//             color: Colors.white70,
//             fontSize: 14,
//             fontWeight: FontWeight.normal,
//             letterSpacing: 0.25,
//           ),
//         ),
//         inputDecorationTheme: InputDecorationTheme(
//           filled: true,
//           fillColor: const Color(0xFF2A2A2A),
//           border: OutlineInputBorder(
//             borderRadius: BorderRadius.circular(12),
//             borderSide: BorderSide.none,
//           ),
//           enabledBorder: OutlineInputBorder(
//             borderRadius: BorderRadius.circular(12),
//             borderSide: BorderSide(color: Colors.white.withOpacity(0.1)),
//           ),
//           focusedBorder: OutlineInputBorder(
//             borderRadius: BorderRadius.circular(12),
//             borderSide: const BorderSide(color: Color(0xFFFFD600), width: 2),
//           ),
//           contentPadding: const EdgeInsets.symmetric(
//             horizontal: 16,
//             vertical: 16,
//           ),
//           hintStyle: TextStyle(
//             color: Colors.white.withOpacity(0.5),
//             fontSize: 16,
//           ),
//         ),
//       ),
//       home:
//           _isFirstRun!
//               ? FirstTimeSetupScreen(
//                 onSetupComplete: () async {
//                   final prefs = await SharedPreferences.getInstance();
//                   await prefs.setBool('first_run_complete', true);
//                   setState(() {
//                     _isFirstRun = false;
//                   });
//                   _ensureDeviceName(); // Double check name is set
//                 },
//               )
//               : (widget.initialShareFiles != null &&
//                   widget.initialShareFiles!.isNotEmpty)
//               ? AndroidHttpFileShareScreen(
//                 initialSharedFiles: widget.initialShareFiles,
//               )
//               : Platform.isAndroid
//               ? const AndroidHomeScreen()
//               : Platform.isWindows
//               ? _isMirrorMode()
//                   ? _buildMirrorFromArgs()
//                   : (widget.launchArgs != null &&
//                       widget.launchArgs!.isNotEmpty &&
//                       File(widget.launchArgs!.first).existsSync())
//                   ? WindowsCastScreen(
//                     initialFile: File(widget.launchArgs!.first),
//                   )
//                   : const WindowsHomeScreen()
//               : Platform.isLinux
//               ? const LinuxHomeScreen()
//               : AndroidHttpFileShareScreen(),
//       debugShowCheckedModeBanner: false,
//       builder: (context, child) {
//         return Stack(
//           children: [if (child != null) child, _AudioStatusOverlay()],
//         );
//       },
//     );
//   }

//   // --- Helper to check for mirror arguments ---
//   bool _isMirrorMode() {
//     if (widget.launchArgs == null) return false;
//     return widget.launchArgs!.contains('--mirror');
//   }

//   Widget _buildMirrorFromArgs() {
//     final args = widget.launchArgs!;
//     final mirrorIdx = args.indexOf('--mirror');
//     if (mirrorIdx != -1 && mirrorIdx + 3 < args.length) {
//       final url = args[mirrorIdx + 1];
//       final name = args[mirrorIdx + 2];
//       final ip = args[mirrorIdx + 3];

//       return ScreenMirrorViewerScreen(
//         streamUrl: url,
//         deviceName: name,
//         senderIp: ip.isEmpty ? null : ip,
//         isSeparateWindow: true,
//       );
//     }
//     return const WindowsHomeScreen();
//   }
// }

// class AndroidNavBar extends StatefulWidget {
//   const AndroidNavBar({super.key});
//   @override
//   State<AndroidNavBar> createState() => _AndroidNavBarState();
// }

// class _AndroidNavBarState extends State<AndroidNavBar> {
//   int _selectedIndex = 0;
//   final List<Widget> _screens = [
//     AndroidHttpFileShareScreen(),
//     AndroidReceiveScreen(),
//     TransferHistoryScreen(),
//   ];
//   @override
//   Widget build(BuildContext context) {
//     return Scaffold(
//       backgroundColor: Colors.black,
//       body: _screens[_selectedIndex],
//       bottomNavigationBar: Padding(
//         padding: const EdgeInsets.only(bottom: 18, left: 16, right: 16),
//         child: ClipRRect(
//           borderRadius: BorderRadius.circular(32),
//           child: Container(
//             color: Colors.white.withOpacity(0.12),
//             child: BottomNavigationBar(
//               type: BottomNavigationBarType.fixed,
//               backgroundColor: Colors.transparent,
//               elevation: 0,
//               selectedItemColor: Colors.white,
//               unselectedItemColor: Colors.white70,
//               showSelectedLabels: true,
//               showUnselectedLabels: true,
//               currentIndex: _selectedIndex,
//               onTap: (index) => setState(() => _selectedIndex = index),
//               items: const [
//                 BottomNavigationBarItem(
//                   icon: Icon(Icons.upload_rounded),
//                   label: 'Send',
//                 ),
//                 BottomNavigationBarItem(
//                   icon: Icon(Icons.download_rounded),
//                   label: 'Receive',
//                 ),
//                 BottomNavigationBarItem(
//                   icon: Icon(Icons.history_rounded),
//                   label: 'History',
//                 ),
//               ],
//             ),
//           ),
//         ),
//       ),
//     );
//   }
// }

// class WindowsNavBar extends StatefulWidget {
//   const WindowsNavBar({super.key});
//   @override
//   State<WindowsNavBar> createState() => _WindowsNavBarState();
// }

// class _WindowsNavBarState extends State<WindowsNavBar>
//     with SingleTickerProviderStateMixin {
//   int _selectedIndex = 0;
//   bool _isCollapsed = false;
//   final double _collapsedWidth = 64;
//   final double _expandedWidth = 180;
//   final Duration _animationDuration = Duration(milliseconds: 250);
//   final List<Widget> _screens = [
//     WindowsFileShareScreen(),
//     WindowsReceiveScreen(),
//     TransferHistoryScreen(),
//   ];

//   @override
//   Widget build(BuildContext context) {
//     return Scaffold(
//       backgroundColor: Colors.black,
//       body: Stack(
//         children: [
//           Row(
//             children: [
//               AnimatedContainer(
//                 duration: _animationDuration,
//                 width: _isCollapsed ? _collapsedWidth : _expandedWidth,
//                 curve: Curves.easeInOut,
//                 margin: EdgeInsets.only(left: 0, top: 0, bottom: 0, right: 0),
//                 decoration: BoxDecoration(
//                   color: const Color(0xFF23272F).withOpacity(0.95),
//                   borderRadius: BorderRadius.only(
//                     topRight: Radius.circular(24),
//                     bottomRight: Radius.circular(24),
//                   ),
//                   boxShadow: [
//                     BoxShadow(
//                       color: Colors.black.withOpacity(0.25),
//                       blurRadius: 24,
//                       offset: Offset(4, 8),
//                     ),
//                   ],
//                 ),
//                 child: Column(
//                   children: [
//                     SizedBox(height: 24),
//                     IconButton(
//                       icon: Icon(
//                         _isCollapsed ? Icons.chevron_right : Icons.chevron_left,
//                         color: Colors.white70,
//                       ),
//                       tooltip:
//                           _isCollapsed
//                               ? 'Expand Navigation'
//                               : 'Collapse Navigation',
//                       onPressed: () {
//                         setState(() {
//                           _isCollapsed = !_isCollapsed;
//                         });
//                       },
//                     ),
//                     const SizedBox(height: 12),
//                     _buildNavItem(
//                       icon: Icons.upload_rounded,
//                       label: 'Send',
//                       selected: _selectedIndex == 0,
//                       onTap: () => setState(() => _selectedIndex = 0),
//                       collapsed: _isCollapsed,
//                     ),
//                     _buildNavItem(
//                       icon: Icons.download_rounded,
//                       label: 'Receive',
//                       selected: _selectedIndex == 1,
//                       onTap: () => setState(() => _selectedIndex = 1),
//                       collapsed: _isCollapsed,
//                     ),
//                     _buildNavItem(
//                       icon: Icons.history_rounded,
//                       label: 'History',
//                       selected: _selectedIndex == 2,
//                       onTap: () => setState(() => _selectedIndex = 2),
//                       collapsed: _isCollapsed,
//                     ),
//                     Spacer(),
//                   ],
//                 ),
//               ),
//               Expanded(child: _screens[_selectedIndex]),
//             ],
//           ),
//         ],
//       ),
//     );
//   }

//   Widget _buildNavItem({
//     required IconData icon,
//     required String label,
//     required bool selected,
//     required VoidCallback onTap,
//     required bool collapsed,
//   }) {
//     return InkWell(
//       onTap: onTap,
//       borderRadius: BorderRadius.circular(16),
//       child: AnimatedContainer(
//         duration: _animationDuration,
//         margin: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
//         padding: EdgeInsets.symmetric(
//           vertical: 12,
//           horizontal: collapsed ? 0 : 10,
//         ),
//         decoration: BoxDecoration(
//           color:
//               selected ? kAccentYellow.withOpacity(0.18) : Colors.transparent,
//           borderRadius: BorderRadius.circular(16),
//         ),
//         child: Row(
//           mainAxisAlignment:
//               collapsed ? MainAxisAlignment.center : MainAxisAlignment.start,
//           children: [
//             Icon(
//               icon,
//               color: selected ? kAccentYellow : Colors.white70,
//               size: 28,
//             ),
//             if (!collapsed) ...[
//               const SizedBox(width: 18),
//               Text(
//                 label,
//                 style: TextStyle(
//                   color: selected ? kAccentYellow : Colors.white70,
//                   fontSize: 16,
//                   fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
//                 ),
//               ),
//             ],
//           ],
//         ),
//       ),
//     );
//   }
// }

// class _AudioStatusOverlay extends StatelessWidget {
//   @override
//   Widget build(BuildContext context) {
//     return StreamBuilder<bool>(
//       stream: DeviceDiscoveryService().activeAudioStream,
//       initialData: DeviceDiscoveryService().isAudioActive,
//       builder: (context, snapshot) {
//         final isActive = snapshot.data ?? false;
//         if (!isActive) return const SizedBox.shrink();

//         return Positioned(
//           top: MediaQuery.of(context).padding.top + 10,
//           left: 10,
//           right: 10,
//           child: Material(
//             color: Colors.transparent,
//             child: Container(
//               padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
//               decoration: BoxDecoration(
//                 color: const Color(0xFF1C1C1E).withOpacity(0.95),
//                 borderRadius: BorderRadius.circular(20),
//                 border: Border.all(
//                   color: const Color(0xFFFFD600).withOpacity(0.3),
//                 ),
//                 boxShadow: [
//                   BoxShadow(
//                     color: Colors.black.withOpacity(0.4),
//                     blurRadius: 15,
//                     offset: const Offset(0, 8),
//                   ),
//                 ],
//               ),
//               child: Row(
//                 children: [
//                   Container(
//                     padding: const EdgeInsets.all(8),
//                     decoration: BoxDecoration(
//                       color: const Color(0xFFFFD600).withOpacity(0.2),
//                       shape: BoxShape.circle,
//                     ),
//                     child: const _PulseIcon(),
//                   ),
//                   const SizedBox(width: 12),
//                   Expanded(
//                     child: Column(
//                       crossAxisAlignment: CrossAxisAlignment.start,
//                       mainAxisSize: MainAxisSize.min,
//                       children: [
//                         Text(
//                           'ZapShare Audio',
//                           style: GoogleFonts.outfit(
//                             color: const Color(0xFFFFD600),
//                             fontWeight: FontWeight.bold,
//                             fontSize: 14,
//                           ),
//                         ),
//                         Text(
//                           'Streaming/Receiving low-latency audio',
//                           style: GoogleFonts.outfit(
//                             color: Colors.white70,
//                             fontSize: 12,
//                           ),
//                         ),
//                       ],
//                     ),
//                   ),
//                   TextButton(
//                     onPressed: () => DeviceDiscoveryService().stopWebRtcAudio(),
//                     style: TextButton.styleFrom(
//                       foregroundColor: Colors.redAccent,
//                       padding: const EdgeInsets.symmetric(horizontal: 12),
//                     ),
//                     child: const Text('STOP'),
//                   ),
//                 ],
//               ),
//             ),
//           ),
//         );
//       },
//     );
//   }
// }

// class _PulseIcon extends StatefulWidget {
//   const _PulseIcon();
//   @override
//   State<_PulseIcon> createState() => _PulseIconState();
// }

// class _PulseIconState extends State<_PulseIcon>
//     with SingleTickerProviderStateMixin {
//   late AnimationController _controller;
//   @override
//   void initState() {
//     super.initState();
//     _controller = AnimationController(
//       vsync: this,
//       duration: const Duration(seconds: 1),
//     )..repeat(reverse: true);
//   }

//   @override
//   void dispose() {
//     _controller.dispose();
//     super.dispose();
//   }

//   @override
//   Widget build(BuildContext context) {
//     return AnimatedBuilder(
//       animation: _controller,
//       builder: (context, child) {
//         return Icon(
//           Icons.graphic_eq_rounded,
//           color: const Color(v
//             0xFFFFD600,
//           ).withOpacity(0.5 + (_controller.value * 0.5)),
//           size: 18,
//         );
//       },
//     );
//   }
// }
