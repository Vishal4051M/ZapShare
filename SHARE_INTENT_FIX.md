# Share Intent Fix - Prevent Multiple Instances & Auto-Navigate to Send Screen

## Issues Fixed

### Issue 1: Multiple App Instances When Sharing
**Problem:** When sharing a file from the file manager while ZapShare was already open, Android would create a new instance of the app instead of using the existing one.

**Root Cause:** The `AndroidManifest.xml` was using `android:launchMode="singleTop"`, which only prevents multiple instances when the activity is already at the top of the stack. However, if the user was on a different screen, a new instance would be created.

**Solution:** Changed launch mode from `singleTop` to `singleTask` in `AndroidManifest.xml`. This ensures only one instance of the app exists at any time, regardless of which screen the user is on.

### Issue 2: Files Not Visible After Sharing
**Problem:** When sharing files to ZapShare, the app would stay on the home screen instead of navigating to the send screen, and users had to manually navigate to see the shared files.

**Root Cause:** The shared files were being handled by the `HttpFileShareScreen` component, but there was no global navigation logic to switch to that screen when files were shared.

**Solution:** Implemented a global shared file handler in `main.dart` that:
1. Listens for shared files from the Android native layer
2. Automatically navigates to the `HttpFileShareScreen` 
3. Passes the shared files as initial data to the screen
4. The screen now processes these files immediately on creation

## Files Modified

### 1. `android/app/src/main/AndroidManifest.xml`
**Change:** Updated launch mode for single instance behavior
```xml
<!-- Before -->
android:launchMode="singleTop"

<!-- After -->
android:launchMode="singleTask"
```

**Effect:** Ensures only one instance of ZapShare runs at any time. When sharing files, Android will bring the existing app to the foreground instead of creating a new instance.

### 2. `lib/main.dart`
**Changes:**
1. Added `MethodChannel` import for native communication
2. Added `_platform` MethodChannel constant
3. Added `_pendingSharedFiles` field to store shared files temporarily
4. Implemented `_listenForSharedFiles()` method to receive files from native layer
5. Implemented `_navigateToSendScreen()` to navigate to send screen with shared files

**New Logic Flow:**
```
File shared from file manager
    ↓
Native layer calls 'sharedFiles' method
    ↓
_listenForSharedFiles() receives the files
    ↓
Stores files in _pendingSharedFiles
    ↓
_navigateToSendScreen() is called
    ↓
Navigates to HttpFileShareScreen with initialSharedFiles parameter
    ↓
Clears _pendingSharedFiles
```

### 3. `lib/Screens/HttpFileShareScreen.dart`
**Changes:**
1. Added optional `initialSharedFiles` parameter to constructor
2. Updated `initState()` to check for and process initial shared files
3. Uses `WidgetsBinding.instance.addPostFrameCallback()` to ensure files are processed after widget is fully built

**New Constructor:**
```dart
class HttpFileShareScreen extends StatefulWidget {
  final List<Map<dynamic, dynamic>>? initialSharedFiles;
  
  const HttpFileShareScreen({super.key, this.initialSharedFiles});
  // ...
}
```

**Processing Logic:**
```dart
if (widget.initialSharedFiles != null && widget.initialSharedFiles!.isNotEmpty) {
  print('📁 Processing initial shared files: ${widget.initialSharedFiles!.length} files');
  WidgetsBinding.instance.addPostFrameCallback((_) {
    _handleSharedFiles(widget.initialSharedFiles!);
  });
}
```

## Technical Details

### Launch Modes Comparison
- **singleTop**: Creates a new instance if the activity is not at the top of the stack
- **singleTask**: Ensures only ONE instance exists in the entire system (our choice)
- **standard**: Always creates a new instance (default behavior)

### Why pushAndRemoveUntil?
```dart
navigatorKey.currentState?.pushAndRemoveUntil(
  MaterialPageRoute(...),
  (route) => false, // Remove all previous routes
);
```
This ensures:
1. User sees the send screen immediately
2. No confusing back navigation to home screen
3. Clean navigation stack

### Benefits of This Approach
1. **Single Instance:** Only one ZapShare app instance runs, preventing confusion
2. **Immediate Visibility:** Files appear immediately on the send screen
3. **Better UX:** Users don't need to manually navigate to see shared files
4. **Memory Efficient:** No duplicate app instances consuming resources
5. **Consistent Behavior:** Same behavior whether app is open or closed

## Testing Checklist

- [x] Share single file from file manager with app closed
- [x] Share single file from file manager with app open on home screen
- [x] Share single file from file manager with app open on send screen
- [x] Share single file from file manager with app open on receive screen
- [x] Share multiple files from file manager with app closed
- [x] Share multiple files from file manager with app open
- [x] Verify only one app instance appears in recent apps
- [x] Verify files appear immediately on send screen
- [x] Verify no need to manually navigate to send screen

## User Experience Flow

### Before Fix:
```
1. User shares file from file manager
2. ZapShare icon appears in share menu
3. User taps ZapShare
4. App opens (or new instance created)
5. User sees home screen
6. User must navigate to send screen
7. User sees shared files
```

### After Fix:
```
1. User shares file from file manager
2. ZapShare icon appears in share menu
3. User taps ZapShare
4. App opens/comes to foreground (single instance)
5. User immediately sees send screen with shared files ready
```

## Notes

- The change from `singleTop` to `singleTask` is backward compatible
- Existing functionality remains unchanged
- The `initialSharedFiles` parameter is optional, so existing code calling `HttpFileShareScreen()` without parameters continues to work
- The navigation logic only triggers when files are actually shared

## Related Files
- `android/app/src/main/kotlin/com/example/zap_share/MainActivity.kt` - Handles share intent from Android
- `lib/Screens/HomeScreen.dart` - Home screen that navigates to send screen
- `lib/Screens/AndroidReceiveScreen.dart` - Receive screen (unaffected)
