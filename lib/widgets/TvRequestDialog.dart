import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import '../services/device_discovery_service.dart';
import 'tv_widgets.dart';

/// TV-optimized connection request dialog.
/// All actions reachable via D-pad — large focusable Decline/Accept buttons.
class TvRequestDialog extends StatelessWidget {
  final ConnectionRequest request;
  final VoidCallback onAccept;
  final VoidCallback onDecline;

  const TvRequestDialog({
    super.key,
    required this.request,
    required this.onAccept,
    required this.onDecline,
  });

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  IconData _getPlatformIcon(String platform) {
    switch (platform.toLowerCase()) {
      case 'android': return Icons.phone_android_rounded;
      case 'ios': return Icons.phone_iphone_rounded;
      case 'windows': return Icons.computer_rounded;
      case 'macos': return Icons.laptop_mac_rounded;
      default: return Icons.devices_rounded;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 580, maxHeight: 680),
        decoration: BoxDecoration(
          color: const Color(0xFF141416),
          borderRadius: BorderRadius.circular(32),
          border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFFFFD600).withValues(alpha: 0.15),
              blurRadius: 60,
              spreadRadius: 10,
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // ── Top section: device identity ──
            Container(
              padding: const EdgeInsets.fromLTRB(36, 36, 36, 24),
              child: Column(
                children: [
                  // Device icon circle
                  Container(
                    width: 90,
                    height: 90,
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFD600),
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFFFFD600).withValues(alpha: 0.4),
                          blurRadius: 28,
                          spreadRadius: 4,
                        ),
                      ],
                    ),
                    child: Icon(
                      _getPlatformIcon(request.platform),
                      color: Colors.black,
                      size: 44,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'INCOMING REQUEST',
                    style: GoogleFonts.outfit(
                      color: const Color(0xFFFFD600),
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 2.0,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    request.deviceName,
                    style: GoogleFonts.outfit(
                      color: Colors.white,
                      fontSize: 28,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.5,
                      height: 1.1,
                    ),
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'wants to send you files',
                    style: GoogleFonts.outfit(color: Colors.white54, fontSize: 15),
                  ),
                ],
              ),
            ),

            // ── Info chips ──
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 36),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _infoChip(
                    Icons.folder_outlined,
                    '${request.fileCount} file${request.fileCount > 1 ? 's' : ''}',
                  ),
                  Container(width: 1, height: 28, color: Colors.white.withValues(alpha: 0.1)),
                  _infoChip(
                    Icons.storage_rounded,
                    _formatBytes(request.totalSize),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 16),

            // ── File list (scrollable, D-pad ▲▼) ──
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 36),
              constraints: const BoxConstraints(maxHeight: 180),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.35),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
              ),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: request.fileNames.length > 5 ? 5 : request.fileNames.length,
                itemBuilder: (context, i) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(7),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFFD600).withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Icon(
                          Icons.insert_drive_file_rounded,
                          color: Color(0xFFFFD600),
                          size: 18,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          request.fileNames[i],
                          style: GoogleFonts.outfit(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w500),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

            if (request.fileNames.length > 5)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  '+ ${request.fileNames.length - 5} more files',
                  style: GoogleFonts.outfit(color: Colors.white38, fontSize: 13, fontStyle: FontStyle.italic),
                ),
              ),

            const SizedBox(height: 28),

            // ── Action buttons — large, D-pad focusable ──
            Padding(
              padding: const EdgeInsets.fromLTRB(36, 0, 36, 36),
              child: Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 58,
                      child: TVFocusableButton(
                        backgroundColor: Colors.white.withValues(alpha: 0.05),
                        focusColor: Colors.redAccent,
                        borderRadius: BorderRadius.circular(18),
                        padding: EdgeInsets.zero,
                        onPressed: () {
                          HapticFeedback.lightImpact();
                          onDecline();
                        },
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(Icons.close_rounded, color: Colors.white54, size: 22),
                            const SizedBox(width: 8),
                            Text(
                              'Decline',
                              style: GoogleFonts.outfit(
                                color: Colors.white54,
                                fontSize: 17,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: SizedBox(
                      height: 58,
                      child: TVFocusableButton(
                        autofocus: true,
                        backgroundColor: const Color(0xFFFFD600),
                        focusColor: const Color(0xFFFFD600),
                        borderRadius: BorderRadius.circular(18),
                        padding: EdgeInsets.zero,
                        onPressed: () {
                          HapticFeedback.mediumImpact();
                          onAccept();
                        },
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(Icons.check_circle_rounded, color: Colors.black, size: 22),
                            const SizedBox(width: 8),
                            Text(
                              'Accept',
                              style: GoogleFonts.outfit(
                                color: Colors.black,
                                fontSize: 17,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _infoChip(IconData icon, String text) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: const Color(0xFFFFD600), size: 20),
        const SizedBox(width: 10),
        Text(
          text,
          style: GoogleFonts.outfit(
            color: Colors.white,
            fontSize: 16,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}
