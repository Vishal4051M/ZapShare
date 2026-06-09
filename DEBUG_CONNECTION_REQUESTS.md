# Debug Guide: Connection Requests Not Working

## Quick Fix Applied ✅

**CRITICAL BUG FIXED**: The app was creating multiple instances of `DeviceDiscoveryService`, causing only one to actually bind to the UDP socket. 

**Solution**: Made `DeviceDiscoveryService` a **singleton** so all screens share the same instance.

---

## What to Look For in Logs

### On SENDER Device (when you tap a nearby device):

```
✅ Sent connection request to 192.168.1.100 (245 bytes)
   Device: My Phone (1234567890)
   Files: 3 files, 5.2 MB
```

### On RECEIVER Device (should see ALL of these):

```
📨 Received UDP message from 192.168.1.50:37020
   Type: ZAPSHARE_CONNECTION_REQUEST
   Sender Device ID: 1234567890
   My Device ID: 9876543210
   🎯 Handling connection request...
📩 Received connection request from 192.168.1.50
   Device: My Phone (1234567890)
   Files: 3 files, 5.2 MB
✅ Connection request added to stream
✅ Connection request listener active
📩 Stream listener received connection request from My Phone (192.168.1.50)
🚀 _showConnectionRequestDialog called
   Device: My Phone
   IP: 192.168.1.50
   Files: 3
   Context valid: true
📱 Building ConnectionRequestDialog...
✅ Dialog shown
```

---

## Diagnostic Steps

### Step 1: Verify Singleton is Working

**On BOTH devices, check logs when app starts:**

✅ **CORRECT** (should see only ONCE per app launch):
```
🔍 Initializing device discovery...
✅ Socket bound to port 37020
✅ Joined multicast group 239.255.43.21
✅ Device discovery started successfully
```

❌ **WRONG** (if you see this twice, singleton not working):
```
🔍 Initializing device discovery...
✅ Socket bound to port 37020
❌ Error starting device discovery: SocketException: Address already in use
```

### Step 2: Check Message Reception

**Send a request and look for this on RECEIVER:**

```
📨 Received UDP message from X.X.X.X:37020
   Type: ZAPSHARE_CONNECTION_REQUEST
```

**If you DON'T see this:**
- ❌ UDP packets not reaching receiver
- Check firewall on receiver device
- Verify both on same network
- Try pinging receiver from sender

**If you DO see it but no "Handling connection request":**
- ❌ Message being ignored (check device IDs)
- Look for: `⏭️  Ignoring own message`
- This means sender and receiver have same device ID!

### Step 3: Check Stream Listener

**After seeing "Connection request added to stream", look for:**

```
📩 Stream listener received connection request from...
```

**If you DON'T see this:**
- ❌ Stream listener not set up correctly
- Check if `_initDeviceDiscovery()` was called
- Look for: `✅ Connection request listener active`

### Step 4: Check Dialog Display

**After stream listener fires, look for:**

```
🚀 _showConnectionRequestDialog called
📱 Building ConnectionRequestDialog...
✅ Dialog shown
```

**If you DON'T see this:**
- ❌ Widget might not be mounted
- Look for: `⚠️  Widget not mounted, ignoring connection request`
- Ensure HttpFileShareScreen is the active screen

---

## Common Issues & Fixes

### Issue 1: "Address already in use"
**Symptom:**
```
❌ Error starting device discovery: SocketException: Address already in use
```

**Cause:** Multiple instances of DeviceDiscoveryService

**Fix:** ✅ Already fixed by making it a singleton

**Verify:** Should only see ONE "Socket bound to port 37020" per app launch

---

### Issue 2: Same Device ID on Both Devices
**Symptom:**
```
⏭️  Ignoring own message
```

**Cause:** Both devices have the same device ID (very rare, but possible if app data was cloned)

**Fix:**
1. Clear app data on one device
2. Restart app
3. New device ID will be generated

**Verify:**
```
My Device ID: 1234567890  ← Sender
Sender Device ID: 1234567890  ← Same! This is the problem
```

Should be:
```
My Device ID: 9876543210  ← Receiver (different)
Sender Device ID: 1234567890  ← Sender (different)
```

