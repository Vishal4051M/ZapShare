import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zap_share/Screens/android/AndroidHttpFileShareScreen.dart';
import 'package:zap_share/Screens/android/AndroidReceiveOptionsScreen.dart';
import 'package:zap_share/Screens/auth/LoginScreen.dart';
import 'package:zap_share/Screens/shared/DeviceSettingsScreen.dart';
import 'package:zap_share/Screens/shared/TransferHistoryScreen.dart';
import 'package:zap_share/blocs/navigation/smooth_page_route.dart';
import 'package:file_picker/file_picker.dart';
import 'package:zap_share/Screens/android/AndroidCastScreen.dart';
import 'package:zap_share/Screens/shared/audio_share_screen.dart';
import 'package:zap_share/Screens/shared/FirstTimeSetupScreen.dart';
import 'package:zap_share/Screens/windows/WindowsHomeScreen.dart';
import 'package:zap_share/Screens/linux/LinuxHomeScreen.dart';
import 'package:zap_share/Screens/android/AndroidCastSelectionScreen.dart';
import 'package:zap_share/services/firebase_service.dart';
import 'package:zap_share/widgets/CustomAvatarWidget.dart';
import 'package:zap_share/modules/remote_p2p/views/RemoteTransferDialog.dart';
import 'package:zap_share/modules/remote_p2p/views/UnifiedP2PSessionView.dart';
import 'package:zap_share/modules/remote_p2p/views/RemoteSendView.dart';
import 'package:zap_share/modules/remote_p2p/views/RemoteReceiveView.dart';
import 'package:zap_share/modules/remote_p2p/views/RemoteCastView.dart';
import 'package:zap_share/modules/remote_p2p/views/RemoteHistoryView.dart';
import 'package:zap_share/modules/remote_p2p/models/P2PSessionModel.dart';

class AndroidHomeScreen extends StatefulWidget {
  const AndroidHomeScreen({super.key});

  @override
  _AndroidHomeScreenState createState() => _AndroidHomeScreenState();
}

