import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../Constants/FocusSurface.dart';

class AudioShareSourceToggle extends StatelessWidget {
  final bool isTvLayout;
  final bool isSystemAudio;
  final ValueChanged<bool> onSourceChanged;

  const AudioShareSourceToggle({
    super.key,
    required this.isTvLayout,
    required this.isSystemAudio,
    required this.onSourceChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: EdgeInsets.symmetric(horizontal: isTvLayout ? 0 : 24),
      padding: EdgeInsets.all(isTvLayout ? 8 : 6),
      decoration: BoxDecoration(
        color: const Color(0xFF1C1C1E),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white10),
      ),
      child: Row(
        children: [
          Expanded(
            child: _buildSourceButton(
              'System Audio',
              Icons.computer_rounded,
              isSystemAudio,
              () => onSourceChanged(true),
              isTvLayout: isTvLayout,
            ),
          ),
          Expanded(
            child: _buildSourceButton(
              'Microphone',
              Icons.mic_none_rounded,
              !isSystemAudio,
              () => onSourceChanged(false),
              isTvLayout: isTvLayout,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSourceButton(
    String label,
    IconData icon,
    bool selected,
    VoidCallback onTap, {
    required bool isTvLayout,
  }) {
    return FocusSurface(
      onTap: onTap,
      builder: (isFocused) {
        return GestureDetector(
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            padding: EdgeInsets.symmetric(vertical: isTvLayout ? 14 : 12),
            decoration: BoxDecoration(
              color: selected ? const Color(0xFFFFD600) : Colors.transparent,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: isFocused ? const Color(0xFFFFD600) : Colors.transparent,
                width: isFocused ? 2 : 1,
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  icon,
                  size: isTvLayout ? 20 : 18,
                  color: selected ? Colors.black : Colors.white24,
                ),
                const SizedBox(width: 8),
                Text(
                  label,
                  style: GoogleFonts.outfit(
                    color: selected ? Colors.black : Colors.white24,
                    fontWeight: FontWeight.w700,
                    fontSize: isTvLayout ? 16 : 14,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
