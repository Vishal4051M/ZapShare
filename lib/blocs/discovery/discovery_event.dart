import 'package:equatable/equatable.dart';
import 'package:zap_share/services/device_discovery_service.dart';

abstract class DiscoveryEvent extends Equatable {
  const DiscoveryEvent();

  @override
  List<Object> get props => [];
}

class StartDiscovery extends DiscoveryEvent {}

class StopDiscovery extends DiscoveryEvent {}

class DevicesUpdated extends DiscoveryEvent {
  final List<DiscoveredDevice> devices;

  const DevicesUpdated(this.devices);

  @override
  List<Object> get props => [devices];
}
