import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class ScreenMirrorConnectingView extends StatelessWidget {
  final String deviceName;
  final String streamUrl;
  final Color accentColor;

  const ScreenMirrorConnectingView({
    super.key,
    required this.deviceName,
    required this.streamUrl,
    required this.accentColor,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 48,
            height: 48,
            child: CircularProgressIndicator(color: accentColor, strokeWidth: 3),
          ),
          const SizedBox(height: 20),
          Text(
            'Connecting to $deviceName...',
            style: GoogleFonts.spaceGrotesk(color: Colors.white70, fontSize: 16),
          ),
          const SizedBox(height: 8),
          Text(
            streamUrl,
            style: const TextStyle(
              color: Colors.white30,
              fontSize: 12,
              fontFamily: 'monospace',
            ),
          ),
        ],
      ),
    );
  }
}

class ScreenMirrorErrorView extends StatelessWidget {
  final String error;
  final VoidCallback onDisconnect;
  final VoidCallback onRetry;
  final Color accentColor;

  const ScreenMirrorErrorView({
    super.key,
    required this.error,
    required this.onDisconnect,
    required this.onRetry,
    required this.accentColor,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.error_outline_rounded,
            size: 56,
            color: Colors.red.withOpacity(0.6),
          ),
          const SizedBox(height: 16),
          Text(
            'Connection Failed',
            style: GoogleFonts.spaceGrotesk(
              color: Colors.white,
              fontWeight: FontWeight.w700,
              fontSize: 18,
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 40),
            child: Text(
              error,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white38, fontSize: 13),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              OutlinedButton.icon(
                onPressed: onDisconnect,
                icon: const Icon(Icons.arrow_back_rounded, size: 18),
                label: const Text('Go Back'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white60,
                  side: const BorderSide(color: Colors.white24),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              ElevatedButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: const Text('Retry'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: accentColor,
                  foregroundColor: Colors.black,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
