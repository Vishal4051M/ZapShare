I have updated the QR code dialog in `AndroidHttpFileShareScreen` to match the design of the `WebReceiveScreen`.

**Changes:**
1.  **Dialog Styling**: Updated the dialog border to `Colors.yellow[300]` with a width of 2.
2.  **QR Code Container**: Changed the background color of the QR code container to `Colors.yellow[300]`.
3.  **QR Code Style**:
    *   Set `backgroundColor` to `Colors.transparent`.
    *   Set `eyeStyle` and `dataModuleStyle` to black squares.
    *   Increased size to 240.0.
4.  **Text**: Changed title to "Scan to Connect".
5.  **Close Button**: Replaced the custom button with a standard `TextButton`.

**Files Modified:**
*   `lib/Screens/android/AndroidHttpFileShareScreen.dart`
