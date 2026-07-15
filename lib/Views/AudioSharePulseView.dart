import 'dart:io';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../widgets/SearchPulseWidget.dart';
import '../widgets/CustomAvatarWidget.dart';

class AudioSharePulseView extends StatelessWidget {
  final bool isTvLayout;
  final bool isCasting;
  final bool isPhoneMuted;
  final VoidCallback onMuteToggle;
  final Animation<double> pulseAnimation;
  final String? avatarId;

  const AudioSharePulseView({
    super.key,
    required this.isTvLayout,
    required this.isCasting,
    required this.isPhoneMuted,
    required this.onMuteToggle,
    required this.pulseAnimation,
    this.avatarId,
  });

  @override
  Widget build(BuildContext context) {
    final double pulseSize = isTvLayout ? 220 : 180;
    final double centerSize = isTvLayout ? 130 : 110;

    return SizedBox(
      height: isTvLayout ? 260 : 240,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Use standard consistent SearchPulseWidget with yellow color
          SearchPulseWidget(
            size: pulseSize,
            color: const Color(0xFFFFD600),
            child: Container(
              width: centerSize,
              height: centerSize,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: Color(0xFFFFD600),
              ),
              child:
                  avatarId != null
                      ? CustomAvatarWidget(
                        avatarId: avatarId,
                        size: centerSize,
                        useBackground: false,
                      )
                      : Icon(
                        isCasting ? Icons.waves_rounded : Icons.mic_rounded,
                        size: isTvLayout ? 48 : 40,
                        color: Colors.black,
                      ),
            ),
          ),
          Positioned(
            bottom: 20,
            child: Column(
              children: [
                Text(
                  isCasting ? 'Streaming Audio' : 'Ready to Share',
                  style: GoogleFonts.outfit(
                    color: Colors.white,
                    fontSize: isTvLayout ? 18 : 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (isCasting && Platform.isAndroid) ...[
                  const SizedBox(height: 8),
                  GestureDetector(
                    onTap: onMuteToggle,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color:
                            isPhoneMuted
                                ? const Color(0xFFE11D48)
                                : Colors.white.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color:
                              isPhoneMuted
                                  ? const Color(0xFFE11D48)
                                  : Colors.white24,
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            isPhoneMuted
                                ? Icons.volume_off_rounded
                                : Icons.volume_up_rounded,
                            color: Colors.white,
                            size: 14,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            isPhoneMuted ? 'Phone Muted' : 'Mute Phone',
                            style: GoogleFonts.outfit(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
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
  }
}
