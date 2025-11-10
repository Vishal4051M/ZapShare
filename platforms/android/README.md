# ZapShare Android

This directory contains Android-specific implementation files for ZapShare.

## Contents

This is a reference/backup directory for the Android implementation. The actual build files remain in the root `android/` folder for Flutter's build system.

## Purpose

- Serves as a backup of the stable Android implementation
- Reference for Android-specific features and native code
- Isolation from Windows development work

## Note

**Do NOT modify files here when working on the Windows version!**

All Android build files in the root `android/` folder should be considered stable and production-ready for the Android app.

## Android App Features

The Android version includes:
- File sharing via HTTP server
- Device discovery on local network
- Hotspot support
- SAF (Storage Access Framework) integration
- Foreground service for reliable file transfers
- Material Design UI
- Android-specific permissions handling
