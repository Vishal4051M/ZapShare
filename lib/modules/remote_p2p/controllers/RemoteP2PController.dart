import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../Constants/AppLogger.dart';
import '../models/P2PSessionModel.dart';
import '../models/RemoteMessageModel.dart';
import '../services/FirebaseP2PService.dart';
import '../services/WebRTCP2PService.dart';
import '../services/RemoteTransferService.dart';

class RemoteP2PController {
  static final RemoteP2PController _instance = RemoteP2PController._internal();
  factory RemoteP2PController() => _instance;
  RemoteP2PController._internal();

  final FirebaseP2PService _firebaseService = FirebaseP2PService();
  final WebRTCP2PService _webrtcService = WebRTCP2PService();
  final GoogleSignIn _googleSignIn = GoogleSignIn(scopes: ['email']);

  GoogleSignInAccount? currentUser;
  P2PSessionModel? activeSession;
  MediaStream? remoteStream; // exposed for RTCVideoRenderer
  final List<RemoteMessageModel> messages = [];
  Future<void> _signalingQueue = Future.value();
  bool _isReconnecting = false;
  int _reconnectAttempts = 0;
  int _totalRecoveryAttempts = 0;
  int _transferRetryCount = 0;
  // Invalidates recovery work that was already in flight when WebRTC reports a
  // successful connection.  Cancelling a Timer alone cannot stop an async ICE
  // restart that has already passed its await points.
  int _recoveryGeneration = 0;
  double _lastTransferProgress = 0;
  Timer? _reconnectTimer;
  bool isHost = false;
  int _connectionGeneration = 0;

  // Settings
  String avatarMode = 'emoji'; // 'emoji' or 'image'
  String customEmoji = '🚀';

  // Streams / Listeners for UI
  final _stateController = StreamController<P2PSessionModel?>.broadcast();
  final _messageController =
      StreamController<List<RemoteMessageModel>>.broadcast();

  Stream<P2PSessionModel?> get stateStream => _stateController.stream;
  Stream<List<RemoteMessageModel>> get messageStream =>
      _messageController.stream;

  void notifyUI() {
    _stateController.add(activeSession);
    _messageController.add(List.unmodifiable(messages));
  }

  Future<void> initialize() async {
    try {
      await _firebaseService.initialize();
      final prefs = await SharedPreferences.getInstance();
      avatarMode = prefs.getString('p2p_avatar_mode') ?? 'emoji';
      customEmoji = prefs.getString('p2p_custom_emoji') ?? '🚀';

      _googleSignIn.onCurrentUserChanged.listen((account) {
        currentUser = account;
        notifyUI();
      });
      await _googleSignIn.signInSilently();
    } catch (e) {
      AppLogger.e("STARTUP", "Error initializing RemoteP2PController", e);
    }
  }

  Future<bool> signInWithGoogle() async {
    try {
      final account = await _googleSignIn.signIn();
      currentUser = account;
      notifyUI();
      return account != null;
    } catch (e) {
      AppLogger.e("FIREBASE", "Google Sign-In failed", e);
      return false;
    }
  }

  Future<void> signOut() async {
    try {
      await _googleSignIn.signOut();
      currentUser = null;
      notifyUI();
    } catch (e) {
      AppLogger.e("FIREBASE", "Google Sign-Out failed", e);
    }
  }

  Future<void> saveAvatarSettings(String mode, String emoji) async {
    try {
      avatarMode = mode;
      customEmoji = emoji;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('p2p_avatar_mode', mode);
      await prefs.setString('p2p_custom_emoji', emoji);
      notifyUI();
    } catch (e) {
      AppLogger.e("STARTUP", "Failed to save avatar settings", e);
    }
  }

  Map<String, dynamic> _getMyProfile() {
    final uid = currentUser?.id ?? "anonymous_${Random().nextInt(10000)}";
    final name = currentUser?.displayName ?? "Guest Device";
    final avatar =
        avatarMode == 'image' && currentUser?.photoUrl != null
            ? currentUser!.photoUrl!
            : customEmoji;
    return {
      'id': uid,
      'name': name,
      'avatar': avatar,
      'avatarType': avatarMode,
    };
  }

