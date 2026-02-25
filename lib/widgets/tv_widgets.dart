import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A focusable button widget optimized for Android TV remote control navigation
class TVFocusableButton extends StatefulWidget {
  final Widget child;
  final VoidCallback? onPressed;
  final bool autofocus;
  final FocusNode? focusNode;
  final Color? focusColor;
  final Color? backgroundColor;
  final EdgeInsetsGeometry? padding;
  final BorderRadius? borderRadius;

  const TVFocusableButton({
    super.key,
    required this.child,
    this.onPressed,
    this.autofocus = false,
    this.focusNode,
    this.focusColor,
    this.backgroundColor,
    this.padding,
    this.borderRadius,
  });

  @override
  State<TVFocusableButton> createState() => _TVFocusableButtonState();
}

class _TVFocusableButtonState extends State<TVFocusableButton> {
  late FocusNode _focusNode;
  bool _isFocused = false;

  @override
  void initState() {
    super.initState();
    _focusNode = widget.focusNode ?? FocusNode();
    _focusNode.addListener(_onFocusChange);
  }

  @override
  void dispose() {
    _focusNode.removeListener(_onFocusChange);
    if (widget.focusNode == null) {
      _focusNode.dispose();
    }
    super.dispose();
  }

  void _onFocusChange() {
    setState(() {
      _isFocused = _focusNode.hasFocus;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _focusNode,
      autofocus: widget.autofocus,
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent) {
          if (event.logicalKey == LogicalKeyboardKey.select ||
              event.logicalKey == LogicalKeyboardKey.enter) {
            widget.onPressed?.call();
            return KeyEventResult.handled;
          }
        }
        return KeyEventResult.ignored;
      },
      child: GestureDetector(
        onTap: widget.onPressed,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: widget.padding ?? const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: widget.backgroundColor ?? Colors.transparent,
            borderRadius: widget.borderRadius ?? BorderRadius.circular(12),
            border: Border.all(
              color:
                  _isFocused
                      ? (widget.focusColor ?? const Color(0xFFFFD600))
                      : Colors.transparent,
              width: _isFocused ? 3 : 0,
            ),
            boxShadow:
                _isFocused
                    ? [
                      BoxShadow(
                        color: (widget.focusColor ?? const Color(0xFFFFD600))
                            .withOpacity(0.4),
                        blurRadius: 12,
                        spreadRadius: 2,
                      ),
                    ]
                    : null,
          ),
          child: widget.child,
        ),
      ),
    );
  }
}

/// A focusable card widget for file items on Android TV
class TVFocusableCard extends StatefulWidget {
  final Widget child;
  final VoidCallback? onPressed;
  final bool autofocus;
  final FocusNode? focusNode;
  final Color? backgroundColor;
  final Color? focusColor;

  const TVFocusableCard({
    super.key,
    required this.child,
    this.onPressed,
    this.autofocus = false,
    this.focusNode,
    this.backgroundColor,
    this.focusColor,
  });

  @override
  State<TVFocusableCard> createState() => _TVFocusableCardState();
}

class _TVFocusableCardState extends State<TVFocusableCard> {
  late FocusNode _focusNode;
  bool _isFocused = false;

  @override
  void initState() {
    super.initState();
    _focusNode = widget.focusNode ?? FocusNode();
    _focusNode.addListener(_onFocusChange);
  }

  @override
  void dispose() {
    _focusNode.removeListener(_onFocusChange);
    if (widget.focusNode == null) {
      _focusNode.dispose();
    }
    super.dispose();
  }

  void _onFocusChange() {
    setState(() {
      _isFocused = _focusNode.hasFocus;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _focusNode,
      autofocus: widget.autofocus,
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent) {
          if (event.logicalKey == LogicalKeyboardKey.select ||
              event.logicalKey == LogicalKeyboardKey.enter) {
            widget.onPressed?.call();
            return KeyEventResult.handled;
          }
        }
        return KeyEventResult.ignored;
      },
      child: GestureDetector(
        onTap: widget.onPressed,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          decoration: BoxDecoration(
            color: widget.backgroundColor ?? const Color(0xFF1C1C1E),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color:
                  _isFocused
                      ? (widget.focusColor ?? const Color(0xFFFFD600))
                      : Colors.white.withOpacity(0.05),
              width: _isFocused ? 3 : 1,
            ),
            boxShadow:
                _isFocused
                    ? [
                      BoxShadow(
                        color: (widget.focusColor ?? const Color(0xFFFFD600))
                            .withOpacity(0.3),
                        blurRadius: 16,
                        spreadRadius: 2,
                      ),
                    ]
                    : null,
          ),
          child: widget.child,
        ),
      ),
    );
  }
}

/// Helper to detect if running on Android TV
class TVHelper {
  static bool isTV(BuildContext context) {
    // Check if the device has a touchscreen
    // On TV, touchscreen is typically not available
    final mediaQuery = MediaQuery.of(context);
    final size = mediaQuery.size;

    // TV screens are typically larger and have different aspect ratios
    // This is a heuristic - you might want to use a platform channel for more accuracy
    return size.width >= 1280 && size.height >= 720;
  }

  static double getScaleFactor(BuildContext context) {
    // Scale UI elements for TV viewing distance
    return isTV(context) ? 1.2 : 1.0;
  }
}
