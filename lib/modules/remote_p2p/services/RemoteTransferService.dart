import 'dart:io';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Wraps [FlutterForegroundTask] to show a persistent notification during
/// a remote WebRTC P2P transfer. Used on both sender and receiver side.
///
/// Usage:
///   await RemoteTransferService.start(peerName: 'Alice', isSender: true);
///   RemoteTransferService.updateProgress(0.45, fileName: 'photo.jpg');
///   await RemoteTransferService.stop();
class RemoteTransferService {
  RemoteTransferService._();

  static bool _running = false;
  static const int _progressNotificationId = 9101;
  static final FlutterLocalNotificationsPlugin _progressNotifications =
      FlutterLocalNotificationsPlugin();
  static Future<void>? _notificationInitialization;
  static DateTime _lastProgressUpdate = DateTime.fromMillisecondsSinceEpoch(0);
  static double _lastProgress = 0;

  /// Configure the foreground task once at app startup (called from main.dart).
  static void configure() {
    if (!Platform.isAndroid) return;
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'zapshare_transfer_channel_v2',
        channelName: 'ZapShare Transfer',
        channelDescription: 'File transfer is running in the background',
        channelImportance: NotificationChannelImportance.HIGH,
        priority: NotificationPriority.HIGH,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        autoRunOnBoot: false,
        allowWakeLock: true,
        allowWifiLock: true,
        eventAction: ForegroundTaskEventAction.once(),
      ),
    );
  }

  /// Start the foreground service notification.
  static Future<void> start({
    required String peerName,
    required bool isSender,
  }) async {
    if (!Platform.isAndroid) return;
    if (_running) return;
    _running = true;
    _lastProgress = 0;
    _lastProgressUpdate = DateTime.fromMillisecondsSinceEpoch(0);
    final verb = isSender ? 'Sending to' : 'Receiving from';
    await FlutterForegroundTask.startService(
      notificationTitle: 'ZapShare Transfer',
      notificationText: '$verb $peerName…',
      notificationIcon: const NotificationIcon(
        metaDataName: 'com.pravera.flutter_foreground_task.notification_icon',
      ),
    );
    await _ensureProgressNotificationsInitialized();
  }

  /// Update the notification text with current progress (0.0–1.0).
  static Future<void> updateProgress(
    double progress, {
    String? fileName,
    required bool isSender,
  }) async {
    if (!Platform.isAndroid || !_running) return;
    final now = DateTime.now();
    if (progress < 1.0 &&
        now.difference(_lastProgressUpdate) <
            const Duration(milliseconds: 500)) {
      return;
    }
    _lastProgressUpdate = now;
    final normalizedProgress = progress.clamp(0.0, 1.0).toDouble();
    if (normalizedProgress < _lastProgress) return;
    _lastProgress = normalizedProgress;
    final percent = (normalizedProgress * 100).toStringAsFixed(0);
    final verb = isSender ? 'Sending' : 'Receiving';
    final label = fileName != null ? '$verb "$fileName"' : '$verb file';
    await _showProgressNotification(
      title: label,
      progress: normalizedProgress,
      text: '$percent% complete',
    );
    await FlutterForegroundTask.updateService(
      notificationTitle: 'ZapShare Transfer',
      notificationText: '$label — $percent%',
    );
  }

  /// Shows recovery status without releasing the foreground service locks.
  static Future<void> updateStatus(String text) async {
    if (!Platform.isAndroid || !_running) return;
    await FlutterForegroundTask.updateService(
      notificationTitle: 'ZapShare Transfer',
      notificationText: text,
    );
  }

  static Future<void> _ensureProgressNotificationsInitialized() {
    return _notificationInitialization ??= () async {
      await _progressNotifications.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('ic_stat_notify'),
        ),
      );
    }();
  }

  static Future<void> _showProgressNotification({
    required String title,
    required double progress,
    required String text,
  }) async {
    await _ensureProgressNotificationsInitialized();
    final percent = (progress.clamp(0.0, 1.0) * 100).round();
    final details = AndroidNotificationDetails(
      'zapshare_remote_transfer_progress',
      'Remote Transfer Progress',
      channelDescription: 'Progress for remote ZapShare file transfers',
      importance: Importance.max,
      priority: Priority.high,
      showProgress: true,
      maxProgress: 100,
      progress: percent,
      onlyAlertOnce: true,
      ongoing: true,
      autoCancel: false,
      icon: 'ic_stat_notify',
    );
    await _progressNotifications.show(
      id: _progressNotificationId,
      title: title,
      body: text,
      notificationDetails: NotificationDetails(android: details),
    );
  }

  /// Stop the foreground service and dismiss the notification.
  static Future<void> stop() async {
    if (!Platform.isAndroid || !_running) return;
    try {
      await _progressNotifications.cancel(id: _progressNotificationId);
      await FlutterForegroundTask.stopService();
    } finally {
      _running = false;
    }
  }

  /// Whether the service is currently active.
  static bool get isRunning => _running;
}
