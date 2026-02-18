# ZapShare Screen Guide

This document details every feature available on each screen of the ZapShare application.

---

## 1. Home Screen (Dashboard)
The central hub of the application.

*   **Bento Grid Navigation:**
    *   **Send (Large Card):** One-tap access to the file sharing interface.
    *   **Receive:** Navigate to reception options (`Receive by Code` or `Web`).
    *   **History:** View logs of past transfers.
*   **Status Card:** Indicators showing if your device is ready to connect (Wi-Fi status).
*   **Header:**
    *   **Settings Icon:** Top-right access to global device settings.
    *   **Logo:** Branding and visual identity.

---

## 2. File Share Screen (Sender)
The "Command Center" for sending files.

*   **Radar View (Background):**
    *   **Pulse Animation:** visualizes scanning for devices.
    *   **Nearby Devices:** Avatars of found devices (iPhone, Android, Windows, etc.) appear in orbit.
    *   **Tap-to-Connect:** Tapping a device avatar instantly sends a connection request.
*   **Connection Code (New):**
    *   **8-Character Display:** Shows your unique code (e.g., `1HG64P9`) for manual connection.
    *   **Tap-to-Copy:** Easily copy the code to share.
*   **File Selection (Bottom Sheet):**
    *   **Drag Handle:** Pull up to view selected files.
    *   **Add Button:** Opens system file picker (multiple files supported).
    *   **File List:** Shows name, size, and icons for selected files.
    *   **Remove:** Delete individual files from the list before sending.
    *   **Action Button:** "Ready to Send" / "Stop Sharing" toggle.
*   **Quick Actions (Top Right):**
    *   **Refresh:** Restart the radar scan.
    *   **QR Code:** Display a QR code for receivers to scan.

---

## 3. Receive Options Screen
A gateway to choose your reception method.

*   **Receive by Code:**
    *   Primary method for app-to-app transfer.
    *   Opens the keypad interface.
*   **Web Receive:**
    *   launches the browser-based sharing interface (no app needed on sender).
*   **Tips Section:**
    *   Helpful reminders about Wi-Fi requirements and preview capabilities.

---

## 4. Receive Screen (App-to-App)
The interface for receiving files from another ZapShare app.

*   **Code Entry:**
    *   **Keypad:** Enter the sender's 8-character code.
    *   **Auto-Paste:** Logic to handle pasted codes.
    *   **Verify & Receive:** Initiates the handshake.
*   **Progress UI:**
    *   **Circular Indicator:** Visual progress of the total transfer.
    *   **Speedometer:** Shows transfer speed in MB/s.
    *   **Status Text:** "Connecting...", "Receiving...", "Completed!".
*   **Completion Actions:**
    *   **Done Button:** Returns to previous screen.
    *   **Enter New Code:** Reset screen for another transfer immediately.

---

## 5. Web Receive Screen (Browser Share)
Allows receiving files from *any* device with a browser (Computer, Friend's phone) without them installing the app.

*   **Host Server:**
    *   Starts a local HTTP server on port `8090`.
    *   **QR Code:** Scannable code to open the upload page on the sender's device.
    *   **URL Display:** Shows `http://192.168.x.x:8090` for manual entry.
*   **Tabbed Interface:**
    *   **Transfers:** Live view of incoming file uploads.
    *   **History:** specific logging for web transfers.
*   **Security:**
    *   **Approval Dialog:** When a browser tries to upload, you must click "Accept" on the phone.

---

## 6. Transfer History Screen
Your log of all activity.

*   **Conversation View:**
    *   Groups transfers by Device (e.g., "Vijageesh's iPhone", "Windows PC").
    *   Shows last activity time and file count.
*   **Selection Mode:**
    *   Long-press a conversation to select multiple.
    *   **Delete:** Remove selected history logs (Bulk delete).
*   **Search Bar:**
    *   Filter history by Device Name or File Name.
*   **Conversation Detail (Chat View):**
    *   Drill down into a specific device's history.
    *   **Bubbles:** Color-coded bubbles for Sent vs Received files.
    *   **Open File:** Tap a file bubble to open it (Video, PDF, etc.).

---

## 7. Device Settings Screen
Customize your identity.

*   **Device Name:**
    *   Edit how you appear to others (e.g., change "New Android" to "My Pixel").
*   **Auto-Discovery Toggle:**
    *   Enable/Disable visibility on the radar.
*   **Info Section:**
    *   View App Version and running Platform (iOS/Android).

