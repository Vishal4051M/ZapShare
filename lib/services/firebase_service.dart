import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'encryption_service.dart';
import 'EnvService.dart';

class User {
  final String id;
  final String? email;
  final Map<String, dynamic>? userMetadata;
  User({required this.id, this.email, this.userMetadata});
}

class Session {
  final User user;
  Session(this.user);
}

class AuthState {
  final Session? session;
  AuthState(User? user) : session = user != null ? Session(user) : null;
}

class FirebaseService {
  static String get _transferNotificationEndpoint {
    const envValue = String.fromEnvironment('ZAPSHARE_NOTIFICATION_ENDPOINT');
    if (envValue.isNotEmpty) return envValue;
    return 'https://zapshare-notifications.vercel.app/api/notify-transfer';
  }

  static String get _friendNotificationEndpoint {
    const envValue = String.fromEnvironment(
      'ZAPSHARE_FRIEND_NOTIFICATION_ENDPOINT',
    );
    if (envValue.isNotEmpty) return envValue;
    return 'https://zapshare-notifications.vercel.app/api/notify-friend';
  }

  static final FirebaseService _instance = FirebaseService._internal();
  factory FirebaseService() => _instance;
  FirebaseService._internal();

  final GoogleSignIn _googleSignIn = GoogleSignIn(scopes: ['email']);
  GoogleSignInAccount? _currentUser;
  User? _fallbackUser;
  final StreamController<AuthState> _authController =
      StreamController<AuthState>.broadcast();

  // Singleton friends stream — shared across all views to avoid duplicate listeners
  Stream<List<Map<String, dynamic>>>? _cachedFriendsStream;
  // Profile cache — avoids re-fetching the same user profile on every friends-list change
  final Map<String, Map<String, dynamic>> _friendProfileCache = {};

  // Cache of last known friends list to prevent empty states on stream resubscription
  List<Map<String, dynamic>>? _lastFriendsList;
  List<Map<String, dynamic>> get lastFriendsList => _lastFriendsList ?? [];

  Future<void> initialize() async {
    try {
      if (Firebase.apps.isEmpty) {
        await Firebase.initializeApp(
          options: FirebaseOptions(
            apiKey: EnvService.get('FIREBASE_API_KEY'),
            appId: EnvService.get('FIREBASE_APP_ID'),
            messagingSenderId: EnvService.get('FIREBASE_MESSAGING_SENDER_ID'),
            projectId: EnvService.get('FIREBASE_PROJECT_ID'),
            storageBucket: EnvService.get('FIREBASE_STORAGE_BUCKET'),
            databaseURL: EnvService.get('FIREBASE_DATABASE_URL'),
          ),
        );
      }

      // Wait for FirebaseAuth to restore the user session from local cache
      int authWaitAttempts = 0;
      while (FirebaseAuth.instance.currentUser == null &&
          authWaitAttempts < 15) {
        await Future.delayed(const Duration(milliseconds: 100));
        authWaitAttempts++;
      }
      if (FirebaseAuth.instance.currentUser != null) {
        print(
          "⚡ [Auth] Restored persisted user session: ${FirebaseAuth.instance.currentUser!.email}",
        );
      }

      // Load fallback user if stored (e.g., for Windows or fallback log-ins)
      final prefs = await SharedPreferences.getInstance();
      final savedId = prefs.getString('fallback_user_id');
      final savedEmail = prefs.getString('fallback_user_email');
      final savedName = prefs.getString('fallback_user_name');
      final savedAvatar = prefs.getString('fallback_user_avatar');

      if (savedId != null && savedEmail != null) {
        _fallbackUser = User(
          id: savedId,
          email: savedEmail,
          userMetadata: {
            'full_name': savedName ?? '',
            'picture': savedAvatar ?? '',
          },
        );
      }

      _googleSignIn.onCurrentUserChanged.listen((account) async {
        _currentUser = account;
        if (account != null) {
          _fallbackUser = null; // Google account takes precedence
          try {
            final googleAuth = await account.authentication;
            final credential = GoogleAuthProvider.credential(
              accessToken: googleAuth.accessToken,
              idToken: googleAuth.idToken,
            );
            await FirebaseAuth.instance.signInWithCredential(credential);
          } catch (e) {
            print("Error signing in to Firebase Auth silently: $e");
          }
        }
        _authController.add(AuthState(currentUser));
      });

      if (_fallbackUser == null) {
        await _googleSignIn.signInSilently();
      } else {
        // Ensure they are authenticated on Firebase so REST API calls work
        try {
          if (FirebaseAuth.instance.currentUser == null) {
            await FirebaseAuth.instance.signInAnonymously();
          }
        } catch (e) {
          print("Desktop anonymous sign-in on initialize failed: $e");
        }
        _authController.add(AuthState(currentUser));
      }
    } catch (e) {
      print("Firebase initialization error in compatibility layer: $e");
    }
  }

  User? get currentUser {
    if (_fallbackUser != null) return _fallbackUser;
    if (_currentUser == null) return null;
    return User(
      id: _currentUser!.id,
      email: _currentUser!.email,
      userMetadata: {
        'full_name': _currentUser!.displayName ?? '',
        'picture': _currentUser!.photoUrl ?? '',
      },
    );
  }

  /// Returns the Firebase Auth UID which must be used for all database paths.
  /// This differs from currentUser.id (Google Account ID) and matches auth.uid
  /// in Firebase security rules.
  String? get _firebaseUid =>
      FirebaseAuth.instance.currentUser?.uid ?? currentUser?.id;

