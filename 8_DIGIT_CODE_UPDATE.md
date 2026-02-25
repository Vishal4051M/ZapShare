# ✅ Updated to 8-Digit Codes

The system has been updated to use **8-digit codes** (matching your WindowsFileShareScreen format).

## Changes Made

### 1. Flutter App (WebReceiveScreen.dart)
- ✅ Added `_ipToCode()` function to convert IP to 8-digit code
- ✅ Sends custom code to relay server during registration
- ✅ Displays 8-digit code in UI (slightly smaller font for better fit)

### 2. Relay Server (server.js)
- ✅ Accepts custom codes via `code` parameter in registration
- ✅ Validates custom codes to prevent conflicts
- ✅ Allows re-registration of same device with same code

### 3. Website (index.html)
- ✅ Updated input fields to accept 8 digits (maxlength="8")
- ✅ Updated placeholder to "ABC12345"
- ✅ Updated validation to check for 8-digit codes
- ✅ Updated hint text to say "8-digit code"

## How the Code Works

**IP Address → 8-Digit Code Conversion:**

```
Example:
IP: 192.168.1.100

Binary representation:
192 = 11000000
168 = 10101000
  1 = 00000001
100 = 01100100

Combined: 3232235876 (decimal)
Convert to base-36: C0A80164
Padded to 8 digits: C0A80164
```

## Testing

1. **Start relay server:**
   ```powershell
   cd d:\Desktop\ZapShare-main\zapshare-relay-server
   npm start
   ```

2. **Open website:**
   ```powershell
   cd d:\Desktop\ZapShare-main\zapshare-website
   python -m http.server 8080
   ```
   Visit: http://localhost:8080

3. **Run Flutter app:**
   - Go to Web Receive screen
   - Start server
   - You'll see an **8-digit code** (e.g., "C0A80164")

4. **Use website:**
   - Enter the 8-digit code
   - Connect and transfer files!

## Example Codes

| IP Address | 8-Digit Code |
|------------|--------------|
| 192.168.1.1 | C0A80101 |
| 192.168.1.100 | C0A80164 |
| 192.168.0.10 | C0A8000A |
| 10.0.0.5 | 0A000005 |

## Consistent Across Platforms

Now both screens use the same code format:
- ✅ **WindowsFileShareScreen**: 8-digit code from IP
- ✅ **WebReceiveScreen**: 8-digit code from IP
- ✅ **Website**: Accepts 8-digit codes
- ✅ **Relay Server**: Handles 8-digit codes

All platforms are now synchronized! 🎉
