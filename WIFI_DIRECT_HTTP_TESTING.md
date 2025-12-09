# WiFi Direct HTTP Testing Guide

## Prerequisites
- Two Android devices with WiFi Direct support
- ZapShare app installed on both devices
- Location permission granted (required for WiFi Direct peer discovery)
- WiFi enabled on both devices

## Test Scenario 1: Basic WiFi Direct File Transfer

### Setup
1. **Device A** (Sender): Open ZapShare app
2. **Device B** (Receiver): Open ZapShare app

### Steps

#### On Device A (Sender):
1. ✅ Open the "Send" screen
2. ✅ Verify "WiFi Direct Mode" section appears
3. ✅ Wait for Device B to appear in the peer list (should take 5-10 seconds)
4. ✅ Select files to share (tap "Select Files" button)
5. ✅ Choose one or more files from file picker
6. ✅ Verify selected files are displayed
7. ✅ Tap on Device B in the WiFi Direct peer list

**Expected Result**: 
- Loading spinner appears on Device B's icon
- Snackbar shows "Connecting to [Device B] via WiFi Direct..."

#### On Device B (Receiver):
8. ✅ WiFi Direct connection request should appear
9. ✅ Accept the WiFi Direct connection
10. ✅ Wait for connection to establish

**Expected Result**:
- Connection establishes (both devices show connected status)
- Device B receives HTTP connection request dialog
- Dialog shows file names and total size

11. ✅ Tap "Accept" on the connection request dialog

**Expected Result**:
- File transfer begins
- Progress bars appear showing download progress
- Files save to device storage
- Transfer completes successfully

### Verification
- ✅ Check Device B's download folder for received files
- ✅ Verify file sizes match original files
- ✅ Open files to ensure they're not corrupted

---

## Test Scenario 2: WiFi Direct Discovery

### Test Discovery Functionality

1. **Device A**: Open Send screen
2. **Device B**: Open Receive screen (or Send screen)

**Expected Behavior**:
- Device A shows "Scanning for WiFi Direct peers..." initially
- After 5-10 seconds, Device B appears in Device A's peer list
- Device B shows device name and Android icon
- Peer list updates automatically as devices come and go

### Test Indicators:
- ✅ Blue-themed WiFi Direct section
- ✅ WiFi Direct icon (📡) visible
- ✅ Peer count displayed ("1 peer found" or "X peers found")
- ✅ Expandable/collapsible peer list

---

## Test Scenario 3: Connection States

### Test UI States During Connection

1. **Initial State**: 
   - ✅ Peer list shows discovered devices
   - ✅ No connecting animation

2. **Tap on Peer**:
   - ✅ Connecting spinner appears around peer icon
   - ✅ Yellow snackbar shows "Connecting..."
   - ✅ UI is responsive (can cancel/navigate away)

3. **Connection Success**:
   - ✅ Green "Connected" badge appears
   - ✅ Spinner stops
   - ✅ HTTP request sent automatically

4. **Connection Failure** (test by turning off WiFi Direct during connection):
   - ✅ Red snackbar shows error message
   - ✅ Peer returns to normal state
   - ✅ Can retry connection

---

## Test Scenario 4: Multiple Peers

### Test with 3+ Devices

1. Have 3 or more devices running ZapShare
2. Open Send screen on one device
3. Verify all peers appear in the list
4. Select a specific peer and connect
5. Verify only that peer shows connecting state

**Expected**:
- ✅ All nearby WiFi Direct devices are discovered
- ✅ Peer list scrolls horizontally if many devices
- ✅ Each peer has distinct icon and name
- ✅ Only selected peer shows connecting animation

---

## Test Scenario 5: Error Handling

### Test A: No Files Selected
1. Open Send screen
2. Don't select any files
3. Tap on a WiFi Direct peer

**Expected**:
- ✅ Yellow snackbar appears: "Please select files first before sending"
- ✅ No connection initiated

### Test B: Connection Timeout
1. Select files
2. Tap on peer
3. On receiving device, reject the WiFi Direct connection

**Expected**:
- ✅ Connection fails
- ✅ Red error snackbar appears
- ✅ Can try again

### Test C: Transfer Interruption
1. Start a large file transfer
2. Turn off WiFi on one device mid-transfer

**Expected**:
- ✅ Transfer pauses/fails
- ✅ Error indicator appears
- ✅ Can reconnect and resume (HTTP range requests)

---

## Test Scenario 6: Network Transition

### Verify HTTP Server on WiFi Direct Network

