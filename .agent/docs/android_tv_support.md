# Android TV Support Documentation

## Overview
ZapShare now supports Android TV, allowing users to receive and download files using a TV remote control with D-pad navigation.

## Features Added

### 1. **Manifest Configuration**
- Added `android.software.leanback` feature (optional)
- Made touchscreen optional with `android.hardware.touchscreen` (required=false)
- Added `LEANBACK_LAUNCHER` category to appear in Android TV launcher

### 2. **TV-Optimized Widgets**

#### `TVFocusableButton` (`lib/widgets/tv_widgets.dart`)
- Focusable button with visual focus indicators
- Supports D-pad SELECT/ENTER key for activation
- Animated focus border and glow effect
- Yellow (#FFD600) focus highlight

#### `TVFocusableCard` (`lib/widgets/tv_widgets.dart`)
- Focusable card container for list items
- D-pad navigation support
- Visual focus feedback with border and shadow
- Used for file items in the download list

#### `TVCodeInput` (`lib/widgets/tv_widgets.dart`)
- TV-friendly code input for entering 11-character codes
- **D-pad Controls**:
  - **↑ (Up)**: Increment current character (0→1→2...→Z→0)
  - **↓ (Down)**: Decrement current character (Z→Y→X...→0→Z)
  - **→ (Right)** or **SELECT**: Move to next character
  - **← (Left)**: Move to previous character
- Visual focus indicator on current character
- Auto-complete when all 11 characters entered

#### `TVHelper` Utility Class
- `isTV(context)`: Detects if running on Android TV
- `getScaleFactor(context)`: Returns 1.2x scale for TV (better readability)

### 3. **Screen Updates**

#### AndroidFileListScreen
- File items wrapped with `TVFocusableCard`
- Download button wrapped with `TVFocusableButton`
- D-pad navigation through file list
- SELECT key to toggle file selection
- Auto-focus on download button when screen loads

#### AndroidReceiveScreen
- TV widgets imported (ready for TV code input integration)
- Can be enhanced with `TVCodeInput` widget for better TV experience

## Usage on Android TV

### Navigation Controls
1. **D-pad Up/Down**: Navigate between items
2. **D-pad Left/Right**: Navigate horizontally (code input)
3. **SELECT/ENTER**: Activate button or select item
4. **BACK**: Go back to previous screen

### Receiving Files on TV
1. Launch ZapShare from Android TV launcher
2. Navigate to "Receive Files"
3. Use D-pad to enter 11-character code:
   - Up/Down to change character
   - Right to move to next position
   - SELECT when code is complete
4. Navigate through file list with D-pad
5. SELECT to toggle file selection
6. Navigate to "Download Selected" button
7. Press SELECT to start download

### Visual Feedback
- **Yellow border**: Indicates focused element
- **Yellow glow**: Enhanced focus visibility
- **Animated transitions**: Smooth focus changes
- **Progress indicators**: Real-time download progress

## Technical Implementation

### Focus Management
```dart
// Example: Focusable button
TVFocusableButton(
  autofocus: true,  // Auto-focus when screen loads
  onPressed: () {
    // Handle button press
  },
  child: Text('Download'),
)
```

### D-pad Key Handling
```dart
onKeyEvent: (node, event) {
  if (event is KeyDownEvent) {
    if (event.logicalKey == LogicalKeyboardKey.select ||
        event.logicalKey == LogicalKeyboardKey.enter) {
      // Handle SELECT/ENTER
      return KeyEventResult.handled;
    }
  }
  return KeyEventResult.ignored;
}
```

### TV Detection
```dart
if (TVHelper.isTV(context)) {
  // Show TV-optimized UI
  final scale = TVHelper.getScaleFactor(context);
  // Apply 1.2x scaling for better readability
}
```

## Testing on Android TV

### Emulator Setup
1. Open Android Studio
2. AVD Manager → Create Virtual Device
3. Select "TV" category
4. Choose Android TV device (e.g., 1080p or 4K)
5. Select system image (API 28+)
6. Launch emulator

### Physical Device Testing
1. Enable Developer Options on Android TV
2. Enable USB Debugging
3. Connect via ADB: `adb connect <TV_IP>:5555`
4. Run: `flutter run -d <device_id>`

### Remote Control Testing
- Use emulator's virtual remote
- Or use physical Android TV remote
- Test all D-pad directions
- Test SELECT and BACK buttons

## Future Enhancements

### Potential Improvements
1. **Voice Input**: Add voice search for code entry
2. **QR Code Scanner**: Use TV camera (if available)
3. **Larger Text**: Increase font sizes for 10-foot UI
4. **Grid Layout**: Show files in grid for better TV viewing
5. **Preview Images**: Show thumbnails for images/videos
6. **Auto-discovery**: Automatically find nearby senders
7. **Gamepad Support**: Support for game controllers

### Accessibility
- High contrast focus indicators
- Large touch targets (48dp minimum)
- Clear visual hierarchy
- Readable fonts at distance

## Known Limitations

1. **Touchscreen**: Some features may require touch (file picker)
2. **Keyboard Input**: Code entry is optimized for D-pad, not keyboard
3. **File Browser**: Native file picker may not work well on TV
4. **Permissions**: Some permissions may require touch interaction

## Troubleshooting

### App Not Appearing in TV Launcher
- Check `LEANBACK_LAUNCHER` category in AndroidManifest.xml
- Verify `android.software.leanback` feature is declared
- Rebuild and reinstall app

### Focus Not Working
- Ensure widgets are wrapped with `TVFocusableButton` or `TVFocusableCard`
- Check `autofocus` property is set on first element
- Verify `FocusNode` is properly initialized

### D-pad Not Responding
- Check `onKeyEvent` handler is implemented
- Verify `KeyEventResult.handled` is returned
- Test with emulator's virtual remote first

## Files Modified

### AndroidManifest.xml
- Added TV feature declarations
- Added LEANBACK_LAUNCHER category

### New Files Created
- `lib/widgets/tv_widgets.dart` - TV-specific widgets
- `lib/widgets/tv_code_input.dart` - TV code input widget
- `.agent/docs/android_tv_support.md` - This documentation

### Modified Files
- `lib/Screens/android/AndroidFileListScreen.dart` - Added TV focus support
- `lib/Screens/android/AndroidReceiveScreen.dart` - Added TV widgets import

## Resources

- [Android TV Design Guidelines](https://developer.android.com/design/tv)
- [Android TV Input Handling](https://developer.android.com/training/tv/start/navigation)
- [Flutter Focus System](https://api.flutter.dev/flutter/widgets/Focus-class.html)
- [D-pad Navigation](https://developer.android.com/training/tv/start/navigation#dpad-navigation)
