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
    final radius = widget.borderRadius ?? BorderRadius.circular(14);
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
      child: AnimatedScale(
        scale: _isFocused ? 1.04 : 1.0,
        duration: const Duration(milliseconds: 150),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          decoration: BoxDecoration(
            color: widget.backgroundColor ?? Colors.transparent,
            borderRadius: radius,
            border: Border.all(
              color: _isFocused
                  ? (widget.focusColor ?? const Color(0xFFFFD600))
                  : Colors.transparent,
              width: 2.5,
            ),
            boxShadow: _isFocused
                ? [
                    BoxShadow(
                      color: (widget.focusColor ?? const Color(0xFFFFD600))
                          .withValues(alpha: 0.55),
                      blurRadius: 18,
                      spreadRadius: 2,
                    ),
                    BoxShadow(
                      color: (widget.focusColor ?? const Color(0xFFFFD600))
                          .withValues(alpha: 0.2),
                      blurRadius: 36,
                      spreadRadius: 6,
                    ),
                  ]
                : null,
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: radius,
              onTap: widget.onPressed,
              splashColor: (widget.focusColor ?? const Color(0xFFFFD600)).withValues(alpha: 0.35),
              highlightColor: (widget.focusColor ?? const Color(0xFFFFD600)).withValues(alpha: 0.15),
              child: Padding(
                padding: widget.padding ?? const EdgeInsets.all(16),
                child: widget.child,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A focusable card widget for Android TV — focus border EXACTLY matches inner card radius
class TVFocusableCard extends StatefulWidget {
  final Widget child;
  final VoidCallback? onPressed;
  final bool autofocus;
  final FocusNode? focusNode;
  final Color? backgroundColor;
  final Color? focusColor;
  /// MUST match the inner card's BorderRadius to avoid corner gaps
  final BorderRadius borderRadius;

  const TVFocusableCard({
    super.key,
    required this.child,
    this.onPressed,
    this.autofocus = false,
    this.focusNode,
    this.backgroundColor,
    this.focusColor,
    this.borderRadius = const BorderRadius.all(Radius.circular(28)),
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
      child: AnimatedScale(
        scale: _isFocused ? 1.04 : 1.0,
        duration: const Duration(milliseconds: 150),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          decoration: BoxDecoration(
            color: widget.backgroundColor ?? const Color(0xFF1C1C1E),
            borderRadius: widget.borderRadius,
            border: Border.all(
              color: _isFocused
                  ? (widget.focusColor ?? const Color(0xFFFFD600))
                  : Colors.white.withValues(alpha: 0.05),
              width: 2.5,
            ),
            boxShadow: _isFocused
                ? [
                    BoxShadow(
                      color: (widget.focusColor ?? const Color(0xFFFFD600))
                          .withValues(alpha: 0.55),
                      blurRadius: 22,
                      spreadRadius: 3,
                    ),
                    BoxShadow(
                      color: (widget.focusColor ?? const Color(0xFFFFD600))
                          .withValues(alpha: 0.2),
                      blurRadius: 44,
                      spreadRadius: 8,
                    ),
                  ]
                : null,
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: widget.borderRadius,
              onTap: widget.onPressed,
              splashColor: (widget.focusColor ?? const Color(0xFFFFD600)).withValues(alpha: 0.3),
              highlightColor: (widget.focusColor ?? const Color(0xFFFFD600)).withValues(alpha: 0.12),
              child: widget.child,
            ),
          ),
        ),
      ),
    );
  }
}

/// A TV-optimized toggle row — two options, D-pad navigable
class TVSourceToggle extends StatelessWidget {
  final bool value; // true = first option selected
  final String firstLabel;
  final IconData firstIcon;
  final String secondLabel;
  final IconData secondIcon;
  final ValueChanged<bool> onChanged;

  const TVSourceToggle({
    super.key,
    required this.value,
    required this.firstLabel,
    required this.firstIcon,
    required this.secondLabel,
    required this.secondIcon,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1C1C1E),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Row(
        children: [
          Expanded(
            child: TVFocusableButton(
              autofocus: value,
              borderRadius: const BorderRadius.horizontal(left: Radius.circular(16)),
              backgroundColor: value
                  ? const Color(0xFFFFD600).withValues(alpha: 0.18)
                  : Colors.transparent,
              focusColor: const Color(0xFFFFD600),
              padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
              onPressed: () => onChanged(true),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(firstIcon,
                      color: value ? const Color(0xFFFFD600) : Colors.white38,
                      size: 20),
                  const SizedBox(width: 8),
                  Text(
                    firstLabel,
                    style: TextStyle(
                      color: value ? const Color(0xFFFFD600) : Colors.white38,
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
            ),
          ),
          Container(width: 1, height: 28, color: Colors.white.withValues(alpha: 0.08)),
          Expanded(
            child: TVFocusableButton(
              autofocus: !value,
              borderRadius: const BorderRadius.horizontal(right: Radius.circular(16)),
              backgroundColor: !value
                  ? const Color(0xFFFFD600).withValues(alpha: 0.18)
                  : Colors.transparent,
              focusColor: const Color(0xFFFFD600),
              padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
              onPressed: () => onChanged(false),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(secondIcon,
                      color: !value ? const Color(0xFFFFD600) : Colors.white38,
                      size: 20),
                  const SizedBox(width: 8),
                  Text(
                    secondLabel,
                    style: TextStyle(
                      color: !value ? const Color(0xFFFFD600) : Colors.white38,
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Helper to detect if running on Android TV
class TVHelper {
  static bool? _isTV;

  static void setTV(bool val) {
    _isTV = val;
  }

  static bool isTV(BuildContext context) {
    if (_isTV != null) return _isTV!;
    final size = MediaQuery.of(context).size;
    return size.width >= 1280 && size.height >= 720;
  }

  static double getScaleFactor(BuildContext context) {
    return isTV(context) ? 1.2 : 1.0;
  }
}
