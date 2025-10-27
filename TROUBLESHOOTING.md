# ZapShare - Troubleshooting Guide

## Connection Request Not Received

### Issue
When you select files and send a connection request, nothing appears on the receiving device.

### Root Causes Fixed

1. **Device Discovery Not Initialized**
   - **Problem**: Discovery service was started without initializing device info first
   - **Symptom**: `_myDeviceId` and `_myDeviceName` were null, causing invalid requests
   - **Fix**: Added `await _discoveryService.initialize()` before `start()`

2. **Wrong Parameter in Response Handler**
   - **Problem**: Sending `request.deviceId` instead of `request.ipAddress` to `sendConnectionResponse()`
   - **Symptom**: Responses sent to wrong destination (device ID instead of IP)
   - **Fix**: Changed to use `request.ipAddress` for both accept and decline

### Debug Logging Added

The app now prints detailed logs to help diagnose issues:

**Sending Side:**
```
🔍 Initializing device discovery...
✅ Device discovery started
✅ All stream listeners set up
📱 Nearby devices updated: 2 devices
✅ Sent connection request to 192.168.1.100 (245 bytes)
   Device: My Phone (1234567890)
   Files: 3 files, 5.2 MB
```

**Receiving Side:**
```
📩 Received connection request from 192.168.1.50
   Device: My Phone (1234567890)
   Files: 3 files, 5.2 MB
✅ Connection request added to stream
📩 Incoming connection request from My Phone (192.168.1.50)
```

**After Accept:**
```
📨 Connection response received: accepted=true, ip=192.168.1.50
✅ Connection accepted! Starting server...
```

### How to Check Logs

**Android:**
```bash
adb logcat | grep -E "Device discovery|connection request|connection response"
```

**Flutter Debug Console:**
- Run app from VS Code or Android Studio
- Watch debug console for emoji-prefixed messages

### Common Issues

#### 1. No Devices Appear
**Symptoms:**
- "Nearby Devices" section is empty or doesn't appear
- No devices discovered

**Possible Causes:**
- Devices not on same network
- UDP port 37020 blocked by firewall
- Multicast disabled on router
- App not running on receiving device

**Solutions:**
- Ensure both devices on same Wi-Fi network
- Check firewall settings (allow UDP 37020)
- Try different Wi-Fi network
- Keep app open on both devices

#### 2. Request Sent But Not Received
**Symptoms:**
- Yellow snackbar shows "Connection request sent"
- Nothing appears on receiver
- Logs show request sent but not received

**Possible Causes:**
- Receiver app in background (Android may kill socket)
- Port blocked on receiver
- Wrong IP address

**Solutions:**
- Keep receiver app in foreground
- Check device IP addresses match what's shown
- Try restarting discovery on both devices

#### 3. No Response After Accept
**Symptoms:**
- Receiver taps Accept
- Sender doesn't start server
- Pending indicator stays on sender

**Possible Causes:**
- Response not reaching sender
- Wrong IP in response
- Stream listener not set up

**Solutions:**
- Check logs for "Connection response received"
- Verify IP addresses
- Restart both apps

### Network Requirements

**Ports Used:**
- **37020 (UDP)**: Device discovery and connection requests
- **8080 (TCP)**: HTTP file transfer server

**Network Setup:**
- Both devices must be on same subnet (e.g., 192.168.1.x)
- Router must allow multicast (239.255.43.21)
- No VPN or firewall blocking UDP broadcast

### Testing Connection

**Step-by-Step Test:**

1. **Device A (Sender):**
   ```
   - Open app
   - Check logs: "Device discovery started"
   - Go to send screen
   - Select files
   - Wait for devices to appear
   ```

2. **Device B (Receiver):**
   ```
   - Open app
   - Keep in foreground
   - Check logs: "Device discovery started"
   - Wait for sender to appear in nearby devices
   ```

3. **Send Request:**
   ```
   - Tap device on sender
   - Check sender logs: "Sent connection request to X.X.X.X"
   - Check receiver logs: "Received connection request from X.X.X.X"
   - Dialog should appear on receiver
   ```

4. **Accept Request:**
   ```
   - Tap Accept on receiver
   - Check receiver logs: "Connection response added to stream"
   - Check sender logs: "Connection response received: accepted=true"
   - Server should start on sender
   ```

### Advanced Debugging

#### Check UDP Socket
```dart
// In device_discovery_service.dart, start() method
print('Socket bound to port $DISCOVERY_PORT');
print('Joined multicast group $MULTICAST_GROUP');
```

#### Verify Device Info
```dart
// After initialize()
print('My Device ID: $_myDeviceId');
print('My Device Name: $_myDeviceName');
```

#### Monitor Network Traffic
**Linux/Mac:**
```bash
tcpdump -i any -n udp port 37020
```

**Windows:**
```powershell
# Use Wireshark with filter: udp.port == 37020
```

### Quick Fixes

**Reset Device Discovery:**
1. Close app completely
2. Clear app data (Settings > Apps > ZapShare > Clear Data)
3. Reopen app
4. Discovery will reinitialize with fresh device ID

**Force Reconnection:**
1. Toggle Wi-Fi off/on
2. Reopen app
3. Wait 10 seconds for cleanup timer

### Error Messages

| Message | Meaning | Solution |
|---------|---------|----------|
| `ERROR: socket is null` | Discovery not started | Restart app |
| `ERROR: device info not initialized` | Initialize() not called | Check _initDeviceDiscovery() |
| `No nearby devices` | Discovery working but none found | Check network, firewall |
| `Connection request was declined` | User declined on receiver | Try again, ask user to accept |

### Performance Tips

1. **Battery Optimization**: Disable for ZapShare (Android)
2. **Background Restrictions**: Allow background activity
3. **Network Permissions**: Ensure granted
4. **Firewall**: Allow UDP 37020 and TCP 8080

### Still Not Working?

**Collect Diagnostic Info:**
1. Device models and OS versions
2. Network type (home Wi-Fi, mobile hotspot, etc.)
3. Full logs from both devices
4. IP addresses shown in app
5. Router model

**Check:**
- Android permissions (Storage, Network)
- Wi-Fi Direct vs regular Wi-Fi
- Guest network isolation
- AP isolation on router

---

**Last Updated**: January 2025  
**Version**: 1.0 with connection request feature
