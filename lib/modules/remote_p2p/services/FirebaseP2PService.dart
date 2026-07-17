import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import '../../../services/firebase_service.dart';

class FirebaseP2PService {
  static final FirebaseP2PService _instance = FirebaseP2PService._internal();
  factory FirebaseP2PService() => _instance;
  FirebaseP2PService._internal();

  FirebaseDatabase? _database;
  StreamSubscription<dynamic>? _signalingSub;
  StreamSubscription<dynamic>? _clipboardSub;
  final List<StreamSubscription<dynamic>> _signalingSubs = [];

  Future<void> initialize() async {
    try {
      if (Firebase.apps.isEmpty) {
        await Firebase.initializeApp(
          options: const FirebaseOptions(
            apiKey: 'AIzaSyAXM2QUxDZ9a0cSo-hyNu-yla5sDBJ3YoE',
            appId: '1:22061846776:android:f615a3240651251305eb0d',
            messagingSenderId: '22061846776',
            projectId: 'assistant-mark-2-bdd7e',
            storageBucket: 'assistant-mark-2-bdd7e.firebasestorage.app',
            databaseURL:
                'https://assistant-mark-2-bdd7e-default-rtdb.asia-southeast1.firebasedatabase.app',
          ),
        );
      }
      if (!kIsWeb && Platform.isWindows) {
        // Skip native initialization for database reference on Windows
      } else {
        _database = FirebaseDatabase.instance;
        // Enable offline persistence if supported
        _database!.setPersistenceEnabled(true);
      }
    } catch (e) {
      print("Error initializing Firebase: $e");
      rethrow;
    }
  }

  dynamic get database {
    if (!kIsWeb && Platform.isWindows) {
      return FallbackDatabase();
    }
    if (_database == null) {
      throw Exception(
        "FirebaseP2PService not initialized. Call initialize() first.",
      );
    }
    return _database!;
  }

  // Room / Signaling API

  Future<void> createRoom(
    String roomId,
    Map<String, dynamic> hostProfile,
  ) async {
    try {
      final roomRef = database.ref('rooms/$roomId');
      await roomRef.set({
        'host': hostProfile,
        'createdAt': ServerValue.timestamp,
      });
      // Do not delete the room on a Firebase transport blip.  The room is the
      // signaling rendezvous used to rebuild WebRTC, so removing it makes a
      // brief Firebase disconnect permanently unrecoverable mid-transfer.
      // leaveRoom() performs the explicit cleanup when the user ends a session.
    } catch (e) {
      print("Error creating room: $e");
      rethrow;
    }
  }

  Future<bool> joinRoom(String roomId, Map<String, dynamic> peerProfile) async {
    try {
      final roomRef = database.ref('rooms/$roomId');
      final snapshot = await roomRef.get();
      if (!snapshot.exists) {
        return false;
      }
      await roomRef.child('peer').set(peerProfile);
      return true;
    } catch (e) {
      print("Error joining room: $e");
      rethrow;
    }
  }

  Future<void> stopSignaling() async {
    for (var sub in _signalingSubs) {
      await sub.cancel();
    }
    _signalingSubs.clear();
    await _signalingSub?.cancel();
    _signalingSub = null;
  }

  void listenToSignaling(
    String roomId,
    bool isHost,
    Function(Map<String, dynamic> signal) onSignalReceived,
    Function(Map<String, dynamic> peerInfo) onPeerJoined,
  ) {
    try {
      // Synchronously copy and clear the list of subscriptions to avoid async race mutations
      final oldSubs = List<StreamSubscription<dynamic>>.from(_signalingSubs);
      _signalingSubs.clear();
      for (var sub in oldSubs) {
        unawaited(sub.cancel());
      }
      if (_signalingSub != null) {
        unawaited(_signalingSub!.cancel());
        _signalingSub = null;
      }

      final roomRef = database.ref('rooms/$roomId');

      // Listen for peer join info
      final peerPath = isHost ? 'peer' : 'host';
      final peerSub = roomRef.child(peerPath).onValue.listen((event) {
        if (event.snapshot.exists && event.snapshot.value != null) {
          final data = Map<String, dynamic>.from(event.snapshot.value as Map);
          onPeerJoined(data);
        }
      });
      _signalingSubs.add(peerSub);

      // Listen for SDP/ICE signals
      final signalPath =
          isHost ? 'signaling/peer_signals' : 'signaling/host_signals';
      final signalSub = roomRef.child(signalPath).onChildAdded.listen((event) {
        if (event.snapshot.exists && event.snapshot.value != null) {
          final data = Map<String, dynamic>.from(event.snapshot.value as Map);
          onSignalReceived(data);
        }
      });
      _signalingSubs.add(signalSub);
    } catch (e) {
      print("Error listening to signaling: $e");
    }
  }