---

### Issue 3: Widget Not Mounted
**Symptom:**
```
⚠️  Widget not mounted, ignoring connection request
```

**Cause:** HttpFileShareScreen disposed or user navigated away

**Fix:** Ensure receiver stays on the main screen or send screen

---

### Issue 4: No UDP Messages Received
**Symptom:**
- No "Received UDP message" logs at all
- Discovery broadcasts work, but connection requests don't

**Possible Causes:**
1. Firewall blocking UDP port 37020
2. Network isolation (guest network, AP isolation)
3. Devices on different subnets
4. Router blocking multicast/broadcast

**Debug:**

**On Sender:**
```
✅ Sent connection request to 192.168.1.100 (245 bytes)
```

**On Receiver:**
```
[NOTHING - no UDP message received]
```

**Solutions:**
- Disable firewall temporarily
- Check both devices on same subnet (192.168.1.x)
- Try mobile hotspot instead
- Use `tcpdump` or Wireshark to see if packets reach receiver

---

## Testing Procedure

### Full End-to-End Test

1. **Start Receiver App:**
   ```
   - Open app
   - Go to Home or Send screen
   - Check logs for: "Device discovery started successfully"
   - Leave app in foreground
   ```

2. **Start Sender App:**
   ```
   - Open app
   - Go to Send screen
   - Select files
   - Check logs for: "Device discovery started successfully"
   - Wait 5-10 seconds for devices to discover each other
   ```

3. **Verify Discovery:**
   ```
   Sender should see receiver in "Nearby Devices"
   Check logs for: "Nearby devices updated: X devices"
   ```

4. **Send Request:**
   ```
   - Tap receiver device
   - Watch logs on BOTH devices
   - Sender: "Sent connection request to..."
   - Receiver: "Received UDP message from..."
   ```

5. **Verify Dialog:**
   ```
   - Dialog should appear on receiver
   - Check logs: "Dialog shown"
   ```

6. **Accept Request:**
   ```
   - Tap Accept
   - Check logs: "User accepted connection request"
   - Sender should get response
   - Server should start
   ```

---

## Log Analysis Tool

### Expected Complete Flow

**Sender Side:**
```
1. 🔍 Initializing device discovery...
2. ✅ Socket bound to port 37020
3. ✅ Device discovery started successfully
4. ✅ Connection request listener active
5. 📱 Nearby devices updated: 1 devices
6. [User taps device]
7. ✅ Sent connection request to 192.168.1.100 (245 bytes)
8. 📨 Connection response received: accepted=true
9. ✅ Connection accepted! Starting server...
```

**Receiver Side:**
```
1. 🔍 Initializing device discovery...
2. ✅ Socket bound to port 37020
3. ✅ Device discovery started successfully
4. ✅ Connection request listener active
5. 📨 Received UDP message from 192.168.1.50:37020
6.    Type: ZAPSHARE_CONNECTION_REQUEST
7. 📩 Received connection request from 192.168.1.50
8. ✅ Connection request added to stream
9. 📩 Stream listener received connection request from My Phone
10. 🚀 _showConnectionRequestDialog called
11. 📱 Building ConnectionRequestDialog...
12. ✅ Dialog shown
13. [User taps Accept]
14. ✅ User accepted connection request
15. ✅ Sent connection response to 192.168.1.50: true
```

---

## Quick Checklist

Before reporting an issue, verify:

- [ ] Both devices show "Socket bound to port 37020" (only once each)
- [ ] Both devices show "Device discovery started successfully"
- [ ] Sender shows "Nearby devices updated" with count > 0
- [ ] Sender shows "Sent connection request" with bytes sent
- [ ] Receiver shows "Received UDP message" with correct type
- [ ] Receiver shows "Connection request added to stream"
- [ ] Receiver shows "Stream listener received connection request"
- [ ] Receiver shows "Dialog shown"
- [ ] Both devices on same network (check IP addresses)
- [ ] No firewall blocking UDP 37020
- [ ] Receiver app in foreground

If ANY of these fail, use this guide to find the broken step!

---

**Last Updated**: January 2025  
**Fix Applied**: Singleton pattern for DeviceDiscoveryService
