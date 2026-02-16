import 'package:equatable/equatable.dart';
import 'package:flutter/material.dart';

/// Navigation events for the app
abstract class NavigationEvent extends Equatable {
  const NavigationEvent();

  @override
  List<Object?> get props => [];
}

/// Navigate to the home screen
class NavigateToHome extends NavigationEvent {}

/// Navigate to the send/share screen
class NavigateToSend extends NavigationEvent {
  final List<Map<dynamic, dynamic>>? initialFiles;

  const NavigateToSend({this.initialFiles});

  @override
  List<Object?> get props => [initialFiles];
}

/// Navigate to receive options screen
class NavigateToReceiveOptions extends NavigationEvent {}

/// Navigate to receive by code screen
class NavigateToReceiveByCode extends NavigationEvent {
  final String? autoConnectCode;

  const NavigateToReceiveByCode({this.autoConnectCode});

  @override
  List<Object?> get props => [autoConnectCode];
}

/// Navigate to web receive screen
class NavigateToWebReceive extends NavigationEvent {}

/// Navigate to transfer history screen
class NavigateToHistory extends NavigationEvent {}

/// Navigate to cast screen
class NavigateToCast extends NavigationEvent {}

/// Navigate to device settings screen
class NavigateToSettings extends NavigationEvent {}

/// Go back to previous screen
class NavigateBack extends NavigationEvent {}

/// Navigate with a custom widget
class NavigateToScreen extends NavigationEvent {
  final Widget screen;
  final String? heroTag;
  final NavigationTransitionType transitionType;

  const NavigateToScreen({
    required this.screen,
    this.heroTag,
    this.transitionType = NavigationTransitionType.slideRight,
  });

  @override
  List<Object?> get props => [screen, heroTag, transitionType];
}

/// Types of navigation transitions
enum NavigationTransitionType { fade, slideRight, slideUp, scale, fadeSlide }