  Future<void> sendSignal(
    String roomId,
    bool isHost,
    Map<String, dynamic> signalPayload,
  ) async {
    try {
      final path = isHost ? 'signaling/host_signals' : 'signaling/peer_signals';
      final ref = database.ref('rooms/$roomId/$path').push();
      await ref.set(signalPayload);
    } catch (e) {
      print("Error sending signal: $e");
      rethrow;
    }
  }

  Future<void> leaveRoom(String roomId) async {
    try {
      await stopSignaling();
      await database.ref('rooms/$roomId').remove();
    } catch (e) {
      print("Error leaving room: $e");
    }
  }

  // Clipboard Sync API

  Future<void> _pruneClipboard(String userId) async {
    try {
      final ref = database.ref('clipboards/$userId');
      final snapshot = await ref.orderByChild('timestamp').get();
      if (snapshot.exists && snapshot.value != null) {
        final Map<dynamic, dynamic> items = snapshot.value as Map;
        if (items.length > 30) {
          final sortedKeys = items.keys.toList()
            ..sort((a, b) {
              final aTime = (items[a] as Map)['timestamp'] ?? 0;
              final bTime = (items[b] as Map)['timestamp'] ?? 0;
              return aTime.compareTo(bTime);
            });
          final keysToDelete = sortedKeys.sublist(0, sortedKeys.length - 30);
          final Map<String, dynamic> updates = {};
          for (final key in keysToDelete) {
            updates[key] = null;
          }
          await ref.update(updates);
        }
      }
    } catch (e) {
      print("Error pruning clipboard: $e");
    }
  }

  Future<void> syncClipboard(String userId, String encryptedContent) async {
    try {
      final ref = database.ref('clipboards/$userId').push();
      await ref.set({
        'content': encryptedContent,
        'timestamp': ServerValue.timestamp,
      });
      unawaited(_pruneClipboard(userId));
    } catch (e) {
      print("Error syncing clipboard: $e");
      rethrow;
    }
  }

  void subscribeToClipboard(
    String userId,
    Function(String encryptedText) onClipReceived,
  ) {
    try {
      _clipboardSub?.cancel();
      final ref = database.ref('clipboards/$userId');
      _clipboardSub = ref
          .orderByChild('timestamp')
          .limitToLast(1)
          .onChildAdded
          .listen((event) {
            if (event.snapshot.exists && event.snapshot.value != null) {
              final data = Map<String, dynamic>.from(
                event.snapshot.value as Map,
              );
              final content = data['content'] as String?;
              if (content != null) {
                onClipReceived(content);
              }
            }
          });
    } catch (e) {
      print("Error subscribing to clipboard: $e");
    }
  }

  Future<void> unsubscribeClipboard() async {
    try {
      await _clipboardSub?.cancel();
      _clipboardSub = null;
    } catch (e) {
      print("Error unsubscribing clipboard: $e");
    }
  }

  Future<void> clearSignaling(String roomId) async {
    try {
      final signalingRef = database.ref('rooms/$roomId/signaling');
      await signalingRef.remove();
      print("🗑️ [Firebase] Cleared signaling signals for room $roomId");
    } catch (e) {
      print("⚠️ [Firebase] Error clearing signaling node: $e");
    }
  }
}