  // Room Orchestration

  Future<String> hostRoom() async {
    try {
      isHost = true;
      final random = Random();
      final code =
          (10000000 + random.nextInt(90000000)).toString(); // 8-digit code
      final profile = _getMyProfile();

      activeSession = P2PSessionModel(
        roomId: code,
        mode: P2PConnectionMode.anywhere,
        connectionState: P2PConnectionState.connecting,
        peerId: '',
        peerName: '',
        peerAvatar: '',
        peerAvatarType: '',
      );
      messages.clear();
      notifyUI();

      await _firebaseService.createRoom(code, profile);
      _setupWebRTC(true, code);
      return code;
    } catch (e) {
      AppLogger.e("SIGNALING", "Error hosting room", e);
      rethrow;
    }
  }

  Future<bool> joinRoom(String roomId) async {
    try {
      isHost = false;
      final profile = _getMyProfile();
      messages.clear();

      final joined = await _firebaseService.joinRoom(roomId, profile);
      if (!joined) return false;

      activeSession = P2PSessionModel(
        roomId: roomId,
        mode: P2PConnectionMode.anywhere,
        connectionState: P2PConnectionState.connecting,
        peerId: '',
        peerName: '',
        peerAvatar: '',
        peerAvatarType: '',
      );
      notifyUI();

      _setupWebRTC(false, roomId);
      return true;
    } catch (e) {
      AppLogger.e("SIGNALING", "Error joining room", e);
      return false;
    }
  }

  void _setupWebRTC(bool isHost, String roomId) async {
    try {
      _recoveryGeneration++;
      _isReconnecting = false;
      _reconnectAttempts = 0;
      _totalRecoveryAttempts = 0;
      _reconnectTimer?.cancel();
      _connectionGeneration++;
      _signalingQueue = Future.value();

      if (isHost) {
        await _firebaseService.clearSignaling(roomId);
      }

      await _webrtcService.initializeConnection(isHost, (sdp) async {
        await _firebaseService.sendSignal(roomId, isHost, sdp);
      }, _connectionGeneration);

      _attachWebRTCListeners(isHost, roomId);

      // Connect signaling listeners (only once per session startup!)
      _firebaseService.listenToSignaling(
        roomId,
        isHost,
        (signal) => _enqueueSignal(roomId, isHost, signal),
        (peerInfo) {
          activeSession = activeSession?.copyWith(
            peerId: peerInfo['id'] ?? '',
            peerName: peerInfo['name'] ?? '',
            peerAvatar: peerInfo['avatar'] ?? '',
            peerAvatarType: peerInfo['avatarType'] ?? 'emoji',
          );
          notifyUI();
        },
      );

      if (isHost) {
        // Host creates the Offer
        final offer = await _webrtcService.createOffer();
        await _firebaseService.sendSignal(roomId, isHost, offer);
      }
    } catch (e) {
      AppLogger.e("SIGNALING", "Error in WebRTC negotiation loop", e);
    }
  }

  void _attachWebRTCListeners(bool isHost, String roomId) {
    _webrtcService.onIceCandidateGenerated = (candidate) async {
      await _firebaseService.sendSignal(roomId, isHost, {
        'type': 'candidate',
        ...candidate,
      });
    };

    _webrtcService.onConnectionStateChanged = (state) {
      AppLogger.i("SIGNALING", "WebRTC connection state changed: ${state.name}");
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        _recoveryGeneration++;
        _isReconnecting = false;
        _reconnectAttempts = 0;
        _totalRecoveryAttempts = 0;
        _reconnectTimer?.cancel();
        _reconnectTimer = null;
        activeSession = activeSession?.copyWith(
          connectionState: P2PConnectionState.connected,
        );
        if (isHost) {
          unawaited(_firebaseService.clearSignaling(roomId));
        }
        unawaited(
          RemoteTransferService.updateStatus(
            'Connection restored; resuming transfer…',
          ),
        );
        notifyUI();
      } else if (state ==
              RTCPeerConnectionState.RTCPeerConnectionStateDisconnected ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        if (activeSession == null ||
            activeSession!.connectionState == P2PConnectionState.disconnected) {
          return;
        }

        if (!_isReconnecting) {
          _isReconnecting = true;
          _reconnectAttempts = 0;
          activeSession = activeSession?.copyWith(
            connectionState: P2PConnectionState.reconnecting,
          );
          unawaited(
            RemoteTransferService.updateStatus(
              'Connection interrupted; reconnecting…',
            ),
          );
          notifyUI();
          _startReconnectionLoop(isHost, roomId);
        }
      }
    };