  String? get firebaseUid =>
      FirebaseAuth.instance.currentUser?.uid ?? currentUser?.id;

  Stream<AuthState> get authStateChanges async* {
    yield AuthState(currentUser);
    yield* _authController.stream;
  }

  Future<void> signOut() async {
    try {
      try {
        await _googleSignIn.signOut();
      } catch (e) {
        print("Google sign out skipped or failed: $e");
      }
      await FirebaseAuth.instance.signOut();
      _currentUser = null;
      _fallbackUser = null;
      // Clear singleton stream + profile cache so a new session gets fresh data
      _cachedFriendsStream = null;
      _friendProfileCache.clear();
      _lastFriendsList = null;
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('fallback_user_id');
      await prefs.remove('fallback_user_email');
      await prefs.remove('fallback_user_name');
      await prefs.remove('fallback_user_avatar');

      // Clear profile settings on signout
      await prefs.remove('device_name');
      await prefs.remove('custom_avatar');
      await prefs.remove('username');
      await prefs.remove('first_run_complete');
      await prefs.remove('anywhere_mode_enabled');

      _authController.add(AuthState(null));
    } catch (e) {
      print("Error signing out: $e");
    }
  }

  Future<bool> signInWithGoogle() async {
    try {
      final account = await _googleSignIn.signIn();
      _currentUser = account;
      _authController.add(AuthState(currentUser));
      return account != null;
    } catch (e) {
      print("Google Sign-In failed: $e");
      return false;
    }
  }

  Future<bool> signInWithGoogleDesktop() async {
    final String desktopClientId = EnvService.get('GOOGLE_DESKTOP_CLIENT_ID');
    final String desktopClientSecret = EnvService.get('GOOGLE_DESKTOP_CLIENT_SECRET');

    if (desktopClientId.startsWith('YOUR_')) {
      if (kDebugMode) {
        print(
          '[ZapShare] Desktop OAuth Client ID not configured. '
          'See firebase_service.dart signInWithGoogleDesktop() for setup instructions.',
        );
      }
      return false;
    }

    try {
      // 1. Find a free local port for the loopback redirect.
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final port = server.port;
      final redirectUri = 'http://127.0.0.1:$port';

      // 2. Build the Google OAuth authorization URL.
      final authUrl = Uri.https('accounts.google.com', '/o/oauth2/v2/auth', {
        'client_id': desktopClientId,
        'redirect_uri': redirectUri,
        'response_type': 'code',
        'scope': 'openid email profile',
        'access_type': 'offline',
        'prompt': 'select_account',
      });

      // 3. Open the system browser.
      await launchUrl(authUrl, mode: LaunchMode.externalApplication);

      // 4. Wait for the redirect to our local server.
      String? authCode;
      await for (final request in server) {
        final code = request.uri.queryParameters['code'];
        final error = request.uri.queryParameters['error'];

        // Respond with a styled success/error page.
        final html =
            code != null
                ? '''<!DOCTYPE html><html><body style="font-family:sans-serif;background:#111;color:#FFD600;text-align:center;padding:80px">
                <h1>✅ Signed in to ZapShare!</h1>
                <p style="color:#ccc">You can close this tab and return to the app.</p>
               </body></html>'''
                : '''<!DOCTYPE html><html><body style="font-family:sans-serif;background:#111;color:#f44;text-align:center;padding:80px">
                <h1>❌ Sign-in cancelled</h1>
                <p style="color:#ccc">You can close this tab.</p>
               </body></html>''';

        request.response
          ..statusCode = 200
          ..headers.contentType = ContentType.html
          ..write(html);
        await request.response.close();

        authCode = code;
        if (error != null || code != null) break;
      }
      await server.close();

      if (authCode == null) return false;

      // 5. Exchange the auth code for tokens.
      final tokenResponse = await http.post(
        Uri.https('oauth2.googleapis.com', '/token'),
        body: {
          'code': authCode,
          'client_id': desktopClientId,
          'client_secret': desktopClientSecret,
          'redirect_uri': redirectUri,
          'grant_type': 'authorization_code',
        },
      );

      if (tokenResponse.statusCode != 200) return false;

      final tokenData = jsonDecode(tokenResponse.body) as Map<String, dynamic>;
      final accessToken = tokenData['access_token'] as String?;
      final idToken = tokenData['id_token'] as String?;
      if (accessToken == null) return false;

      if (idToken != null) {
        try {
          final credential = GoogleAuthProvider.credential(
            accessToken: accessToken,
            idToken: idToken,
          );
          await FirebaseAuth.instance.signInWithCredential(credential);
        } catch (e) {
          print("Desktop Firebase Auth sign-in failed: $e");
        }
      }

      // 6. Use the access token to fetch the user profile.
      final profileResponse = await http.get(
        Uri.https('www.googleapis.com', '/oauth2/v2/userinfo'),
        headers: {'Authorization': 'Bearer $accessToken'},
      );

      if (profileResponse.statusCode != 200) return false;

      final profile = jsonDecode(profileResponse.body) as Map<String, dynamic>;
      final email = profile['email'] as String? ?? '';
      final name = profile['name'] as String? ?? email.split('@').first;
      final picture = profile['picture'] as String? ?? '';

      // 7. Sign in using the email-based fallback with real Google profile data.
      return await signInWithEmail(email, name, avatarUrl: picture);
    } catch (e) {
      if (kDebugMode) print('[ZapShare] Desktop Google Sign-In error: $e');
      return false;
    }
  }

