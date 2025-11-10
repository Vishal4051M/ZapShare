# ⚡ ZapShare Code-Based File Sharing

This feature allows users to send and receive files using simple 6-character codes instead of typing long IP addresses!

## 🎯 What This Does

### Before (Manual)
```
User: "Hey, I want to send you a file"
You: "Go to http://192.168.1.147:8090"
User: "What? Can you repeat that?"
```

### After (With Code)
```
User: "Hey, I want to send you a file"
You: "Visit zapshare.me and enter code: ABC123"
User: "Done! Uploading now..."
```

## 🏗️ Architecture

```
┌─────────────┐         ┌──────────────────┐         ┌─────────────┐
│             │         │                  │         │             │
│  ZapShare   │◄───────►│  Relay Server    │◄───────►│ zapshare.me │
│  Flutter    │  Code   │  (Node.js)       │  Lookup │  Website    │
│  App        │  Reg.   │                  │         │             │
│             │         │                  │         │             │
└─────────────┘         └──────────────────┘         └─────────────┘
      │                                                      │
      │                                                      │
      │          Direct File Transfer (HTTP)                 │
      └──────────────────────────────────────────────────────┘
```

## 📦 Components

### 1. **Relay Server** (`zapshare-relay-server/`)
- Node.js/Express server
- Generates unique 6-character codes
- Maps codes to device IP addresses
- Automatically expires old codes (24 hours)

### 2. **Website** (`zapshare-website/`)
- Beautiful single-page app
- Black & yellow theme matching the app
- Two tabs: Send and Receive
- Direct device communication (no file storage on server)

### 3. **Flutter App Integration**
- Modified `WebReceiveScreen.dart`
- Auto-registers with relay server on startup
- Displays prominent code in UI
- Auto-refreshes registration every 20 minutes

## 🚀 Quick Start

### 1. Start Relay Server (Local Testing)

```bash
cd zapshare-relay-server
npm install
npm start
```

Server runs on `http://localhost:3000`

### 2. Open Website

```bash
cd zapshare-website
# Open index.html in browser
# Or use a simple HTTP server:
python -m http.server 8080
# Visit http://localhost:8080
```

### 3. Run Flutter App

1. Make sure your phone/emulator is on the same network
2. Open ZapShare app
3. Go to Web Receive screen
4. Start server
5. You'll see a **6-character code** displayed prominently

### 4. Test It!

**To Send Files:**
1. Open website in browser
2. Click "Send" tab
3. Enter the 6-character code from app
4. Click "Connect"
5. Upload files!

**To Receive Files:**
1. Make sure files are on device
2. Open website
3. Click "Receive" tab
4. Enter code
5. Download files!

## 🌐 Production Deployment

### Step 1: Deploy Relay Server

**Recommended: Railway.app (Free)**

```bash
cd zapshare-relay-server
# Push to GitHub first
# Then connect Railway to your GitHub repo
# Railway auto-deploys Node.js apps
```

You'll get a URL like: `https://zapshare-relay.railway.app`

**Alternative Options:**
- Heroku (free tier)
- Render.com (free tier)
- DigitalOcean App Platform ($5/month)

See `zapshare-relay-server/README.md` for detailed deployment guides.

### Step 2: Deploy Website

**Recommended: Vercel (Free)**

```bash
cd zapshare-website
npm i -g vercel
vercel
```

**Alternative Options:**
- Netlify (free)
- GitHub Pages (free)
- Cloudflare Pages (free)

See `zapshare-website/DEPLOYMENT.md` for detailed guides.

### Step 3: Update URLs

**In Flutter app** (`lib/Screens/WebReceiveScreen.dart`):
```dart
static const String RELAY_SERVER_URL = 'https://zapshare-relay.railway.app';
```

**In website** (`zapshare-website/index.html`):
```javascript
const RELAY_SERVER = 'https://zapshare-relay.railway.app';
```

### Step 4: Get Domain (Optional)

1. Buy `zapshare.me` from Namecheap/GoDaddy (~$10-15/year)
2. Point it to your website hosting (Vercel/Netlify)
3. Users can now visit `zapshare.me` instead of a random URL!

## 💡 How It Works

### Device Registration
```
1. User starts Web Receive in app
2. App gets local IP (e.g., 192.168.1.100)
3. App sends IP to relay server
4. Server generates code (e.g., ABC123)
5. App displays code to user
```

### File Sending
```
1. Sender visits zapshare.me
2. Enters code: ABC123
3. Website asks relay server: "What's the IP for ABC123?"
4. Server responds: "192.168.1.100:8090"
5. Website uploads files DIRECTLY to device
6. No files stored on relay server!
```

### File Receiving
```
1. Receiver visits zapshare.me
2. Enters code: ABC123
3. Website connects to device
4. Shows list of available files
5. Downloads files DIRECTLY from device
```

## 🎨 UI Features

- **Matching Theme**: Black and yellow colors like the app
- **Responsive Design**: Works on mobile and desktop
- **Drag & Drop**: Easy file uploads
- **Progress Bars**: Per-file upload progress
- **Clean UX**: Simple, intuitive interface
- **Animations**: Smooth transitions and effects

## 🔒 Security & Privacy

✅ **Files transfer directly** - relay server only stores IP addresses  
✅ **Codes expire** - automatic cleanup after 24 hours  
✅ **Local network** - works best on same WiFi  
✅ **No file storage** - server never touches your files  
✅ **Approval required** - device user must approve uploads  

## 📊 Cost Breakdown

| Component | Service | Cost |
|-----------|---------|------|
| Relay Server | Railway/Render | **Free** |
| Website | Vercel/Netlify | **Free** |
| Domain (optional) | Namecheap | $10-15/year |
| **Total** | | **$0-15/year** |

## 🛠️ Troubleshooting

### "Code not found"
- Make sure relay server is running
- Check if code expired (24 hours)
- Verify RELAY_SERVER_URL is correct

### "Connection failed"
- Ensure device and browser are on same network
- Check if Web Receive is running in app
- Verify firewall isn't blocking port 8090

### "Upload denied"
- Device user must approve uploads in app
- Approval window lasts 2 minutes

### Website can't connect
- Check RELAY_SERVER constant in index.html
- Verify relay server is accessible
- Check browser console for errors

## 🔄 Future Improvements

- [ ] Add QR code for quick code entry
- [ ] Support for remote connections (VPN/tunnel)
- [ ] File encryption for sensitive transfers
- [ ] Transfer history on website
- [ ] Multiple simultaneous transfers
- [ ] Progressive Web App (PWA) for offline use

## 📝 Testing Checklist

- [ ] Relay server deploys successfully
- [ ] Website deploys successfully
- [ ] Flutter app connects to relay server
- [ ] Code is displayed in app
- [ ] Code can be copied
- [ ] Website can lookup code
- [ ] Files can be uploaded from website
- [ ] Device receives approval dialog
- [ ] Files transfer successfully
- [ ] Progress bars work
- [ ] Files can be downloaded from website

## 🤝 Contributing

Want to improve this feature? Here's how:

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Test thoroughly
5. Submit a pull request

## 📄 License

MIT License - see LICENSE file for details

## 🎉 Credits

Built with ⚡ for ZapShare - Lightning-fast local file sharing!
