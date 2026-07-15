import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../../Constants/AppColors.dart';
import '../../../Constants/AppStyles.dart';
import '../controllers/RemoteP2PController.dart';
import '../models/P2PSessionModel.dart';
import '../models/RemoteMessageModel.dart';

class RemoteReceiveView extends StatefulWidget {
  final String? initialRoomId;
  const RemoteReceiveView({super.key, this.initialRoomId});

  @override
  State<RemoteReceiveView> createState() => _RemoteReceiveViewState();
}

class _RemoteReceiveViewState extends State<RemoteReceiveView> {
  final RemoteP2PController _controller = RemoteP2PController();
  final TextEditingController _roomCodeController = TextEditingController();
  bool _isConnecting = false;

  @override
  void initState() {
    super.initState();
    _controller.initialize();
    if (widget.initialRoomId != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _joinRoomAutomatically(widget.initialRoomId!);
      });
    }
  }

  void _joinRoomAutomatically(String code) async {
    setState(() => _isConnecting = true);
    final success = await _controller.joinRoom(code);
    setState(() => _isConnecting = false);
    if (!success && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Failed to join room automatically.")),
      );
    }
  }

  @override
  void dispose() {
    _controller.disconnect();
    _roomCodeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Hero(
        tag: 'remote_receive_card',
        child: Material(
          color: Colors.transparent,
          child: SafeArea(
            child: StreamBuilder<P2PSessionModel?>(
              stream: _controller.stateStream,
              initialData: _controller.activeSession,
              builder: (context, snapshot) {
                final session = snapshot.data;

                if (session != null && session.connectionState == P2PConnectionState.disconnected) {
                  return _buildNATErrorView();
                }

                if (widget.initialRoomId != null) {
                  if (session == null ||
                      session.connectionState ==
                          P2PConnectionState.connecting ||
                      _isConnecting) {
                    return _buildDirectConnectingView();
                  }
                  return _buildReceivingProgressView(session);
                }

                if (session == null) {
                  return _buildSetupView();
                }
                if (session.connectionState == P2PConnectionState.connecting) {
                  return _buildWaitingView(session);
                }
                return _buildReceivingProgressView(session);
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildNATErrorView() {
    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildHeader("Connection Failed"),
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

  Widget _buildDirectConnectingView() {
    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildHeader("Receiving File"),
          const Spacer(),
          Center(
            child: Column(
              children: [
                _buildPulseRadar(Icons.downloading_rounded),
                const SizedBox(height: 40),
                Text(
                  "Connecting to Sender...",
                  style: GoogleFonts.outfit(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  "Establishing a secure direct transfer connection. Please wait.",
                  textAlign: TextAlign.center,
                  style: GoogleFonts.outfit(
                    color: AppColors.textMuted,
                    fontSize: 14,
                  ),
                ),
              ],
            ),
          ),
          const Spacer(),
          TextButton(
            onPressed: () {
              _controller.disconnect();
              Navigator.pop(context);
            },
            style: TextButton.styleFrom(foregroundColor: AppColors.error),
            child: const Text("Cancel & Disconnect"),
          ),
        ],
      ),
    );
  }

  Widget _buildSetupView() {
    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildHeader("Cloud Receive"),
          const Spacer(),
          Center(
            child: Column(
              children: [
                _buildPulseRadar(Icons.download_rounded),
                const SizedBox(height: 32),
                Text(
                  "Receive Files via Cloud",
                  style: GoogleFonts.outfit(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  "Establish a direct remote session using room codes",
                  textAlign: TextAlign.center,
                  style: GoogleFonts.outfit(
                    color: AppColors.textMuted,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
          const Spacer(),
          ElevatedButton.icon(
            onPressed: () async {
              await _controller.hostRoom();
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.black,
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
            ),
            icon: const Icon(Icons.wifi_tethering_rounded, size: 22),
            label: Text(
              "Create Receive Room",
              style: GoogleFonts.outfit(
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              const Expanded(child: Divider(color: Colors.white10)),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  "or",
                  style: GoogleFonts.outfit(color: Colors.white30),
                ),
              ),
              const Expanded(child: Divider(color: Colors.white10)),
            ],
          ),
          const SizedBox(height: 16),
          Container(
            decoration: BoxDecoration(
              color: AppColors.cardBackground,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white.withOpacity(0.05)),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _roomCodeController,
                    keyboardType: TextInputType.number,
                    style: GoogleFonts.outfit(color: Colors.white),
                    decoration: InputDecoration(
                      hintText: "Enter Sender's Room Code",
                      hintStyle: GoogleFonts.outfit(color: Colors.white30),
                      border: InputBorder.none,
                    ),
                  ),
                ),
                ElevatedButton(
                  onPressed: () async {
                    final code = _roomCodeController.text.trim();
                    if (code.length == 8) {
                      setState(() => _isConnecting = true);
                      final success = await _controller.joinRoom(code);
                      setState(() => _isConnecting = false);
                      if (!success) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text("Failed to join room. Verify code."),
                          ),
                        );
                      }
                    }
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.white.withOpacity(0.08),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child:
                      _isConnecting
                          ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                          : const Text("Join"),
                ),
              ],
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
          _buildHeader("Hosting Room"),
          const Spacer(),
          Center(
            child: Column(
              children: [
                _buildPulseRadar(Icons.wifi_tethering_rounded),
                const SizedBox(height: 40),
                Text(
                  "Waiting for your friend's secure transfer request",
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

  Widget _buildReceivingProgressView(P2PSessionModel session) {
    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildHeader("Receiving..."),
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
                        session.connectionState == P2PConnectionState.reconnecting
                            ? "Reconnecting..."
                            : "Connected",
                        style: GoogleFonts.outfit(
                          color: session.connectionState == P2PConnectionState.reconnecting
                              ? Colors.orangeAccent
                              : AppColors.primary,
                          fontSize: 12,
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
                      "Waiting for incoming files...",
                      style: GoogleFonts.outfit(color: AppColors.textMuted),
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
                              isCompleted
                                  ? AppColors.primary.withOpacity(0.2)
                                  : Colors.white10,
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            isCompleted
                                ? Icons.check_circle_rounded
                                : Icons.arrow_downward_rounded,
                            color:
                                isCompleted
                                    ? AppColors.primary
                                    : Colors.white60,
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
                                    color: AppColors.textMuted,
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
              backgroundColor: AppColors.error,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
            ),
            child: const Text("Finish / Disconnect"),
          ),
        ],
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
        Expanded(
          child: Text(
            title,
            style: GoogleFonts.outfit(
              color: Colors.white,
              fontSize: 26,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.5,
            ),
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
