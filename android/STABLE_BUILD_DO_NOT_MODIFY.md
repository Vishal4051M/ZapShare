# Android Build - Stable Version

This directory contains the **stable, production-ready Android build** of ZapShare.

## ⚠️ IMPORTANT - DO NOT MODIFY ⚠️

**These files should NOT be modified while working on the Windows version!**

## Version Info

- **Status**: Stable Production Build
- **Platform**: Android
- **Last Stable Build**: November 6, 2025
- **Purpose**: Android app distribution

## What's Here

All Android-specific build files, configurations, and native code for the Android app version of ZapShare.

## For Windows Development

If you're working on the Windows version:
1. ✅ **DO**: Work in `windows/` and `platforms/windows/` directories
2. ✅ **DO**: Use shared Dart code from `lib/` folder
3. ❌ **DON'T**: Modify any files in `android/` directory
4. ❌ **DON'T**: Change Android-specific configurations

## Android Build Commands

Build Android APK:
```bash
flutter build apk --release
```

Build Android App Bundle:
```bash
flutter build appbundle --release
```

Run on Android device:
```bash
flutter run
```

## File Structure

- `app/` - Android app module
- `build.gradle.kts` - Project-level Gradle configuration
- `gradle/` - Gradle wrapper and dependencies
- `local.properties` - Local SDK paths (ignored by git)
- `settings.gradle.kts` - Gradle settings

---

**Remember**: This is the Android production build. Keep it stable!