    // Set up chat-level data events
    _webrtcService.getSavePath = (fileName) async {
      final prefs = await SharedPreferences.getInstance();
      final customFolder = prefs.getString('custom_save_folder');
      final targetFolder = customFolder ?? await _getDefaultDownloadFolder();
      return '$targetFolder/$fileName';
    };

    _webrtcService.onMessageReceived =
        (text) => _appendMessage(RemoteMessageType.text, text, true);
    _webrtcService.onEmojiReceived =
        (emoji) => _appendMessage(RemoteMessageType.emoji, emoji, true);

    _webrtcService.onRemoteStreamAdded = (stream) {
      remoteStream = stream;
      notifyUI();
    };

    _webrtcService.onFileIncoming = (name, size) {
      final header = "$name|$size";
      final isResumeHeader =
          messages.isNotEmpty &&
          messages.last.type == RemoteMessageType.fileHeader &&
          messages.last.content == header;
      if (!isResumeHeader) {
        _appendMessage(RemoteMessageType.fileHeader, header, true);
      }
      if (!isResumeHeader) _lastTransferProgress = 0;
      // Start foreground service on receiver side
      final peerName = activeSession?.peerName ?? 'Sender';
      RemoteTransferService.start(peerName: peerName, isSender: false);
    };

    _webrtcService.onFileProgress = (progress) {
      _updateLatestFileProgress(progress);
    };

