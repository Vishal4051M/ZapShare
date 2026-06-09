import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'navigation_event.dart';

/// Smooth page route configurations for beautiful transitions
class SmoothPageRoute {
  /// Create a smooth page route with the specified transition type
  static PageRouteBuilder<T> create<T>({
    required Widget page,
    NavigationTransitionType type = NavigationTransitionType.slideRight,
    Duration duration = const Duration(milliseconds: 400),
    Duration reverseDuration = const Duration(milliseconds: 350),
    String? heroTag,
    bool hapticFeedback = true,
  }) {
    if (hapticFeedback) {
      HapticFeedback.lightImpact();
    }

    return PageRouteBuilder<T>(
      transitionDuration: duration,
      reverseTransitionDuration: reverseDuration,
      pageBuilder: (context, animation, secondaryAnimation) {
        // Don't wrap in Hero - screens handle their own Hero animations
        return page;
      },
      transitionsBuilder: (context, animation, secondaryAnimation, child) {
        return _buildTransition(type, animation, secondaryAnimation, child);
      },
    );
  }

  /// Create a fade transition route (best for Hero animations)
  static PageRouteBuilder<T> fade<T>({
    required Widget page,
    Duration duration = const Duration(milliseconds: 620),
    Duration reverseDuration = const Duration(milliseconds: 560),
    String? heroTag,
  }) {
    return create(
      page: page,
      type: NavigationTransitionType.fade,
      duration: duration,
      reverseDuration: reverseDuration,
      heroTag: heroTag,
    );
  }

  /// Create a slide-from-right transition route
  static PageRouteBuilder<T> slideRight<T>({
    required Widget page,
    Duration duration = const Duration(milliseconds: 620),
    Duration reverseDuration = const Duration(milliseconds: 560),
    String? heroTag,
  }) {
    return create(
      page: page,
      type: NavigationTransitionType.slideRight,
      duration: duration,
      reverseDuration: reverseDuration,
      heroTag: heroTag,
    );
  }

  /// Create a slide-from-bottom transition route
  static PageRouteBuilder<T> slideUp<T>({
    required Widget page,
    Duration duration = const Duration(milliseconds: 400),
    Duration reverseDuration = const Duration(milliseconds: 350),
    String? heroTag,
  }) {
    return create(
      page: page,
      type: NavigationTransitionType.slideUp,
      duration: duration,
      reverseDuration: reverseDuration,
      heroTag: heroTag,
    );
  }

  /// Create a scale transition route
  static PageRouteBuilder<T> scale<T>({
    required Widget page,
    Duration duration = const Duration(milliseconds: 400),
    Duration reverseDuration = const Duration(milliseconds: 350),
    String? heroTag,
  }) {
    return create(
      page: page,
      type: NavigationTransitionType.scale,
      duration: duration,
      reverseDuration: reverseDuration,
      heroTag: heroTag,
    );
  }

  /// Create a no-op transition route (Hero-only)
  static PageRouteBuilder<T> none<T>({
    required Widget page,
    Duration duration = const Duration(milliseconds: 620),
    Duration reverseDuration = const Duration(milliseconds: 560),
    String? heroTag,
  }) {
    return create(
      page: page,
      type: NavigationTransitionType.none,
      duration: duration,
      reverseDuration: reverseDuration,
      heroTag: heroTag,
    );
  }

  /// Create a fade transition route (no slide)
  static PageRouteBuilder<T> fadeSlide<T>({
    required Widget page,
    Duration duration = const Duration(milliseconds: 450),
    Duration reverseDuration = const Duration(milliseconds: 400),
    String? heroTag,
  }) {
    return create(
      page: page,
      type: NavigationTransitionType.fadeSlide,
      duration: duration,
      reverseDuration: reverseDuration,
      heroTag: heroTag,
    );
  }

  /// Build the transition animation based on type
  static Widget _buildTransition(
    NavigationTransitionType type,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    switch (type) {
      case NavigationTransitionType.none:
        return child;

      case NavigationTransitionType.fade:
        return FadeTransition(
          opacity: CurvedAnimation(
            parent: animation,
            curve: Curves.easeInOutCubic,
            reverseCurve: Curves.easeInOutCubic,
          ),
          child: child,
        );

      case NavigationTransitionType.slideRight:
        // Apple-like curve: smooth, floaty motion
        return SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(1.0, 0.0),
            end: Offset.zero,
          ).animate(
            CurvedAnimation(
              parent: animation,
              curve: Curves.easeInOutCubic,
              reverseCurve: Curves.easeInOutCubic,
            ),
          ),
          child: child,
        );

