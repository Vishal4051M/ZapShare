import 'package:equatable/equatable.dart';
import 'package:flutter/material.dart';

/// Navigation states for the app
abstract class NavigationState extends Equatable {
  const NavigationState();

  @override
  List<Object?> get props => [];
}

/// Initial navigation state (on app start)
class NavigationInitial extends NavigationState {}

/// Currently on home screen
class NavigationHome extends NavigationState {}

/// Currently on send screen
class NavigationSend extends NavigationState {
  final List<Map<dynamic, dynamic>>? initialFiles;

  const NavigationSend({this.initialFiles});

  @override
  List<Object?> get props => [initialFiles];
}

/// Currently on receive options
class NavigationReceiveOptions extends NavigationState {}

/// Currently on receive by code screen
class NavigationReceiveByCode extends NavigationState {
  final String? autoConnectCode;

  const NavigationReceiveByCode({this.autoConnectCode});

  @override
  List<Object?> get props => [autoConnectCode];
}

/// Currently on web receive screen
class NavigationWebReceive extends NavigationState {}

/// Currently on history screen
class NavigationHistory extends NavigationState {}

/// Currently on cast screen
class NavigationCast extends NavigationState {}

/// Currently on settings screen
class NavigationSettings extends NavigationState {}

/// Navigating to a custom screen
class NavigationCustomScreen extends NavigationState {
  final Widget screen;
  final String? heroTag;

  const NavigationCustomScreen({required this.screen, this.heroTag});

  @override
  List<Object?> get props => [screen, heroTag];
}
