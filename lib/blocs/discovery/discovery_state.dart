import 'package:equatable/equatable.dart';
import 'package:zap_share/services/device_discovery_service.dart';

abstract class DiscoveryState extends Equatable {
  const DiscoveryState();

  @override
  List<Object> get props => [];
}

class DiscoveryInitial extends DiscoveryState {}

class DiscoveryLoaded extends DiscoveryState {
  final List<DiscoveredDevice> devices;

  const DiscoveryLoaded(this.devices);

  @override
  List<Object> get props => [devices];
}
