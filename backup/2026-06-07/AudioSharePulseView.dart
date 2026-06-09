import 'dart:io';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class AudioSharePulseView extends StatelessWidget {
  final bool isTvLayout;
  final bool isCasting;
  final bool isPhoneMuted;
  final VoidCallback onMuteToggle;
  final Animation<double> pulseAnimation;

  const AudioSharePulseView({
    super.key,
    required this.isTvLayout,
    required this.isCasting,
    required this.isPhoneMuted,
    required this.onMuteToggle,
    required this.pulseAnimation,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: isTvLayout ? 260 : 240,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Solid White/Yellow Outlines for Rings
          ...List.generate(2, (index) {
            return AnimatedBuilder(
              animation: pulseAnimation,
              builder: (context, child) {
                final scale = 1.0 + (index * 0.4) + (pulseAnimation.value * 0.2);
                final opacity = (1.0 - (scale - 1.0) / 1.0).clamp(0.0, 0.4);
                return Container(
                  width: 100 * scale,
                  height: 100 * scale,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: const Color(0xFFFFD600).withOpacity(opacity),
                      width: 2,
                    ),
                  ),
                );
              },
            );
          }),
          Container(
            width: isTvLayout ? 130 : 110,
            height: isTvLayout ? 130 : 110,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: Color(0xFFFFD600),
            ),
            child: Icon(
              isCasting ? Icons.waves_rounded : Icons.mic_rounded,
              size: isTvLayout ? 48 : 40,
              color: Colors.black,
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
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                      decoration: BoxDecoration(
                        color: isPhoneMuted
                            ? const Color(0xFFE11D48)
                            : Colors.white.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: isPhoneMuted
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
