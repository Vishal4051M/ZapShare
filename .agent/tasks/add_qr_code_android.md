I have added a QR code button to the `AndroidHttpFileShareScreen` to allow users to easily share the file server URL.

**Changes:**
1.  **Imports**: Added `qr_flutter` and `screen_brightness` imports to `lib/Screens/android/AndroidHttpFileShareScreen.dart`.
2.  **QR Dialog**: Implemented `_showQrDialog` method which:
    *   Constructs the server URL using the local IP and port 8080.
    *   Maximizes screen brightness for better scanning.
    *   Displays the QR code in a dialog.
    *   Restores screen brightness upon closing.
3.  **UI**: Added a QR code `IconButton` to the `AppBar` in `AndroidHttpFileShareScreen`.

**Files Modified:**
*   `lib/Screens/android/AndroidHttpFileShareScreen.dart`
