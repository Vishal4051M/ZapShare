# 🧪 Testing Checklist - Hotspot Discovery Fix

## ✅ Pre-Test Requirements

- [ ] Code changes applied (AndroidManifest.xml + MainActivity.kt)
- [ ] App rebuilt with `flutter clean && flutter run`
- [ ] App installed on BOTH devices
- [ ] Both devices have ZapShare app with latest version

---

## 📋 Test Scenarios

### Test 1: Hotspot Mode (Your Device as Host)

**Setup:**
1. [ ] Your device: Turn ON mobile hotspot
2. [ ] Other device: Connect to your hotspot
3. [ ] Check: Other device connected successfully
4. [ ] Check: Other device has internet (if tethering enabled)

**Test Discovery:**
1. [ ] Your device: Open ZapShare
2. [ ] Your device: Go to Send screen (or stay on Home)
3. [ ] Other device: Open ZapShare
4. [ ] Other device: Go to Send screen (or stay on Home)
5. [ ] Wait 10 seconds for discovery

**Expected Results:**
- [ ] Your device shows: "1 device found" (other device visible) ✅
- [ ] Other device shows: "1 device found" (your device visible) ✅
- [ ] Both devices show correct device names
- [ ] Both devices show correct IP addresses (192.168.43.x)

**Logs to Check (adb logcat):**
```bash
# On your device (hotspot host)
adb logcat | grep -E "Multicast|Socket bound|discovery"
```

Expected log output:
- [ ] `✅ Multicast lock ACQUIRED - UDP discovery enabled`
- [ ] `✅ Socket bound to port 37020`
- [ ] `✅ Joined multicast group 239.255.43.21`
- [ ] `✅ Device discovery started successfully`
- [ ] `📨 Received UDP message from 192.168.43.XXX:37020`
- [ ] `📱 Nearby devices updated: 1 devices`

---

### Test 2: File Transfer (Hotspot Mode)

**Send from Your Device (Hotspot) → Other Device:**
1. [ ] Your device: Select files to send
2. [ ] Your device: Tap on other device in "Nearby Devices"
3. [ ] Other device: Connection request dialog appears
4. [ ] Other device: Tap "Accept"
5. [ ] Files transfer successfully
6. [ ] Files saved on other device

**Send from Other Device → Your Device (Hotspot):**
1. [ ] Other device: Select files to send
2. [ ] Other device: Tap on your device in "Nearby Devices"
3. [ ] Your device: Connection request dialog appears
4. [ ] Your device: Tap "Accept"
5. [ ] Files transfer successfully
6. [ ] Files saved on your device

**Expected Results:**
- [ ] Both directions work ✅
- [ ] No connection errors
- [ ] Transfer speed reasonable (depends on WiFi)

---

### Test 3: Regular WiFi Mode (Both on Same Network)

**Setup:**
1. [ ] Both devices: Turn OFF hotspot (if on)
2. [ ] Both devices: Connect to same WiFi network
3. [ ] Check: Both connected to same network

**Test Discovery:**
1. [ ] Both devices: Open ZapShare
2. [ ] Both devices: Go to Send screen
3. [ ] Wait 10 seconds for discovery

**Expected Results:**
- [ ] Both devices see each other ✅
- [ ] Discovery works (should have worked before too)
- [ ] File transfer works in both directions

---

### Test 4: Hotspot Mode (Other Device as Host)

**Setup:**
1. [ ] Other device: Turn ON mobile hotspot
2. [ ] Your device: Connect to their hotspot
3. [ ] Check: Connected successfully

**Test Discovery:**
1. [ ] Both devices: Open ZapShare
2. [ ] Wait 10 seconds

**Expected Results:**
- [ ] Both devices see each other ✅
- [ ] File transfer works both ways

---

## 🔍 Troubleshooting Tests

### If Discovery Fails:

**Test: Permission Check**
```bash
# Check if permission is in manifest
adb shell dumpsys package com.example.zap_share | grep -i multicast
```
- [ ] Should show: `android.permission.CHANGE_WIFI_MULTICAST_STATE`

**Test: Multicast Lock Status**
```bash
adb logcat | grep "Multicast lock"
```
- [ ] Should show: `✅ Multicast lock ACQUIRED - UDP discovery enabled`

**Test: Socket Binding**
```bash
adb logcat | grep "Socket bound"
```
- [ ] Should show: `✅ Socket bound to port 37020`

