import 'dart:typed_data';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

class ScreenMirrorStreamView extends StatelessWidget {
  final Uint8List? currentFrame;
  final GlobalKey imageKey;
  final Function(PointerSignalEvent) onPointerSignal;
  final Function(TapUpDetails) onTapUp;
  final Function(LongPressStartDetails) onLongPressStart;
  final Function(DragStartDetails) onPanStart;
  final Function(DragUpdateDetails) onPanUpdate;
  final Function(DragEndDetails) onPanEnd;

  const ScreenMirrorStreamView({
    super.key,
    required this.currentFrame,
    required this.imageKey,
    required this.onPointerSignal,
    required this.onTapUp,
    required this.onLongPressStart,
    required this.onPanStart,
    required this.onPanUpdate,
    required this.onPanEnd,
  });

  @override
  Widget build(BuildContext context) {
    if (currentFrame != null) {
      return SizedBox.expand(
        child: Listener(
          onPointerSignal: onPointerSignal,
          child: GestureDetector(
            onTapUp: onTapUp,
            onSecondaryTapUp: (details) {
              // Trigger same as tap/back gesture
            },
            onLongPressStart: onLongPressStart,
            onPanStart: onPanStart,
            onPanUpdate: onPanUpdate,
            onPanEnd: onPanEnd,
            child: Image.memory(
              currentFrame!,
              key: imageKey,
              gaplessPlayback: true,
              fit: BoxFit.fill,
              filterQuality: FilterQuality.high,
            ),
          ),
        ),
      );
    }

    return const Center(
      child: Text(
        'Waiting for frames...',
        style: TextStyle(color: Colors.white38),
      ),
    );
  }
}
