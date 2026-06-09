# MPV Setup for ZapShare Native Player

## Quick Setup (< 2 minutes)

### Option 1: Automatic Download (Recommended)

Run this in PowerShell from the `windows` directory:

```powershell
.\download_mpv.ps1
```

If it fails due to network issues, use **Option 2** below.

---

### Option 2: Manual Download

1. **Download MPV** (choose one source):
   - https://mpv.io/installation/ (Official site - recommended)
   - https://sourceforge.net/projects/mpv-player-windows/files/
   - https://github.com/zhongfly/mpv-winbuild/releases/latest

2. **Download the 64-bit build** (file ending in `.7z`)

3. **Extract the archive**:
   - Right-click → "Extract All" (or use 7-Zip)
   
4. **Copy files** to: `windows\mpv\`
   ```
   ZapShare-main\
   └── windows\
       └── mpv\          ← Create this folder
           ├── mpv.exe    ← The main executable
           ├── mpv.com
           └── *.dll       ← All DLL files
   ```

5. **Verify** the structure:
   ```
   windows\mpv\mpv.exe should exist
   ```

---

### Option 3: System Installation

If you have MPV installed system-wide, the app will auto-detect it.

Install via:
```powershell
winget install mpv
```

---

## Build & Run

Once MPV is set up:

```powershell
flutter build windows --release
```

The MPV folder will be automatically bundled with your app at:
```
build\windows\x64\runner\Release\mpv\
```

---

## Troubleshooting

**"MPV not found" error:**
- Make sure `windows\mpv\mpv.exe` exists
- Or install MPV system-wide with `winget install mpv`
- Check the bundled app folder: `build\windows\x64\runner\Release\mpv\`

**Build errors:**
- Run: `flutter clean && flutter pub get`
- Then: `flutter build windows`

---

## What Gets Bundled?

Your built app will include:
- `zap_share.exe` - Your Flutter app
- `mpv/` folder with:
  - `mpv.exe` - Video player
  - `*.dll` - Required libraries

App size increase: ~15-20 MB

The app will automatically use the bundled MPV, no user installation required!
