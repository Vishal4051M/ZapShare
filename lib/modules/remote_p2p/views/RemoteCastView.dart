import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zap_share/blocs/navigation/smooth_page_route.dart';
import '../../../Constants/AppColors.dart';
import '../../../services/firebase_service.dart';
import '../../../widgets/CustomAvatarWidget.dart';
import '../controllers/RemoteP2PController.dart';
import '../models/P2PSessionModel.dart';

class RemoteCastView extends StatefulWidget {
  final String? initialRoomId;
  final String? castMode;
  const RemoteCastView({super.key, this.initialRoomId, this.castMode});

  @override
  State<RemoteCastView> createState() => _RemoteCastViewState();
}

class _RemoteCastViewState extends State<RemoteCastView> {
  final RemoteP2PController _controller = RemoteP2PController();
  final TextEditingController _roomCodeController = TextEditingController();
  final RTCVideoRenderer _remoteRenderer = RTCVideoRenderer();
  bool _isAudioSharing = false;
  bool _isScreenSharing = false;
  String? _pendingCastMode;
  bool _isStartingRequestedCast = false;
  bool _isMuted = false;

  late final Stream<List<Map<String, dynamic>>> _friendsStream;

  @override
  void initState() {
    super.initState();
    _controller.initialize();
    _friendsStream = FirebaseService().getFriendsStream();
    _remoteRenderer.initialize();
    if (widget.initialRoomId != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _joinRoomAutomatically(widget.initialRoomId!);
      });
    }
  }

  void _joinRoomAutomatically(String code) async {
    final success = await _controller.joinRoom(code);
    if (!success && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Failed to join cast session automatically."),
        ),
      );
    }
  }

  @override
  void dispose() {
    _controller.disconnect();
    _roomCodeController.dispose();
    _remoteRenderer.dispose();
    super.dispose();
  }

  Future<void> _toggleAudio() async {
    setState(() {
      _isAudioSharing = !_isAudioSharing;
    });
    try {
      await _controller.toggleAudioShare(_isAudioSharing);
    } catch (_) {
      if (mounted) setState(() => _isAudioSharing = !_isAudioSharing);
    }
  }

  Future<void> _toggleScreen() async {
    setState(() {
      _isScreenSharing = !_isScreenSharing;
    });
    try {
      await _controller.toggleScreenShare(_isScreenSharing);
    } catch (_) {
      if (mounted) setState(() => _isScreenSharing = !_isScreenSharing);
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Hero(
        tag: 'remote_cast_card',
        createRectTween:
            (begin, end) => SmoothRectTween(begin: begin, end: end),
        child: Material(
          color: Colors.black,
          child: SafeArea(
            child: OverflowBox(
              minWidth: size.width,
              maxWidth: size.width,
              minHeight: size.height,
              maxHeight: size.height,
              alignment: Alignment.center,
              child: StreamBuilder<P2PSessionModel?>(
                stream: _controller.stateStream,
                initialData: _controller.activeSession,
                builder: (context, snapshot) {
                  final session = snapshot.data;
                  if (session == null) {
                    return _buildSetupView();
                  }
                  if (session.connectionState ==
                      P2PConnectionState.connecting) {
                    return _buildWaitingView(session);
                  }
                  _startRequestedCastWhenConnected();
                  return _buildCastingView(session);
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  double _uiScale(BuildContext context) => 1.0;
  double _scaled(BuildContext context, double value) =>
      value * _uiScale(context);
  EdgeInsets _pagePadding(BuildContext context) =>
      const EdgeInsets.fromLTRB(24, 26, 24, 24);

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

  Widget _buildCard({
    required BuildContext context,
    required String title,
    required String subtitle,
    required IconData icon,
    required Color backgroundColor,
    required Color textColor,
    required Color iconBgColor,
    required Color iconColor,
    bool isMainFeature = false,
    required VoidCallback onTap,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(32),
        gradient:
            isMainFeature
                ? const LinearGradient(
                  colors: [Color(0xFFFFD84D), Color(0xFFF5C400)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                )
                : backgroundColor == const Color(0xFF1C1C1E)
                ? const LinearGradient(
                  colors: [Color(0xFF2C2C2E), Color(0xFF1C1C1E)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                )
                : const LinearGradient(
                  colors: [Color(0xFFF0F0F0), Color(0xFFE5E5E5)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(32),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Align(
                    alignment: Alignment.topLeft,
                    child: Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: iconBgColor,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(icon, color: iconColor, size: 26),
                    ),
                  ),
                  const Spacer(),
                  Text(
                    title,
                    style: GoogleFonts.outfit(
                      color: textColor,
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.5,
                      height: 1.1,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: GoogleFonts.outfit(
                      color: textColor.withOpacity(0.7),
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      height: 1.2,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSetupView() {
    return ListView(
      padding: _pagePadding(context),
      physics: const BouncingScrollPhysics(),
      children: [
        _buildHeader("Cloud Cast"),
        SizedBox(height: _scaled(context, 32)),
        Text(
          "CLOUD CAST OPTIONS",
          style: GoogleFonts.outfit(
            color: Colors.grey[300],
            fontSize: 12,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.2,
          ),
        ),
        SizedBox(height: _scaled(context, 20)),
        LayoutBuilder(
          builder: (context, constraints) {
            final spacing = _scaled(context, 16);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildSquareCardRow(
                  context: context,
                  maxWidth: constraints.maxWidth,
                  spacing: spacing,
                  left: _buildCard(
                    context: context,
                    title: 'Audio Share',
                    subtitle: 'Real-time sync',
                    icon: Icons.waves_rounded,
                    backgroundColor: const Color(0xFFF5C400),
                    textColor: Colors.black,
                    iconBgColor: Colors.black.withOpacity(0.1),
                    iconColor: Colors.black,
                    isMainFeature: true,
                    onTap: () => _showFriendSelectionSheet('audio'),
                  ),
                  right: _buildCard(
                    context: context,
                    title: 'Phone Screen',
                    subtitle: 'Mirror Screen',
                    icon: Icons.screen_share_rounded,
                    backgroundColor: const Color(0xFF1C1C1E),
                    textColor: Colors.white,
                    iconBgColor: Colors.white.withOpacity(0.1),
                    iconColor: const Color(0xFFFFD600),
                    onTap: () => _showFriendSelectionSheet('screen'),
                  ),
                ),
                SizedBox(height: spacing),
                _buildSquareCardRow(
                  context: context,
                  maxWidth: constraints.maxWidth,
                  spacing: spacing,
                  left: _buildCard(
                    context: context,
                    title: 'Video Cast',
                    subtitle: 'Stream movies',
                    icon: Icons.movie_filter_rounded,
                    backgroundColor: const Color(0xFFEDEDED),
                    textColor: const Color(0xFF2C2C2E),
                    iconBgColor: Colors.black.withOpacity(0.08),
                    iconColor: Colors.black,
                    onTap: () => _showFriendSelectionSheet('video'),
                  ),
                  right: const SizedBox(),
                ),
              ],
            );
          },
        ),
      ],
    );
  }

  void _showFriendSelectionSheet(String castMode) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.cardBackground,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        return StreamBuilder<List<Map<String, dynamic>>>(
          stream: _friendsStream,
          initialData: FirebaseService().lastFriendsList,
          builder: (context, snapshot) {
            if (!snapshot.hasData) {
              return const Center(
                child: CircularProgressIndicator(color: AppColors.primary),
              );
            }
            final friends = snapshot.data!;
            if (friends.isEmpty) {
              return Padding(
                padding: const EdgeInsets.all(24.0),
                child: Text(
                  "No friends added yet. Add friends to start casting!",
                  style: GoogleFonts.outfit(color: Colors.white70),
                  textAlign: TextAlign.center,
                ),
              );
            }
            return ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: friends.length,
              itemBuilder: (context, index) {
                final friend = friends[index];
                return ListTile(
                  leading: CustomAvatarWidget(
                    avatarId: friend['avatarUrl'] ?? 'face_1',
                    size: 40,
                  ),
                  title: Text(
                    friend['username'] ?? 'Friend',
                    style: GoogleFonts.outfit(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  subtitle: Text(
                    friend['email'] ?? '',
                    style: GoogleFonts.outfit(color: Colors.white54),
                  ),
                  onTap: () async {
                    Navigator.pop(context);
                    _startRemoteCast(friend['uid'], castMode);
                  },
                );
              },
            );
          },
        );
      },
    );
  }

  void _startRemoteCast(String targetUid, String castMode) async {
    try {
      final roomId = await _controller.hostRoom();
      final prefs = await SharedPreferences.getInstance();
      final senderName = prefs.getString('device_name') ?? 'ZapShare User';
      final senderAvatar =
          (await CustomAvatarWidget.getEffectiveLocalAvatar()) ?? 'face_1';
      final senderEmail = FirebaseService().currentUser?.email ?? 'Unknown';

      await FirebaseService().sendCastRequest(
        targetUid: targetUid,
        senderName: senderName,
        senderEmail: senderEmail,
        senderAvatar: senderAvatar,
        roomId: roomId,
        castMode: castMode,
      );
      if (mounted) setState(() => _pendingCastMode = castMode);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text("Cast request failed: $e")));
      }
    }
  }

  void _startRequestedCastWhenConnected() {
    if (_pendingCastMode == null || _isStartingRequestedCast) return;
    _isStartingRequestedCast = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final mode = _pendingCastMode;
      _pendingCastMode = null;
      if (mode == 'audio') {
        await _toggleAudio();
      } else if (mode == 'screen') {
        await _toggleScreen();
      }
      _isStartingRequestedCast = false;
    });
  }

  Widget _buildWaitingView(P2PSessionModel session) {
    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildHeader("Hosting Cast"),
          const Spacer(),
          Center(
            child: Column(
              children: [
                _buildPulseRadar(Icons.sensors_rounded),
                const SizedBox(height: 40),
                Text(
                  "Secure cast request sent",
                  style: GoogleFonts.outfit(
                    color: AppColors.textMuted,
                    fontSize: 14,
                    letterSpacing: 0.5,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  "Waiting for your friend to accept the cast request",
                  textAlign: TextAlign.center,
                  style: GoogleFonts.outfit(
                    color: Colors.white60,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
          const Spacer(),
          TextButton(
            onPressed: () => _controller.disconnect(),
            style: TextButton.styleFrom(foregroundColor: AppColors.error),
            child: const Text("Cancel & Stop Hosting"),
          ),
        ],
      ),
    );
  }

  void _toggleMute() {
    setState(() {
      _isMuted = !_isMuted;
    });
    if (_controller.remoteStream != null) {
      for (var track in _controller.remoteStream!.getAudioTracks()) {
        track.enabled = !_isMuted;
      }
    }
  }

  Widget _buildCastingView(P2PSessionModel session) {
    final bool isReceiver = widget.initialRoomId != null;

    if (isReceiver) {
      final hasStream = _controller.remoteStream != null;
      if (hasStream) {
        _remoteRenderer.srcObject = _controller.remoteStream;
      }

      return Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildHeader("Received Cast"),
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
                    backgroundColor: AppColors.primary.withOpacity(0.1),
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
                          "Casting to you",
                          style: GoogleFonts.outfit(
                            color: AppColors.primary,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: Icon(
                      _isMuted
                          ? Icons.volume_off_rounded
                          : Icons.volume_up_rounded,
                      color: _isMuted ? Colors.redAccent : AppColors.primary,
                    ),
                    onPressed: _toggleMute,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.black,
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: Colors.white10),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(24),
                  child:
                      hasStream
                          ? RTCVideoView(
                            _remoteRenderer,
                            objectFit:
                                RTCVideoViewObjectFit
                                    .RTCVideoViewObjectFitContain,
                          )
                          : Center(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const CircularProgressIndicator(
                                  valueColor: AlwaysStoppedAnimation<Color>(
                                    AppColors.primary,
                                  ),
                                ),
                                const SizedBox(height: 16),
                                Text(
                                  "Waiting for stream...",
                                  style: GoogleFonts.outfit(
                                    color: Colors.white70,
                                    fontSize: 15,
                                  ),
                                ),
                              ],
                            ),
                          ),
                ),
              ),
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: () => _controller.disconnect(),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.error,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
              child: const Text("Disconnect"),
            ),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildHeader("Active Cast"),
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
                  backgroundColor: AppColors.primary.withOpacity(0.1),
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
                        "Connected",
                        style: GoogleFonts.outfit(
                          color: AppColors.primary,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 48),
          _buildCastControlTile(
            title: "Screen Mirroring",
            description: "Share your screen live over P2P",
            icon: Icons.screen_share_rounded,
            isActive: _isScreenSharing,
            onTap: _toggleScreen,
          ),
          const SizedBox(height: 20),
          _buildCastControlTile(
            title: "Audio Share",
            description: "Stream system audio over P2P",
            icon: Icons.volume_up_rounded,
            isActive: _isAudioSharing,
            onTap: _toggleAudio,
          ),
          const Spacer(),
          ElevatedButton(
            onPressed: () => _controller.disconnect(),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.error,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              padding: const EdgeInsets.symmetric(vertical: 16),
            ),
            child: const Text("Stop Casting"),
          ),
        ],
      ),
    );
  }

  Widget _buildCastControlTile({
    required String title,
    required String description,
    required IconData icon,
    required bool isActive,
    required VoidCallback onTap,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.cardBackground,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: isActive ? AppColors.primary.withOpacity(0.2) : Colors.white10,
        ),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        leading: Icon(
          icon,
          color: isActive ? AppColors.primary : Colors.white60,
          size: 28,
        ),
        title: Text(
          title,
          style: GoogleFonts.outfit(
            color: Colors.white,
            fontWeight: FontWeight.bold,
          ),
        ),
        subtitle: Text(
          description,
          style: GoogleFonts.outfit(color: AppColors.textMuted, fontSize: 12),
        ),
        trailing: Switch(
          value: isActive,
          activeColor: AppColors.primary,
          onChanged: (_) => onTap(),
        ),
      ),
    );
  }

  Widget _buildHeader(String title) {
    return Row(
      children: [
        Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: AppColors.cardBackground,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white.withOpacity(0.05)),
          ),
          child: IconButton(
            icon: const Icon(
              Icons.arrow_back_ios_new_rounded,
              color: Colors.white,
              size: 20,
            ),
            onPressed: () => Navigator.pop(context),
          ),
        ),
        const SizedBox(width: 16),
        Text(
          title,
          style: GoogleFonts.outfit(
            color: Colors.white,
            fontSize: 26,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.5,
          ),
        ),
      ],
    );
  }

  Widget _buildPulseRadar(IconData icon) {
    return Container(
      width: 140,
      height: 140,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: AppColors.primary.withOpacity(0.05),
        border: Border.all(color: AppColors.primary.withOpacity(0.2), width: 2),
      ),
      child: Center(
        child: Container(
          width: 90,
          height: 90,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: AppColors.primary.withOpacity(0.1),
          ),
          child: Center(child: Icon(icon, color: AppColors.primary, size: 36)),
        ),
      ),
    );
  }
}
