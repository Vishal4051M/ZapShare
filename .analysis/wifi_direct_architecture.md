# Wi-Fi Direct Architecture Fix

## Current Problems

### 1. **Incorrect Role Assumption**
- ❌ Code assumes Group Owner = Sender
- ❌ Code assumes Client = Receiver
- ✅ **Reality**: Wi-Fi Direct only establishes P2P network, roles are independent

### 2. **Performance Issues**
- Multiple UDP broadcasts causing crashes
- Inefficient connection request handling
- App and IDE becoming slow/unresponsive

### 3. **Missing IP Discovery**
- After Wi-Fi Direct connection, devices don't properly discover each other's IPs
- HTTP communication not properly established

## Correct Architecture

### Phase 1: Wi-Fi Direct Connection (Network Establishment Only)
```
Device A                          Device B
   |                                 |
   |-- Discover Peers -------------→ |
   |← Peer List -------------------- |
   |                                 |
   |-- Connect (GO Intent=15) -----→ |
   |                                 |
   |← Connection Established -------- |
   |                                 |
   | Group Formed:                   |
   | - GO: 192.168.49.1              |
   | - Client: 192.168.49.2          |
```

### Phase 2: HTTP Server & IP Discovery
```
Both Devices Start HTTP Servers:
   Device A: http://192.168.49.1:8080
   Device B: http://192.168.49.2:8080

Both Devices Broadcast UDP Discovery:
   "I'm here at 192.168.49.X"
```

### Phase 3: File Transfer (Independent of Wi-Fi Direct Roles)
```
Sender (can be GO or Client):
   1. Selects files
   2. Starts HTTP server
   3. Sends connection request via UDP to peer IP
   4. Waits for receiver to accept

Receiver (can be GO or Client):
   1. Receives connection request
   2. Shows approval dialog
   3. If accepted, downloads files via HTTP
```

## Key Changes Needed

### 1. Remove Role-Based Logic
- Don't assume GO = sender
- Don't hardcode IP based on role
- Both devices should discover each other via UDP

### 2. Optimize UDP Discovery
- Reduce broadcast frequency
- Implement debouncing for connection requests
- Add request deduplication

### 3. Proper IP Discovery
- After Wi-Fi Direct connection, wait for IP assignment
- Use UDP discovery to find peer's actual IP
- Don't assume fixed IPs (192.168.49.1/2)

### 4. Performance Optimization
- Throttle UI updates
- Debounce connection requests (prevent multiple dialogs)
- Implement proper cleanup

## Implementation Plan

1. **Fix Wi-Fi Direct Connection Handler**
   - Remove sender/receiver assumptions
   - Both devices start HTTP server
   - Both devices start UDP discovery

2. **Fix Connection Request Logic**
   - Add request deduplication
   - Implement debouncing (prevent multiple dialogs)
   - Use discovered IP, not assumed IP

3. **Optimize Performance**
   - Reduce UDP broadcast frequency
   - Throttle UI updates
   - Proper resource cleanup

4. **Fix IP Discovery**
   - Wait for proper IP assignment
   - Use UDP discovery to find peer
   - Handle both GO and Client scenarios
