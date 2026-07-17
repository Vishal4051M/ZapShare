import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:file_picker/file_picker.dart';
import 'package:saf_util/saf_util.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zap_share/blocs/navigation/smooth_page_route.dart';
import '../../../widgets/CustomAvatarWidget.dart';
import '../../../widgets/SearchPulseWidget.dart';
import '../../../Constants/AppColors.dart';
import '../../../services/firebase_service.dart';
import '../controllers/RemoteP2PController.dart';
import '../models/P2PSessionModel.dart';
import '../models/RemoteMessageModel.dart';

class RemoteSendView extends StatefulWidget {
  final List<PlatformFile>? initialFiles;

  const RemoteSendView({super.key, this.initialFiles});

  @override
  State<RemoteSendView> createState() => _RemoteSendViewState();
}

class _RemoteSendViewState extends State<RemoteSendView> {
  final RemoteP2PController _controller = RemoteP2PController();
  final TextEditingController _recipientController = TextEditingController();
  List<PlatformFile> _selectedFiles = [];
  bool _isSending = false;
  bool _isCurrentlySendingFiles = false;
  // A connected-state update can rebuild this view several times before the
  // post-frame callback runs.  Keep the automatic send a one-shot action.
  bool _hasScheduledSelectedTransfer = false;
  String _customAvatar = 'face_1';
  late final Stream<List<Map<String, dynamic>>> _friendsStream;
  late final Stream<List<Map<String, dynamic>>> _friendRequestsStream;

  @override
  void initState() {
    super.initState();
    _controller.initialize();
    _friendsStream = FirebaseService().getFriendsStream();
    _friendRequestsStream = FirebaseService().getIncomingFriendRequestsStream();
    if (widget.initialFiles != null) {
      _selectedFiles = List<PlatformFile>.from(widget.initialFiles!);
      _resolveInitialFileSizes();
    }
    CustomAvatarWidget.getEffectiveLocalAvatar().then((avatar) {
      if (mounted && avatar != null) {
        setState(() {
          _customAvatar = avatar;
        });
      }
    });
  }

  Future<void> _resolveInitialFileSizes() async {
    if (!Platform.isAndroid) return;
    bool updated = false;
    final List<PlatformFile> updatedFiles = [];
    for (final file in _selectedFiles) {
      if (file.size == 0 &&
          file.path != null &&
          file.path!.startsWith('content://')) {
        int size = 0;
        try {
          final sizeResult = await const MethodChannel(
            'zapshare.saf',
          ).invokeMethod<int>('getFileSize', {'uri': file.path});
          size = sizeResult ?? 0;
        } catch (e) {
          print("Error getting size for initial file: $e");
        }
        updatedFiles.add(
          PlatformFile(
            path: file.path,
            name: file.name,
            size: size,
            bytes: file.bytes,
            readStream: file.readStream,
          ),
        );
        updated = true;
      } else {
        updatedFiles.add(file);
      }
    }
    if (updated && mounted) {
      setState(() {
        _selectedFiles = updatedFiles;
      });
    }
  }

  @override
  void dispose() {
    _controller.disconnect();
    _recipientController.dispose();
    super.dispose();
  }

  void _pickFiles() async {
    try {
      if (Platform.isAndroid) {
        final safUtil = SafUtil();
        final result = await safUtil.pickFiles(multiple: true);
        if (result != null && result.isNotEmpty) {
          final List<PlatformFile> pickedFiles = [];
          for (final docFile in result) {
            int size = 0;
            try {
              final sizeResult = await const MethodChannel(
                'zapshare.saf',
              ).invokeMethod<int>('getFileSize', {'uri': docFile.uri});
              size = sizeResult ?? 0;
            } catch (e) {
              print("Error getting size: $e");
            }
            pickedFiles.add(
              PlatformFile(path: docFile.uri, name: docFile.name, size: size),
            );
          }
          setState(() {
            _selectedFiles = pickedFiles;
            _hasScheduledSelectedTransfer = false;
          });
        }
      } else {
        final result = await FilePicker.platform.pickFiles(allowMultiple: true);
        if (result != null) {
          setState(() {
            _selectedFiles = result.files;
            _hasScheduledSelectedTransfer = false;
          });
        }
      }
    } catch (e) {
      print("File picking error: $e");
    }
  }

