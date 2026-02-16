import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'dart:async';
import 'encryption_service.dart';

class SupabaseService {
  static final SupabaseService _instance = SupabaseService._internal();

  factory SupabaseService() {
    return _instance;
  }

  SupabaseService._internal();

  Future<void> initialize() async {
    final supabaseUrl = dotenv.env['SUPABASE_URL'];
    final supabaseAnonKey = dotenv.env['SUPABASE_KEY'];

    if (supabaseUrl == null || supabaseAnonKey == null) {
      print("Warning: Supabase credentials missing from .env");
      return;
    }

    try {
      await Supabase.initialize(url: supabaseUrl, anonKey: supabaseAnonKey);
      print("Supabase Initialized Successfully");
    } catch (e) {
      print(
        "Supabase initialization failed (might be already initialized): $e",
      );
    }
  }

  // Safe getter for client
  SupabaseClient? get _safeClient {
    try {
      return Supabase.instance.client;
    } catch (_) {
      return null;
    }
  }

  SupabaseClient get _client {
    if (_safeClient == null) {
      throw Exception("Supabase not initialized. Call initialize() first.");
    }
    return Supabase.instance.client;
  }

  User? get currentUser {
    if (_safeClient == null) return null;
    return _safeClient!.auth.currentUser;
  }

  Stream<AuthState> get authStateChanges {
    if (_safeClient == null) return const Stream.empty();
    return _safeClient!.auth.onAuthStateChange;
  }

  Future<AuthResponse> signIn(String email, String password) async {
    return await _client.auth.signInWithPassword(
      email: email,
      password: password,
    );
  }

  Future<AuthResponse> signUp(String email, String password) async {
    return await _client.auth.signUp(email: email, password: password);
  }

  Future<void> signOut() async {
    await _client.auth.signOut();
  }

  Future<bool> signInWithGoogle() async {
    // For Native Android/iOS we use the native Google Sign-In via Supabase's helper or standard OAuth flow
    // IMPORTANT: Make sure you have configured Google Auth in Supabase dashboard
    // and added the SHA-1 fingerprint for Android in Firebase/Google Cloud Console.

    // Using simple PKCE flow for better compatibility across platforms in this starter
    if (_safeClient == null) {
      await initialize();
      if (_safeClient == null) {
        throw Exception(
          "Supabase initialization failed. Check your internet connection and .env file.",
        );
      }
    }
    return await _client.auth.signInWithOAuth(
      OAuthProvider.google,
      redirectTo: kIsWeb ? null : 'io.supabase.zapshare://login-callback/',
      authScreenLaunchMode:
          kIsWeb ? LaunchMode.platformDefault : LaunchMode.externalApplication,
    );
  }

  // Profile Methods

  /// Fetches user profile from profiles table
  /// Returns null if profile doesn't exist or user is not logged in
  Future<Map<String, dynamic>?> getUserProfile() async {
    if (currentUser == null) return null;

    try {
      final response =
          await _client
              .from('profiles')
              .select()
              .eq('id', currentUser!.id)
              .maybeSingle();

      if (kDebugMode && response != null) {
        print('📋 Profile Data from Database:');
        response.forEach((key, value) {
          print('  $key: $value');
        });
      }

      return response;
    } catch (e) {
      if (kDebugMode) {
        print('Error fetching profile: $e');
      }
      return null;
    }
  }

  /// Updates user profile in profiles table
  Future<void> updateUserProfile({String? fullName, String? avatarUrl}) async {
    if (currentUser == null) return;

    final updates = <String, dynamic>{
      'updated_at': DateTime.now().toIso8601String(),
    };

    if (fullName != null) updates['full_name'] = fullName;
    if (avatarUrl != null) updates['avatar_url'] = avatarUrl;

    await _client.from('profiles').update(updates).eq('id', currentUser!.id);
  }

  // Clipboard Sync Methods

  // Clipboard Sync Methods (Optimized: Single Row per User)

  Future<void> addClipboardItem(String content) async {
    if (currentUser == null) return;

    try {
      // Use Server-Side Function (RPC) for atomic updates
      // ENCRYPT content before sending to DB (End-to-End Encryption)
      final encryptedContent = EncryptionService.encrypt(content);

      await _client.rpc(
        'append_clipboard_item',
        params: {'p_user_id': currentUser!.id, 'p_content': encryptedContent},
      );
    } catch (e) {
      if (kDebugMode) {
        print('Error adding clipboard item: $e');
      }
      rethrow;
    }
  }

  Future<List<Map<String, dynamic>>> fetchClipboardHistory() async {
    if (currentUser == null) return [];

    try {
      final response =
          await _client
              .from('user_clipboards')
              .select('clips')
              .eq('user_id', currentUser!.id)
              .maybeSingle();

      if (response == null || response['clips'] == null) return [];

      final List<dynamic> clips = response['clips'];
      return clips.map((e) {
        final item = Map<String, dynamic>.from(e);
        // DECRYPT content
        item['content'] = EncryptionService.decrypt(item['content'] ?? '');
        return item;
      }).toList();
    } catch (e) {
      if (kDebugMode) {
        print('Error fetching clipboard history: $e');
      }
      return [];
    }
  }

  Stream<List<Map<String, dynamic>>> getClipboardStream() {
    if (currentUser == null) return const Stream.empty();

    return _client
        .from('user_clipboards')
        .stream(primaryKey: ['user_id'])
        .eq('user_id', currentUser!.id)
        .map((event) {
          if (event.isEmpty) return [];
          final row = event.first;
          if (row['clips'] == null) return [];
          final List<dynamic> clips = row['clips'];
          return clips.map((e) {
            final item = Map<String, dynamic>.from(e);
            item['content'] = EncryptionService.decrypt(item['content'] ?? '');
            return item;
          }).toList();
        });
  }

  // Efficient realtime subscription for UPDATES on the user's row
  Stream<Map<String, dynamic>> subscribeToClipboardUpdates() {
    if (currentUser == null) return const Stream.empty();

    final controller = StreamController<Map<String, dynamic>>.broadcast();

    final channel = _client.channel('public:user_clipboards:updates');

    channel
        .onPostgresChanges(
          event: PostgresChangeEvent.all, // Listen for INSERT or UPDATE
          schema: 'public',
          table: 'user_clipboards',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'user_id',
            value: currentUser!.id,
          ),
          callback: (payload) {
            if (!controller.isClosed) {
              // We receive the full row. extract the latest item.
              final newRecord = payload.newRecord;
              if (newRecord.isNotEmpty && newRecord['clips'] != null) {
                final List clips = newRecord['clips'];
                if (clips.isNotEmpty) {
                  // Return the latest item so the UI can process it (notify/copy)
                  final item = Map<String, dynamic>.from(clips.first);
                  item['content'] = EncryptionService.decrypt(
                    item['content'] ?? '',
                  );
                  controller.add(item);
                }
              }
            }
          },
        )
        .subscribe((status, error) {
          if (status == RealtimeSubscribeStatus.closed) {
            controller.close();
          }
        });

    controller.onCancel = () {
      channel.unsubscribe();
    };

    return controller.stream;
  }
}
