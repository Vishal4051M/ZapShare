import 'package:flutter/material.dart';
import '../../Views/AudioReceiverView.dart';

class AudioReceiverScreen extends StatelessWidget {
  final String senderName;
  final String senderIp;
  final bool useLanAudio;
  final String? audioUrl;

  const AudioReceiverScreen({
    super.key,
    required this.senderName,
    required this.senderIp,
    this.useLanAudio = true,
    this.audioUrl,
  });

  @override
  Widget build(BuildContext context) {
    return AudioReceiverView(
      senderName: senderName,
      senderIp: senderIp,
      useLanAudio: useLanAudio,
      audioUrl: audioUrl,
    );
  }
}