      case NavigationTransitionType.slideUp:
        return SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0.0, 1.0),
            end: Offset.zero,
          ).animate(
            CurvedAnimation(
              parent: animation,
              curve: Curves.easeOutCubic,
              reverseCurve: Curves.easeInCubic,
            ),
          ),
          child: child,
        );

      case NavigationTransitionType.scale:
        return ScaleTransition(
          scale: Tween<double>(begin: 0.96, end: 1.0).animate(
            CurvedAnimation(
              parent: animation,
              curve: Curves.easeInOutCubic,
              reverseCurve: Curves.easeInOutCubic,
            ),
          ),
          child: FadeTransition(
            opacity: CurvedAnimation(
              parent: animation,
              curve: Curves.easeInOutCubic,
              reverseCurve: Curves.easeInOutCubic,
            ),
            child: child,
          ),
        );

      case NavigationTransitionType.fadeSlide:
        return FadeTransition(
          opacity: CurvedAnimation(
            parent: animation,
            curve: Curves.easeOut,
            reverseCurve: Curves.easeIn,
          ),
          child: child,
        );
    }
  }
}

/// A premium RectTween for Apple-level Hero animations
class SmoothRectTween extends RectTween {
  SmoothRectTween({super.begin, super.end});

  @override
  Rect? lerp(double t) {
    // Apple-level elastic curve for the geometry transition
    final curve = const Cubic(0.1, 0.9, 0.2, 1.0).transform(t);
    return Rect.fromLTRB(
      _lerpDouble(begin?.left, end?.left, curve)!,
      _lerpDouble(begin?.top, end?.top, curve)!,
      _lerpDouble(begin?.right, end?.right, curve)!,
      _lerpDouble(begin?.bottom, end?.bottom, curve)!,
    );
  }

  double? _lerpDouble(double? a, double? b, double t) {
    if (a == null || b == null) return b;
    return a + (b - a) * t;
  }
}

/// Extension for easy navigation from BuildContext
extension SmoothNavigator on BuildContext {
  /// Navigate to a screen with fade transition (best for Hero animations)
  Future<T?> navigateFade<T>(Widget page, {String? heroTag}) {
    return Navigator.push<T>(
      this,
      SmoothPageRoute.fade(page: page, heroTag: heroTag),
    );
  }

  /// Navigate to a screen with slide-from-right transition
  Future<T?> navigateSlideRight<T>(Widget page, {String? heroTag}) {
    return Navigator.push<T>(
      this,
      SmoothPageRoute.slideRight(page: page, heroTag: heroTag),
    );
  }

  /// Navigate to a screen with slide-from-bottom transition
  Future<T?> navigateSlideUp<T>(Widget page, {String? heroTag}) {
    return Navigator.push<T>(
      this,
      SmoothPageRoute.slideUp(page: page, heroTag: heroTag),
    );
  }

  /// Navigate to a screen with scale transition
  Future<T?> navigateScale<T>(Widget page, {String? heroTag}) {
    return Navigator.push<T>(
      this,
      SmoothPageRoute.scale(page: page, heroTag: heroTag),
    );
  }

  /// Navigate to a screen with no transition (Hero-only)
  Future<T?> navigateNone<T>(Widget page, {String? heroTag}) {
    return Navigator.push<T>(
      this,
      SmoothPageRoute.none(page: page, heroTag: heroTag),
    );
  }

  /// Navigate to a screen with fade transition (no slide)
  Future<T?> navigateFadeSlide<T>(Widget page, {String? heroTag}) {
    return Navigator.push<T>(
      this,
      SmoothPageRoute.fadeSlide(page: page, heroTag: heroTag),
    );
  }

  /// Navigate back with haptic feedback
  void navigateBack<T>([T? result]) {
    HapticFeedback.lightImpact();
    Navigator.pop<T>(this, result);
  }
}