    _webrtcService.onFileReceivedPath = (tempPath) async {
      final fileName = tempPath.split('/').last;
      _appendMessage(
        RemoteMessageType.fileAck,
        "Saving file permanently...",
        true,
      );
      notifyUI();

      await saveReceivedFile(tempPath, fileName);

      // Remove the temporary acknowledgment message and append the success message
      if (messages.isNotEmpty &&
          messages.last.type == RemoteMessageType.fileAck) {
        messages.removeLast();
      }
      _appendMessage(RemoteMessageType.fileAck, "File Saved: $fileName", true);
      notifyUI();
      // Stop foreground service on receiver side
      await RemoteTransferService.stop();
    };
  }

  void _startReconnectionLoop(bool isHost, String roomId) async {
    final recoveryGeneration = ++_recoveryGeneration;
    _reconnectTimer?.cancel();
    unawaited(
      RemoteTransferService.updateStatus('Reconnecting secure transfer…'),
    );

    // 1. Try ICE restart first (quick check)
    try {
      _totalRecoveryAttempts++;
      AppLogger.i("ICE", "Attempting ICE restart recovery... (Total recovery attempts: $_totalRecoveryAttempts/10)");
      if (isHost) {
        final offer = await _webrtcService.createOffer(iceRestart: true);
        if (recoveryGeneration != _recoveryGeneration || !_isReconnecting) {
          return;
        }
        await _firebaseService.sendSignal(roomId, isHost, offer);
      } else {
        await _firebaseService.sendSignal(roomId, isHost, {'type': 'request_renegotiation'});
      }

      // A peer connection is usable only once its data channel is open.
      await Future.delayed(const Duration(seconds: 3));
      if (recoveryGeneration != _recoveryGeneration || !_isReconnecting) {
        return;
      }
      if (activeSession?.connectionState == P2PConnectionState.connected &&
          _webrtcService.isDataChannelOpen) {
        AppLogger.i("ICE", "ICE restart successfully recovered connection!");
        return;
      }
    } catch (e) {
      AppLogger.w("ICE", "ICE restart attempt failed: $e");
    }

    // 2. Rebuild connection loop with exponential backoff
    if (recoveryGeneration == _recoveryGeneration && _isReconnecting) {
      _rebuildConnectionAttempt(isHost, roomId, recoveryGeneration);
    }
  }

  void _rebuildConnectionAttempt(
    bool isHost,
    String roomId,
    int recoveryGeneration,
  ) async {
    if (recoveryGeneration != _recoveryGeneration ||
        !_isReconnecting ||
        activeSession == null ||
        (activeSession!.connectionState == P2PConnectionState.connected &&
            _webrtcService.isDataChannelOpen)) {
      _isReconnecting = false;
      return;
    }

    if (_totalRecoveryAttempts >= 10) {
      AppLogger.e(
        "SIGNALING",
        "Total recovery attempts exhausted ($_totalRecoveryAttempts/10). Marking session disconnected.",
      );
      _isReconnecting = false;
      activeSession = activeSession?.copyWith(
        connectionState: P2PConnectionState.disconnected,
      );
      unawaited(
        RemoteTransferService.updateStatus('Connection could not be restored'),
      );
      notifyUI();
      return;
    }

    _reconnectAttempts++;
    _totalRecoveryAttempts++;
    final delaySeconds = min(30, pow(2, _reconnectAttempts).toInt());
    unawaited(
      RemoteTransferService.updateStatus(
        'Reconnecting transfer (attempt $_reconnectAttempts of 10)…',
      ),
    );
    AppLogger.w(
      "SIGNALING",
      "Reconnection attempt: $_reconnectAttempts, Transfer retry: $_transferRetryCount, Total recovery attempts: $_totalRecoveryAttempts/10. Next try in ${delaySeconds}s.",
    );

    _reconnectTimer = Timer(Duration(seconds: delaySeconds), () async {
      try {
        if (recoveryGeneration != _recoveryGeneration ||
            !_isReconnecting ||
            activeSession == null ||
            (activeSession!.connectionState == P2PConnectionState.connected &&
                _webrtcService.isDataChannelOpen)) {
          return;
        }

        AppLogger.i("SIGNALING", "Rebuilding peer connection...");
        _connectionGeneration++;
        _signalingQueue = Future.value();

        if (isHost) {
          await _firebaseService.clearSignaling(roomId);
        }

        if (recoveryGeneration != _recoveryGeneration || !_isReconnecting) {
          return;
        }

        // Re-initialize webrtc connection (do NOT leave room)
        await _webrtcService.initializeConnection(isHost, (sdp) async {
          await _firebaseService.sendSignal(roomId, isHost, sdp);
        }, _connectionGeneration);

        // Re-hook all listeners
        _attachWebRTCListeners(isHost, roomId);

        if (isHost) {
          final offer = await _webrtcService.createOffer();
          if (recoveryGeneration != _recoveryGeneration || !_isReconnecting) {
            return;
          }
          await _firebaseService.sendSignal(roomId, isHost, offer);
        } else {
          await _firebaseService.sendSignal(roomId, isHost, {'type': 'request_renegotiation'});
        }
      } catch (e) {
        AppLogger.w("SIGNALING", "Reconnection rebuild attempt failed: $e");
      }

      // Schedule next attempt if not connected yet
      if (recoveryGeneration == _recoveryGeneration &&
          _isReconnecting &&
          activeSession?.connectionState == P2PConnectionState.reconnecting) {
        _rebuildConnectionAttempt(isHost, roomId, recoveryGeneration);
      }
    });
  }

  void _enqueueSignal(String roomId, bool isHost, Map<String, dynamic> signal) {
    final gen = _connectionGeneration;
    _signalingQueue = _signalingQueue
        .then((_) {
          if (gen != _connectionGeneration) {
            AppLogger.d(
              "SIGNALING",
              "Ignoring stale signal from generation $gen (current: $_connectionGeneration)",
            );
            return Future<void>.value();
          }
          return _handleSignal(roomId, isHost, signal);
        })
        .catchError((Object error, StackTrace stackTrace) {
          AppLogger.e("SIGNALING", "Error handling remote P2P signal: $error", error, stackTrace);
        });
  }

  Future<void> _handleSignal(
    String roomId,
    bool isHost,
    Map<String, dynamic> signal,
  ) async {
    final type = signal['type'];
    if (type == 'offer' && !isHost) {
      final answer = await _webrtcService.createAnswer(signal);
      await _firebaseService.sendSignal(roomId, isHost, answer);
    } else if (type == 'answer' && isHost) {
      await _webrtcService.setAnswer(signal);
    } else if (type == 'candidate') {
      await _webrtcService.addCandidate(signal);
    } else if (type == 'request_renegotiation' && isHost) {
      AppLogger.i("SIGNALING", "Received request_renegotiation signal on host side.");
      _triggerHostRenegotiation(roomId);
    }
  }

  void _triggerHostRenegotiation(String roomId) {
    if (activeSession == null ||
        activeSession!.connectionState == P2PConnectionState.disconnected) {
      return;
    }

    if (!_isReconnecting) {
      _isReconnecting = true;
      _reconnectAttempts = 0;
      activeSession = activeSession?.copyWith(
        connectionState: P2PConnectionState.reconnecting,
      );
      unawaited(
        RemoteTransferService.updateStatus(
          'Renegotiation requested; reconnecting…',
        ),
      );
      notifyUI();
      _startReconnectionLoop(true, roomId);
    } else {
      final recoveryGeneration = ++_recoveryGeneration;
      _reconnectTimer?.cancel();
      _rebuildConnectionAttempt(true, roomId, recoveryGeneration);
    }
  }

  Future<String> _getDefaultDownloadFolder() async {
    try {
      final downloadsCandidate = Directory(
        '/storage/emulated/0/Download/ZapShare',
      );
      if (Platform.isAndroid) {
        try {
          if (!await downloadsCandidate.exists()) {
            await downloadsCandidate.create(recursive: true);
          }
          return downloadsCandidate.path;
        } catch (_) {}
      }
      final downloadsDir = await getDownloadsDirectory();
      if (downloadsDir != null) {
        final zapDir = Directory('${downloadsDir.path}/ZapShare');
        if (!await zapDir.exists()) await zapDir.create(recursive: true);
        return zapDir.path;
      }
      return '/storage/emulated/0/Download/ZapShare';
    } catch (e) {
      return '/storage/emulated/0/Download/ZapShare';
    }
  }

  Future<void> saveReceivedFile(String tempPath, String fileName) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final customFolder = prefs.getString('custom_save_folder');
      final targetFolder = customFolder ?? await _getDefaultDownloadFolder();

      final targetPath = '$targetFolder/$fileName';
      if (tempPath == targetPath) {
        AppLogger.i("TRANSFER", "File was already written directly to: $targetPath");
        return;
      }
      final tempFile = File(tempPath);
      final destFile = File(targetPath);

      if (await destFile.exists()) {
        await destFile.delete();
      }
      await tempFile.rename(targetPath);
      AppLogger.i("TRANSFER", "File permanently saved to: $targetPath");
    } catch (e) {
      AppLogger.w("TRANSFER", "Error renaming file, falling back to copy/delete: $e");
      try {
        final prefs = await SharedPreferences.getInstance();
        final customFolder = prefs.getString('custom_save_folder');
        final targetFolder = customFolder ?? await _getDefaultDownloadFolder();
        final targetPath = '$targetFolder/$fileName';
        final tempFile = File(tempPath);
        await tempFile.copy(targetPath);
        await tempFile.delete();
      } catch (copyErr) {
        AppLogger.e("TRANSFER", "Fallback copy failed: $copyErr", copyErr);
      }
    }
  }

  void _appendMessage(RemoteMessageType type, String content, bool isIncoming) {
    final senderProfile = _getMyProfile();
    final msg = RemoteMessageModel(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      senderId:
          isIncoming
              ? (activeSession?.peerId ?? 'peer')
              : (senderProfile['id'] ?? 'me'),
      senderName:
          isIncoming
              ? (activeSession?.peerName ?? 'Peer')
              : (senderProfile['name'] ?? 'Me'),
      senderAvatar:
          isIncoming
              ? (activeSession?.peerAvatar ?? '👤')
              : (senderProfile['avatar'] ?? '👤'),
      senderAvatarType:
          isIncoming
              ? (activeSession?.peerAvatarType ?? 'emoji')
              : (senderProfile['avatarType'] ?? 'emoji'),
      type: type,
      content: content,
      timestamp: DateTime.now().millisecondsSinceEpoch,
    );
    messages.add(msg);
    notifyUI();
  }

  void _updateLatestFileProgress(double progress) {
    final index = messages.lastIndexWhere(
      (message) => message.type == RemoteMessageType.fileHeader,
    );
    if (index < 0) return;
    final normalizedProgress = progress.clamp(0.0, 1.0).toDouble();
    if (normalizedProgress < _lastTransferProgress) return;
    _lastTransferProgress = normalizedProgress;
    // Update notification for both sender and receiver
    final fileName = messages[index].content.split('|').firstOrNull;
    final myId = _getMyProfile()['id'] as String? ?? '';
    final isSenderSide = messages[index].senderId == myId;
    RemoteTransferService.updateProgress(
      progress,
      fileName: fileName,
      isSender: isSenderSide,
    );
    messages[index] = messages[index].copyWith(
      progress: normalizedProgress,
    );
    notifyUI();
  }

  // Active Messaging API

  void sendTextMessage(String text) {
    _webrtcService.sendControlMessage({'type': 'text', 'content': text});
    _appendMessage(RemoteMessageType.text, text, false);
  }

  void sendEmojiMessage(String emoji) {
    _webrtcService.sendControlMessage({'type': 'emoji', 'content': emoji});
    _appendMessage(RemoteMessageType.emoji, emoji, false);
  }

  Future<void> sendSharedFile({
    String? filePath,
    Uint8List? fileBytes,
    required String name,
    required int size,
    int retryCount = 0,
  }) async {
    _transferRetryCount = retryCount;
    if (retryCount == 0) {
      _lastTransferProgress = 0;
      _totalRecoveryAttempts = 0;
      _reconnectAttempts = 0;
      _appendMessage(RemoteMessageType.fileHeader, "$name|$size", false);
    }
    // Start foreground service on sender side
    final peerName = activeSession?.peerName ?? 'Receiver';
    await RemoteTransferService.start(peerName: peerName, isSender: true);
    try {
      if (filePath != null) {
        if (filePath.startsWith('content://')) {
          await _webrtcService.sendFileStreamFromUri(filePath, name, size, (
            progress,
          ) {
            _updateLatestFileProgress(progress);
          });
        } else {
          await _webrtcService.sendFileStream(filePath, name, (progress) {
            _updateLatestFileProgress(progress);
          });
        }
      } else if (fileBytes != null) {
        await _webrtcService.sendFile(fileBytes, name, (progress) {
          _updateLatestFileProgress(progress);
        });
      }
      // Remove any temporary "waiting to resume..." status message before posting complete
      if (messages.isNotEmpty &&
          messages.last.type == RemoteMessageType.fileAck &&
          messages.last.content.contains("waiting to resume")) {
        messages.removeLast();
      }
      _appendMessage(RemoteMessageType.fileAck, "Transfer Completed", false);
    } catch (e) {
      final errStr = e.toString();
      final isRecoverable = e is TransferException;
      if (isRecoverable && _totalRecoveryAttempts < 10 && retryCount < 12) {
        AppLogger.w(
          "TRANSFER",
          "Transfer interrupted or data channel failed to open. Initiating recovery... (Attempt ${retryCount + 1}/12, total recovery attempts: $_totalRecoveryAttempts/10)",
        );

        // If the peer connection is 'connected' but the data channel failed to open,
        // the connection state is out of sync. Force a new reconnection attempt.
        if (activeSession != null && !_isReconnecting) {
          _isReconnecting = true;
          activeSession = activeSession!.copyWith(
            connectionState: P2PConnectionState.reconnecting,
          );
          notifyUI();
          _startReconnectionLoop(isHost, activeSession!.roomId);
        }

        _appendMessage(
          RemoteMessageType.fileAck,
          "Connection lost, waiting to resume...",
          false,
        );
        notifyUI();

        // Wait for a rebuilt peer connection, then separately wait for its
        // data channel.  PeerConnection.connected does not guarantee SCTP is
        // ready, and restarting the stream before it is ready caused the
        // repeated failures seen on large files.
        bool reconnected = false;
        for (int i = 0; i < 300; i++) {
          await Future.delayed(const Duration(seconds: 1));
          if (activeSession == null ||
              activeSession!.connectionState ==
                  P2PConnectionState.disconnected) {
            break; // session aborted
          }
          if (activeSession!.connectionState == P2PConnectionState.connected) {
            try {
              await _webrtcService.waitForDataChannelOpen(
                timeout: const Duration(seconds: 30),
              );
              reconnected = true;
              break;
            } catch (_) {
              // The reconnection loop will rebuild the peer connection; keep
              // waiting instead of starting another transfer on a closed SCTP
              // channel.
            }
          }
        }

        if (reconnected && activeSession != null) {
          AppLogger.i("TRANSFER", "Reconnected! Auto-resuming transfer...");
          // Remove the "Connection lost, waiting to resume..." message
          if (messages.isNotEmpty &&
              messages.last.type == RemoteMessageType.fileAck) {
            messages.removeLast();
          }
          notifyUI();

          // Re-invoke sendSharedFile recursively
          await sendSharedFile(
            filePath: filePath,
            fileBytes: fileBytes,
            name: name,
            size: size,
            retryCount: retryCount + 1,
          );
          return;
        }
      }

      if (isRecoverable && (_totalRecoveryAttempts >= 10 || retryCount >= 12)) {
        AppLogger.e(
          "TRANSFER",
          "Transfer recovery limit reached (total attempts: $_totalRecoveryAttempts/10, retryCount: $retryCount/12).",
        );
      }

      AppLogger.e("TRANSFER", "Error during remote file transfer", e);
      // Remove any temporary status message
      if (messages.isNotEmpty &&
          messages.last.type == RemoteMessageType.fileAck) {
        messages.removeLast();
      }
      _appendMessage(
        RemoteMessageType.fileAck,
        "Transfer Failed: ${errStr.replaceAll("Exception: ", "")}",
        false,
      );
    } finally {
      if (retryCount == 0) {
        await RemoteTransferService.stop();
      }
    }
  }

  // Media Streams toggles

  Future<void> toggleAudioShare(bool start) async {
    if (start) {
      await _webrtcService.startAudioSharing();
    } else {
      await _webrtcService.stopSharing();
    }
  }

  Future<void> toggleScreenShare(bool start) async {
    if (start) {
      await _webrtcService.startScreenSharing();
    } else {
      await _webrtcService.stopSharing();
    }
  }

  Future<void> disconnect() async {
    try {
      _recoveryGeneration++;
      _reconnectTimer?.cancel();
      _reconnectTimer = null;
      _isReconnecting = false;
      _reconnectAttempts = 0;
      if (activeSession != null) {
        await _firebaseService.leaveRoom(activeSession!.roomId);
      }
      await _webrtcService.dispose();
      await RemoteTransferService.stop();
      remoteStream = null;
      activeSession = null;
      messages.clear();
      notifyUI();
    } catch (e) {
      AppLogger.e("SIGNALING", "Error disconnecting session", e);
    }
  }
}
