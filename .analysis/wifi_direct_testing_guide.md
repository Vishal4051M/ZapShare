# Wi-Fi Direct Testing Guide

## Quick Test Scenarios

### Scenario 1: Device A (GO) sends to Device B (Client)
```
1. Device A: Enable Wi-Fi Direct mode
2. Device B: Enable Wi-Fi Direct mode
3. Device A: Discover and connect to Device B
4. Wait for connection (Device A becomes GO)
5. Device A: Select files
6. Device A: Should discover Device B's IP via UDP
7. Device A: Sends connection request
8. Device B: Should see SINGLE dialog (not multiple!)
9. Device B: Accept
10. Files transfer successfully
```

### Scenario 2: Device B (Client) sends to Device A (GO)
```
1. (Continue from Scenario 1 - still connected)
2. Device B: Select different files
3. Device B: Should discover Device A's IP via UDP
4. Device B: Sends connection request
5. Device A: Should see SINGLE dialog
6. Device A: Accept
7. Files transfer successfully
8. ✅ This proves role independence!
```

### Scenario 3: Device B (GO) sends to Device A (Client)
```
1. Disconnect from previous session
2. Device B: Enable Wi-Fi Direct mode
3. Device A: Enable Wi-Fi Direct mode
4. Device B: Discover and connect to Device A
5. Wait for connection (Device B becomes GO)
6. Device B: Select files
7. Device B: Sends connection request
8. Device A: Should see SINGLE dialog
9. Device A: Accept
10. Files transfer successfully
```

## What to Watch For

### ✅ Success Indicators
- Single connection dialog appears
- App remains responsive
- IDE doesn't slow down
- Files transfer successfully
- Both devices can send/receive regardless of GO/Client role

### ❌ Failure Indicators
- Multiple dialogs appear (deduplication failed)
- App crashes or freezes
- IDE becomes unresponsive
- Connection request not received
- Hardcoded IP assumptions visible in logs

## Log Messages to Check

### Good Logs (After Fix)
```
🔗 WiFi Direct Connected! Group Owner: true, Owner Address: 192.168.49.1
   ⚠️  NOTE: Wi-Fi Direct role does NOT determine sender/receiver!
   Both devices will start HTTP server and use UDP discovery.
🚀 Starting HTTP server on WiFi Direct network...
   My IP: 192.168.49.1
   Role: Group Owner
📡 UDP discovery active - waiting to discover peer device...
   Peer will be discovered automatically via UDP broadcast
📤 Files selected - will send connection request once peer is discovered
   Files: 3 files
⏳ Waiting for peer device to appear in discovery list...
   Currently discovered 1 devices
✅ Found Wi-Fi Direct peer via UDP discovery: Device B (192.168.49.2)
✅ Connection request sent to discovered peer

📩 Received connection request from 192.168.49.2
   Device: Device A (abc123)
   Files: 3 files, 15.50 MB
   ✅ First request from this device (or outside deduplication window)
✅ Connection request added to stream (will show dialog)
```

### Bad Logs (Before Fix)
```
❌ Multiple connection requests received
❌ Showing multiple dialogs
❌ App becoming unresponsive
❌ Hardcoded IP: 192.168.49.2 (based on role)
```

## Performance Metrics

### Before Fix
- UDP broadcast: Every 5 seconds
- Connection dialogs: 3-5 per request (crashes!)
- App responsiveness: Poor during Wi-Fi Direct
- IDE: Becomes slow

### After Fix
- UDP broadcast: Every 8 seconds (37% reduction)
- Connection dialogs: 1 per request (deduplicated)
- App responsiveness: Good
- IDE: Normal performance

## Debugging Commands

### Check UDP Discovery
```bash
# On Android device
adb logcat | grep "📡\|📩\|✅"
```

### Check Connection Requests
```bash
# Look for deduplication messages
adb logcat | grep "IGNORING duplicate\|First request"
```

### Check Wi-Fi Direct Status
```bash
# Check Wi-Fi Direct connection info
adb logcat | grep "WiFi Direct Connected\|Group Owner"
```

## Common Issues & Solutions

### Issue: No connection dialog appears
**Cause:** UDP discovery not working
**Solution:** Check multicast lock, check network interfaces

### Issue: Multiple dialogs appear
**Cause:** Deduplication not working
**Solution:** Check `_recentConnectionRequests` map, verify 10s window

### Issue: Connection request fails
**Cause:** IP not discovered yet
**Solution:** Increase wait time, check fallback IPs

### Issue: App crashes
**Cause:** Too many UDP messages
**Solution:** Verify broadcast interval is 8s, check deduplication

## Test Matrix

| Scenario | Device A Role | Device B Role | Sender | Receiver | Expected Result |
|----------|---------------|---------------|--------|----------|-----------------|
| 1 | GO | Client | A | B | ✅ Works |
| 2 | GO | Client | B | A | ✅ Works |
| 3 | Client | GO | A | B | ✅ Works |
| 4 | Client | GO | B | A | ✅ Works |

**All 4 scenarios should work!** This proves role independence.

## Quick Verification Checklist

- [ ] Single dialog per connection request
- [ ] App remains responsive
- [ ] Both GO and Client can send
- [ ] Both GO and Client can receive
- [ ] UDP discovery finds peer IP
- [ ] Fallback IPs work if needed
- [ ] No crashes or freezes
- [ ] IDE remains responsive

---

**Remember:** Wi-Fi Direct role (GO/Client) is for network topology only.
Sender/Receiver is determined by who has files selected, not by Wi-Fi Direct role!
