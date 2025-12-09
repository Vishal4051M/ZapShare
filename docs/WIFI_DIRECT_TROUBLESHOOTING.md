# Wi-Fi Direct Troubleshooting Guide

## Issue: Wi-Fi Direct Devices Not Showing Up

### Quick Checklist

Run the app and check the logs for these messages:

1. **Initialization**
   ```
   📡 [WifiDirect] Initializing Wi-Fi Direct...
   ```

2. **Persistent Groups Deletion**
   ```
   🧹 [WifiDirect] Deleting persistent groups...
   🧹 [WifiDirect] Delete result: {success: true, message: ...}
   ```

3. **Discovery Start**
   ```
   🔍 [WifiDirect] Starting peer discovery...
   🔍 [WifiDirect] Discovery result: {success: true, message: ...}
   ✅ [WifiDirect] Discovery started successfully!
   ```

4. **Peer Discovery Callback**
   ```
   📱 [WifiDirect] onPeersDiscovered callback triggered!
   📱 [WifiDirect] Total peers received: X
   ```

### Common Issues and Solutions

#### 1. No Initialization Logs
**Problem**: You don't see `📡 [WifiDirect] Initializing Wi-Fi Direct...`

**Solution**:
- Check that `_initWifiDirect()` is called in `initState()`
- Verify the app is running on a real Android device (not emulator)

#### 2. Discovery Fails
**Problem**: You see `❌ [WifiDirect] Discovery failed: ...`

**Possible Causes**:
- **Missing Permissions**: Check AndroidManifest.xml has:
  ```xml
  <uses-permission android:name="android.permission.ACCESS_WIFI_STATE" />
  <uses-permission android:name="android.permission.CHANGE_WIFI_STATE" />
  <uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />
  <uses-permission android:name="android.permission.NEARBY_WIFI_DEVICES" 
                   android:usesPermissionFlags="neverForLocation" />
  ```

- **Runtime Permissions Not Granted**:
  - Android < 13: Need `ACCESS_FINE_LOCATION`
  - Android >= 13: Need `NEARBY_WIFI_DEVICES`
  
  **Check permissions in app settings**:
  Settings → Apps → ZapShare → Permissions

- **Wi-Fi Disabled**: Enable Wi-Fi on the device

#### 3. Discovery Starts But No Peers Found
**Problem**: Discovery succeeds but `onPeersDiscovered` never triggers

**Debugging Steps**:

1. **Check Native Logs** (Android Studio Logcat):
   ```
   Filter: WifiDirectManager
   ```
   Look for:
   - `Peer discovery started successfully`
   - `Discovered X peers`
   - `Peers changed, requesting peer list`

2. **Verify Method Channel**:
   - Check that `WifiDirectMethodHandler` is initialized in MainActivity
   - Look for line: `wifiDirectMethodHandler = WifiDirectMethodHandler(...)`

3. **Test on Another Device**:
   - Wi-Fi Direct requires **two physical devices**
   - Both devices must have Wi-Fi enabled
   - Both devices should run the app

4. **Check Wi-Fi P2P State**:
   Look for this log:
   ```
   📡 [WifiDirect] Wi-Fi P2P state changed: ENABLED
   ```
   If you see `DISABLED`, enable Wi-Fi on the device.

#### 4. Peers Discovered But Not Showing in UI
**Problem**: Logs show peers but UI is empty

**Check**:
1. **Peer Status**: Only peers with status `3` (Available) are shown
   ```
   📱 [WifiDirect] Available peers: X
   ```

2. **UI Update**: Look for:
   ```
   ✅ [WifiDirect] UI updated with X available peers
   ```

3. **Device List**: Check `_buildCompactDeviceList()` is being called

### Testing Commands

#### Check Permissions (ADB)
```bash
# Check if permissions are granted
adb shell dumpsys package com.example.zap_share | grep permission

# Grant permissions manually
adb shell pm grant com.example.zap_share android.permission.ACCESS_FINE_LOCATION
adb shell pm grant com.example.zap_share android.permission.NEARBY_WIFI_DEVICES
```

#### Check Wi-Fi P2P Status
```bash
# Check if Wi-Fi P2P is supported
adb shell dumpsys wifip2p
```

### Expected Log Flow (Success)

```
📡 [WifiDirect] Initializing Wi-Fi Direct...
📡 [WifiDirect] Wi-Fi P2P state changed: ENABLED
🧹 [WifiDirect] Deleting persistent groups...
🧹 [WifiDirect] Delete result: {success: true, message: Deleted X persistent groups}
🔍 [WifiDirect] Starting peer discovery...
🔍 [WifiDirect] Discovery result: {success: true, message: Discovery started}
✅ [WifiDirect] Discovery started successfully!
   Waiting for peers to be discovered...
   Make sure:
   1. Wi-Fi is enabled on both devices
   2. Location permission is granted
   3. Nearby devices permission is granted (Android 13+)

[After a few seconds when another device is nearby]
📱 [WifiDirect] onPeersDiscovered callback triggered!
📱 [WifiDirect] Total peers received: 1
   - Device: Device Name
     Address: XX:XX:XX:XX:XX:XX
     Status: Available (3)
     Available: true
📱 [WifiDirect] Available peers: 1
✅ [WifiDirect] UI updated with 1 available peers
```

### Manual Testing Steps

1. **Device A (Sender)**:
   - Open ZapShare app
   - Check logs for Wi-Fi Direct initialization
   - Select files to share

2. **Device B (Receiver)**:
   - Open ZapShare app
   - Check logs for Wi-Fi Direct initialization
   - Should see Device A in the device list (blue icon with Wi-Fi symbol)

3. **If devices don't see each other**:
   - Ensure both devices have Wi-Fi **enabled**
   - Check both devices have **location services** enabled
   - Verify **permissions** are granted on both devices
   - Try restarting Wi-Fi on both devices
   - Check if devices can see each other in system Wi-Fi Direct settings:
     - Settings → Wi-Fi → Wi-Fi preferences → Wi-Fi Direct

### Advanced Debugging

#### Enable Verbose Logging in Native Code

Edit `WifiDirectManager.kt` and add more logs:

```kotlin
private fun requestPeers() {
    // Add this log
    Log.d(tag, "🔍 Requesting peer list...")
    
    wifiP2pManager?.requestPeers(channel) { peerList ->
        Log.d(tag, "📱 Peer list received: ${peerList.deviceList.size} devices")
        // ... rest of code
    }
}
```

#### Check Broadcast Receiver

Verify the broadcast receiver is registered in `WifiDirectManager.kt`:
```kotlin
context.registerReceiver(receiver, intentFilter)
```

### Still Not Working?

If you've tried everything above and it still doesn't work:

1. **Check Android Version**: Wi-Fi Direct works best on Android 4.1+
2. **Check Device Compatibility**: Some devices have limited Wi-Fi Direct support
3. **Try System Wi-Fi Direct**: Go to Settings → Wi-Fi → Wi-Fi Direct and see if devices can discover each other there
4. **Check Logs**: Share the full logcat output filtered by "WifiDirect" and "WifiDirectManager"

### Known Limitations

- **Emulators**: Wi-Fi Direct does NOT work on emulators
- **Same Device**: Cannot discover itself
- **Distance**: Devices must be within Wi-Fi range (typically 50-200 meters)
- **Interference**: Other Wi-Fi networks may slow discovery
- **Battery Saver**: Some battery saver modes may disable Wi-Fi Direct
