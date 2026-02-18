import 'package:flutter/material.dart';
import 'dart:math' as math;

class LiquidBackground extends StatefulWidget {
  final Widget child;

  const LiquidBackground({Key? key, required this.child}) : super(key: key);

  @override
  State<LiquidBackground> createState() => _LiquidBackgroundState();
}

class _LiquidBackgroundState extends State<LiquidBackground> with TickerProviderStateMixin {
  late AnimationController _controller;
  
  // Colors for the Aurora effect - Strictly Zap Yellow Grades
  final Color _color1 = const Color(0xFFFFD600); // Zap Standard Yellow
  final Color _color2 = const Color(0xFFF5C400); // Zap Darker Yellow
  final Color _color3 = const Color(0xFFFFD84D); // Zap Lighter Yellow

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 20),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // Deep Dark Background
        Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Color(0xFF000000),
                Color(0xFF1A1A1A),
              ],
            ),
          ),
        ),
        
        // Animated Mesh/Aurora
        AnimatedBuilder(
          animation: _controller,
          builder: (context, child) {
            return CustomPaint(
              painter: _AuroraPainter(
                animationValue: _controller.value,
                colors: [_color1, _color2, _color3],
              ),
              child: Container(),
            );
          },
        ),

        // Blur overlay to fuse everything into "Liquid"
        // Using a blurred container instead of BackdropFilter to avoid full-screen blur cost if possible,
        // but BackdropFilter is key for the "Glass" look over the background elements.
        // Actually, for the background itself, we want the painters to be blurry.
        
        // Subtle Noise Overlay (Optional Pattern)
        // Ignoring for now to keep it clean.

        // Main Content
        widget.child,
      ],
    );
  }
}

class _AuroraPainter extends CustomPainter {
  final double animationValue;
  final List<Color> colors;

  _AuroraPainter({required this.animationValue, required this.colors});

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    
    // We paint large sweeping gradients
    final paint = Paint()
      ..blendMode = BlendMode.screen
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 80.0); // Heavy blur baked in

    // Calculate movement based on animation
    // We create 3 distinct "waves" or "beams"
    
    // Beam 1: Yellow - Top Left sweeping diagonally
    final t1 = animationValue * 2 * math.pi;
    final path1 = Path();
    path1.moveTo(0, h * 0.3);
    path1.quadraticBezierTo(
      w * 0.5 + math.sin(t1) * 50, 
      h * 0.2 + math.cos(t1) * 50, 
      w, 
      0
    );
    path1.lineTo(w, h * 0.5);
    path1.quadraticBezierTo(
      w * 0.5 - math.sin(t1) * 30, 
      h * 0.6 - math.cos(t1) * 30, 
      0, 
      h * 0.8
    );
    path1.close();

    paint.color = colors[0].withOpacity(0.15);
    canvas.drawPath(path1, paint);

    // Beam 2: Purple - Bottom Right sweeping up
    final t2 = (animationValue + 0.33) * 2 * math.pi;
    final path2 = Path();
    path2.moveTo(w, h * 0.7);
    path2.quadraticBezierTo(
      w * 0.4 + math.cos(t2) * 60, 
      h * 0.8 + math.sin(t2) * 60, 
      0, 
      h
    );
    path2.lineTo(0, h * 0.4);
    path2.quadraticBezierTo(
      w * 0.6 - math.cos(t2) * 40, 
      h * 0.3 - math.sin(t2) * 40, 
      w, 
      h * 0.2
    );
    path2.close();

    paint.color = colors[1].withOpacity(0.12);
    canvas.drawPath(path2, paint);

    // Beam 3: Blue - flowing across middle
    final t3 = (animationValue + 0.66) * 2 * math.pi;
    final path3 = Path();
    path3.addOval(Rect.fromCenter(
      center: Offset(
        w * 0.5 + math.sin(t3) * 100, 
        h * 0.5 + math.cos(t3 * 0.5) * 50
      ), 
      width: w * 0.8, 
      height: h * 0.4
    ));

    paint.color = colors[2].withOpacity(0.1);
    canvas.drawPath(path3, paint);
  }

  @override
  bool shouldRepaint(covariant _AuroraPainter oldDelegate) {
    return oldDelegate.animationValue != animationValue;
  }
}