  void _sendFiles() async {
    if (_selectedFiles.isEmpty || _isCurrentlySendingFiles) return;
    _isCurrentlySendingFiles = true;

    final filesToSend = List<PlatformFile>.from(_selectedFiles);
    setState(() {
      _selectedFiles.clear();
    });

    try {
      for (final file in filesToSend) {
        if (file.path != null || file.bytes != null) {
          await _controller.sendSharedFile(
            filePath: file.path,
            fileBytes: file.bytes,
            name: file.name,
            size: file.size,
          );
        }
      }
    } catch (e) {
      print("Error sending files: $e");
    } finally {
      _isCurrentlySendingFiles = false;
    }
  }

  void _handleSend() async {
    final recipient = _recipientController.text.trim().toLowerCase();
    if (recipient.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Please enter a recipient's Gmail or Username"),
        ),
      );
      return;
    }
    if (_selectedFiles.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Please select files first")),
      );
      return;
    }

    setState(() => _isSending = true);

    try {
      // 1. Resolve identifier to recipient's UID
      final targetUid = await FirebaseService().getUidFromUsernameOrEmail(
        recipient,
      );
      if (targetUid == null) {
        setState(() => _isSending = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("Recipient not found! Check username/email."),
          ),
        );
        return;
      }

      // Check if recipient is a friend
      final isFriend = await FirebaseService().isFriend(targetUid);
      if (!isFriend) {
        setState(() => _isSending = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              "You can only send files to friends. Add them as a friend first!",
            ),
            backgroundColor: Colors.redAccent,
          ),
        );
        return;
      }

      // 2. Start hosting the room (gets code/roomId)
      final roomId = await _controller.hostRoom();

      // 3. Write transfer request to recipient's node
      final prefs = await SharedPreferences.getInstance();
      final senderName = prefs.getString('device_name') ?? 'ZapShare User';
      final senderAvatar =
          (await CustomAvatarWidget.getEffectiveLocalAvatar()) ?? 'face_1';
      final senderEmail = FirebaseService().currentUser?.email ?? 'Unknown';

      await FirebaseService().sendTransferRequest(
        targetUid: targetUid,
        senderName: senderName,
        senderEmail: senderEmail,
        senderAvatar: senderAvatar,
        roomId: roomId,
        fileNames: _selectedFiles.map((f) => f.name).toList(),
        fileSize: _selectedFiles.fold<int>(0, (sum, f) => sum + f.size),
      );

      // Show confirmation dialog so user knows request is sent, especially if receiver is offline
      if (mounted) {
        showDialog(
          context: context,
          builder:
              (context) => AlertDialog(
                backgroundColor: const Color(0xFF1C1C1E),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(24),
                ),
                title: Text(
                  "Transfer Request Sent",
                  style: GoogleFonts.outfit(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                content: Text(
                  "The transfer request has been successfully sent to the recipient. If they are currently offline, the transfer will start as soon as they open the app and accept.",
                  style: GoogleFonts.outfit(
                    color: Colors.white70,
                    fontSize: 14,
                  ),
                ),
                actions: [
                  ElevatedButton(
                    onPressed: () => Navigator.pop(context),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFFFD600),
                      foregroundColor: Colors.black,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: Text(
                      "Got It",
                      style: GoogleFonts.outfit(fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
        );
      }

      // Now we wait for receiver to accept (P2P session will automatically connect)
      setState(() => _isSending = false);
    } catch (e) {
      setState(() => _isSending = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text("Send failed: $e")));
    }
  }

  void _showAddFriendDialog() {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder:
          (context) => AlertDialog(
            backgroundColor: const Color(0xFF1C1C1E),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(24),
            ),
            title: Text(
              "Add Friend",
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
                  "Enter your friend's Username or Gmail to add them.",
                  style: GoogleFonts.outfit(
                    color: Colors.white70,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 16),
                Container(
                  decoration: BoxDecoration(
                    color: Colors.black45,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: TextField(
                    controller: controller,
                    style: GoogleFonts.outfit(color: Colors.white),
                    decoration: InputDecoration(
                      hintText: "Username or Email",
                      hintStyle: GoogleFonts.outfit(color: Colors.white38),
                      border: InputBorder.none,
                    ),
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(
                  "Cancel",
                  style: GoogleFonts.outfit(color: Colors.white54),
                ),
              ),
              ElevatedButton(
                onPressed: () async {
                  final identifier = controller.text.trim();
                  if (identifier.isEmpty) return;

                  final messenger = ScaffoldMessenger.of(context);
                  Navigator.pop(context);
                  try {
                    await FirebaseService().addFriend(identifier);
                    messenger.showSnackBar(
                      const SnackBar(
                        content: Text("Friend request sent successfully!"),
                        backgroundColor: Colors.green,
                      ),
                    );
                  } catch (e) {
                    messenger.showSnackBar(
                      SnackBar(
                        content: Text(
                          "Error adding friend: ${e.toString().replaceAll("Exception: ", "")}",
                        ),
                        backgroundColor: Colors.redAccent,
                      ),
                    );
                  }
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFFFD600),
                  foregroundColor: Colors.black,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: Text(
                  "Add",
                  style: GoogleFonts.outfit(fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
    );
  }

  void _showRemoveFriendConfirmation(String friendUid, String username) {
    showDialog(
      context: context,
      builder:
          (context) => AlertDialog(
            backgroundColor: const Color(0xFF1C1C1E),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(24),
            ),
            title: Text(
              "Remove Friend",
              style: GoogleFonts.outfit(
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
            content: Text(
              "Are you sure you want to remove $username from your friends list?",
              style: GoogleFonts.outfit(color: Colors.white70, fontSize: 14),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(
                  "Cancel",
                  style: GoogleFonts.outfit(color: Colors.white54),
                ),
              ),
              ElevatedButton(
                onPressed: () async {
                  Navigator.pop(context);
                  try {
                    await FirebaseService().removeFriend(friendUid);
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text("Friend removed successfully."),
                          backgroundColor: Colors.grey,
                        ),
                      );
                    }
                  } catch (e) {
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text("Error removing friend: $e"),
                          backgroundColor: Colors.redAccent,
                        ),
                      );
                    }
                  }
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.redAccent,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: Text(
                  "Remove",
                  style: GoogleFonts.outfit(fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;

    return StreamBuilder<P2PSessionModel?>(
      stream: _controller.stateStream,
      initialData: _controller.activeSession,
      builder: (context, snapshot) {
        final session = snapshot.data;

        if (session == null) {
          // Setup / discovery view: Yellow theme with Orbiting Friends
          return Scaffold(
            backgroundColor: const Color(0xFFF5C400),
            resizeToAvoidBottomInset: false,
            body: Hero(
              tag: 'remote_send_card',
              createRectTween:
                  (begin, end) => SmoothRectTween(begin: begin, end: end),
              child: Material(
                type: MaterialType.transparency,
                child: Container(
                  width: size.width,
                  height: size.height,
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [Color(0xFFFFD84D), Color(0xFFF5C400)],
                    ),
                  ),
                  child: OverflowBox(
                    minWidth: size.width,
                    maxWidth: size.width,
                    minHeight: size.height,
                    maxHeight: size.height,
                    alignment: Alignment.center,
                    child: _buildSetupView(),
                  ),
                ),
              ),
            ),
          );
        }

        // Active session / progress / error view: Dark theme
        return Scaffold(
          backgroundColor: Colors.black,
          body: Hero(
            tag: 'remote_send_card',
            createRectTween:
                (begin, end) => SmoothRectTween(begin: begin, end: end),
            child: Material(
              color: Colors.transparent,
              child: SafeArea(
                child: Builder(
                  builder: (context) {
                    if (session.connectionState ==
                        P2PConnectionState.disconnected) {
                      return _buildNATErrorView();
                    }
                    if (session.connectionState ==
                        P2PConnectionState.connecting) {
                      return _buildWaitingView(session);
                    }
                    return _buildSendingProgressView(session);
                  },
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildNATErrorView() {
    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildHeader("Connection Failed", isDark: false),
          const Spacer(),
          Center(
            child: Column(
              children: [
                Container(
                  width: 90,
                  height: 90,
                  decoration: BoxDecoration(
                    color: Colors.redAccent.withOpacity(0.1),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.portable_wifi_off_rounded,
                    color: Colors.redAccent,
                    size: 44,
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  "P2P Connection Failed",
                  style: GoogleFonts.outfit(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 12),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                    "ZapShare operates direct peer-to-peer file transfers. Connection failed, likely due to strict firewall or symmetric NAT networks.",
                    textAlign: TextAlign.center,
                    style: GoogleFonts.outfit(
                      color: Colors.white60,
                      fontSize: 14,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const Spacer(),
          ElevatedButton(
            onPressed: () {
              _controller.disconnect();
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFFFD600),
              foregroundColor: Colors.black,
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
            ),
            child: Text(
              "Go Back",
              style: GoogleFonts.outfit(
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSetupView() {
    final size = MediaQuery.of(context).size;
    final isCompact = size.width < 800;

    if (!isCompact) {
      return Row(
        children: [
          // Left Side: Orbit background & pulsing radar (Yellow Gradient matching mobile)
          Expanded(
            flex: 6,
            child: ClipRect(
              child: Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color(0xFFFFD84D), Color(0xFFF5C400)],
                  ),
                ),
                child: Stack(
                  children: [
                    _buildFriendsOrbitBackground(),
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      child: SafeArea(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 24,
                            vertical: 16,
                          ),
                          child: _buildHeader("Cloud Send", isDark: true),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          // Right Side: Control panel (Files, Recipient, Send button) (Solid Black)
          Expanded(flex: 5, child: _buildDesktopControlPanel()),
        ],
      );
    }

    return Stack(
      children: [
        // Pulse Background & Orbiting Friends
        KeyedSubtree(
          key: const ValueKey('remote_friends_pulse'),
          child: _buildFriendsOrbitBackground(),
        ),

        // Header (isDark = true for yellow background text coloring)
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
              child: _buildHeader("Cloud Send", isDark: true),
            ),
          ),
        ),

        // Bottom Sheet holding file details, recipient, etc.
        _buildBottomSheet(true),
      ],
    );
  }

  Widget _buildDesktopControlPanel() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.black,
        border: Border(left: BorderSide(color: Colors.white.withOpacity(0.05))),
      ),
      child: CustomScrollView(
        slivers: [
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
          ..._buildControlPanelSlivers(),
        ],
      ),
    );
  }

  Widget _buildFileSelector() {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: AppColors.cardBackground,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.white.withOpacity(0.05)),
      ),
      child: Column(
        children: [
          const Icon(
            Icons.insert_drive_file_rounded,
            size: 54,
            color: AppColors.primary,
          ),
          const SizedBox(height: 16),
          Text(
            _selectedFiles.isEmpty
                ? "No files selected"
                : "${_selectedFiles.length} files selected",
            style: GoogleFonts.outfit(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            "Select the files you wish to transfer instantly",
            textAlign: TextAlign.center,
            style: GoogleFonts.outfit(
              color: AppColors.textSecondary,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 20),
          ElevatedButton(
            onPressed: _pickFiles,
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.white.withOpacity(0.08),
              foregroundColor: Colors.white,
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(color: Colors.white.withOpacity(0.1)),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            ),
            child: Text(
              "Choose Files",
              style: GoogleFonts.outfit(fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildWaitingView(P2PSessionModel session) {
    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildHeader("Connecting...", isDark: false),
          const Spacer(),
          Center(
            child: Column(
              children: [
                _buildPulseRadar(),
                const SizedBox(height: 40),
                Text(
                  "Secure invite sent",
                  style: GoogleFonts.outfit(
                    color: AppColors.primary,
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  "Waiting for the receiver to accept the transfer request...",
                  textAlign: TextAlign.center,
                  style: GoogleFonts.outfit(
                    color: AppColors.textSecondary,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
          const Spacer(),
          TextButton(
            onPressed: () => _controller.disconnect(),
            style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
            child: Text(
              "Cancel & Disconnect",
              style: GoogleFonts.outfit(fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSendingProgressView(P2PSessionModel session) {
    // Automatically trigger sending picked files if we are host and just connected
    if (session.connectionState == P2PConnectionState.connected &&
        _selectedFiles.isNotEmpty &&
        !_hasScheduledSelectedTransfer) {
      _hasScheduledSelectedTransfer = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _sendFiles();
      });
    }

    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildHeader(
            session.connectionState == P2PConnectionState.reconnecting
                ? "Reconnecting..."
                : "Sending...",
            isDark: false,
          ),
          const SizedBox(height: 24),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.cardBackground,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white.withOpacity(0.05)),
            ),
            child: Row(
              children: [
                CircleAvatar(
                  backgroundColor: Colors.white.withOpacity(0.08),
                  child: Text(
                    session.peerAvatar.isNotEmpty ? session.peerAvatar : '👤',
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        session.peerName,
                        style: GoogleFonts.outfit(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        "Connected & Transferring",
                        style: GoogleFonts.outfit(
                          color: AppColors.textSecondary,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          Expanded(
            child: StreamBuilder<List<RemoteMessageModel>>(
              stream: _controller.messageStream,
              initialData: _controller.messages,
              builder: (context, snapshot) {
                final msgs = snapshot.data ?? [];
                final fileMsgs =
                    msgs
                        .where(
                          (m) =>
                              m.type == RemoteMessageType.fileHeader ||
                              m.type == RemoteMessageType.fileAck,
                        )
                        .toList();
                if (fileMsgs.isEmpty) {
                  return Center(
                    child: Text(
                      "Preparing transfer...",
                      style: GoogleFonts.outfit(
                        color: AppColors.textSecondary,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  );
                }
                return ListView.builder(
                  itemCount: fileMsgs.length,
                  itemBuilder: (context, index) {
                    final msg = fileMsgs[index];
                    final parts = msg.content.split('|');
                    final name = parts[0];
                    final size =
                        parts.length > 1
                            ? double.tryParse(parts[1]) ?? 0.0
                            : 0.0;
                    final isCompleted = msg.type == RemoteMessageType.fileAck;

                    return Container(
                      margin: const EdgeInsets.only(bottom: 12),
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: AppColors.cardBackground,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color:
                              isCompleted ? Colors.white10 : Colors.transparent,
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            isCompleted
                                ? Icons.check_circle_rounded
                                : Icons.arrow_upward_rounded,
                            color:
                                isCompleted ? Colors.green : AppColors.primary,
                            size: 24,
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: GoogleFonts.outfit(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                Text(
                                  isCompleted
                                      ? "Success"
                                      : "${(msg.progress * 100).toStringAsFixed(0)}% of ${(size / (1024 * 1024)).toStringAsFixed(2)} MB",
                                  style: GoogleFonts.outfit(
                                    color: AppColors.textSecondary,
                                    fontSize: 12,
                                  ),
                                ),
                                if (!isCompleted) ...[
                                  const SizedBox(height: 8),
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(99),
                                    child: LinearProgressIndicator(
                                      value: msg.progress,
                                      minHeight: 6,
                                      backgroundColor: Colors.white10,
                                      valueColor: const AlwaysStoppedAnimation(
                                        AppColors.primary,
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                );
              },
            ),
          ),
          const SizedBox(height: 16),
          ElevatedButton(
            onPressed: () => _controller.disconnect(),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.black,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
            ),
            child: Text(
              "Finish / Disconnect",
              style: GoogleFonts.outfit(fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(String title, {bool isDark = false}) {
    final color = isDark ? Colors.black : Colors.white;
    return Row(
      children: [
        Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color:
                isDark
                    ? Colors.black.withOpacity(0.08)
                    : AppColors.cardBackground,
            shape: BoxShape.circle,
          ),
          child: IconButton(
            icon: Icon(
              Icons.arrow_back_ios_new_rounded,
              color: color,
              size: 20,
            ),
            onPressed: () => Navigator.pop(context),
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Text(
            title,
            style: GoogleFonts.outfit(
              color: color,
              fontSize: 26,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.5,
            ),
          ),
        ),
        if (isDark)
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.08),
              shape: BoxShape.circle,
            ),
            child: IconButton(
              icon: const Icon(
                Icons.person_add_rounded,
                color: Colors.black,
                size: 22,
              ),
              onPressed: _showAddFriendDialog,
            ),
          ),
      ],
    );
  }

  Widget _buildPulseRadar() {
    return Container(
      width: 140,
      height: 140,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.white.withOpacity(0.04),
        border: Border.all(color: Colors.white.withOpacity(0.12), width: 2),
      ),
      child: Center(
        child: Container(
          width: 90,
          height: 90,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.white.withOpacity(0.08),
          ),
          child: const Center(
            child: Icon(
              Icons.wifi_tethering_rounded,
              color: AppColors.primary,
              size: 36,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFriendsOrbitBackground() {
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: _friendsStream,
      initialData: FirebaseService().lastFriendsList,
      builder: (context, snapshot) {
        final friends = snapshot.data ?? [];

        final screenWidth = MediaQuery.of(context).size.width;
        final screenHeight = MediaQuery.of(context).size.height;
        final safeAreaTop = MediaQuery.of(context).padding.top;

        final isCompact = screenWidth < 800;

        // Calculate available size based on layout mode
        final double availableWidth =
            isCompact ? screenWidth : (screenWidth * 6 / 11);
        final double pulseSize = (availableWidth * 0.85).clamp(320.0, 520.0);

        final headerHeight = safeAreaTop + 80;
        final double availableHeight =
            isCompact
                ? (screenHeight - headerHeight - (screenHeight * 0.38))
                : (screenHeight - headerHeight - 40);

        final pulseTop = headerHeight + (availableHeight - pulseSize) / 2;

        final List<Widget> friendNodes = [];
        final int totalCount = friends.length;
        const int maxVisibleFriends = 8;
        final int visibleCount = totalCount.clamp(0, maxVisibleFriends);
        final int overflowCount = totalCount - visibleCount;

        final double deviceScale =
            totalCount <= 4 ? 1.0 : (totalCount <= 6 ? 0.9 : 0.8);
        final double deviceNodeSize = 60.0 * deviceScale;

        final double pulseRadius = pulseSize / 2;
        const double orbitPadding = 24.0;
        final double orbitRadius =
            pulseRadius - (deviceNodeSize / 2) - orbitPadding;
        const double startAngle = -3.14159 / 2; // Start from top

        for (int i = 0; i < visibleCount; i++) {
          final double angle = startAngle + (2 * 3.14159 * i / visibleCount);
          final double offsetX = orbitRadius * cos(angle);
          final double offsetY = orbitRadius * sin(angle);

          friendNodes.add(
            Transform.translate(
              offset: Offset(offsetX, offsetY),
              child: Transform.scale(
                scale: deviceScale,
                child: _buildFriendNode(friends[i]),
              ),
            ),
          );
        }

        // Add overflow indicator if there are more friends - positioned at center
        if (overflowCount > 0) {
          friendNodes.add(
            GestureDetector(
              onTap: () {
                _showAllFriendsDialog(friends);
              },
              child: Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.85),
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white38, width: 1.5),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.3),
                      blurRadius: 8,
                      spreadRadius: 1,
                    ),
                  ],
                ),
                child: Center(
                  child: Text(
                    '+$overflowCount',
                    style: GoogleFonts.outfit(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.5,
                    ),
                  ),
                ),
              ),
            ),
          );
        }

        return Stack(
          alignment: Alignment.center,
          children: [
            // Pulse Effect - Responsive size
            Positioned(
              top: pulseTop,
              left: 0,
              right: 0,
              child: Center(
                child: SizedBox(
                  width: pulseSize,
                  height: pulseSize,
                  child: SearchPulseWidget(
                    key: const ValueKey('remote_pulse_effect'),
                    size: pulseSize,
                    color:
                        Colors
                            .black, // Consistent dark mode style inside yellow
                  ),
                ),
              ),
            ),

            // Centered User Avatar & Friends "Orbit" - same size as pulse
            Positioned(
              top: pulseTop,
              left: 0,
              right: 0,
              child: Center(
                child: SizedBox(
                  width: pulseSize,
                  height: pulseSize,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      // Central user avatar
                      CustomAvatarWidget(
                        avatarId: _customAvatar,
                        size: 60,
                        useBackground: true,
                        showBorder: true,
                        borderColor: const Color(0xFFFFD600).withOpacity(0.5),
                      ),
                      ...friendNodes,
                    ],
                  ),
                ),
              ),
            ),

            // Status label below pulse
            Positioned(
              top: pulseTop + pulseSize + 12,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Text(
                    totalCount == 0
                        ? "Add friends to start cloud sharing"
                        : "Tap a friend's bubble to share files",
                    style: GoogleFonts.outfit(
                      color: Colors.black87,
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildFriendNode(Map<String, dynamic> friend) {
    final String username = friend['username'] ?? 'Friend';
    final String avatarUrl = friend['avatarUrl'] ?? '';
    final String uid = friend['uid'] ?? '';

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () {
          setState(() {
            _recipientController.text = username;
          });
          HapticFeedback.lightImpact();
          if (_selectedFiles.isNotEmpty) {
            _handleSend();
          } else {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                  "Please select files first before sending to a friend.",
                ),
                backgroundColor: Colors.orangeAccent,
              ),
            );
          }
        },
        onLongPress: () {
          _showRemoveFriendConfirmation(uid, username);
        },
        child: Padding(
          padding: const EdgeInsets.all(8.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 60,
                height: 60,
                decoration: BoxDecoration(
                  color: const Color(0xFF1C1C1E),
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.15),
                      blurRadius: 8,
                      offset: const Offset(0, 4),
                    ),
                  ],
                  border: Border.all(
                    color: Colors.white.withOpacity(0.15),
                    width: 1.5,
                  ),
                ),
                child: CustomAvatarWidget(
                  avatarId: avatarUrl,
                  size: 60,
                  useBackground: true,
                ),
              ),
              const SizedBox(height: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.65),
                  borderRadius: BorderRadius.circular(8),
                ),
                constraints: const BoxConstraints(maxWidth: 80),
                child: Text(
                  username,
                  style: GoogleFonts.outfit(
                    color: Colors.white,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showAllFriendsDialog(List<Map<String, dynamic>> friends) {
    showDialog(
      context: context,
      builder:
          (context) => AlertDialog(
            backgroundColor: const Color(0xFF1C1C1E),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(24),
            ),
            title: Text(
              "All Friends",
              style: GoogleFonts.outfit(
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
            content: SizedBox(
              width: double.maxFinite,
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: friends.length,
                itemBuilder: (context, index) {
                  final friend = friends[index];
                  final username = friend['username'] ?? 'Friend';
                  final avatarUrl = friend['avatarUrl'] ?? '';

                  return ListTile(
                    leading: CustomAvatarWidget(avatarId: avatarUrl, size: 40),
                    title: Text(
                      username,
                      style: GoogleFonts.outfit(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    onTap: () {
                      setState(() {
                        _recipientController.text = username;
                      });
                      Navigator.pop(context);
                      if (_selectedFiles.isNotEmpty) {
                        _handleSend();
                      } else {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text(
                              "Please select files first before sending to a friend.",
                            ),
                            backgroundColor: Colors.orangeAccent,
                          ),
                        );
                      }
                    },
                  );
                },
              ),
            ),
          ),
    );
  }

  String _formatSize(int bytes) {
    if (bytes <= 0) return "0 B";
    const suffixes = ["B", "KB", "MB", "GB", "TB"];
    var i = (log(bytes) / log(1024)).floor();
    return "${(bytes / pow(1024, i)).toStringAsFixed(2)} ${suffixes[i]}";
  }

  String _formatTotalSize(List<PlatformFile> files) {
    final total = files.fold<int>(0, (sum, f) => sum + f.size);
    return _formatSize(total);
  }

  Widget _buildBottomSheet(bool isCompact) {
    return DraggableScrollableSheet(
      initialChildSize: 0.38,
      minChildSize: 0.38,
      maxChildSize: 0.85,
      snap: true,
      snapSizes: const [0.38, 0.85],
      builder: (context, scrollController) {
        return Container(
          decoration: BoxDecoration(
            color: Colors.black,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(32)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.5),
                blurRadius: 20,
                offset: const Offset(0, -5),
              ),
            ],
          ),
          child: CustomScrollView(
            controller: scrollController,
            slivers: [
              // Draggable Handle
              SliverToBoxAdapter(
                child: Center(
                  child: Container(
                    margin: const EdgeInsets.only(top: 12, bottom: 20),
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.grey[600],
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ),
              ..._buildControlPanelSlivers(),
            ],
          ),
        );
      },
    );
  }

  List<Widget> _buildControlPanelSlivers() {
    return [
      // File Selector and Details
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildFileSelector(),
              const SizedBox(height: 20),
              Text(
                "RECIPIENT DETAILS",
                style: GoogleFonts.outfit(
                  color: AppColors.textSecondary,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.5,
                ),
              ),
              const SizedBox(height: 8),
              Container(
                decoration: BoxDecoration(
                  color: AppColors.cardBackground,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.white.withOpacity(0.05)),
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 6,
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.alternate_email_rounded,
                      color: AppColors.primary,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: _recipientController,
                        keyboardType: TextInputType.emailAddress,
                        style: GoogleFonts.outfit(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                        decoration: InputDecoration(
                          hintText: "Enter Gmail or Username",
                          hintStyle: GoogleFonts.outfit(color: Colors.white30),
                          border: InputBorder.none,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              // Pending Requests inside bottom sheet
              _buildPendingRequestsSection(),
            ],
          ),
        ),
      ),

      const SliverToBoxAdapter(child: SizedBox(height: 12)),

      // Action button to send files
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: ElevatedButton.icon(
            onPressed:
                (_selectedFiles.isEmpty || _isSending) ? null : _handleSend,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.black,
              disabledBackgroundColor: Colors.white.withOpacity(0.12),
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
            ),
            icon:
                _isSending
                    ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        color: Colors.black,
                        strokeWidth: 2,
                      ),
                    )
                    : const Icon(Icons.send_rounded, size: 22),
            label: Text(
              _isSending ? "Finding Recipient..." : "Send Files Securely",
              style: GoogleFonts.outfit(
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ),
      ),

      const SliverToBoxAdapter(child: SizedBox(height: 20)),

      // Selected Files Details / List Header
      if (_selectedFiles.isNotEmpty)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  "SELECTED FILES (${_selectedFiles.length})",
                  style: GoogleFonts.outfit(
                    color: AppColors.textSecondary,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.5,
                  ),
                ),
                Text(
                  _formatTotalSize(_selectedFiles),
                  style: GoogleFonts.outfit(
                    color: AppColors.primary,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
        ),

      // Selected Files List
      if (_selectedFiles.isNotEmpty)
        SliverList(
          delegate: SliverChildBuilderDelegate((context, index) {
            final file = _selectedFiles[index];
            return Container(
              margin: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.cardBackground,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white.withOpacity(0.05)),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.insert_drive_file_rounded,
                    color: AppColors.primary,
                    size: 24,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          file.name,
                          style: GoogleFonts.outfit(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                            fontSize: 14,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          _formatSize(file.size),
                          style: GoogleFonts.outfit(
                            color: AppColors.textMuted,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(
                      Icons.close_rounded,
                      color: Colors.redAccent,
                      size: 20,
                    ),
                    onPressed: () {
                      setState(() {
                        _selectedFiles.removeAt(index);
                      });
                    },
                  ),
                ],
              ),
            );
          }, childCount: _selectedFiles.length),
        ),

      const SliverToBoxAdapter(child: SizedBox(height: 30)),
    ];
  }

  Widget _buildPendingRequestsSection() {
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: _friendRequestsStream,
      builder: (context, snapshot) {
        if (!snapshot.hasData || snapshot.data!.isEmpty) {
          return const SizedBox.shrink();
        }
        final requests =
            snapshot.data!.where((r) => r['status'] == 'pending').toList();
        if (requests.isEmpty) {
          return const SizedBox.shrink();
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              "PENDING FRIEND REQUESTS",
              style: GoogleFonts.outfit(
                color: AppColors.primary,
                fontSize: 12,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.5,
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 64,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                physics: const BouncingScrollPhysics(),
                itemCount: requests.length,
                itemBuilder: (context, index) {
                  final req = requests[index];
                  final senderUid = req['senderId'] as String;
                  final senderName = req['senderName'] ?? 'Someone';
                  final senderEmail = req['senderEmail'] ?? '';
                  final senderAvatar = req['senderAvatar'] ?? '';

                  return Container(
                    margin: const EdgeInsets.only(right: 12),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.cardBackground,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: Colors.white.withOpacity(0.05)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CustomAvatarWidget(avatarId: senderAvatar, size: 36),
                        const SizedBox(width: 8),
                        Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              senderName,
                              style: GoogleFonts.outfit(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                                fontSize: 13,
                              ),
                            ),
                            if (senderEmail.isNotEmpty)
                              Text(
                                senderEmail,
                                style: GoogleFonts.outfit(
                                  color: AppColors.textMuted,
                                  fontSize: 10,
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(width: 16),
                        IconButton(
                          onPressed: () async {
                            final messenger = ScaffoldMessenger.of(context);
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
                          icon: const Icon(
                            Icons.check_circle_rounded,
                            color: Colors.green,
                            size: 28,
                          ),
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                        ),
                        const SizedBox(width: 10),
                        IconButton(
                          onPressed: () async {
                            await FirebaseService().declineFriendRequest(
                              senderUid,
                            );
                          },
                          icon: const Icon(
                            Icons.cancel_rounded,
                            color: Colors.redAccent,
                            size: 28,
                          ),
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 20),
          ],
        );
      },
    );
  }
}
