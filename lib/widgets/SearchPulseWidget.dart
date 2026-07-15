import 'dart:math';
import 'package:flutter/material.dart';

class SearchPulseWidget extends StatefulWidget {
  final double size;
  final Color color;
  final Widget? child;
  final bool showCenterDot;

  const SearchPulseWidget({
    super.key,
    this.size = 300,
    this.color = Colors.black,
    this.child,
    this.showCenterDot = true,
  });

  @override
  State<SearchPulseWidget> createState() => _SearchPulseWidgetState();
}

class _SearchPulseWidgetState extends State<SearchPulseWidget>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  static const Duration _duration = Duration(milliseconds: 3000);

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: _duration)
      ..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      alignment: Alignment.center,
      children: [
        RepaintBoundary(
          child: SizedBox(
            width: widget.size,
            height: widget.size,
            child: AnimatedBuilder(
              animation: _controller,
              builder:
                  (_, __) => CustomPaint(
                    painter: _SearchPulsePainter(
                      progress: _controller.value,
                      color: widget.color,
                      showCenterDot: widget.showCenterDot,
                    ),
                    isComplex: false,
                    willChange: true,
                  ),
            ),
          ),
        ),
        if (widget.child != null) widget.child!,
      ],
    );
  }
}

class _SearchPulsePainter extends CustomPainter {
  final double progress;
  final Color color;
  final bool showCenterDot;

  const _SearchPulsePainter({
    required this.progress,
    required this.color,
    required this.showCenterDot,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxRadius = size.width / 2;

    for (int i = 0; i < 3; i++) {
      final p = (progress + i / 3) % 1.0;
      final eased = 1.0 - (1.0 - p) * (1.0 - p) * (1.0 - p);
      final radius = maxRadius * (0.2 + eased * 0.8);
      final d = (radius / maxRadius).clamp(0.3, 1.0);
      final opacity = ((0.3 / (d * d)) * (1.0 - p * p)).clamp(0.0, 0.35);
      final stroke = 2.5 - eased * 2.0;

      if (opacity > 0.02) {
        canvas.drawCircle(
          center,
          radius,
          Paint()
            ..color = color.withOpacity(opacity)
            ..style = PaintingStyle.stroke
            ..strokeWidth = stroke,
        );
      }
    }

    if (showCenterDot) {
      final breathe = (0.5 + 0.5 * sin(progress * 2 * 3.14159)).abs();
      final dotR = size.width * 0.05 * (0.9 + breathe * 0.2);

      canvas.drawCircle(
        center,
        dotR * 1.6,
        Paint()
          ..color = color.withOpacity(0.12)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
      );

      canvas.drawCircle(center, dotR, Paint()..color = color.withOpacity(0.3));
    }
  }

  @override
  bool shouldRepaint(_SearchPulsePainter old) =>
      old.progress != progress ||
      old.color != color ||
      old.showCenterDot != showCenterDot;
}
