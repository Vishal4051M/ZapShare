import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../Constants/FocusSurface.dart';

class AudioShareHeader extends StatelessWidget {
  final bool isTvLayout;
  final bool isScanning;
  final VoidCallback onBackTap;
  final VoidCallback onRefreshTap;

  const AudioShareHeader({
    super.key,
    required this.isTvLayout,
    required this.isScanning,
    required this.onBackTap,
    required this.onRefreshTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: isTvLayout ? 0 : 24,
        vertical: isTvLayout ? 8 : 12,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          _buildHeaderButton(
            icon: Icons.arrow_back_ios_new_rounded,
            onTap: onBackTap,
            isTvLayout: isTvLayout,
          ),
          Text(
            'Audio Share',
            style: GoogleFonts.outfit(
              color: Colors.white,
              fontSize: isTvLayout ? 28 : 22,
              fontWeight: FontWeight.w900,
              letterSpacing: -0.5,
            ),
          ),
          _buildHeaderButton(
            icon: isScanning ? Icons.sync : Icons.refresh_rounded,
            onTap: onRefreshTap,
            isTvLayout: isTvLayout,
          ),
        ],
      ),
    );
  }

  Widget _buildHeaderButton({
    required IconData icon,
    required VoidCallback onTap,
    required bool isTvLayout,
  }) {
    final size = isTvLayout ? 56.0 : 48.0;
    return FocusSurface(
      onTap: onTap,
      builder: (isFocused) {
        return GestureDetector(
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: size,
            height: size,
            decoration: BoxDecoration(
              color: const Color(0xFF1C1C1E),
              shape: BoxShape.circle,
              border: Border.all(
                color:
                    isFocused
                        ? const Color(0xFFFFD600)
                        : Colors.white.withOpacity(0.05),
                width: isFocused ? 2 : 1,
              ),
            ),
            child: Icon(icon, color: Colors.white, size: isTvLayout ? 24 : 20),
          ),
        );
      },
    );
  }
}