  Future<bool> signInWithEmail(
    String email,
    String displayName, {
    String avatarUrl = '',
  }) async {
    try {
      final sanitized = email.trim().toLowerCase();
      final id = 'email_${sanitized.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_')}';

      _fallbackUser = User(
        id: id,
        email: sanitized,
        userMetadata: {'full_name': displayName, 'picture': avatarUrl},
      );

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('fallback_user_id', id);
      await prefs.setString('fallback_user_email', sanitized);
      await prefs.setString('fallback_user_name', displayName);
      await prefs.setString('fallback_user_avatar', avatarUrl);

      // Support fallback / anonymous login for unauthenticated desktop or custom emails
      try {
        if (FirebaseAuth.instance.currentUser == null) {
          await FirebaseAuth.instance.signInAnonymously();
        }
      } catch (e) {
        print("Desktop anonymous sign-in failed: $e");
      }

      // Automatically sync profile to the database under their Firebase UID
      final uid = _firebaseUid;
      print("🔐 DB SYNC: Attempting database write for UID: $uid");
      if (uid != null) {
        final defaultUsername = sanitized.split('@').first.replaceAll('.', '_');
        final sanitizedEmail = sanitizeEmail(sanitized);
        try {
          print("🔐 DB SYNC: Writing to users/$uid");
          await _db.ref('users/$uid').set({
            'email': sanitized,
            'username': defaultUsername,
            'fullName': displayName,
            'avatarUrl': avatarUrl.isNotEmpty ? avatarUrl : 'face_1',
          });
          print("🔐 DB SYNC: Writing to usernames/$defaultUsername");
          await _db.ref('usernames/$defaultUsername').set(uid);
          if (sanitizedEmail.isNotEmpty) {
            print("🔐 DB SYNC: Writing to emails/$sanitizedEmail");
            await _db.ref('emails/$sanitizedEmail').set(uid);
          }
          print("🔐 DB SYNC: All writes completed successfully!");
        } catch (e) {
          print("Error auto-creating user profile in DB: $e");
        }
      } else {
        print("🔐 DB SYNC: Skipped write because uid is null");
      }

