import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:zap_share/blocs/navigation/smooth_page_route.dart';
import '../../../Constants/AppColors.dart';
import '../../../Constants/AppStyles.dart';
import '../../../services/firebase_service.dart';
import '../../../widgets/CustomAvatarWidget.dart';

class RemoteHistoryView extends StatefulWidget {
  const RemoteHistoryView({super.key});

  @override
  State<RemoteHistoryView> createState() => _RemoteHistoryViewState();
}

class _RemoteHistoryViewState extends State<RemoteHistoryView> {
  bool _isLoading = false;
  List<Map<String, dynamic>> _clipboardItems = [];
  Map<String, dynamic>? _selectedFriend;
  late final Stream<List<Map<String, dynamic>>> _friendsStream;

  @override
  void initState() {
    super.initState();
    _friendsStream = FirebaseService().getFriendsStream();
    _loadHistory();
  }

  Future<void> _loadHistory() async {
    setState(() => _isLoading = true);
    try {
      final history = await FirebaseService().fetchClipboardHistory();
      setState(() {
        _clipboardItems = history;
        _isLoading = false;
      });
    } catch (e) {
      setState(() => _isLoading = false);
      print("Error loading history: $e");
    }
  }

  void _copyToClipboard(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    HapticFeedback.lightImpact();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Copied to clipboard',
            style: GoogleFonts.outfit(
              color: Colors.black,
              fontWeight: FontWeight.bold,
            ),
          ),
          backgroundColor: AppColors.primary,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Hero(
        tag: 'history_card_container',
        createRectTween:
            (begin, end) => SmoothRectTween(begin: begin, end: end),
        child: Material(
          color: Colors.transparent,
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildHeader(),
                  const SizedBox(height: 24),
                  Text(
                    "CHOOSE A FRIEND",
                    style: GoogleFonts.outfit(
                      color: AppColors.textSecondary,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.5,
                    ),
                  ),
                  const SizedBox(height: 12),
                  _buildFriendsRow(),
                  const SizedBox(height: 24),
                  Expanded(
                    child:
                        _selectedFriend == null
                            ? _buildNoFriendSelectedState()
                            : _buildChatHistorySection(),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFriendsRow() {
    return SizedBox(
      height: 80,
      child: StreamBuilder<List<Map<String, dynamic>>>(
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
            return Container(
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                color: AppColors.cardBackground,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Text(
                "Add friends in Send screen to start chatting!",
                style: GoogleFonts.outfit(
                  color: AppColors.textSecondary,
                  fontSize: 13,
                ),
              ),
            );
          }
          return ListView.builder(
            scrollDirection: Axis.horizontal,
            physics: const BouncingScrollPhysics(),
            itemCount: friends.length,
            itemBuilder: (context, index) {
              final friend = friends[index];
              final isSelected = _selectedFriend?['uid'] == friend['uid'];
              return Padding(
                padding: const EdgeInsets.only(right: 16.0),
                child: GestureDetector(
                  onTap: () {
                    setState(() {
                      _selectedFriend = friend;
                    });
                    HapticFeedback.lightImpact();
                  },
                  child: Column(
                    children: [
                      Container(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                            color:
                                isSelected
                                    ? AppColors.primary
                                    : Colors.transparent,
                            width: 2,
                          ),
                        ),
                        padding: const EdgeInsets.all(2),
                        child: CustomAvatarWidget(
                          avatarId: friend['avatarUrl'] ?? 'face_1',
                          size: 48,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        friend['username'] ?? 'Friend',
                        style: GoogleFonts.outfit(
                          color:
                              isSelected ? AppColors.primary : Colors.white70,
                          fontSize: 12,
                          fontWeight:
                              isSelected ? FontWeight.bold : FontWeight.normal,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildNoFriendSelectedState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.chat_bubble_outline_rounded,
            size: 64,
            color: Colors.white24,
          ),
          const SizedBox(height: 16),
          Text(
            "Select a friend to view chats & shared history",
            style: GoogleFonts.outfit(color: AppColors.textMuted, fontSize: 15),
          ),
        ],
      ),
    );
  }

  Widget _buildChatHistorySection() {
    if (_isLoading) {
      return const Center(
        child: CircularProgressIndicator(color: AppColors.primary),
      );
    }
    if (_clipboardItems.isEmpty) {
      return Center(
        child: Text(
          "No logs with ${_selectedFriend?['username']}",
          style: GoogleFonts.outfit(color: AppColors.textMuted),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              "Exchanged with ${_selectedFriend?['username']}",
              style: GoogleFonts.outfit(
                color: Colors.white54,
                fontSize: 12,
                fontWeight: FontWeight.bold,
              ),
            ),
            IconButton(
              icon: const Icon(
                Icons.refresh_rounded,
                color: Colors.white38,
                size: 18,
              ),
              onPressed: _loadHistory,
            ),
          ],
        ),
        Expanded(
          child: RefreshIndicator(
            color: AppColors.primary,
            backgroundColor: AppColors.cardBackground,
            onRefresh: _loadHistory,
            child: ListView.builder(
              physics: const BouncingScrollPhysics(),
              itemCount: _clipboardItems.length,
              itemBuilder: (context, index) {
                final item = _clipboardItems[index];
                final content = item['content'] as String;
                final createdAt = item['created_at'].toString();
                final time = DateTime.tryParse(createdAt)?.toLocal();
                final timeLabel =
                    time != null
                        ? "${time.hour}:${time.minute.toString().padLeft(2, '0')}"
                        : "";

                final isMe = index % 2 == 0;
                return Align(
                  alignment:
                      isMe ? Alignment.centerRight : Alignment.centerLeft,
                  child: Container(
                    margin: const EdgeInsets.symmetric(vertical: 6),
                    padding: const EdgeInsets.all(12),
                    constraints: BoxConstraints(
                      maxWidth: MediaQuery.of(context).size.width * 0.7,
                    ),
                    decoration: BoxDecoration(
                      color:
                          isMe ? AppColors.primary : AppColors.cardBackground,
                      borderRadius: BorderRadius.only(
                        topLeft: const Radius.circular(16),
                        topRight: const Radius.circular(16),
                        bottomLeft:
                            isMe ? const Radius.circular(16) : Radius.zero,
                        bottomRight:
                            isMe ? Radius.zero : const Radius.circular(16),
                      ),
                      border: Border.all(
                        color:
                            isMe
                                ? Colors.transparent
                                : Colors.white.withOpacity(0.05),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          content,
                          style: GoogleFonts.outfit(
                            color: isMe ? Colors.black : Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              timeLabel,
                              style: GoogleFonts.robotoMono(
                                color: isMe ? Colors.black54 : Colors.white38,
                                fontSize: 9,
                              ),
                            ),
                            const SizedBox(width: 6),
                            InkWell(
                              onTap: () => _copyToClipboard(content),
                              child: Icon(
                                Icons.copy_rounded,
                                color: isMe ? Colors.black54 : Colors.white38,
                                size: 12,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildHeader() {
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
          "Cloud History",
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
}