1. Connect devices via WiFi Direct
2. Once connected, check logs for:
   - ✅ "WiFi Direct group formed"
   - ✅ IP addresses assigned (192.168.49.x)
   - ✅ "HTTP server started"
   - ✅ "UDP discovery active"

3. Verify HTTP communication:
   - ✅ Peer discovered via UDP on WiFi Direct network
   - ✅ HTTP request sent to correct IP
   - ✅ Files transfer over HTTP

---

## Test Scenario 7: Screen Lifecycle

### Test Dispose/Cleanup

1. Open Send screen → WiFi Direct starts discovering
2. Navigate away (back button)
3. Check logs for:
   - ✅ "WiFi Direct service stopped"
   - ✅ Subscriptions cancelled
   - ✅ No memory leaks

4. Re-open Send screen
5. Verify WiFi Direct discovery starts again

---

## Test Scenario 8: Parallel Transfers

### Test Multiple File Transfer

1. Select multiple files (5-10 files)
2. Connect to peer via WiFi Direct
3. Accept transfer on receiver
4. Monitor progress

**Expected**:
- ✅ All files appear in transfer list
- ✅ Individual progress bars for each file
- ✅ Parallel streaming works (HTTP range requests)
- ✅ All files complete successfully

---

## Test Scenario 9: Large File Transfer

### Test with Large File (>1GB)

1. Select a large video or archive file
2. Transfer via WiFi Direct
3. Monitor progress and speed

**Expected**:
- ✅ Progress updates smoothly
- ✅ Speed indicator shows Mbps
- ✅ Transfer completes without errors
- ✅ File integrity maintained (verify hash if possible)

---

## Test Scenario 10: Bidirectional Transfer

### Test Both Devices Sending

1. Device A sends files to Device B
2. Wait for transfer to complete
3. Device B sends files back to Device A
4. Verify both directions work

**Expected**:
- ✅ Both devices can act as sender/receiver
- ✅ HTTP servers on both devices handle requests
- ✅ No conflicts or issues

---

## Debugging Tips

### Enable Verbose Logging
Check these log tags:
- `🔧 Initializing WiFi Direct service...`
- `🔍 Starting WiFi Direct peer discovery...`
- `📱 WiFi Direct peers updated`
- `🔗 Initiating Wi-Fi Direct connection`
- `✅ WiFi Direct group formed`
- `🚀 Starting HTTP server`
- `📡 UDP discovery active`

### Common Issues

**Issue**: Peers not appearing
- ✅ Check location permission granted
- ✅ Verify WiFi is enabled
- ✅ Check if WiFi Direct is supported on device
- ✅ Wait longer (discovery can take 10-15 seconds)

**Issue**: Connection fails immediately
- ✅ Check both devices have WiFi Direct enabled
- ✅ Verify no existing WiFi Direct connection
- ✅ Try restarting WiFi on both devices

**Issue**: HTTP request not received
- ✅ Verify WiFi Direct group formed (check IP addresses)
- ✅ Check HTTP server started on both devices
- ✅ Verify UDP discovery running
- ✅ Check firewall/security apps not blocking

**Issue**: Slow transfer speed
- ✅ Verify devices support 5GHz WiFi Direct
- ✅ Check for interference (other WiFi networks)
- ✅ Move devices closer together
- ✅ Ensure devices have sufficient storage space

---

## Performance Benchmarks

Expected transfer speeds over WiFi Direct:
- **Good**: 10-30 Mbps (1-4 MB/s)
- **Excellent**: 30-100 Mbps (4-12 MB/s)
- **Outstanding**: 100+ Mbps (12+ MB/s) on newer devices with WiFi 6

Test with various file sizes:
- Small (< 10 MB): Should complete in seconds
- Medium (10-100 MB): Should complete in < 1 minute
- Large (100 MB - 1 GB): Should complete in 1-10 minutes
- Very Large (> 1 GB): May take 10+ minutes depending on speed

---

## Checklist Summary

- [ ] WiFi Direct discovery works
- [ ] Peers appear in UI
- [ ] Can tap peer to connect
- [ ] Connection establishes successfully
- [ ] HTTP server starts on WiFi Direct network
- [ ] UDP discovers peer IP
- [ ] HTTP request sent and received
- [ ] File transfer completes
- [ ] Progress tracking works
- [ ] Error handling works
- [ ] Screen cleanup works (no leaks)
- [ ] Multiple peers supported
- [ ] Large files work
- [ ] Bidirectional transfers work

---

**Status**: Ready for Testing
**Last Updated**: December 7, 2025
