# Testing the ZapShare Code Feature

Follow these steps to test the complete feature locally.

## Prerequisites

- Node.js installed
- Flutter app running on a device/emulator
- Device and computer on the same WiFi network

## Step 1: Start the Relay Server

```bash
cd zapshare-relay-server
npm install
npm start
```

You should see:
```
🚀 ZapShare Relay Server running on port 3000
```

## Step 2: Test Relay Server

Open a new terminal and test the API:

```bash
# Register a test device
curl -X POST http://localhost:3000/api/register \
  -H "Content-Type: application/json" \
  -d '{"ip":"192.168.1.100","port":8090,"deviceName":"Test Device"}'
```

You should get a response like:
```json
{
  "code": "ABC123",
  "expiresIn": "24 hours"
}
```

Now lookup the device:
```bash
curl http://localhost:3000/api/device/ABC123
```

Response:
```json
{
  "ip": "192.168.1.100",
  "port": 8090,
  "deviceName": "Test Device",
  "url": "http://192.168.1.100:8090"
}
```

## Step 3: Open the Website

**Option A: Direct File Open**
- Navigate to `zapshare-website` folder
- Double-click `index.html`
- It will open in your default browser

**Option B: Local Server (Recommended)**
```bash
cd zapshare-website

# Python 3
python -m http.server 8080

# Or Python 2
python -m SimpleHTTPServer 8080

# Or Node.js
npx http-server -p 8080
```

Then visit: `http://localhost:8080`

## Step 4: Run Flutter App

1. Build and run the app:
```bash
cd path/to/zapshare
flutter run
```

2. In the app, navigate to Web Receive screen
3. Tap "Start" to start the web server
4. You should see a **6-character code** displayed (e.g., "XYZ789")

**Note:** If you don't see a code, check:
- Flutter console for errors
- Make sure relay server is running on `localhost:3000`
- Check that `RELAY_SERVER_URL` in `WebReceiveScreen.dart` is correct

## Step 5: Test Sending Files

1. Open the website in your browser
2. Click the "Send" tab
3. Enter the code from the app (e.g., "XYZ789")
4. Click "Connect"
5. You should see: "✅ Connected to ZapShare Device"
6. The upload area should become active
7. Drag & drop a file or click "Choose Files"
8. Click "Send Files"
9. The app should show an approval dialog
10. Approve the upload
11. Watch the progress bars!

## Step 6: Test Receiving Files

1. Make sure some files are in the received files list in the app
2. In the website, click the "Receive" tab
3. Enter the code
4. Click "Connect"
5. You should see a list of available files
6. Click "Download" on any file

## Troubleshooting

### Code not showing in app

Check Flutter console for errors:
```
Failed to register with relay server: SocketException...
```

**Solution:** Make sure relay server is running on `localhost:3000`

### Website can't connect

Open browser console (F12) and check for errors:
```
Failed to fetch: CORS error
```

**Solution:** The relay server has CORS enabled, but make sure you're not blocking requests

### "Code not found"

The relay server might have restarted. Codes are stored in memory and lost on restart.

**Solution:** 
1. Stop the web server in the app
2. Start it again to get a new code

### Upload doesn't work

Make sure:
1. Device and browser are on the **same WiFi network**
2. Web server is running in the app
3. Firewall isn't blocking port 8090
4. You approved the upload on the device

### Can't download files

Make sure:
1. There are files in the "Received Files" tab in the app
2. The `/files` endpoint is working (check app logs)

## Success Checklist

- [ ] Relay server starts without errors
- [ ] Can register device via curl
- [ ] Can lookup device via curl
- [ ] Website loads correctly
- [ ] App shows a 6-character code
- [ ] Can connect from website using code
- [ ] Upload area activates after connecting
- [ ] Can select files for upload
- [ ] Approval dialog appears on device
- [ ] Progress bars show upload progress
- [ ] Files appear in app after upload
- [ ] Can view received files list from website
- [ ] Can download files from website

## Next Steps

Once local testing works:

1. Deploy relay server to Railway/Render
2. Update `RELAY_SERVER_URL` in `WebReceiveScreen.dart`
3. Update `RELAY_SERVER` in `index.html`
4. Deploy website to Vercel/Netlify
5. (Optional) Point custom domain to website
6. Test end-to-end with deployed infrastructure

## Common Error Messages

| Error | Cause | Solution |
|-------|-------|----------|
| "ECONNREFUSED" | Relay server not running | Start relay server |
| "Code not found" | Invalid/expired code | Get new code from app |
| "CORS error" | Browser blocking request | Use http-server instead of file:// |
| "Network error" | Different WiFi networks | Connect to same network |
| "Upload denied" | User denied on device | Approve in app dialog |

## Demo Video Script

1. Show app on phone with Web Receive started
2. Show code displayed prominently (e.g., "ABC123")
3. Open website on computer
4. Enter code in Send tab
5. Upload a photo
6. Show approval dialog on phone
7. Approve upload
8. Show progress bar
9. Show file received in app
10. Switch to Receive tab
11. Enter code again
12. Show files list
13. Download a file
14. Success! 🎉