class _AndroidHomeScreenState extends State<AndroidHomeScreen>
    with WidgetsBindingObserver {
  static const MethodChannel _platform = MethodChannel('zapshare.saf');
  String? _lastClipboardContent;

  StreamSubscription<List<Map<String, dynamic>>>? _cloudClipboardSubscription;

  StreamSubscription<AuthState>? _authStateSubscription;
  String? _lastCloudContent;
  final FlutterLocalNotificationsPlugin _notificationsPlugin =
      FlutterLocalNotificationsPlugin();
  final Set<String> _notifiedFriendRequests = {};

  bool _isAnywhereMode = false;

  int _currentClipboardPage = 0;
  late PageController _clipboardPageController;

  @override
  void initState() {
    super.initState();
    _initNotifications();
    _initFCM();
    _clipboardPageController = PageController();
    WidgetsBinding.instance.addObserver(this);
    _listenForSharedFiles();
    _loadAnywhereMode();

    // Listen for auth state changes
    _authStateSubscription = FirebaseService().authStateChanges.listen((data) {
      if (mounted) {
        final isLoggedIn = FirebaseService().currentUser != null;
        setState(() {
          _isAnywhereMode = isLoggedIn;
        });
        _subscribeToCloudClipboard();
        _subscribeToTransfers();
        _subscribeToFriendRequests();
        _subscribeToCastRequests();
        _initFCM();
      }
    });

    _subscribeToCloudClipboard();
    _subscribeToTransfers();
    _subscribeToFriendRequests();
    _subscribeToCastRequests();
  }

  StreamSubscription<List<Map<String, dynamic>>>? _transfersSubscription;
  StreamSubscription<List<Map<String, dynamic>>>? _friendRequestsSubscription;
  StreamSubscription<List<Map<String, dynamic>>>? _castRequestsSubscription;
  bool _isShowingTransferDialog = false;
  bool _isShowingFriendRequestDialog = false;
  bool _isShowingCastDialog = false;

  void _subscribeToTransfers() {
    _transfersSubscription?.cancel();
    final user = FirebaseService().currentUser;
    if (user == null) return;

    // Stream now emits one record at a time via onChildAdded.
    _transfersSubscription = FirebaseService()
        .getIncomingTransfersStream()
        .listen((transfers) {
          if (transfers.isNotEmpty) {
            final transfer = transfers.first;
            if (transfer['status'] == 'pending' && mounted) {
              _showIncomingTransferDialog(transfer);
            }
          }
        });
  }

  void _subscribeToCastRequests() {
    _castRequestsSubscription?.cancel();
    final user = FirebaseService().currentUser;
    if (user == null) return;

    // Stream now emits one record at a time via onChildAdded.
    _castRequestsSubscription = FirebaseService()
        .getIncomingCastRequestsStream()
        .listen((requests) {
          if (requests.isNotEmpty) {
            final request = requests.first;
            if (request['status'] == 'pending' && mounted) {
              _showIncomingCastDialog(request);
            }
          }
        });
  }

  void _showIncomingCastDialog(Map<String, dynamic> cast) {
    if (_isShowingCastDialog) return;
    _isShowingCastDialog = true;

    final castId = cast['id'] as String;
    final senderName = cast['senderName'] ?? 'Someone';
    final senderEmail = cast['senderEmail'] ?? 'Unknown';
    final senderAvatar = cast['senderAvatar'] ?? '';
    final roomId = cast['roomId'] as String;
    final castMode = cast['castMode'] as String? ?? 'audio';

    showDialog(
      context: context,
      barrierDismissible: false,
      builder:
          (context) => AlertDialog(
            backgroundColor: const Color(0xFF1C1C1E),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(24),
            ),
            title: Row(
              children: [
                CircleAvatar(
                  backgroundColor: const Color(0xFFFFD600).withOpacity(0.1),
                  child: Text(senderAvatar.isNotEmpty ? senderAvatar : '👤'),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    "Incoming Cast",
                    style: GoogleFonts.outfit(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  "$senderName ($senderEmail) wants to cast to your device:",
                  style: GoogleFonts.outfit(
                    color: Colors.white70,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  "Mode: ${castMode.toUpperCase()}",
                  style: GoogleFonts.outfit(
                    color: const Color(0xFFFFD600),
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 24),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () async {
                          Navigator.pop(context);
                          _isShowingCastDialog = false;
                          await FirebaseService().updateCastRequestStatus(
                            castId,
                            'rejected',
                          );
                          // Delete the record — prevents accumulation that inflates future downloads
                          await FirebaseService().deleteCastRequest(castId);
                        },
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white60,
                          side: const BorderSide(color: Colors.white10),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                        child: Text(
                          "Decline",
                          style: GoogleFonts.outfit(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: () async {
                          Navigator.pop(context);
                          _isShowingCastDialog = false;
                          await FirebaseService().updateCastRequestStatus(
                            castId,
                            'accepted',
                          );
                          // Delete the record — prevents accumulation that inflates future downloads
                          await FirebaseService().deleteCastRequest(castId);

                          if (mounted) {
                            Navigator.push(
                              context,
                              SmoothPageRoute.fade(
                                page: RemoteCastView(
                                  initialRoomId: roomId,
                                  castMode: castMode,
                                ),
                                duration: const Duration(milliseconds: 620),
                              ),
                            );
                          }
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFFFD600),
                          foregroundColor: Colors.black,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                        child: Text(
                          "Accept",
                          style: GoogleFonts.outfit(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
    );
  }

  Future<void> _initNotifications() async {
    if (!Platform.isAndroid) return;
    try {
      const androidInitSettings = AndroidInitializationSettings(
        'ic_stat_notify',
      );
      const initSettings = InitializationSettings(android: androidInitSettings);
      await _notificationsPlugin.initialize(settings: initSettings);

      // Create FCM channels for background/offline requests
      final androidLocalNotifications =
          _notificationsPlugin
              .resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin
              >();
      if (androidLocalNotifications != null) {
        await androidLocalNotifications.createNotificationChannel(
          const AndroidNotificationChannel(
            'zapshare_transfer_requests', // id
            'Transfer Requests', // name
            description: 'Incoming file transfer requests', // description
            importance: Importance.max,
            playSound: true,
            enableVibration: true,
          ),
        );
        await androidLocalNotifications.createNotificationChannel(
          const AndroidNotificationChannel(
            'friend_requests_channel', // id
            'Friend Requests', // name
            description:
                'Notifications for incoming friend requests', // description
            importance: Importance.max,
            playSound: true,
            enableVibration: true,
          ),
        );
      }
    } catch (e) {
      print("Error initializing local notifications: $e");
    }
  }

  Future<void> _initFCM() async {
    if (!Platform.isAndroid) return;
    try {
      final user = FirebaseService().currentUser;
      if (user == null) return;

      final messaging = FirebaseMessaging.instance;
      await messaging.requestPermission(
        alert: true,
        announcement: false,
        badge: true,
        carPlay: false,
        criticalAlert: false,
        provisional: false,
        sound: true,
      );

      final token = await messaging.getToken();
      if (token != null) {
        await FirebaseService().saveFcmToken(token);
      }

      messaging.onTokenRefresh.listen((newToken) {
        FirebaseService().saveFcmToken(newToken);
      });

      FirebaseMessaging.onMessage.listen((RemoteMessage message) {
        final notification = message.notification;
        if (notification != null) {
          _triggerLocalNotification(
            notification.title ?? 'ZapShare',
            notification.body ?? '',
          );
        }
      });
    } catch (e) {
      print("Error initializing FCM on Home Screen: $e");
    }
  }

  Future<void> _triggerLocalNotification(String title, String body) async {
    if (!Platform.isAndroid) return;
    const androidDetails = AndroidNotificationDetails(
      'fcm_foreground_channel',
      'Alerts',
      channelDescription: 'Foreground notifications from ZapShare services',
      importance: Importance.max,
      priority: Priority.high,
      showWhen: true,
      icon: 'ic_stat_notify',
    );
    const details = NotificationDetails(android: androidDetails);
    try {
      await _notificationsPlugin.show(
        id: 999,
        title: title,
        body: body,
        notificationDetails: details,
      );
    } catch (e) {
      print("Error showing foreground notification: $e");
    }
  }

  void _subscribeToFriendRequests() {
    _friendRequestsSubscription?.cancel();
    final user = FirebaseService().currentUser;
    if (user == null) return;

    _friendRequestsSubscription = FirebaseService()
        .getIncomingFriendRequestsStream()
        .listen((requests) {
          if (requests.isNotEmpty) {
            final pending = requests.firstWhere(
              (r) => r['status'] == 'pending',
              orElse: () => <String, dynamic>{},
            );
            if (pending.isNotEmpty && mounted) {
              _showIncomingFriendRequestDialog(pending);

              final senderId = pending['senderId'] as String?;
              if (senderId != null &&
                  !_notifiedFriendRequests.contains(senderId)) {
                _notifiedFriendRequests.add(senderId);
                _triggerFriendRequestNotification(pending);
              }
            }
          }
        });
  }

  Future<void> _triggerFriendRequestNotification(
    Map<String, dynamic> request,
  ) async {
    final senderName = request['senderName'] ?? 'Someone';
    final senderEmail = request['senderEmail'] ?? 'Unknown';

    const androidDetails = AndroidNotificationDetails(
      'friend_requests_channel',
      'Friend Requests',
      channelDescription: 'Notifications for incoming friend requests',
      importance: Importance.max,
      priority: Priority.high,
      showWhen: true,
    );

    const details = NotificationDetails(android: androidDetails);
    try {
      await _notificationsPlugin.show(
        id: 888,
        title: 'New Friend Request',
        body: '$senderName ($senderEmail) wants to add you as a friend.',
        notificationDetails: details,
      );
    } catch (e) {
      print("Error showing friend request notification: $e");
    }
  }

  void _showIncomingFriendRequestDialog(Map<String, dynamic> request) {
    if (_isShowingFriendRequestDialog) return;
    _isShowingFriendRequestDialog = true;

    final senderUid = request['senderId'] as String;
    final senderName = request['senderName'] ?? 'Someone';
    final senderEmail = request['senderEmail'] ?? 'Unknown';
    final senderAvatar = request['senderAvatar'] ?? '';

    showDialog(
      context: context,
      barrierDismissible: false,
      builder:
          (context) => AlertDialog(
            backgroundColor: const Color(0xFF1C1C1E),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(24),
            ),
            title: Row(
              children: [
                CustomAvatarWidget(
                  avatarId: senderAvatar,
                  size: 40,
                  showBorder: true,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    "Friend Request",
                    style: GoogleFonts.outfit(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  "$senderName ($senderEmail) wants to add you as a friend to share files.",
                  style: GoogleFonts.outfit(
                    color: Colors.white70,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 24),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () async {
                          Navigator.pop(context);
                          setState(() => _isShowingFriendRequestDialog = false);
                          await FirebaseService().declineFriendRequest(
                            senderUid,
                          );
                        },
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white60,
                          side: const BorderSide(color: Colors.white10),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                        child: Text(
                          "Decline",
                          style: GoogleFonts.outfit(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: () async {
                          final messenger = ScaffoldMessenger.of(context);
                          Navigator.pop(context);
                          setState(() => _isShowingFriendRequestDialog = false);
                          await FirebaseService().acceptFriendRequest(
                            senderUid,
                          );
                          messenger.showSnackBar(
                            const SnackBar(
                              content: Text("Friend request accepted!"),
                              backgroundColor: Colors.green,
                            ),
                          );
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFFFD600),
                          foregroundColor: Colors.black,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                        child: Text(
                          "Accept",
                          style: GoogleFonts.outfit(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
    );
  }

  void _showIncomingTransferDialog(Map<String, dynamic> transfer) {
    if (_isShowingTransferDialog) return;
    _isShowingTransferDialog = true;

    final transferId = transfer['id'] as String;
    final senderName = transfer['senderName'] ?? 'Someone';
    final senderEmail = transfer['senderEmail'] ?? 'Unknown';
    final senderAvatar = transfer['senderAvatar'] ?? '';
    final roomId = transfer['roomId'] as String;
    final fileNames = List<String>.from(transfer['fileNames'] ?? []);
    final fileSize = transfer['fileSize'] as int? ?? 0;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder:
          (dialogContext) => AlertDialog(
            backgroundColor: const Color(0xFF1C1C1E),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(24),
            ),
            title: Row(
              children: [
                CircleAvatar(
                  backgroundColor: const Color(0xFFFFD600).withOpacity(0.1),
                  child: Text(senderAvatar.isNotEmpty ? senderAvatar : '👤'),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    "Incoming Transfer",
                    style: GoogleFonts.outfit(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  "$senderName ($senderEmail) wants to send you files:",
                  style: GoogleFonts.outfit(
                    color: Colors.white70,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.black45,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        fileNames.join(', '),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.outfit(
                          color: Colors.white,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        "${(fileSize / (1024 * 1024)).toStringAsFixed(2)} MB",
                        style: GoogleFonts.outfit(
                          color: const Color(0xFFFFD600),
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () async {
                          Navigator.pop(dialogContext);
                          _isShowingTransferDialog = false;
                          await FirebaseService().updateTransferStatus(
                            transferId,
                            'rejected',
                          );
                          // Delete the record — prevents accumulation that inflates future downloads
                          await FirebaseService().deleteTransfer(transferId);
                        },
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white60,
                          side: const BorderSide(color: Colors.white10),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                        child: Text(
                          "Decline",
                          style: GoogleFonts.outfit(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: () async {
                          Navigator.pop(dialogContext);
                          _isShowingTransferDialog = false;
                          await FirebaseService().updateTransferStatus(
                            transferId,
                            'accepted',
                          );
                          // Delete the record — prevents accumulation that inflates future downloads
                          await FirebaseService().deleteTransfer(transferId);

                          if (mounted) {
                            Navigator.push(
                              context,
                              SmoothPageRoute.fade(
                                page: RemoteReceiveView(initialRoomId: roomId),
                                duration: const Duration(milliseconds: 620),
                              ),
                            );
                          }
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFFFD600),
                          foregroundColor: Colors.black,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                        child: Text(
                          "Download",
                          style: GoogleFonts.outfit(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
    );
  }

  void _showLoginPromptDialog() {
    showDialog(
      context: context,
      builder:
          (context) => AlertDialog(
            backgroundColor: const Color(0xFF1C1C1E),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(24),
            ),
            title: Text(
              "Unlock Cloud Mode",
              style: GoogleFonts.outfit(
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  "Sign in with Google to enable secure, background file sharing via unique usernames and email addresses globally.",
                  style: GoogleFonts.outfit(
                    color: Colors.white70,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 24),
                ElevatedButton.icon(
                  onPressed: () async {
                    Navigator.pop(context);
                    await Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const LoginScreen()),
                    );
                    if (mounted && FirebaseService().currentUser != null) {
                      _setMode(true);
                    }
                  },
                  icon: const Icon(Icons.login_rounded, color: Colors.black),
                  label: Text(
                    "Sign In with Google",
                    style: GoogleFonts.outfit(fontWeight: FontWeight.bold),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFFFD600),
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                ),
              ],
            ),
          ),
    );
  }

  Future<void> _loadAnywhereMode() async {
    final prefs = await SharedPreferences.getInstance();
    final isLoggedIn = FirebaseService().currentUser != null;
    setState(() {
      _isAnywhereMode = isLoggedIn;
    });
  }

  void _setMode(bool val) async {
    if (_isAnywhereMode == val) return;
    HapticFeedback.mediumImpact();

    if (val && FirebaseService().currentUser == null) {
      _showLoginPromptDialog();
      return;
    }

    setState(() {
      _isAnywhereMode = val;
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('anywhere_mode_enabled', val);
  }

  StreamSubscription<Map<String, dynamic>>? _clipboardInsertSubscription;
  final StreamController<List<Map<String, dynamic>>> _uiStreamController =
      StreamController<List<Map<String, dynamic>>>.broadcast();

  void _subscribeToCloudClipboard() {
    _cloudClipboardSubscription?.cancel();
    _clipboardInsertSubscription?.cancel();

    if (FirebaseService().currentUser == null) return;

    final subscriptionTime = DateTime.now();

    // 1. Subscribe to the LIST (Base Stream)
    // Connecting Firebase stream to our UI controller
    _cloudClipboardSubscription = FirebaseService().getClipboardStream().listen(
      (items) {
        if (!_uiStreamController.isClosed) {
          _uiStreamController.add(items);
        }
      },
    );

    // Fetch initial history immediately to prevent loading spinner hang
    FirebaseService()
        .fetchClipboardHistory()
        .then((history) {
          if (!_uiStreamController.isClosed) {
            _uiStreamController.add(history);
          }
        })
        .catchError((e) {
          print("Error fetching initial clipboard history: $e");
        });

    // 2. Subscribe to REALTIME UPDATES for instant background sync
    _clipboardInsertSubscription = FirebaseService()
        .subscribeToClipboardUpdates()
        .listen((newItem) async {
          if (DateTime.now().difference(subscriptionTime).inMilliseconds <
              1500) {
            return;
          }
          final content = newItem['content'] as String;
          await _processCloudContent(content);

          // FORCE UI REFRESH
          try {
            final history = await FirebaseService().fetchClipboardHistory();
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

      // Sync FROM Cloud TO Android Clipboard
      try {
        await Clipboard.setData(ClipboardData(text: content));
      } catch (e) {
        if (kDebugMode) {
          print("⚠️ [Clipboard] Failed to write to system clipboard: $e");
        }
      }

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

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cloudClipboardSubscription?.cancel();
    _clipboardInsertSubscription?.cancel();
    _authStateSubscription?.cancel();
    _transfersSubscription?.cancel();
    _friendRequestsSubscription?.cancel();
    _castRequestsSubscription?.cancel();
    _uiStreamController.close();
    _clipboardPageController.dispose();

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
      if (FirebaseService().currentUser == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Please login to sync clipboard')),
          );
        }
        return;
      }

      try {
        await FirebaseService().addClipboardItem(text);

        // Update trackers immediately to prevent duplicate toast on resubscription
        _lastClipboardContent = text;
        _lastCloudContent = text;

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
          if (FirebaseService().currentUser != null) {
            await FirebaseService().addClipboardItem(data.text!);
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
    final user = FirebaseService().currentUser;
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
            await FirebaseService().signOut();
            if (mounted) {
              Navigator.of(context).pushAndRemoveUntil(
                MaterialPageRoute(
                  builder:
                      (context) => FirstTimeSetupScreen(
                        onSetupComplete: () async {
                          final prefs = await SharedPreferences.getInstance();
                          await prefs.setBool('first_run_complete', true);
                          Widget homeScreen;
                          if (Platform.isWindows) {
                            homeScreen = const WindowsHomeScreen();
                          } else if (Platform.isLinux) {
                            homeScreen = const LinuxHomeScreen();
                          } else {
                            homeScreen = const AndroidHomeScreen();
                          }
                          Navigator.of(context).pushAndRemoveUntil(
                            MaterialPageRoute(builder: (context) => homeScreen),
                            (route) => false,
                          );
                        },
                      ),
                ),
                (route) => false,
              );
            }
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
        final Map<dynamic, dynamic> payload =
            call.arguments as Map<dynamic, dynamic>;
        final List<dynamic> files = payload['files'] as List<dynamic>;
        final String shareMode = payload['mode'] as String? ?? 'select';

        if (files.isNotEmpty && mounted) {
          print(
            '📁 [HomeScreen] Received shared files: ${files.length} files, navigating to send screen with mode $shareMode',
          );

          Widget targetScreen;
          if (shareMode == 'local') {
            targetScreen = AndroidHttpFileShareScreen(
              initialSharedFiles: files.cast<Map<dynamic, dynamic>>(),
            );
          } else if (shareMode == 'remote') {
            final platformFiles =
                files
                    .map(
                      (f) => PlatformFile(
                        path: f['uri'] as String,
                        name: f['name'] as String,
                        size: f['size'] as int? ?? 0,
                      ),
                    )
                    .toList();
            targetScreen = RemoteSendView(initialFiles: platformFiles);
          } else if (shareMode == 'cast') {
            final firstVideo = files.first;
            targetScreen = AndroidCastScreen(
              initialMode: CastMode.video,
              initialVideoUri: firstVideo['uri'] as String,
              initialVideoName: firstVideo['name'] as String,
            );
          } else {
            targetScreen = AndroidHttpFileShareScreen(
              initialSharedFiles: files.cast<Map<dynamic, dynamic>>(),
            );
          }

          Navigator.pushReplacement(
            context,
            MaterialPageRoute(builder: (context) => targetScreen),
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
    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // Header
                _buildHeader(),
                const SizedBox(height: 12),

                // Dashboard Section
                _buildSectionTitle("DASHBOARD"),
                const SizedBox(height: 10),
                _buildDashboardGrid(),

                const SizedBox(height: 16),

                // Tips Section
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    _buildSectionTitle("CLIPBOARD SYNC"),
                    _buildUserStatus(),
                  ],
                ),
                const SizedBox(height: 10),
              ],
            ),
          ),

          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
            child: SizedBox(
              height: (MediaQuery.of(context).size.height * 0.38).clamp(
                300.0,
                360.0,
              ),
              child: _buildClipboardSection(enableScroll: true),
            ),
          ),
        ],
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
                          return SingleChildScrollView(
                            physics: const BouncingScrollPhysics(),
                            child: _buildDashboardGrid(
                              maxHeight: dashConstraints.maxHeight,
                            ),
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

  Widget _buildModeToggleCompact() {
    return Container(
      height: 38,
      width: 110,
      decoration: BoxDecoration(
        color: const Color(0xFF1C1C1E),
        borderRadius: BorderRadius.circular(19),
        border: Border.all(color: Colors.white.withOpacity(0.08), width: 1),
      ),
      child: Stack(
        children: [
          AnimatedAlign(
            alignment:
                _isAnywhereMode ? Alignment.centerRight : Alignment.centerLeft,
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeInOut,
            child: FractionallySizedBox(
              widthFactor: 0.5,
              child: Container(
                height: 30,
                margin: const EdgeInsets.symmetric(horizontal: 3, vertical: 3),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFFFFE082), Color(0xFFFFD600)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(15),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFFFFD600).withOpacity(0.2),
                      blurRadius: 4,
                      offset: const Offset(0, 1),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Row(
            children: [
              Expanded(
                child: GestureDetector(
                  onTap: () => _setMode(false),
                  behavior: HitTestBehavior.opaque,
                  child: Center(
                    child: Icon(
                      Icons.wifi_rounded,
                      size: 16,
                      color: _isAnywhereMode ? Colors.white60 : Colors.black,
                    ),
                  ),
                ),
              ),
              Expanded(
                child: GestureDetector(
                  onTap: () => _setMode(true),
                  behavior: HitTestBehavior.opaque,
                  child: Center(
                    child: Icon(
                      Icons.cloud_rounded,
                      size: 16,
                      color: _isAnywhereMode ? Colors.black : Colors.white60,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
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
            const SizedBox(width: 12),
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
                          fontSize: 24,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.5,
                        ),
                      ),
                      TextSpan(
                        text: "Share",
                        style: GoogleFonts.outfit(
                          color: Colors.white,
                          fontSize: 24,
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
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildModeToggleCompact(),
            const SizedBox(width: 10),
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: const Color(0xFF1C1C1E),
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white.withOpacity(0.05)),
              ),
              child: IconButton(
                icon: const Icon(
                  Icons.settings_outlined,
                  color: Colors.white,
                  size: 20,
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
        ),
      ],
    );
  }

  double _uiScale(BuildContext context) {
    return 1.0;
  }

  double _scaled(BuildContext context, double value) {
    return value * _uiScale(context);
  }

  double _squareCardSize(
    BuildContext context,
    double maxWidth, {
    double? maxHeight,
    required double spacing,
  }) {
    var size = (maxWidth - spacing) / 2;
    final heightLimit = MediaQuery.of(context).size.height * 0.32;
    if (maxHeight != null && size > maxHeight) {
      size = maxHeight;
    }
    if (size > heightLimit) {
      size = heightLimit;
    }
    return size.clamp(0.0, 260.0);
  }

  Widget _buildSquareCardRow({
    required BuildContext context,
    required Widget left,
    required Widget right,
    required double maxWidth,
    double? maxHeight,
    required double spacing,
  }) {
    final size = _squareCardSize(
      context,
      maxWidth,
      maxHeight: maxHeight,
      spacing: spacing,
    );
    final totalWidth = size * 2 + spacing;

    return Align(
      alignment: Alignment.centerLeft,
      child: SizedBox(
        width: totalWidth,
        height: size,
        child: Row(
          children: [
            SizedBox(width: size, height: size, child: left),
            SizedBox(width: spacing),
            SizedBox(width: size, height: size, child: right),
          ],
        ),
      ),
    );
  }

  Widget _buildDashboardGrid({double? maxHeight}) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final spacing = _scaled(context, 16);
        final size = _squareCardSize(
          context,
          constraints.maxWidth,
          maxHeight: maxHeight,
          spacing: spacing,
        );
        final totalWidth = size * 2 + spacing;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_isAnywhereMode)
              Align(
                alignment: Alignment.centerLeft,
                child: SizedBox(
                  width: totalWidth,
                  height: size,
                  child: Hero(
                    tag: 'remote_send_card',
                    createRectTween:
                        (begin, end) => SmoothRectTween(begin: begin, end: end),
                    child: _buildCard(
                      title: "Send",
                      subtitle: "Share Files via Cloud",
                      icon: Icons.cloud_upload_rounded,
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
              )
            else
              _buildSquareCardRow(
                context: context,
                maxWidth: constraints.maxWidth,
                maxHeight: maxHeight,
                spacing: spacing,
                left: Hero(
                  tag: 'send_card_container',
                  createRectTween:
                      (begin, end) => SmoothRectTween(begin: begin, end: end),
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
                right: Hero(
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
            SizedBox(height: spacing),
            _buildSquareCardRow(
              context: context,
              maxWidth: constraints.maxWidth,
              maxHeight: maxHeight,
              spacing: spacing,
              left: Hero(
                tag: 'history_card_container',
                createRectTween:
                    (begin, end) => SmoothRectTween(begin: begin, end: end),
                child: _buildCard(
                  title: "History",
                  subtitle: _isAnywhereMode ? "Chats & Shared" : "Recent",
                  icon:
                      _isAnywhereMode
                          ? Icons.chat_bubble_outline_rounded
                          : Icons.history_rounded,
                  backgroundColor: const Color(0xFF1C1C1E),
                  textColor: Colors.white,
                  iconBgColor: Colors.white.withOpacity(0.1),
                  iconColor: const Color(0xFFFFD600),
                  onTap: () => _navigateToScreen(2),
                  context: context,
                ),
              ),
              right: Hero(
                tag:
                    _isAnywhereMode
                        ? 'remote_cast_card'
                        : 'cast_card_container',
                createRectTween:
                    (begin, end) => SmoothRectTween(begin: begin, end: end),
                child: _buildCard(
                  title: "Cast",
                  subtitle:
                      _isAnywhereMode ? "Cloud Cast" : "Media/Audio/Mirror",
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
        );
      },
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
    final isSmallScreen = MediaQuery.of(context).size.height < 780;
    final isCompact = isLandscape || isTV || isSmallScreen;
    final scale = _uiScale(context);

    return Container(
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(32 * scale),
        gradient:
            isMainFeature
                ? const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xFFFFD84D), Color(0xFFF5C400)],
                )
                : backgroundColor == Colors.white ||
                    backgroundColor == const Color(0xFFF5F5F7) ||
                    backgroundColor == const Color(0xFFEDEDED)
                ? const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xFFF0F0F0), Color(0xFFE5E5E5)],
                )
                : const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xFF2C2C2E), Color(0xFF1C1C1E)],
                ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(32 * scale),
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
                        size: 120 * scale,
                        color:
                            isMainFeature
                                ? Colors.black.withOpacity(0.05)
                                : backgroundColor == Colors.white ||
                                    backgroundColor ==
                                        const Color(0xFFF5F5F7) ||
                                    backgroundColor == const Color(0xFFEDEDED)
                                ? Colors.black.withOpacity(0.04)
                                : Colors.white.withOpacity(0.02),
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
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final isTight = constraints.maxHeight < 150;
                    final isUltraTight = constraints.maxHeight < 130;
                    final isTiny = constraints.maxHeight < 110;
                    final sizeFactor =
                        isTiny
                            ? 0.7
                            : (isUltraTight ? 0.78 : (isTight ? 0.85 : 1.0));
                    final showSubtitle = !isUltraTight;
                    final showTitle = !isTiny;
                    final padding =
                        (isCompact ? 12.0 : 16.0) * scale * sizeFactor;
                    final iconPadding =
                        (isCompact ? 8.0 : 10.0) * scale * sizeFactor;
                    final iconSize =
                        (isCompact ? 22.0 : 26.0) * scale * sizeFactor;
                    final titleSize =
                        (isCompact ? 18.0 : 20.0) * scale * sizeFactor;
                    final subtitleSize =
                        (isCompact ? 13.0 : 15.0) * scale * sizeFactor;
                    final gap = (isCompact ? 3.0 : 4.0) * scale * sizeFactor;
                    final textTopGap = isUltraTight ? gap * 0.5 : gap;

                    return Padding(
                      padding: EdgeInsets.all(padding),
                      child:
                          isTiny
                              ? Center(
                                child: Container(
                                  padding: EdgeInsets.all(iconPadding),
                                  decoration: BoxDecoration(
                                    color: iconBgColor,
                                    shape: BoxShape.circle,
                                  ),
                                  child: Icon(
                                    icon,
                                    color: iconColor,
                                    size: iconSize,
                                  ),
                                ),
                              )
                              : Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Align(
                                    alignment: Alignment.topLeft,
                                    child: Container(
                                      padding: EdgeInsets.all(iconPadding),
                                      decoration: BoxDecoration(
                                        color: iconBgColor,
                                        shape: BoxShape.circle,
                                      ),
                                      child: Icon(
                                        icon,
                                        color: iconColor,
                                        size: iconSize,
                                      ),
                                    ),
                                  ),
                                  const Spacer(),
                                  if (showTitle)
                                    Text(
                                      title,
                                      style: GoogleFonts.outfit(
                                        color: textColor,
                                        fontSize: titleSize,
                                        fontWeight: FontWeight.w800,
                                        letterSpacing: -0.5,
                                        height: 1.1,
                                      ),
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  if (showSubtitle) ...[
                                    SizedBox(height: textTopGap),
                                    Text(
                                      subtitle,
                                      style: GoogleFonts.outfit(
                                        color: textColor.withOpacity(0.7),
                                        fontSize: subtitleSize,
                                        fontWeight: FontWeight.w500,
                                        height: 1.2,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ],
                                ],
                              ),
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildClipboardSection({bool enableScroll = false}) {
    final user = FirebaseService().currentUser;

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
                      child: CircularProgressIndicator(
                        color: Color(0xFFFFD600),
                        strokeWidth: 2,
                      ),
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
                                      await FirebaseService()
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
                        child: PageView.builder(
                          controller: _clipboardPageController,
                          scrollDirection: Axis.vertical,
                          physics: const PageScrollPhysics(
                            parent: BouncingScrollPhysics(),
                          ),
                          itemCount: items.length,
                          onPageChanged: (index) {
                            setState(() {
                              _currentClipboardPage = index;
                            });
                            HapticFeedback.lightImpact();
                          },
                          itemBuilder: (context, index) {
                            final item = items[index];
                            final content = item['content'] as String;
                            var timeStr = item['created_at'].toString();
                            if (!timeStr.endsWith('Z') &&
                                !timeStr.contains('+')) {
                              timeStr += 'Z';
                            }
                            final time = DateTime.tryParse(timeStr)?.toLocal();

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
                                timeLabel =
                                    "${time.day}/${time.month} $hourMin";
                              }
                            }

                            return Container(
                              margin: const EdgeInsets.symmetric(vertical: 4),
                              decoration: BoxDecoration(
                                color: const Color(0xFF0F0F0F),
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(
                                  color: Colors.white.withOpacity(0.08),
                                  width: 1,
                                ),
                              ),
                              child: Material(
                                color: Colors.transparent,
                                child: InkWell(
                                  onTap: () => _copyToClipboard(content),
                                  borderRadius: BorderRadius.circular(16),
                                  child: Padding(
                                    padding: const EdgeInsets.all(12.0),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.spaceBetween,
                                          children: [
                                            Row(
                                              children: [
                                                Container(
                                                  padding: const EdgeInsets.all(
                                                    6,
                                                  ),
                                                  decoration:
                                                      const BoxDecoration(
                                                        color: Color(
                                                          0xFF1C1C1E,
                                                        ),
                                                        shape: BoxShape.circle,
                                                      ),
                                                  child: const Icon(
                                                    Icons.copy_rounded,
                                                    color: Color(0xFFFFD600),
                                                    size: 12,
                                                  ),
                                                ),
                                                const SizedBox(width: 8),
                                                Text(
                                                  "Clip #${items.length - index}",
                                                  style: GoogleFonts.outfit(
                                                    color: Colors.white70,
                                                    fontSize: 12,
                                                    fontWeight: FontWeight.w600,
                                                  ),
                                                ),
                                              ],
                                            ),
                                            if (time != null)
                                              Text(
                                                timeLabel,
                                                style: GoogleFonts.robotoMono(
                                                  color: Colors.white38,
                                                  fontSize: 10,
                                                ),
                                              ),
                                          ],
                                        ),
                                        const SizedBox(height: 10),
                                        Expanded(
                                          child: SingleChildScrollView(
                                            physics:
                                                const BouncingScrollPhysics(),
                                            child: Text(
                                              content,
                                              style: GoogleFonts.outfit(
                                                color: Colors.white,
                                                fontSize: 14,
                                                fontWeight: FontWeight.w400,
                                                height: 1.4,
                                              ),
                                            ),
                                          ),
                                        ),
                                        const SizedBox(height: 6),
                                        Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.end,
                                          children: [
                                            Text(
                                              "Tap to copy",
                                              style: GoogleFonts.outfit(
                                                color: const Color(
                                                  0xFFFFD600,
                                                ).withOpacity(0.7),
                                                fontSize: 10,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                            const SizedBox(width: 4),
                                            Icon(
                                              Icons.content_copy_rounded,
                                              color: const Color(
                                                0xFFFFD600,
                                              ).withOpacity(0.7),
                                              size: 10,
                                            ),
                                          ],
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
    HapticFeedback.lightImpact();

    Widget targetScreen;

    if (_isAnywhereMode) {
      if (index == 0) {
        targetScreen = const RemoteSendView();
      } else if (index == 1) {
        targetScreen = const RemoteReceiveView();
      } else if (index == 2) {
        targetScreen = const RemoteHistoryView();
      } else if (index == 3) {
        targetScreen = const RemoteCastView();
      } else if (index == 4) {
        targetScreen = const AudioShareScreen();
      } else {
        return;
      }
    } else {
      if (index == 0) {
        targetScreen = AndroidHttpFileShareScreen();
      } else if (index == 1) {
        targetScreen = AndroidReceiveOptionsScreen();
      } else if (index == 2) {
        targetScreen = TransferHistoryScreen();
      } else if (index == 3) {
        targetScreen = const AndroidCastSelectionScreen();
      } else if (index == 4) {
        targetScreen = const AudioShareScreen();
      } else {
        return;
      }
    }

    // Use SmoothPageRoute with a floaty fade for smooth Hero transitions
    Navigator.push(
      context,
      SmoothPageRoute.fade(
        page: targetScreen,
        duration: const Duration(milliseconds: 620),
        reverseDuration: const Duration(milliseconds: 560),
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