**Test: UDP Packets (Advanced)**
```bash
# On hotspot host device
adb shell su -c "tcpdump -i any -n udp port 37020"
```
- [ ] Should see packets flowing in BOTH directions
- [ ] Incoming packets from client device
- [ ] Outgoing packets to multicast group

---

## 📊 Performance Tests

### Battery Drain Test
1. [ ] Full charge both devices
2. [ ] Run ZapShare with hotspot for 1 hour
3. [ ] Check battery usage in Settings → Battery
4. [ ] Expected: < 5% drain for multicast lock

### Discovery Speed Test
1. [ ] Start stopwatch
2. [ ] Open ZapShare on both devices
3. [ ] Record time until devices appear
4. [ ] Expected: < 10 seconds (usually 5-6 seconds)

### Multiple Devices Test (If Available)
1. [ ] Your device: Turn ON hotspot
2. [ ] Connect 2-3 other devices to hotspot
3. [ ] Open ZapShare on all devices
4. [ ] Check: All devices see each other
5. [ ] Expected: N devices should see (N-1) devices each

---

## 📝 Test Results Template

**Date:** _______________  
**Tester:** _______________  
**App Version:** _______________

| Test | Status | Notes |
|------|--------|-------|
| Hotspot Discovery (You as Host) | ☐ Pass ☐ Fail | |
| File Transfer (You → Other) | ☐ Pass ☐ Fail | |
| File Transfer (Other → You) | ☐ Pass ☐ Fail | |
| Regular WiFi Discovery | ☐ Pass ☐ Fail | |
| Hotspot Discovery (Other as Host) | ☐ Pass ☐ Fail | |
| Multicast Lock Acquired | ☐ Pass ☐ Fail | |
| Battery Impact Acceptable | ☐ Pass ☐ Fail | |
| Discovery Speed < 10s | ☐ Pass ☐ Fail | |

**Overall Result:** ☐ PASS ☐ FAIL

**Issues Found:** 
_____________________________________________
_____________________________________________
_____________________________________________

**Screenshots:**
- [ ] Both devices showing each other
- [ ] Connection request dialog
- [ ] Successful file transfer
- [ ] Log output showing multicast lock

---

## 🐛 Common Issues & Solutions

### Issue: "Multicast lock not acquired" in logs
**Solution:** 
- Check if `CHANGE_WIFI_MULTICAST_STATE` permission in AndroidManifest.xml
- Rebuild app with `flutter clean`
- Ensure MainActivity.kt has multicast lock code

### Issue: Still can't see other device (hotspot mode)
**Checklist:**
- [ ] App rebuilt after code changes?
- [ ] Multicast lock acquired? (check logs)
- [ ] Both on same network? (check IP addresses)
- [ ] Firewall disabled on both devices?
- [ ] Hotspot AP isolation disabled?

### Issue: Works on WiFi but not hotspot
**Diagnosis:**
- This means multicast lock not working
- Check: `adb logcat | grep "Multicast lock"`
- Should see: "✅ Multicast lock ACQUIRED"
- If not, permission might be missing

### Issue: Discovery slow (> 30 seconds)
**Possible Causes:**
- Poor WiFi signal
- High network congestion
- Discovery service not started
- Check logs for broadcast messages

---

## 🎯 Success Criteria

The fix is successful if:

1. ✅ Both devices see each other in hotspot mode (you as host)
2. ✅ Discovery time < 10 seconds
3. ✅ File transfer works both directions
4. ✅ Multicast lock acquired (confirmed in logs)
5. ✅ Works on both hotspot AND regular WiFi
6. ✅ Battery impact minimal (< 5% per hour)
7. ✅ No crashes or errors

If ALL above are ✅, the fix is **SUCCESSFUL!** 🎉

---

## 📸 Evidence Checklist

For documentation, collect:
- [ ] Screenshot: Both devices showing each other
- [ ] Screenshot: "Multicast lock ACQUIRED" log entry
- [ ] Screenshot: Successful file transfer
- [ ] Video: Complete discovery flow (optional)
- [ ] Battery stats after 1 hour (optional)

---

**Last Updated:** January 2025  
**Related Docs:** `HOTSPOT_DISCOVERY_FIX.md`, `QUICK_FIX_SUMMARY.md`
