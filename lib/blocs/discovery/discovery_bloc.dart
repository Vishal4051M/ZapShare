import 'dart:async';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:zap_share/services/device_discovery_service.dart';
import 'discovery_event.dart';
import 'discovery_state.dart';

class DiscoveryBloc extends Bloc<DiscoveryEvent, DiscoveryState> {
  final DeviceDiscoveryService _discoveryService;
  StreamSubscription? _devicesSubscription;

  List<DiscoveredDevice> _udpDevices = [];

  DiscoveryBloc({
    DeviceDiscoveryService? discoveryService,
  }) : _discoveryService = discoveryService ?? DeviceDiscoveryService(),
       super(DiscoveryInitial()) {
    on<StartDiscovery>(_onStartDiscovery);
    on<StopDiscovery>(_onStopDiscovery);
    on<DevicesUpdated>(_onDevicesUpdated);
  }

  Future<void> _onStartDiscovery(
    StartDiscovery event,
    Emitter<DiscoveryState> emit,
  ) async {
    // Start UDP discovery
    await _discoveryService.initialize();
    await _discoveryService.start();

    _devicesSubscription?.cancel();
    _devicesSubscription = _discoveryService.devicesStream.listen((devices) {
      add(DevicesUpdated(devices));
    });
  }

  Future<void> _onStopDiscovery(
    StopDiscovery event,
    Emitter<DiscoveryState> emit,
  ) async {
    _devicesSubscription?.cancel();
  }

  void _onDevicesUpdated(DevicesUpdated event, Emitter<DiscoveryState> emit) {
    // Filter online devices
    _udpDevices = event.devices.where((d) => d.isOnline).toList();
    _emitDevices(emit);
  }
  
  void _emitDevices(Emitter<DiscoveryState> emit) {
    print('🔍 Discovery Bloc: ${_udpDevices.length} UDP devices');
    emit(DiscoveryLoaded(_udpDevices));
  }

  @override
  Future<void> close() {
    _devicesSubscription?.cancel();
    return super.close();
  }
}
