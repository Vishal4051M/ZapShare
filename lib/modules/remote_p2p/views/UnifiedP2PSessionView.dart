import 'dart:io' show Platform;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:saf_util/saf_util.dart';
import '../controllers/RemoteP2PController.dart';
import '../models/P2PSessionModel.dart';
import '../models/RemoteMessageModel.dart';
import 'AvatarSelectionDialog.dart';

class UnifiedP2PSessionView extends StatefulWidget {
  final P2PConnectionMode initialMode;
  const UnifiedP2PSessionView({super.key, required this.initialMode});

  @override
  State<UnifiedP2PSessionView> createState() => _UnifiedP2PSessionViewState();
}

class _UnifiedP2PSessionViewState extends State<UnifiedP2PSessionView> {
  final RemoteP2PController _controller = RemoteP2PController();
  final TextEditingController _messageTextController = TextEditingController();
  final TextEditingController _roomCodeInputController =
      TextEditingController();

  bool _isAudioSharing = false;
  bool _isScreenSharing = false;

  @override
  void initState() {
    super.initState();
    _controller.initialize();
  }

  @override
  void dispose() {
    _controller.disconnect();
    _messageTextController.dispose();
    _roomCodeInputController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F0F1A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF141424),
        title: const Text(
          "P2P Remote Sharing",
          style: TextStyle(color: Colors.white),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings, color: Colors.white70),
            onPressed: _showAvatarSettings,
          ),
        ],
      ),
      body: StreamBuilder<P2PSessionModel?>(
        stream: _controller.stateStream,
        initialData: _controller.activeSession,
        builder: (context, snapshot) {
          final session = snapshot.data;
          if (session == null) {
            return _buildPairingSetup();
          }

          if (session.connectionState == P2PConnectionState.connecting) {
            return _buildConnectingState(session);
          }

          return _buildActiveSession(session);
        },
      ),
    );
  }

  // Setup / Pairing UI

  Widget _buildPairingSetup() {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.leak_add, size: 72, color: Color(0xFF34D399)),
            const SizedBox(height: 16),
            const Text(
              "Cloud Share",
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              "Send files and chat with devices across the internet directly.",
              textAlign: TextAlign.center,
              style: TextStyle(color: Color(0xFFA0A0C0), fontSize: 13),
            ),
            const SizedBox(height: 32),
            ElevatedButton.icon(
              onPressed: () async {
                await _controller.hostRoom();
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF34D399),
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(
                  horizontal: 32,
                  vertical: 16,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
              icon: const Icon(Icons.wifi_tethering),
              label: const Text(
                "Host a Room",
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            const SizedBox(height: 16),
            const Text("or", style: TextStyle(color: Colors.white30)),
            const SizedBox(height: 16),
            Container(
              decoration: BoxDecoration(
                color: const Color(0xFF141424),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0xFF27273F)),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _roomCodeInputController,
                      keyboardType: TextInputType.number,
                      style: const TextStyle(color: Colors.white),
                      decoration: const InputDecoration(
                        hintText: "Enter 8-Digit Room Code",
                        hintStyle: TextStyle(color: Colors.white30),
                        border: InputBorder.none,
                      ),
                    ),
                  ),
                  ElevatedButton(
                    onPressed: () async {
                      final code = _roomCodeInputController.text.trim();
                      if (code.length == 8) {
                        final success = await _controller.joinRoom(code);
                        if (!success) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text(
                                "Failed to join room. Verify the code.",
                              ),
                            ),
                          );
                        }
                      }
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF27273F),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: const Text("Join"),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildConnectingState(P2PSessionModel session) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const CircularProgressIndicator(color: Color(0xFF34D399)),
          const SizedBox(height: 24),
          Text(
            "Room Code: ${session.roomId}",
            style: const TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            "Share this code with your peer to establish connection",
            style: TextStyle(color: Colors.white54),
          ),
          const SizedBox(height: 48),
          ElevatedButton(
            onPressed: () => _controller.disconnect(),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            child: const Text("Cancel / Leave"),
          ),
        ],
      ),
    );
  }

  // Connected Active Interface

  Widget _buildActiveSession(P2PSessionModel session) {
    return Column(
      children: [
        // Connection Info Panel
        Container(
          color: const Color(0xFF141424),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              _buildAvatarWidget(session.peerAvatar, session.peerAvatarType),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      session.peerName,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      session.connectionState == P2PConnectionState.reconnecting
                          ? "Reconnecting..."
                          : "Connected",
                      style: TextStyle(
                        color: session.connectionState == P2PConnectionState.reconnecting
                            ? Colors.orangeAccent
                            : const Color(0xFF34D399),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: Icon(
                  Icons.mic,
                  color: _isAudioSharing ? Colors.green : Colors.white54,
                ),
                onPressed: _toggleAudio,
              ),
              IconButton(
                icon: Icon(
                  Icons.screen_share,
                  color: _isScreenSharing ? Colors.green : Colors.white54,
                ),
                onPressed: _toggleScreen,
              ),
            ],
          ),
        ),
        // Unified Message List
        Expanded(
          child: StreamBuilder<List<RemoteMessageModel>>(
            stream: _controller.messageStream,
            initialData: _controller.messages,
            builder: (context, snapshot) {
              final msgs = snapshot.data ?? [];
              return ListView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: msgs.length,
                itemBuilder: (context, index) {
                  final msg = msgs[index];
                  final isMe = msg.senderId != session.peerId;
                  return _buildMessageBubble(msg, isMe);
                },
              );
            },
          ),
        ),
        // Input Control Bar
        _buildInputControlBar(),
      ],
    );
  }

  Widget _buildMessageBubble(RemoteMessageModel msg, bool isMe) {
    Widget contentWidget;
    switch (msg.type) {
      case RemoteMessageType.emoji:
        contentWidget = Text(msg.content, style: const TextStyle(fontSize: 48));
        break;
      case RemoteMessageType.fileHeader:
        final parts = msg.content.split('|');
        final name = parts[0];
        final size = parts.length > 1 ? double.tryParse(parts[1]) ?? 0.0 : 0.0;
        contentWidget = Container(
          width: 240,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xFF27273F),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              const Icon(
                Icons.insert_drive_file,
                color: Color(0xFF34D399),
                size: 36,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      "${(size / (1024 * 1024)).toStringAsFixed(2)} MB",
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
        break;
      case RemoteMessageType.fileAck:
        contentWidget = Text(
          msg.content,
          style: const TextStyle(
            color: Colors.greenAccent,
            fontSize: 12,
            fontStyle: FontStyle.italic,
          ),
        );
        break;
      default:
        contentWidget = Text(
          msg.content,
          style: const TextStyle(color: Colors.white, fontSize: 14),
        );
    }

    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4.0),
        child: Row(
          mainAxisAlignment:
              isMe ? MainAxisAlignment.end : MainAxisAlignment.start,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!isMe) ...[
              _buildAvatarWidget(
                msg.senderAvatar,
                msg.senderAvatarType,
                radius: 16,
              ),
              const SizedBox(width: 8),
            ],
            Container(
              padding:
                  msg.type == RemoteMessageType.emoji
                      ? EdgeInsets.zero
                      : const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 10,
                      ),
              decoration:
                  msg.type == RemoteMessageType.emoji ||
                          msg.type == RemoteMessageType.fileHeader
                      ? null
                      : BoxDecoration(
                        color:
                            isMe
                                ? const Color(0xFF3E3E6E)
                                : const Color(0xFF1D1D2C),
                        borderRadius: BorderRadius.circular(16),
                      ),
              child: contentWidget,
            ),
            if (isMe) ...[
              const SizedBox(width: 8),
              _buildAvatarWidget(
                msg.senderAvatar,
                msg.senderAvatarType,
                radius: 16,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildInputControlBar() {
    return Container(
      color: const Color(0xFF141424),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.attach_file, color: Color(0xFF34D399)),
            onPressed: _pickAndSendFile,
          ),
          IconButton(
            icon: const Icon(Icons.emoji_emotions, color: Colors.amberAccent),
            onPressed: _showEmojiDrawer,
          ),
          Expanded(
            child: TextField(
              controller: _messageTextController,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                hintText: "Type a message...",
                hintStyle: TextStyle(color: Colors.white30),
                border: InputBorder.none,
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.send, color: Color(0xFF34D399)),
            onPressed: () {
              final text = _messageTextController.text.trim();
              if (text.isNotEmpty) {
                _controller.sendTextMessage(text);
                _messageTextController.clear();
              }
            },
          ),
        ],
      ),
    );
  }

  Widget _buildAvatarWidget(String avatar, String type, {double radius = 20}) {
    if (type == 'image' && avatar.startsWith('http')) {
      return CircleAvatar(
        radius: radius,
        backgroundImage: NetworkImage(avatar),
      );
    }
    return CircleAvatar(
      radius: radius,
      backgroundColor: const Color(0xFF27273F),
      child: Text(
        avatar.isNotEmpty ? avatar : '👤',
        style: TextStyle(fontSize: radius * 1.1),
      ),
    );
  }

  // Toggles and Options triggers

  void _toggleAudio() {
    setState(() {
      _isAudioSharing = !_isAudioSharing;
    });
    _controller.toggleAudioShare(_isAudioSharing);
  }

  void _toggleScreen() {
    setState(() {
      _isScreenSharing = !_isScreenSharing;
    });
    _controller.toggleScreenShare(_isScreenSharing);
  }

  void _pickAndSendFile() async {
    try {
      if (Platform.isAndroid) {
        final safUtil = SafUtil();
        final result = await safUtil.pickFiles(multiple: false);
        if (result != null && result.isNotEmpty) {
          final docFile = result.first;
          int size = 0;
          try {
            final sizeResult = await const MethodChannel('zapshare.saf')
                .invokeMethod<int>('getFileSize', {'uri': docFile.uri});
            size = sizeResult ?? 0;
          } catch (e) {
            print("Error getting size: $e");
          }
          await _controller.sendSharedFile(
            filePath: docFile.uri,
            name: docFile.name,
            size: size,
          );
        }
      } else {
        final result = await FilePicker.platform.pickFiles(withData: false);
        if (result != null) {
          final file = result.files.single;
          if (file.path != null || file.bytes != null) {
            await _controller.sendSharedFile(
              filePath: file.path,
              fileBytes: file.bytes,
              name: file.name,
              size: file.size,
            );
          }
        }
      }
    } catch (e) {
      print("File picking error: $e");
    }
  }

  void _showEmojiDrawer() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF141424),
      builder: (context) {
        final emojis = ['😀', '🔥', '💖', '👋', '🎉', '👍', '💡', '💯'];
        return GridView.builder(
          padding: const EdgeInsets.all(16),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 4,
          ),
          itemCount: emojis.length,
          itemBuilder: (context, index) {
            final emo = emojis[index];
            return InkWell(
              onTap: () {
                _controller.sendEmojiMessage(emo);
                Navigator.pop(context);
              },
              child: Center(
                child: Text(emo, style: const TextStyle(fontSize: 36)),
              ),
            );
          },
        );
      },
    );
  }

  void _showAvatarSettings() {
    showDialog(
      context: context,
      builder: (context) {
        return AvatarSelectionDialog(
          currentMode: _controller.avatarMode,
          currentEmoji: _controller.customEmoji,
          googlePhotoUrl: _controller.currentUser?.photoUrl,
          onSave: (mode, emoji) {
            _controller.saveAvatarSettings(mode, emoji);
          },
        );
      },
    );
  }
}
