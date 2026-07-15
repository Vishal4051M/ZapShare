import 'package:flutter/material.dart';

class FocusSurface extends StatefulWidget {
  final Widget Function(bool isFocused) builder;
  final VoidCallback? onTap;

  const FocusSurface({super.key, required this.builder, required this.onTap});

  @override
  State<FocusSurface> createState() => _FocusSurfaceState();
}

class _FocusSurfaceState extends State<FocusSurface> {
  bool _isFocused = false;

  @override
  Widget build(BuildContext context) {
    return FocusableActionDetector(
      onFocusChange: (focused) => setState(() => _isFocused = focused),
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (intent) {
            widget.onTap?.call();
            return null;
          },
        ),
      },
      child: widget.builder(_isFocused),
    );
  }
}
