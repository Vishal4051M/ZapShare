ZapShare
========

Lightning-fast, privacy-first file sharing across devices on the same network. Built with Flutter, runs on Android, iOS, Windows, macOS, and Linux.



Table of Contents
-----------------
- Features
- How It Works
  - Send Files (HTTP Share)
  - Receive by Code
  - Web Receive
  - Transfer History
- Quick Start
- Build and Run
- Permissions
- Troubleshooting
- FAQ

Features
--------
- Cross‑platform Flutter app with a clean, modern UI
- Two receive modes:
  - Receive by 8‑character code (peer‑to‑peer over LAN)
  - Web Receive (host device exposes a simple upload page)
- Send mode: Share local files over HTTP with progress and background service
- Background transfers with notifications (Android)
- Local transfer history (lightweight log)
- Works fully offline on local Wi‑Fi/hotspot (no cloud)

How It Works
------------
ZapShare discovers or encodes device IPs for LAN transfers.
- Send mode starts a small HTTP server on the sender to serve selected files.
- Receive by Code decodes an 8‑char code to the sender’s IP and pulls files.
- Web Receive starts a simple upload page on the receiver; others upload from a browser.

All transfers remain within your local network.

Send Files (HTTP Share)
-----------------------
1. Open the app → Send tab (Android opens this by default when launched from Share sheet)
2. Add files or entire folders
3. Tap Send to start the HTTP server (default port 8080)
4. Share the 8‑character code or URL with receivers
5. Receivers open the page or use code to download files

Notes
- Background service keeps transfers alive, with notifications showing progress
- Multiple clients can download simultaneously

Receive by Code
---------------
1. Open Receive → Receive by Code
2. Enter the 8‑character code from the sender
3. App decodes the code to the sender’s IP and fetches the file list
4. Select files and download with parallel progress and notifications

Web Receive
-----------
1. Open Receive → Web Receive
2. Start hosting; the device shows a URL like `http://<your-ip>:8090`
3. Others on the same network visit that URL in a browser
4. They drag‑and‑drop/upload files; your device receives them with progress

Transfer History
----------------
- View recent “Sent” and “Received” entries (filename, size, peer, date)
- Limited to a small rolling window stored locally

Quick Start
-----------
- Android: Install the APK and grant requested permissions on first run
- Windows/macOS/Linux: Run the desktop app; ensure devices share the same LAN
- iOS/macOS: Requires appropriate entitlements; run via Xcode during development

Build and Run
-------------
Prerequisites
- Flutter (3.19+ recommended)
- Dart SDK matching your Flutter channel

Install dependencies
```
flutter pub get
```

Android build
```
flutter build apk --release
```

iOS build
```
flutter build ios --release
```

Desktop (example Windows)
```
flutter config --enable-windows-desktop
flutter build windows --release
```

Run in debug
```
flutter run -d <device-id>
```

Permissions
-----------
Actual prompts vary by platform, but commonly:
- Storage/Photos/Media: read and write shared files
- Notifications: show progress in background
- Nearby Wi‑Fi/Local network: discover IP and communicate
- Manage External Storage (Android 11+): reliable access to Downloads

All data stays local to your devices; no external servers are used.

Troubleshooting
---------------
- Can’t find peer: ensure both devices are on the same Wi‑Fi or hotspot
- Code fails: double‑check the 8‑character code; confirm sender is active
- Upload/download blocked: check OS firewall or VPN
- Android 11+: grant “Manage External Storage” for saving to public Downloads
- Ports in use: defaults are 8080 (Send) and 8090 (Web Receive); avoid conflicts

FAQ
---
- Do I need the internet? No. LAN/hotspot is enough.
- Is data encrypted? Traffic stays on your LAN. For hardened environments, put devices on a trusted network segment.
- Why Web Receive and Code both? Web Receive is sender‑agnostic (any browser). Code mode is app‑to‑app, optimized for speed and parallelism.
- Does it work with very large files? Yes, but ensure both devices stay on power and the app has proper permissions.

Contributing
------------
PRs are welcome. Please format with `dart format` and keep UI consistent with the existing design language.

License
-------
MIT

