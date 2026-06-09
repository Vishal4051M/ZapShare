# Building Release APK for Android TV Testing

## Quick Build Command

```bash
flutter build apk --release
```

The APK will be located at:
```
build/app/outputs/flutter-apk/app-release.apk
```

## Install on Android TV

### Method 1: USB Cable
```bash
adb install build/app/outputs/flutter-apk/app-release.apk
```

### Method 2: Wireless ADB
```bash
# On TV: Enable Developer Options → Enable USB Debugging
# Get TV IP address from Settings → Network

adb connect <TV_IP_ADDRESS>:5555
adb install build/app/outputs/flutter-apk/app-release.apk
```

### Method 3: USB Drive
1. Copy APK to USB drive
2. Plug USB into TV
3. Use file manager app on TV to install APK

## Testing Checklist

### Basic Navigation
- [ ] App appears in Android TV launcher
- [ ] D-pad navigation works in all screens
- [ ] SELECT button activates items
- [ ] BACK button returns to previous screen

### Receive Screen
- [ ] Can enter code using D-pad (↑↓ to change char, → to move)
- [ ] Code input shows focus indicator
- [ ] Connect button is focusable
- [ ] Recent codes are selectable with D-pad

### File List Screen
- [ ] File items are focusable with D-pad
- [ ] SELECT toggles file selection
- [ ] Download button is focusable
- [ ] Progress shows during download
- [ ] Can navigate while downloading

### Visual Feedback
- [ ] Yellow focus border appears on focused items
- [ ] Focus glow effect is visible
- [ ] Smooth transitions between focus states
- [ ] Text is readable from 10 feet away

### Performance
- [ ] No lag when navigating with D-pad
- [ ] Downloads work properly
- [ ] App doesn't crash on TV
- [ ] Memory usage is acceptable

## Known Issues to Watch For

1. **File Picker**: May not work well on TV (no touch)
   - Workaround: Use default download folder
   
2. **Keyboard Input**: If TV has keyboard, test code entry
   
3. **Permissions**: Some may require touch interaction
   - Test storage permissions flow

## Optimization Tips

If you encounter issues:

1. **Increase Font Sizes**: For better readability at distance
2. **Larger Touch Targets**: Make buttons bigger (min 48dp)
3. **Simplify Navigation**: Reduce number of focusable items
4. **Add Shortcuts**: Quick actions for common tasks

## Feedback

After testing, note:
- Which features work well
- Which features need improvement
- Any crashes or bugs
- User experience on TV vs phone

Good luck with testing! 🚀
