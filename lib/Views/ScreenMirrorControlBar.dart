import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class ScreenMirrorControlBar extends StatelessWidget {
  final bool showControls;
  final bool isFullscreen;
  final bool remoteInputEnabled;
  final String? inputStatusText;
  final String? senderIp;
  final VoidCallback onDisconnect;
  final VoidCallback onToggleControls;
  final VoidCallback onTextInputDialog;
  final VoidCallback onToggleRemoteInput;
  final Function(String) onSendControl;
  final Color accentColor;

  const ScreenMirrorControlBar({
    super.key,
    required this.showControls,
    required this.isFullscreen,
    required this.remoteInputEnabled,
    required this.inputStatusText,
    required this.senderIp,
    required this.onDisconnect,
    required this.onToggleControls,
    required this.onTextInputDialog,
    required this.onToggleRemoteInput,
    required this.onSendControl,
    required this.accentColor,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // Close / Open Controls buttons
        if (!isFullscreen)
          Positioned(
            top: 16,
            left: 16,
            right: 16,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                if (showControls)
                  _buildGlassBtn(
                    icon: Icons.close_rounded,
                    onTap: onDisconnect,
                    tooltip: 'Close',
                  )
                else
                  const SizedBox.shrink(),
                _buildGlassBtn(
                  icon: showControls
                      ? Icons.grid_view_rounded
                      : Icons.grid_view_outlined,
                  onTap: onToggleControls,
                  highlight: showControls,
                  tooltip: 'Controls',
                ),
              ],
            ),
          ),

        // Bottom Navigation Bar
        if (showControls && senderIp != null && !isFullscreen)
          _buildBottomNavigationBar(),

        // Input Status Pill
        if (inputStatusText != null)
          Positioned(
            top: showControls ? 64 : 16,
            right: 16,
            child: _buildInputStatusPill(),
          ),
      ],
    );
  }

  Widget _buildBottomNavigationBar() {
    return Positioned(
      bottom: 24,
      left: 12,
      right: 12,
      child: Center(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: BackdropFilter(
            filter: ui.ImageFilter.blur(sigmaX: 4, sigmaY: 4),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.05),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Colors.white.withOpacity(0.1)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.1),
                    blurRadius: 10,
                  ),
                ],
              ),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 300),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    Expanded(
                      child: _buildNavBtn(
                        Icons.arrow_back_ios_new_rounded,
                        () => onSendControl('back'),
                      ),
                    ),
                    Expanded(
                      child: _buildNavBtn(
                        Icons.circle_outlined,
                        () => onSendControl('home'),
                      ),
                    ),
                    Expanded(
                      child: _buildNavBtn(
                        Icons.crop_square_rounded,
                        () => onSendControl('recents'),
                      ),
                    ),
                    Expanded(
                      child: _buildNavBtn(
                        Icons.keyboard_rounded,
                        onTextInputDialog,
                        onLongPress: onToggleRemoteInput,
                        highlight: remoteInputEnabled,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildNavBtn(
    IconData icon,
    VoidCallback onTap, {
    VoidCallback? onLongPress,
    bool highlight = false,
  }) {
    final iconColor = highlight ? accentColor : Colors.white.withOpacity(0.85);
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        color: Colors.transparent,
        padding: const EdgeInsets.all(8),
        child: Icon(icon, color: iconColor, size: 24),
      ),
    );
  }

  Widget _buildInputStatusPill() {
    final text = inputStatusText;
    if (text == null) return const SizedBox.shrink();

    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 8, sigmaY: 8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.5),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Colors.white.withOpacity(0.15)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.keyboard_rounded, color: accentColor, size: 16),
              const SizedBox(width: 6),
              Text(
                text,
                style: GoogleFonts.spaceGrotesk(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildGlassBtn({
    required IconData icon,
    required VoidCallback onTap,
    bool highlight = false,
    String? tooltip,
  }) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: highlight
                  ? accentColor.withOpacity(0.2)
                  : Colors.white.withOpacity(0.12),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: highlight
                    ? accentColor.withOpacity(0.4)
                    : Colors.white.withOpacity(0.2),
              ),
            ),
            child: Icon(
              icon,
              color: highlight ? accentColor : Colors.white,
              size: 20,
            ),
          ),
        ),
      ),
    );
  }
}
