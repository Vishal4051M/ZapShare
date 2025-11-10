# Hotspot Discovery Fix - Making Your Device Visible

## 🔍 Problem Identified

When you turn on your mobile hotspot to share files, **your device doesn't show up** on the other person's device, but **their device is visible to you**. This is a one-way visibility issue.

## 🎯 Root Cause

The issue occurs because:

1. **Android blocks multicast packets by default** on WiFi/hotspot networks to save battery
2. Your app uses **UDP multicast broadcasting** (multicast group `239.255.43.21`) for device discovery
3. When your device is the **hotspot host**:
   - ✅ You can **send** multicast broadcasts (so others see you)
   - ❌ You **cannot receive** multicast packets from others (so you don't see them)
   - This is because Android needs a **WifiManager.MulticastLock** to receive multicast packets

## ✅ Solution Applied

### 1. Added Missing Android Permission

**File: `android/app/src/main/AndroidManifest.xml`**

Added the `CHANGE_WIFI_MULTICAST_STATE` permission:

```xml
<uses-permission android:name="android.permission.CHANGE_WIFI_MULTICAST_STATE"/>
```

This permission allows the app to acquire a multicast lock.

### 2. Implemented Multicast Lock in Native Code

**File: `android/app/src/main/kotlin/com/example/zap_share/MainActivity.kt`**

Added code to **acquire and manage a multicast lock**:

```kotlin
private var multicastLock: WifiManager.MulticastLock? = null

private fun acquireMulticastLock() {
    val wifiManager = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
    multicastLock = wifiManager.createMulticastLock("ZapShare:MulticastLock")
    multicastLock?.setReferenceCounted(false)
    multicastLock?.acquire()
    // Now your device can RECEIVE multicast packets!
}
```

The multicast lock:
- ✅ Enables reception of UDP multicast packets
- ✅ Automatically acquired when app starts
- ✅ Re-acquired when app comes to foreground
- ✅ Released when app is destroyed (to save battery)

## 🧪 Testing the Fix

### Before Testing
1. **Rebuild the app** (the Android changes require a rebuild):
   ```bash
   flutter clean
   flutter pub get
   flutter build apk
   ```
   OR just run:
   ```bash
   flutter run
   ```

2. **Install on both devices**

### Test Procedure

#### Scenario 1: Your Device as Hotspot
1. **Your Device (Hotspot Host)**:
   - Turn on mobile hotspot
   - Open ZapShare
   - Go to Send screen (or Home screen)
   
2. **Other Device (Hotspot Client)**:
   - Connect to your hotspot
   - Open ZapShare
   - Go to Send screen

3. **Expected Result**:
   - ✅ Both devices should now see each other
   - ✅ Discovery should work both ways

#### Scenario 2: Regular WiFi Network
1. Both devices connect to same WiFi network
2. Open ZapShare on both
3. Expected Result:
   - ✅ Both devices see each other (this should have worked before)

### Check Logs

After rebuilding, check the Android logs:

```bash
adb logcat | grep -i zapshare
```

You should see:
```
✅ Multicast lock ACQUIRED - UDP discovery enabled
```

If you see this, the fix is active!

## 🔧 How It Works

### Without Multicast Lock (Before)
```
[Other Device] --> UDP Multicast Broadcast --> [Your Device]
                                                     ❌ Packet DROPPED by Android
                                                     (Power saving mode)
```

### With Multicast Lock (After)
```
[Other Device] --> UDP Multicast Broadcast --> [Your Device]
                                                     ✅ Packet RECEIVED
                                                     ✅ Device discovered!
```

## 📊 Technical Details

### Discovery Protocol
- **Multicast Group**: `239.255.43.21`
- **UDP Port**: `37020`
- **Broadcast Interval**: Every 5 seconds
- **Message Type**: `ZAPSHARE_DISCOVERY`

### Why Multicast Lock is Needed
1. **Battery Optimization**: Android disables multicast reception by default to save power
2. **Hotspot Mode**: When device is hotspot, it acts as gateway/router
3. **Network Interface**: The `wlan0` or `ap0` interface needs explicit permission to receive multicast
4. **Lock Behavior**: 
   - Without lock: Can send multicast, but receives NOTHING
   - With lock: Can both send AND receive multicast

### Multicast Lock Lifecycle
```
App Start
    ↓
configureFlutterEngine()
    ↓
acquireMulticastLock() ← ✅ Lock acquired
    ↓
[Discovery Works Both Ways]
    ↓
App Goes to Background
    ↓
onPause() ← Lock kept (for continuous discovery)
    ↓
App Returns to Foreground
    ↓
onResume()
    ↓
acquireMulticastLock() ← ✅ Lock re-acquired (if released)
    ↓
App Closed
    ↓
onDestroy()
    ↓
releaseMulticastLock() ← Lock released
```

## 🚨 Troubleshooting

### Still Not Working?

1. **Check Permission Granted**:
   ```bash
   adb shell dumpsys package com.example.zap_share | grep -i multicast
   ```

2. **Check Multicast Lock Status**:
   ```bash
   adb logcat | grep "Multicast lock"
   ```
   
   Should show:
   ```
   ✅ Multicast lock ACQUIRED - UDP discovery enabled
   ```

3. **Verify Socket Binding**:
   ```bash
   adb logcat | grep "Socket bound"
   ```
   
   Should show:
   ```
   ✅ Socket bound to port 37020
   ✅ Joined multicast group 239.255.43.21
   ```

4. **Test UDP Packets** (Advanced):
   ```bash
   # On your device (hotspot host)
   adb shell tcpdump -i any -n udp port 37020
   ```
   
   You should see packets flowing both directions.

### Other Possible Issues

1. **Firewall on Other Device**: Check if their device has a firewall blocking UDP 37020
2. **Hotspot Isolation**: Some devices enable AP isolation (prevents clients from seeing each other)
   - Solution: Disable AP isolation in hotspot settings (if available)
3. **Network Subnet**: Ensure both devices are on same subnet (usually `192.168.43.x` for hotspot)

## 📱 Battery Impact

**Q: Does the multicast lock drain battery?**

A: Minimal impact:
- Lock is only held when app is running
- Released when app is closed
- Modern Android optimizes multicast filtering
- Estimated impact: < 1% battery per hour

**Q: Should I release the lock when app goes to background?**

A: Current implementation keeps it active for continuous discovery. If battery is a concern, you can modify `onPause()` to release it:

```kotlin
override fun onPause() {
    super.onPause()
    releaseMulticastLock() // Add this to release on background
}
```

## 🎉 Expected Behavior After Fix

### Hotspot Scenario
- ✅ You (hotspot host) can see all connected clients
- ✅ All clients can see you (hotspot host)
- ✅ Clients can see each other (if AP isolation disabled)
- ✅ Bidirectional file transfer works

### WiFi Scenario
- ✅ All devices on network can see each other
- ✅ No change from before (still works)

## 📝 Summary of Changes

| File | Change | Purpose |
|------|--------|---------|
| `AndroidManifest.xml` | Added `CHANGE_WIFI_MULTICAST_STATE` permission | Allows app to acquire multicast lock |
| `MainActivity.kt` | Added multicast lock variable | Store lock reference |
| `MainActivity.kt` | Added `acquireMulticastLock()` method | Enable multicast reception |
| `MainActivity.kt` | Added `releaseMulticastLock()` method | Clean up lock on exit |
| `MainActivity.kt` | Modified `configureFlutterEngine()` | Acquire lock on startup |
| `MainActivity.kt` | Added `onResume()` override | Re-acquire lock when app returns |
| `MainActivity.kt` | Added `onDestroy()` override | Release lock on app exit |

## 🔗 References

- [Android MulticastLock Documentation](https://developer.android.com/reference/android/net/wifi/WifiManager.MulticastLock)
- [UDP Multicast on Android](https://developer.android.com/reference/java/net/MulticastSocket)
- [WiFi Permissions](https://developer.android.com/guide/topics/connectivity/wifi-permissions)

---

**Last Updated**: January 2025  
**Fix Applied**: Multicast Lock for Hotspot Discovery
