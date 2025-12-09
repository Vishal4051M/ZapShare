// Wi-Fi Direct Connection Handler
// Add this code to AndroidHttpFileShareScreen.dart

// ============================================================================
// STEP 1: Add import at the top of the file
// ============================================================================
import '../../services/wifi_direct_service.dart';

// ============================================================================
// STEP 2: Add Wi-Fi Direct stream subscription to class fields (around line 90)
// ============================================================================
StreamSubscription? _wifiDirectConnectionSubscription;

// ============================================================================
// STEP 3: Add Wi-Fi Direct connection listener in initState() or create new method
// ============================================================================

void _initWifiDirectListener() {
  if (!Platform.isAndroid) return;

  print('🔧 Initializing Wi-Fi Direct connection listener...');

  final wifiDirectService = WiFiDirectService();

  // Listen for Wi-Fi Direct group formation
  _wifiDirectConnectionSubscription = wifiDirectService.connectionInfoStream.listen(
    (connectionInfo) async {
      if (!mounted) return;

      if (connectionInfo.groupFormed) {
        print('📡 ========================================');
        print('📡 Wi-Fi Direct Group Formed!');
        print('📡 ========================================');
        print('   Is Group Owner: ${connectionInfo.isGroupOwner}');
        print('   Group Owner Address: ${connectionInfo.groupOwnerAddress}');
        print('   Pending Device: ${_pendingDevice?.deviceName ?? "None"}');

        // CRITICAL: Both devices are now on the same network (192.168.49.x)
        // Both devices need to start HTTP servers

        if (!_isSharing) {
          print('🚀 Starting HTTP server for Wi-Fi Direct connection...');
          await _startServer();
          print('✅ HTTP server started on Wi-Fi Direct network');
        } else {
          print('ℹ️  HTTP server already running');
        }

        // Wait for IP assignment (both GO and client get IPs)
        print('⏳ Waiting 2 seconds for IP assignment...');
        await Future.delayed(Duration(seconds: 2));

        // Determine peer IP based on our role
        String? peerIp;

        if (connectionInfo.isGroupOwner) {
          // We are Group Owner (192.168.49.1)
          // Peer is Client (will be 192.168.49.x, discovered via UDP)
          print('👑 We are Group Owner (192.168.49.1)');
          print('   Waiting for client to send connection request via UDP...');
          // No action needed - we'll receive UDP request from client
        } else {
          // We are Client
          // Group Owner is at groupOwnerAddress
          peerIp = connectionInfo.groupOwnerAddress;
          print('📱 We are Client');
          print('   Group Owner is at: $peerIp');
        }

        // If we have a pending Wi-Fi Direct connection request, send it now
        // This happens on the SENDER device (the one that initiated the connection)
        if (_pendingDevice != null &&
            _pendingDevice!.discoveryMethod == DiscoveryMethod.wifiDirect) {
          print('📤 ========================================');
          print('📤 Sending Connection Request');
          print('📤 ========================================');
          print('   To Device: ${_pendingDevice!.deviceName}');
          print('   MAC Address: ${_pendingDevice!.wifiDirectAddress}');
          print('   Files: ${_fileNames.length}');

          // Update the device IP in discovery service
          if (peerIp != null && _pendingDevice!.wifiDirectAddress != null) {
            print('🔄 Updating device IP in discovery service...');
            _discoveryService.updateWifiDirectDeviceIp(
              _pendingDevice!.wifiDirectAddress!,
              peerIp,
            );
            print('✅ Device IP updated to: $peerIp');
          }

          // Calculate total size
          final totalSize = _fileSizeList.fold<int>(
            0,
            (sum, size) => sum + size,
          );
          print('📊 Total file size: ${formatBytes(totalSize)}');

          // Send connection request to peer IP via UDP
          if (peerIp != null) {
            print('📡 Sending UDP connection request to: $peerIp');
            await _discoveryService.sendConnectionRequest(
              peerIp,
              _fileNames,
              totalSize,
            );
            print('✅ Connection request sent successfully');

            // Update pending request IP for timeout tracking
            setState(() {
              _pendingRequestDeviceIp = peerIp;
            });

            // Start timeout timer
            _requestTimeoutTimer?.cancel();
            _requestTimeoutTimer = Timer(Duration(seconds: 10), () {
              if (mounted && _pendingRequestDeviceIp != null) {
                print(
                  '⏰ Connection request timeout - no response after 10 seconds',
                );
                _showRetryDialog();
              }
            });

            print('⏱️  Timeout timer started (10 seconds)');
          } else {
            print('❌ ERROR: Peer IP is null, cannot send connection request');
          }
        } else {
          print('ℹ️  No pending Wi-Fi Direct device (this is the receiver)');
        }

        print('📡 ========================================');
        print('📡 Wi-Fi Direct Setup Complete');
        print('📡 ========================================');
      }
    },
    onError: (error) {
      print('❌ Error in Wi-Fi Direct connection stream: $error');
    },
    onDone: () {
      print('⚠️  Wi-Fi Direct connection stream closed');
    },
  );

  print('✅ Wi-Fi Direct connection listener initialized');
}

// ============================================================================
// STEP 4: Call _initWifiDirectListener() in initState()
// ============================================================================
// Add this line in initState() after _initDeviceDiscovery():
// _initWifiDirectListener();

// ============================================================================
// STEP 5: Add helper method to get Wi-Fi Direct IP (optional, for debugging)
// ============================================================================

/// Get our IP address on the Wi-Fi Direct interface
Future<String?> _getWifiDirectIp() async {
  try {
    final interfaces = await NetworkInterface.list();
    for (var interface in interfaces) {
      // Look for p2p interface (Wi-Fi Direct)
      if (interface.name.contains('p2p')) {
        for (var addr in interface.addresses) {
          if (addr.type == InternetAddressType.IPv4 && !addr.isLoopback) {
            print(
              '📍 Found Wi-Fi Direct IP: ${addr.address} on ${interface.name}',
            );
            return addr.address;
          }
        }
      }
    }
    print('⚠️  No Wi-Fi Direct interface found');
  } catch (e) {
    print('❌ Error getting Wi-Fi Direct IP: $e');
  }
  return null;
}

// ============================================================================
// STEP 6: Cancel subscription in dispose()
// ============================================================================
// Add this line in dispose() method:
// _wifiDirectConnectionSubscription?.cancel();

// ============================================================================
// USAGE NOTES
// ============================================================================
/*
1. This code handles the Wi-Fi Direct group formation on BOTH devices
2. When group is formed:
   - BOTH devices start HTTP servers
   - SENDER device (with _pendingDevice set) sends connection request
   - RECEIVER device waits for connection request via UDP
3. The connection request dialog is shown on receiver via existing
   _connectionRequestSubscription listener
4. File transfer happens via HTTP over Wi-Fi Direct network (192.168.49.x)

FLOW:
Device A (Sender):
  1. User taps Wi-Fi Direct device → _sendConnectionRequest() → connectToWifiDirectPeer()
  2. Group forms → _initWifiDirectListener() fires
  3. Starts HTTP server
  4. Sends UDP connection request to peer
  5. Waits for response

Device B (Receiver):
  1. Receives Wi-Fi Direct connection (system dialog)
  2. Group forms → _initWifiDirectListener() fires
  3. Starts HTTP server
  4. Receives UDP connection request → shows dialog
  5. User accepts → navigates to receive screen
  6. Downloads files via HTTP
*/
