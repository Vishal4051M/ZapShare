import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// A touchpad widget for controlling Windows mouse from Android.
///
/// - Single finger pan → relative mouse movement (mousemove)
/// - Single tap → left click
/// - Two-finger scroll → vertical scroll
/// - Long press → right click
/// - Left/Right buttons at bottom for explicit clicks
class TouchpadWidget extends StatefulWidget {
  /// Called with relative (dx, dy) pixel deltas for mouse movement.
  final void Function(double dx, double dy) onMouseMove;

  /// Called on left click (tap or button press).
  final VoidCallback onLeftClick;

  /// Called on right click (long press or button press).
  final VoidCallback onRightClick;

  /// Called on scroll with delta (positive = down, negative = up).
  final void Function(double delta) onScroll;

  const TouchpadWidget({
    super.key,
    required this.onMouseMove,
    required this.onLeftClick,
    required this.onRightClick,
    required this.onScroll,
  });

  @override
  State<TouchpadWidget> createState() => _TouchpadWidgetState();
}

class _TouchpadWidgetState extends State<TouchpadWidget>
    with SingleTickerProviderStateMixin {
  static const _accentColor = Color(0xFFFFD600);

  // Pointer tracking
  Offset? _lastPointer;
  bool _moved = false;
  static const _moveThreshold = 4.0; // px before we call it a drag

  // Sensitivity multiplier — applied to all delta movements
  double _sensitivity = 2.0;

  // Button press state
  bool _leftDown = false;
  bool _rightDown = false;

  // Ripple animation for tap feedback
  late AnimationController _rippleController;
  Offset? _rippleCenter;

  @override
  void initState() {
    super.initState();
    _rippleController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
  }

  @override
  void dispose() {
    _rippleController.dispose();
    super.dispose();
  }

  void _showRipple(Offset pos) {
    setState(() => _rippleCenter = pos);
    _rippleController.forward(from: 0);
  }

  void _onPanStart(DragStartDetails details) {
    _lastPointer = details.localPosition;
    _moved = false;
  }

  void _onPanUpdate(DragUpdateDetails details) {
    if (_lastPointer == null) return;

    final dx = details.localPosition.dx - _lastPointer!.dx;
    final dy = details.localPosition.dy - _lastPointer!.dy;

    if (!_moved && (dx.abs() > _moveThreshold || dy.abs() > _moveThreshold)) {
      _moved = true;
    }

    if (_moved) {
      widget.onMouseMove(dx * _sensitivity, dy * _sensitivity);
    }

    _lastPointer = details.localPosition;
  }

  void _onPanEnd(DragEndDetails details) {
    if (!_moved) {
      // Treated as a tap → left click
      _showRipple(_lastPointer ?? Offset.zero);
      widget.onLeftClick();
    }
    _lastPointer = null;
    _moved = false;
  }

  void _onLongPress(LongPressStartDetails details) {
    _moved = true; // suppress click
    _showRipple(details.localPosition);
    widget.onRightClick();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // ── Sensitivity slider ──────────────────────────
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              const Icon(Icons.mouse_rounded, color: Colors.white38, size: 16),
              const SizedBox(width: 8),
              Expanded(
                child: SliderTheme(
                  data: SliderThemeData(
                    trackHeight: 2,
                    thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: 6,
                    ),
                    activeTrackColor: _accentColor.withValues(alpha: 0.6),
                    inactiveTrackColor: Colors.white12,
                    thumbColor: _accentColor,
                    overlayColor: _accentColor.withValues(alpha: 0.1),
                  ),
                  child: Slider(
                    value: _sensitivity,
                    min: 0.5,
                    max: 5.0,
                    divisions: 18,
                    onChanged: (v) => setState(() => _sensitivity = v),
                  ),
                ),
              ),
              SizedBox(
                width: 32,
                child: Text(
                  '${_sensitivity.toStringAsFixed(1)}x',
                  style: GoogleFonts.jetBrainsMono(
                    color: Colors.white38,
                    fontSize: 10,
                  ),
                  textAlign: TextAlign.right,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 6),

        // ── Main Touchpad Area ──────────────────────────
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: GestureDetector(
              onPanStart: _onPanStart,
              onPanUpdate: _onPanUpdate,
              onPanEnd: _onPanEnd,
              onLongPressStart: _onLongPress,
              child: Container(
                height: 200,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.04),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.08),
                  ),
                ),
                child: Stack(
                  children: [
                    // Grid dots pattern for visual cue
                    Positioned.fill(
                      child: CustomPaint(painter: TouchpadGridDotPainter()),
                    ),
                    // Center hint text
                    Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.touch_app_rounded,
                            color: Colors.white.withValues(alpha: 0.1),
                            size: 32,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Slide to move mouse\nTap to click • Long press for right-click',
                            textAlign: TextAlign.center,
                            style: GoogleFonts.outfit(
                              color: Colors.white.withValues(alpha: 0.15),
                              fontSize: 11,
                              height: 1.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                    // Ripple feedback
                    if (_rippleCenter != null)
                      AnimatedBuilder(
                        animation: _rippleController,
                        builder: (_, __) {
                          final progress = _rippleController.value;
                          return Positioned(
                            left: _rippleCenter!.dx - 30 * progress,
                            top: _rippleCenter!.dy - 30 * progress,
                            child: Opacity(
                              opacity: (1.0 - progress).clamp(0.0, 1.0),
                              child: Container(
                                width: 60 * progress,
                                height: 60 * progress,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: _accentColor.withValues(
                                    alpha: 0.3 * (1.0 - progress),
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 10),

        // ── Left/Right Buttons + Scroll ─────────────────
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              // Left Click Button
              Expanded(
                flex: 5,
                child: _buildClickButton(
                  label: 'Left Click',
                  icon: Icons.mouse_rounded,
                  onTap: () {
                    setState(() => _leftDown = true);
                    widget.onLeftClick();
                    Future.delayed(const Duration(milliseconds: 120), () {
                      if (mounted) setState(() => _leftDown = false);
                    });
                  },
                  isActive: _leftDown,
                ),
              ),
              const SizedBox(width: 8),
              // Scroll Up/Down
              Column(
                children: [
                  _buildScrollBtn(
                    Icons.keyboard_arrow_up_rounded,
                    () => widget.onScroll(-3.0),
                  ),
                  const SizedBox(height: 4),
                  _buildScrollBtn(
                    Icons.keyboard_arrow_down_rounded,
                    () => widget.onScroll(3.0),
                  ),
                ],
              ),
              const SizedBox(width: 8),
              // Right Click Button
              Expanded(
                flex: 5,
                child: _buildClickButton(
                  label: 'Right Click',
                  icon: Icons.mouse_rounded,
                  onTap: () {
                    setState(() => _rightDown = true);
                    widget.onRightClick();
                    Future.delayed(const Duration(milliseconds: 120), () {
                      if (mounted) setState(() => _rightDown = false);
                    });
                  },
                  isActive: _rightDown,
                  accent: false,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
      ],
    );
  }

  Widget _buildClickButton({
    required String label,
    required IconData icon,
    required VoidCallback onTap,
    required bool isActive,
    bool accent = true,
  }) {
    final activeColor = accent ? _accentColor : Colors.white70;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 100),
        height: 52,
        decoration: BoxDecoration(
          color:
              isActive
                  ? activeColor.withValues(alpha: 0.2)
                  : Colors.white.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color:
                isActive
                    ? activeColor.withValues(alpha: 0.5)
                    : Colors.white.withValues(alpha: 0.08),
          ),
        ),
        child: Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                color: isActive ? activeColor : Colors.white38,
                size: 16,
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: GoogleFonts.outfit(
                  color: isActive ? activeColor : Colors.white38,
                  fontSize: 12,
                  fontWeight: isActive ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildScrollBtn(IconData icon, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 36,
        height: 24,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.white12),
        ),
        child: Icon(icon, color: Colors.white38, size: 16),
      ),
    );
  }
}

/// Subtle grid of dots drawn on the touchpad surface
class TouchpadGridDotPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint =
        Paint()
          ..color = Colors.white.withValues(alpha: 0.06)
          ..style = PaintingStyle.fill;
    const spacing = 20.0;
    const radius = 1.0;
    for (double x = spacing; x < size.width; x += spacing) {
      for (double y = spacing; y < size.height; y += spacing) {
        canvas.drawCircle(Offset(x, y), radius, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