      _authController.add(AuthState(currentUser));
      return true;
    } catch (e) {
      print("Email Sign-In failed: $e");
      return false;
    }
  }

  Future<Map<String, dynamic>?> getUserProfile() async {
    if (currentUser == null) return null;
    return {
      'id': currentUser!.id,
      'full_name': _currentUser?.displayName ?? 'Guest User',
      'avatar_url': _currentUser?.photoUrl ?? '',
    };
  }

  Future<void> updateUserProfile({String? fullName, String? avatarUrl}) async {
    // Local configuration only (handled on Firebase presence profiles if needed)
  }

  dynamic get _db {
    if (!kIsWeb && Platform.isWindows) {
      return FallbackDatabase();
    }
    return FirebaseDatabase.instance;
  }

  Future<void> addClipboardItem(String content) async {
    final user = currentUser;
    final uid = _firebaseUid;
    if (user == null || uid == null) return;
    try {
      final encryptedContent = EncryptionService.encrypt(content, user.id);
      final ref = _db.ref('clipboards/$uid').push();
      await ref.set({
        'content': encryptedContent,
        'timestamp': ServerValue.timestamp,
      });
    } catch (e) {
      print("Error adding clipboard item: $e");
      rethrow;
    }
  }

  Future<void> _sendTransferNotification({
    required String targetUid,
    required String transferId,
    required String senderName,
    required List<String> fileNames,
  }) async {
    if (_transferNotificationEndpoint.isEmpty) return;

    try {
      final idToken = await FirebaseAuth.instance.currentUser?.getIdToken();
      if (idToken == null) return;

      await http
          .post(
            Uri.parse(_transferNotificationEndpoint),
            headers: {
              'Authorization': 'Bearer $idToken',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({
              'targetUid': targetUid,
              'transferId': transferId,
              'senderName': senderName,
              'fileNames': fileNames,
            }),
          )
          .timeout(const Duration(seconds: 10));
    } catch (e) {
      // A notification failure must never block the direct P2P transfer.
      print('Transfer push notification failed: $e');
    }
  }

  Future<void> _sendFriendNotification({
    required String targetUid,
    required String senderName,
  }) async {
    if (_friendNotificationEndpoint.isEmpty) return;

    try {
      final idToken = await FirebaseAuth.instance.currentUser?.getIdToken();
      if (idToken == null) return;

      await http
          .post(
            Uri.parse(_friendNotificationEndpoint),
            headers: {
              'Authorization': 'Bearer $idToken',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({
              'targetUid': targetUid,
              'senderName': senderName,
            }),
          )
          .timeout(const Duration(seconds: 10));
    } catch (e) {
      // A notification failure must never block the client-side operation.
      print('Friend request push notification failed: $e');
    }
  }

  Future<List<Map<String, dynamic>>> fetchClipboardHistory() async {
    final user = currentUser;
    final uid = _firebaseUid;
    if (user == null || uid == null) return [];
    try {
      final ref = _db.ref('clipboards/$uid');
      final snapshot =
          await ref.orderByChild('timestamp').limitToLast(20).get();
      if (!snapshot.exists || snapshot.value == null) return [];

      final List<Map<String, dynamic>> list = [];
      final Map<dynamic, dynamic> items = snapshot.value as Map;
      items.forEach((key, val) {
        final data = Map<String, dynamic>.from(val as Map);
        final encrypted = data['content'] as String?;
        if (encrypted != null) {
          list.add({
            'content': EncryptionService.decrypt(encrypted, user.id),
            'created_at':
                DateTime.fromMillisecondsSinceEpoch(
                  data['timestamp'] ?? 0,
                ).toIso8601String(),
          });
        }
      });
      list.sort((a, b) => b['created_at'].compareTo(a['created_at']));
      return list;
    } catch (e) {
      print("Error fetching clipboard history: $e");
      return [];
    }
  }

  Stream<List<Map<String, dynamic>>> getClipboardStream() {
    final user = currentUser;
    final uid = _firebaseUid;
    if (user == null || uid == null) return const Stream.empty();

    final controller = StreamController<List<Map<String, dynamic>>>.broadcast();
    final ref = _db.ref('clipboards/$uid');
    final subscription = ref.onValue.listen((event) {
      if (event.snapshot.exists && event.snapshot.value != null) {
        final List<Map<String, dynamic>> list = [];
        final Map<dynamic, dynamic> items = event.snapshot.value as Map;
        items.forEach((key, val) {
          final data = Map<String, dynamic>.from(val as Map);
          final encrypted = data['content'] as String?;
          if (encrypted != null) {
            list.add({
              'content': EncryptionService.decrypt(encrypted, user.id),
              'created_at':
                  DateTime.fromMillisecondsSinceEpoch(
                    data['timestamp'] ?? 0,
                  ).toIso8601String(),
            });
          }
        });
        list.sort((a, b) => b['created_at'].compareTo(a['created_at']));
        controller.add(list);
      } else {
        controller.add([]);
      }
    });

    controller.onCancel = () {
      subscription.cancel();
    };

    return controller.stream;
  }

  Stream<Map<String, dynamic>> subscribeToClipboardUpdates() {
    final user = currentUser;
    final uid = _firebaseUid;
    if (user == null || uid == null) return const Stream.empty();

    final controller = StreamController<Map<String, dynamic>>.broadcast();
    final ref = _db.ref('clipboards/$uid');
    final subscription = ref
        .orderByChild('timestamp')
        .limitToLast(1)
        .onChildAdded
        .listen((event) {
          if (event.snapshot.exists && event.snapshot.value != null) {
            final data = Map<String, dynamic>.from(event.snapshot.value as Map);
            final encrypted = data['content'] as String?;
            if (encrypted != null) {
              controller.add({
                'content': EncryptionService.decrypt(encrypted, user.id),
                'created_at':
                    DateTime.fromMillisecondsSinceEpoch(
                      data['timestamp'] ?? 0,
                    ).toIso8601String(),
              });
            }
          }
        });

    controller.onCancel = () {
      subscription.cancel();
    };

    return controller.stream;
  }

  String sanitizeEmail(String email) {
    return email.replaceAll('.', '_').replaceAll('@', '_');
  }

  Future<void> saveUserProfile({
    required String username,
    required String fullName,
    required String avatarUrl,
  }) async {
    final user = currentUser;
    final uid = _firebaseUid;
    if (user == null || uid == null) return;

    try {
      final sanitizedEmail = sanitizeEmail(user.email ?? '');

      // 1. Update users/$uid (using Firebase Auth UID to match rules)
      await _db.ref('users/$uid').set({
        'email': user.email,
        'username': username,
        'fullName': fullName,
        'avatarUrl': avatarUrl,
      });

      // 2. Update usernames/$username -> uid
      await _db.ref('usernames/$username').set(uid);

      // 3. Update emails/$sanitizedEmail -> uid
      if (sanitizedEmail.isNotEmpty) {
        await _db.ref('emails/$sanitizedEmail').set(uid);
      }
    } catch (e) {
      print("Error saving user profile: $e");
      rethrow;
    }
  }

  Future<String?> uploadCustomAvatar(File imageFile) async {
    final uid = _firebaseUid;
    if (uid == null) return null;
    try {
      final storageRef = FirebaseStorage.instance
          .ref()
          .child('avatars')
          .child('$uid.png');
      print(
        "🚀 Starting upload for avatars/$uid.png, file size: ${await imageFile.length()} bytes",
      );

      final uploadTask = storageRef.putFile(imageFile);

      uploadTask.snapshotEvents.listen(
        (TaskSnapshot snapshot) {
          final double progress =
              snapshot.totalBytes > 0
                  ? 100 * (snapshot.bytesTransferred / snapshot.totalBytes)
                  : 0;
          print(
            "⚡ Upload progress: ${progress.toStringAsFixed(2)}% (${snapshot.bytesTransferred}/${snapshot.totalBytes} bytes) [State: ${snapshot.state}]",
          );
        },
        onError: (e) {
          print("❌ Error during upload progress: $e");
        },
      );

      final snapshot = await uploadTask;
      final downloadUrl = await snapshot.ref.getDownloadURL();
      print("✅ Upload finished successfully! Download URL: $downloadUrl");
      return downloadUrl;
    } catch (e) {
      print("❌ Error uploading avatar to Firebase Storage: $e");
      return null;
    }
  }

  Future<String?> uploadCustomAvatarBase64(File imageFile) async {
    try {
      final bytes = await imageFile.readAsBytes();

      // Resize image to 120x120 pixels using Flutter's built-in engine
      final ui.Codec codec = await ui.instantiateImageCodec(
        bytes,
        targetWidth: 120,
        targetHeight: 120,
      );
      final ui.FrameInfo fi = await codec.getNextFrame();
      final ui.Image image = fi.image;
      final ByteData? byteData = await image.toByteData(
        format: ui.ImageByteFormat.png,
      );
      if (byteData == null) return null;

      final Uint8List pngBytes = byteData.buffer.asUint8List();
      final base64String = base64Encode(pngBytes);
      return 'data:image/png;base64,$base64String';
    } catch (e) {
      print("❌ Error encoding and resizing avatar: $e");
      return null;
    }
  }

  Future<bool> isUsernameAvailable(String username) async {
    try {
      final snapshot = await _db.ref('usernames/$username').get();
      return !snapshot.exists;
    } catch (e) {
      print("Error checking username: $e");
      return false;
    }
  }

  Future<String?> getUidFromUsernameOrEmail(String identifier) async {
    try {
      final trimmed = identifier.trim().toLowerCase();
      if (trimmed.contains('@')) {
        final sanitized = sanitizeEmail(trimmed);
        final snapshot = await _db.ref('emails/$sanitized').get();
        return snapshot.value as String?;
      } else {
        final snapshot = await _db.ref('usernames/$trimmed').get();
        return snapshot.value as String?;
      }
    } catch (e) {
      print("Error looking up identifier: $e");
      return null;
    }
  }

  Future<void> sendTransferRequest({
    required String targetUid,
    required String senderName,
    required String senderEmail,
    required String senderAvatar,
    required String roomId,
    required List<String> fileNames,
    required int fileSize,
  }) async {
    final user = currentUser;
    final uid = _firebaseUid;
    if (user == null || uid == null) return;
    try {
      final ref = _db.ref('transfers/$targetUid').push();
      await ref.set({
        'id': ref.key,
        'senderId': uid,
        'senderName': senderName,
        'senderEmail': senderEmail,
        'senderAvatar': senderAvatar,
        'roomId': roomId,
        'status': 'pending',
        'fileNames': fileNames,
        'fileSize': fileSize,
        'timestamp': ServerValue.timestamp,
      });
      await _sendTransferNotification(
        targetUid: targetUid,
        transferId: ref.key,
        senderName: senderName,
        fileNames: fileNames,
      );
    } catch (e) {
      print("Error sending transfer request: $e");
      rethrow;
    }
  }

  Future<void> sendCastRequest({
    required String targetUid,
    required String senderName,
    required String senderEmail,
    required String senderAvatar,
    required String roomId,
    required String castMode,
  }) async {
    final user = currentUser;
    final uid = _firebaseUid;
    if (user == null || uid == null) return;
    try {
      final ref = _db.ref('cast_requests/$targetUid').push();
      await ref.set({
        'id': ref.key,
        'senderId': uid,
        'senderName': senderName,
        'senderEmail': senderEmail,
        'senderAvatar': senderAvatar,
        'roomId': roomId,
        'castMode': castMode,
        'status': 'pending',
        'timestamp': ServerValue.timestamp,
      });
    } catch (e) {
      print("Error sending cast request: $e");
      rethrow;
    }
  }

  Stream<List<Map<String, dynamic>>> getIncomingCastRequestsStream() {
    final uid = _firebaseUid;
    if (uid == null) return const Stream.empty();

    // onChildAdded — only delivers NEW records, not the full list on every change.
    // limitToLast(20) caps the initial backlog replay to the 20 most recent entries.
    final controller = StreamController<List<Map<String, dynamic>>>.broadcast();
    final ref = _db
        .ref('cast_requests/$uid')
        .orderByChild('timestamp')
        .limitToLast(20);

    final subscription = ref.onChildAdded.listen((event) {
      if (event.snapshot.exists && event.snapshot.value != null) {
        final data = Map<String, dynamic>.from(event.snapshot.value as Map);
        if (!controller.isClosed) controller.add([data]);
      }
    });

    controller.onCancel = () => subscription.cancel();
    return controller.stream;
  }

  /// Deletes a cast request record after it has been accepted or declined.
  Future<void> deleteCastRequest(String requestId) async {
    final uid = _firebaseUid;
    if (uid == null) return;
    try {
      await _db.ref('cast_requests/$uid/$requestId').remove();
    } catch (e) {
      print('Error deleting cast request: $e');
    }
  }

  Future<void> updateCastRequestStatus(
    String castRequestId,
    String status,
  ) async {
    final uid = _firebaseUid;
    if (uid == null) return;
    try {
      await _db.ref('cast_requests/$uid/$castRequestId/status').set(status);
    } catch (e) {
      print("Error updating cast request status: $e");
    }
  }

  Stream<List<Map<String, dynamic>>> getIncomingTransfersStream() {
    final uid = _firebaseUid;
    if (uid == null) return const Stream.empty();

    // onChildAdded — only delivers NEW transfer notifications, not the full list.
    final controller = StreamController<List<Map<String, dynamic>>>.broadcast();
    final ref = _db
        .ref('transfers/$uid')
        .orderByChild('timestamp')
        .limitToLast(20);

    final subscription = ref.onChildAdded.listen((event) {
      if (event.snapshot.exists && event.snapshot.value != null) {
        final data = Map<String, dynamic>.from(event.snapshot.value as Map);
        if (!controller.isClosed) controller.add([data]);
      }
    });

    controller.onCancel = () => subscription.cancel();
    return controller.stream;
  }

  /// Deletes a transfer notification record after it has been accepted or declined.
  Future<void> deleteTransfer(String transferId) async {
    final uid = _firebaseUid;
    if (uid == null) return;
    try {
      await _db.ref('transfers/$uid/$transferId').remove();
    } catch (e) {
      print('Error deleting transfer record: $e');
    }
  }

  Future<void> updateTransferStatus(String transferId, String status) async {
    final uid = _firebaseUid;
    if (uid == null) return;
    try {
      await _db.ref('transfers/$uid/$transferId/status').set(status);
    } catch (e) {
      print("Error updating transfer status: $e");
    }
  }

  Future<Map<String, dynamic>?> getUserProfileByUid(String uid) async {
    try {
      final snapshot = await _db.ref('users/$uid').get();
      if (snapshot.exists && snapshot.value != null) {
        return Map<String, dynamic>.from(snapshot.value as Map);
      }
      return null;
    } catch (e) {
      print("Error getting profile for $uid: $e");
      rethrow;
    }
  }

  Future<void> saveFcmToken(String token) async {
    final uid = _firebaseUid;
    if (uid == null) return;
    try {
      await _db.ref('users/$uid/fcmToken').set(token);
    } catch (e) {
      print("Error saving FCM token: $e");
    }
  }

  Future<void> addFriend(String identifier) async {
    final uid = _firebaseUid;
    if (uid == null) throw Exception("Please login first");

    try {
      final friendUid = await getUidFromUsernameOrEmail(identifier);
      if (friendUid == null) {
        throw Exception("User not found!");
      }

      if (friendUid == uid) {
        throw Exception("You cannot add yourself as a friend.");
      }

      final alreadyFriends = await isFriend(friendUid);
      if (alreadyFriends) {
        throw Exception("You are already friends with this user.");
      }

      // Check if request is already sent
      final sentReqSnap =
          await _db.ref('friend_requests/$friendUid/$uid').get();
      if (sentReqSnap.exists) {
        throw Exception("Friend request already sent!");
      }

      final myProfileSnap = await _db.ref('users/$uid').get();
      Map<String, dynamic> myProfile = {};
      if (myProfileSnap.exists && myProfileSnap.value != null) {
        myProfile = Map<String, dynamic>.from(myProfileSnap.value as Map);
      }

      final prefs = await SharedPreferences.getInstance();
      final senderName =
          prefs.getString('device_name') ??
          myProfile['fullName'] ??
          'ZapShare User';
      final senderAvatar =
          prefs.getString('custom_avatar') ??
          myProfile['avatarUrl'] ??
          'face_1';
      final senderEmail = currentUser?.email ?? myProfile['email'] ?? 'Unknown';
      final senderUsername =
          prefs.getString('username') ??
          myProfile['username'] ??
          (senderEmail.split('@').first);

      // Write request to recipient's node
      await _db.ref('friend_requests/$friendUid/$uid').set({
        'senderId': uid,
        'senderUsername': senderUsername,
        'senderName': senderName,
        'senderEmail': senderEmail,
        'senderAvatar': senderAvatar,
        'status': 'pending',
        'timestamp': ServerValue.timestamp,
      });

      // Send offline push notification for friend request
      await _sendFriendNotification(
        targetUid: friendUid,
        senderName: senderName,
      );
    } catch (e) {
      print("Error sending friend request: $e");
      rethrow;
    }
  }

  Stream<List<Map<String, dynamic>>> getIncomingFriendRequestsStream() {
    final uid = _firebaseUid;
    if (uid == null) return const Stream.empty();

    final controller = StreamController<List<Map<String, dynamic>>>.broadcast();
    final ref = _db.ref('friend_requests/$uid');

    final subscription = ref.onValue.listen((event) {
      try {
        if (event.snapshot.exists && event.snapshot.value != null) {
          final Map<dynamic, dynamic> requestsMap = event.snapshot.value as Map;
          final List<Map<String, dynamic>> requestsList = [];
          for (final entry in requestsMap.entries) {
            final key = entry.key as String;
            final val = entry.value;
            if (val is Map) {
              final Map<String, dynamic> data = Map<String, dynamic>.from(val);
              data['senderId'] ??= key;
              requestsList.add(data);
            }
          }
          if (!controller.isClosed) controller.add(requestsList);
        } else {
          if (!controller.isClosed) controller.add([]);
        }
      } catch (e) {
        print("Error in incoming friend requests stream: $e");
        if (!controller.isClosed) controller.addError(e);
      }
    });

    controller.onCancel = () => subscription.cancel();
    return controller.stream;
  }

  Future<void> acceptFriendRequest(String senderUid) async {
    final uid = _firebaseUid;
    if (uid == null) throw Exception("Please login first");

    try {
      // 1. Add bidirectional friendship
      await _db.ref('friends/$uid/$senderUid').set(true);
      await _db.ref('friends/$senderUid/$uid').set(true);

      // 2. Remove the friend request
      await _db.ref('friend_requests/$uid/$senderUid').remove();
    } catch (e) {
      print("Error accepting friend request: $e");
      rethrow;
    }
  }

  Future<void> declineFriendRequest(String senderUid) async {
    final uid = _firebaseUid;
    if (uid == null) return;
    try {
      await _db.ref('friend_requests/$uid/$senderUid').remove();
    } catch (e) {
      print("Error declining friend request: $e");
      rethrow;
    }
  }

  Future<void> removeFriend(String friendUid) async {
    final uid = _firebaseUid;
    if (uid == null) throw Exception("Please login first");
    try {
      await _db.ref('friends/$uid/$friendUid').remove();
      await _db.ref('friends/$friendUid/$uid').remove();
    } catch (e) {
      print("Error removing friend: $e");
      rethrow;
    }
  }

  Future<bool> isFriend(String friendUid) async {
    final uid = _firebaseUid;
    if (uid == null) return false;
    if (friendUid == uid) return true; // Self is automatically a friend/allowed

    try {
      final snapshot = await _db.ref('friends/$uid/$friendUid').get();
      return snapshot.exists;
    } catch (e) {
      print("Error checking friendship: $e");
      return false;
    }
  }

  /// Returns a singleton broadcast stream of the current user's friends list.
  /// All views share the same underlying Firebase listener — no duplicate reads.
  Stream<List<Map<String, dynamic>>> getFriendsStream() {
    final uid = _firebaseUid;
    if (uid == null) return const Stream.empty();

    // Return cached stream if already active for this auth session.
    if (_cachedFriendsStream != null) return _cachedFriendsStream!;

    final controller = StreamController<List<Map<String, dynamic>>>.broadcast();
    final ref = _db.ref('friends/$uid');

    StreamSubscription? sub;
    sub = ref.onValue.listen((event) async {
      try {
        if (event.snapshot.exists && event.snapshot.value != null) {
          final Map<dynamic, dynamic> friendsMap = event.snapshot.value as Map;

          final List<Future<Map<String, dynamic>?>> futures = [];
          for (final entry in friendsMap.entries) {
            final fUid = entry.key as String;
            // Use cached profile if already fetched — avoids N reads on every friends-list change.
            if (_friendProfileCache.containsKey(fUid)) {
              futures.add(
                Future.value({'uid': fUid, ..._friendProfileCache[fUid]!}),
              );
            } else {
              futures.add(
                getUserProfileByUid(fUid)
                    .then((profile) {
                      if (profile != null) {
                        _friendProfileCache[fUid] = profile;
                        return {'uid': fUid, ...profile};
                      }
                      return null;
                    })
                    .catchError((_) => null),
              );
            }
          }

          final results = await Future.wait(futures);
          final List<Map<String, dynamic>> friendsList =
              results
                  .where((p) => p != null)
                  .cast<Map<String, dynamic>>()
                  .toList();

          _lastFriendsList = friendsList;
          if (!controller.isClosed) controller.add(friendsList);
        } else {
          _lastFriendsList = [];
          if (!controller.isClosed) controller.add([]);
        }
      } catch (e) {
        print('Error in friends stream listener: $e');
        if (!controller.isClosed) controller.addError(e);
      }
    });

    controller.onCancel = () {
      sub?.cancel();
      _cachedFriendsStream = null; // Allow recreation if all listeners cancel
    };

    _cachedFriendsStream = controller.stream;
    return _cachedFriendsStream!;
  }
}

class FallbackDatabase {
  FallbackDatabaseRef ref(String path) => FallbackDatabaseRef(path);
}

class FallbackDatabaseRef {
  final String path;
  final String? orderByVal;
  final int? limitToLastVal;

  FallbackDatabaseRef(this.path, {this.orderByVal, this.limitToLastVal});

  static const String _dbUrl =
      'https://assistant-mark-2-bdd7e-default-rtdb.asia-southeast1.firebasedatabase.app';

  static Future<String?>? _tokenFuture;
  static String? _cachedToken;
  static DateTime? _tokenExpiry;
  static final http.Client _client = http.Client();

  static Future<String?> _getAuthToken() async {
    if (_cachedToken != null &&
        _tokenExpiry != null &&
        DateTime.now().isBefore(_tokenExpiry!)) {
      return _cachedToken;
    }
    if (_tokenFuture != null) {
      return _tokenFuture;
    }
    _tokenFuture = _fetchToken();
    try {
      return await _tokenFuture;
    } finally {
      _tokenFuture = null;
    }
  }

  static Future<String?> _fetchToken() async {
    try {
      final token = await FirebaseAuth.instance.currentUser?.getIdToken();
      if (token != null) {
        _cachedToken = token;
        _tokenExpiry = DateTime.now().add(const Duration(minutes: 30));
        return token;
      }
    } catch (e) {
      print("Error fetching id token: $e");
    }
    return null;
  }

  Future<String> _getUrl([String? queryParams, bool forceNoFilters = false]) async {
    final token = await _getAuthToken();
    String url = '$_dbUrl/$path.json';
    List<String> params = [];
    if (token != null) {
      params.add('auth=$token');
    }
    if (!forceNoFilters) {
      if (queryParams != null) {
        params.add(queryParams);
      } else {
        if (orderByVal != null) {
          if (orderByVal == r'$key') {
            params.add('orderBy="%24key"');
          } else {
            params.add('orderBy="$orderByVal"');
          }
        }
        if (limitToLastVal != null) {
          params.add('limitToLast=$limitToLastVal');
        }
      }
    }
    if (params.isNotEmpty) {
      url += '?${params.join('&')}';
    }
    return url;
  }

  String get key => path.split('/').last;

  FallbackDatabaseRef child(String pathSegment) {
    return FallbackDatabaseRef('$path/$pathSegment');
  }

  Future<void> set(dynamic value) async {
    final url = await _getUrl(null, true);
    final res = await _client.put(
      Uri.parse(url),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(value),
    );
    if (res.statusCode != 200) {
      throw Exception("REST set failed: ${res.body}");
    }
  }

  Future<void> update(Map<String, dynamic> value) async {
    final url = await _getUrl(null, true);
    final res = await _client.patch(
      Uri.parse(url),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(value),
    );
    if (res.statusCode != 200) {
      throw Exception("REST update failed: ${res.body}");
    }
  }

  Future<void> remove() async {
    final url = await _getUrl(null, true);
    final res = await _client.delete(
      Uri.parse(url),
      headers: {'Content-Type': 'application/json'},
    );
    if (res.statusCode != 200) {
      throw Exception("REST delete failed: ${res.body}");
    }
  }

  FallbackDatabaseRef push() {
    final uniqueId = DateTime.now().microsecondsSinceEpoch.toString();
    return FallbackDatabaseRef('$path/$uniqueId');
  }

  dynamic _applyClientSideFilters(dynamic data) {
    if (data is! Map) return data;

    // Convert entries to list to sort them
    var entries = data.entries.toList();

    if (orderByVal != null) {
      entries.sort((a, b) {
        final valA = (a.value is Map) ? a.value[orderByVal] : null;
        final valB = (b.value is Map) ? b.value[orderByVal] : null;
        if (valA == null && valB == null) return 0;
        if (valA == null) return -1;
        if (valB == null) return 1;
        if (valA is Comparable && valB is Comparable) {
          return valA.compareTo(valB);
        }
        return 0;
      });
    }

    if (limitToLastVal != null && entries.length > limitToLastVal!) {
      entries = entries.sublist(entries.length - limitToLastVal!);
    }

    return Map.fromEntries(entries);
  }

  Future<FallbackDataSnapshot> get([String? queryParams, bool forceNoFilters = false]) async {
    final url = await _getUrl(queryParams, forceNoFilters);
    final res = await _client.get(Uri.parse(url));
    if (res.statusCode != 200) {
      if (!forceNoFilters && res.statusCode == 400 && res.body.contains("Index not defined")) {
        // Fallback: Fetch without server filters, and apply them client-side
        return get(null, true);
      }
      throw Exception("REST get failed: status ${res.statusCode}, body: ${res.body}");
    }
    if (res.body == 'null') {
      return FallbackDataSnapshot(null);
    }
    final decoded = jsonDecode(res.body);
    if (forceNoFilters || (queryParams == null && (orderByVal != null || limitToLastVal != null))) {
      final filtered = _applyClientSideFilters(decoded);
      return FallbackDataSnapshot(filtered);
    }
    return FallbackDataSnapshot(decoded);
  }

  FallbackDatabaseRef orderByChild(String child) {
    return FallbackDatabaseRef(path, orderByVal: child, limitToLastVal: limitToLastVal);
  }

  FallbackDatabaseRef limitToLast(int limit) {
    return FallbackDatabaseRef(path, orderByVal: orderByVal, limitToLastVal: limit);
  }

  FallbackOnDisconnect onDisconnect() => FallbackOnDisconnect(this);

  Stream<FallbackDatabaseEvent> get onValue {
    final controller = StreamController<FallbackDatabaseEvent>.broadcast();
    Timer? timer;
    bool isPolling = false;

    void poll() async {
      if (isPolling) return;
      isPolling = true;
      try {
        final snapshot = await get();
        if (!controller.isClosed) {
          controller.add(FallbackDatabaseEvent(snapshot));
        }
      } catch (e) {
        print("REST poll error: $e");
      } finally {
        isPolling = false;
      }
    }

    poll();
    timer = Timer.periodic(const Duration(milliseconds: 3000), (_) => poll());

    controller.onCancel = () {
      timer?.cancel();
      controller.close();
    };

    return controller.stream;
  }

  Stream<FallbackDatabaseEvent> get onChildAdded {
    final controller = StreamController<FallbackDatabaseEvent>.broadcast();
    Timer? timer;
    final Set<String> seenKeys = {};
    String? lastKey;
    bool isPolling = false;

    void poll() async {
      if (isPolling) return;
      isPolling = true;
      try {
        String? queryParams;
        if (lastKey != null) {
          queryParams = 'orderBy=%22%24key%22&startAt=%22$lastKey%22';
        }
        final snapshot = await get(queryParams);
        if (controller.isClosed) return;

        if (snapshot.exists && snapshot.value is Map) {
          final map = snapshot.value as Map;
          final sortedKeys = map.keys.map((k) => k.toString()).toList()..sort();
          for (final key in sortedKeys) {
            if (!seenKeys.contains(key)) {
              seenKeys.add(key);
              lastKey = key;
              final childVal = map[key];
              final childSnap = FallbackDataSnapshot(childVal, key: key);
              controller.add(FallbackDatabaseEvent(childSnap));
            }
          }
        } else if (!snapshot.exists) {
          // Node has been deleted (e.g. clearSignaling), reset polling state
          seenKeys.clear();
          lastKey = null;
        }
      } catch (e) {
        print("REST poll error: $e");
      } finally {
        isPolling = false;
      }
    }

    poll();
    timer = Timer.periodic(const Duration(milliseconds: 3000), (_) => poll());

    controller.onCancel = () {
      timer?.cancel();
      controller.close();
    };

    return controller.stream;
  }
}

class FallbackDataSnapshot {
  final dynamic value;
  final String? key;
  FallbackDataSnapshot(this.value, {this.key});
  bool get exists => value != null;
}

class FallbackDatabaseEvent {
  final FallbackDataSnapshot snapshot;
  FallbackDatabaseEvent(this.snapshot);
}

class FallbackOnDisconnect {
  final FallbackDatabaseRef ref;
  FallbackOnDisconnect(this.ref);

  Future<void> remove() async {
    // No-op for REST API client fallback database
  }

  Future<void> set(dynamic value) async {
    // No-op
  }

  Future<void> update(Map<String, dynamic> value) async {
    // No-op
  }

  Future<void> cancel() async {
    // No-op
  }
}
