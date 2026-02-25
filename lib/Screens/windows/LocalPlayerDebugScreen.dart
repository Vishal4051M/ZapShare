import 'dart:io';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../shared/native_platform_mpv_player.dart';

class LocalPlayerDebugScreen extends StatefulWidget {
  final File file;
  final File? subtitleFile;

  const LocalPlayerDebugScreen({
    super.key,
    required this.file,
    this.subtitleFile,
  });

  @override
  State<LocalPlayerDebugScreen> createState() => _LocalPlayerDebugScreenState();
}

class _LocalPlayerDebugScreenState extends State<LocalPlayerDebugScreen> {
  late final NativePlatformMpvPlayer _player;
  bool _isPlaying = true;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;

  @override
  void initState() {
    super.initState();
    _player = NativePlatformMpvPlayer();
    _initPlayer();

    _player.positionStream.listen((pos) {
      if (mounted) setState(() => _position = pos);
    });

    _player.durationStream.listen((dur) {
      if (mounted) setState(() => _duration = dur);
    });

    _player.playingStream.listen((playing) {
      if (mounted) setState(() => _isPlaying = playing);
    });
  }

  Future<void> _initPlayer() async {
    await _player.open(
      widget.file.path,
      subtitlePath: widget.subtitleFile?.path,
    );
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  String _formatDuration(Duration d) {
    if (d == Duration.zero) return "--:--";
    String twoDigits(int n) => n.toString().padLeft(2, "0");
    String twoDigitMinutes = twoDigits(d.inMinutes.remainder(60));
    String twoDigitSeconds = twoDigits(d.inSeconds.remainder(60));
    if (d.inHours > 0) {
      return "${twoDigits(d.inHours)}:$twoDigitMinutes:$twoDigitSeconds";
    }
    return "$twoDigitMinutes:$twoDigitSeconds";
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text(
          "Local Debug Player",
          style: GoogleFonts.outfit(color: Colors.white),
        ),
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                Container(
                  width: double.infinity,
                  height: double.infinity,
                  color: Colors.black,
                ),
                Center(
                  child: AspectRatio(
                    aspectRatio: 16 / 9,
                    child: _player.buildVideoWidget(),
                  ),
                ),
              ],
            ),
          ),

          // Debug Controls
          Container(
            color: Colors.white.withOpacity(0.1),
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      _formatDuration(_position),
                      style: GoogleFonts.robotoMono(color: Colors.white),
                    ),
                    Text(
                      _formatDuration(_duration),
                      style: GoogleFonts.robotoMono(color: Colors.white),
                    ),
                  ],
                ),
                Slider(
                  value: _position.inSeconds.toDouble().clamp(
                    0,
                    _duration.inSeconds.toDouble(),
                  ),
                  min: 0,
                  max:
                      _duration.inSeconds.toDouble() > 0
                          ? _duration.inSeconds.toDouble()
                          : 1.0,
                  onChanged: (val) {
                    _player.seek(Duration(seconds: val.toInt()));
                  },
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton(
                      icon: Icon(
                        _isPlaying
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                        color: Colors.white,
                        size: 32,
                      ),
                      onPressed: () => _player.playOrPause(),
                    ),
                    const SizedBox(width: 16),
                    OutlinedButton(
                      onPressed: () {
                        // Force refresh duration check
                        _player.open(widget.file.path);
                      },
                      child: const Text("Reload"),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  "Debug Info: Duration: ${_duration.inSeconds}s | HTTP: No (Local File)",
                  style: const TextStyle(color: Colors.grey, fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
