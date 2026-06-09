import 'package:flutter_bloc/flutter_bloc.dart';
import 'navigation_event.dart';
import 'navigation_state.dart';

/// Navigation Bloc for managing app-wide navigation with smooth transitions
class NavigationBloc extends Bloc<NavigationEvent, NavigationState> {
  NavigationBloc() : super(NavigationInitial()) {
    on<NavigateToHome>(_onNavigateToHome);
    on<NavigateToSend>(_onNavigateToSend);
    on<NavigateToReceiveOptions>(_onNavigateToReceiveOptions);
    on<NavigateToReceiveByCode>(_onNavigateToReceiveByCode);
    on<NavigateToWebReceive>(_onNavigateToWebReceive);
    on<NavigateToHistory>(_onNavigateToHistory);
    on<NavigateToCast>(_onNavigateToCast);
    on<NavigateToSettings>(_onNavigateToSettings);
    on<NavigateToScreen>(_onNavigateToScreen);
    on<NavigateBack>(_onNavigateBack);
  }

  void _onNavigateToHome(NavigateToHome event, Emitter<NavigationState> emit) {
    emit(NavigationHome());
  }

  void _onNavigateToSend(NavigateToSend event, Emitter<NavigationState> emit) {
    emit(NavigationSend(initialFiles: event.initialFiles));
  }

  void _onNavigateToReceiveOptions(
    NavigateToReceiveOptions event,
    Emitter<NavigationState> emit,
  ) {
    emit(NavigationReceiveOptions());
  }

  void _onNavigateToReceiveByCode(
    NavigateToReceiveByCode event,
    Emitter<NavigationState> emit,
  ) {
    emit(NavigationReceiveByCode(autoConnectCode: event.autoConnectCode));
  }

  void _onNavigateToWebReceive(
    NavigateToWebReceive event,
    Emitter<NavigationState> emit,
  ) {
    emit(NavigationWebReceive());
  }

  void _onNavigateToHistory(
    NavigateToHistory event,
    Emitter<NavigationState> emit,
  ) {
    emit(NavigationHistory());
  }

  void _onNavigateToCast(NavigateToCast event, Emitter<NavigationState> emit) {
    emit(NavigationCast());
  }

  void _onNavigateToSettings(
    NavigateToSettings event,
    Emitter<NavigationState> emit,
  ) {
    emit(NavigationSettings());
  }

  void _onNavigateToScreen(
    NavigateToScreen event,
    Emitter<NavigationState> emit,
  ) {
    emit(NavigationCustomScreen(screen: event.screen, heroTag: event.heroTag));
  }

  void _onNavigateBack(NavigateBack event, Emitter<NavigationState> emit) {
    // Just trigger a state that can be listened to for navigation
    // The actual pop is handled by the listener
    emit(NavigationInitial());
  }
}
