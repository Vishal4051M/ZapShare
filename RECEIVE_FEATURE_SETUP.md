# ZapShare Receive Feature Setup

## ✅ Changes Made

### 1. Added CORS Headers to HttpFileShareScreen
The Flutter app now includes CORS headers in the HTTP server to allow cross-origin requests from the website.

**File Modified**: `lib/Screens/HttpFileShareScreen.dart`

Added these headers to all HTTP responses:
- `Access-Control-Allow-Origin: *`
- `Access-Control-Allow-Methods: GET, POST, OPTIONS`
- `Access-Control-Allow-Headers: *`

Also handles OPTIONS preflight requests.

### 2. Website with Tab Navigation
The website now has two tabs:
- **Send Files**: Redirects to device's upload interface (port 8090)
- **Receive Files**: Fetches file list and downloads files (port 8080)

## 🚀 How to Test

### Step 1: Rebuild the Flutter App
Since we modified the Dart code, you need to rebuild the app:

```powershell
cd D:\Desktop\ZapShare-main
flutter run
```

Or rebuild the APK if testing on Android.

### Step 2: Start File Sharing in the App
1. Open ZapShare app
2. Select files to share
3. Tap "Start Sharing"
4. Note the 8-digit code displayed (e.g., `C0A80164`)

### Step 3: Test the Receive Feature
1. Open your browser
2. Go to `http://localhost:8080` (if testing the website locally)
3. Click the "Receive Files" tab
4. Enter the 8-digit code from the app
5. Click "Fetch Files"

You should see:
- List of all shared files
- File names and sizes
- Individual download buttons
- "Download All" button (if multiple files)

## 🔍 Troubleshooting

### Error: "Cannot reach device"

**Check these things:**

1. **Same Network**: Both devices must be on the same WiFi/network
   - Check device IP: The code converts to an IP like `192.168.1.100`
   - Make sure both devices can ping each other

2. **App is Running**: 
   - The ZapShare app must have "Start Sharing" active
   - Server runs on port 8080
   - You should see the share code displayed

3. **Firewall**:
   - Windows/Mac firewall might block the connection
   - Temporarily disable to test
   - Or add exception for port 8080

4. **CORS (after rebuild)**:
   - Make sure you rebuilt the app after adding CORS headers
   - Old version won't have CORS support

### Test Locally First

To verify the app's server works:

1. Start sharing in the app (note the code, e.g., `C0A80164`)
2. Convert code to IP manually:
   - Open browser console
   - Run: `parseInt('C0A80164', 36).toString(16)` → `c0a80164`
   - Convert hex to IP: `192.168.1.100`
3. Visit `http://192.168.1.100:8080/list` directly
4. You should see JSON response like:
   ```json
   [
     {"index": 0, "name": "photo.jpg", "size": 1234567},
     {"index": 1, "name": "document.pdf", "size": 987654}
   ]
   ```

If this works, the problem is in the website. If it doesn't, the problem is in the app/network.

## 📝 API Endpoints

The HttpFileShareScreen server provides:

- `GET /` or `/index.html` - Web interface (built-in)
- `GET /list` - JSON array of files with index, name, size
- `GET /file/0` - Download first file
- `GET /file/1` - Download second file
- etc.

## 🎯 Expected Behavior

1. **Enter Code**: User enters 8-digit code
2. **Decode IP**: Code converts to IP address (base-36 to IP)
3. **Fetch List**: Browser fetches `http://IP:8080/list`
4. **Display Files**: Website shows all files with download buttons
5. **Download**: Clicking download creates link to `http://IP:8080/file/INDEX`

## ✨ Features

- ✅ Tab navigation (Send/Receive)
- ✅ Code validation and conversion
- ✅ File list fetching with CORS support
- ✅ Individual file downloads
- ✅ Download all files (staggered)
- ✅ File size formatting
- ✅ Loading states
- ✅ Error handling
- ✅ Responsive design

## 🔧 Next Steps

After rebuilding the app with CORS headers:
1. Test the `/list` endpoint directly in browser
2. Test the website receive feature
3. Verify downloads work correctly
4. Test on mobile devices
