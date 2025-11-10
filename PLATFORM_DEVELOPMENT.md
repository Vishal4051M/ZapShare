# Platform-Specific Development Guide

This guide explains how to work with the ZapShare codebase now that it's organized for multi-platform development.

## 📁 Directory Structure

```
ZapShare-main/
├── lib/                          # Shared Dart code (Android & Windows)
│   ├── main.dart
│   ├── Screens/
│   ├── services/
│   └── widgets/
│
├── android/                      # ⚠️ STABLE - Android build files (DO NOT MODIFY for Windows work)
│   ├── app/
│   ├── build.gradle.kts
│   └── STABLE_BUILD_DO_NOT_MODIFY.md
│
├── windows/                      # Windows build files (modify for Windows features)
│   ├── runner/
│   └── CMakeLists.txt
│
├── platforms/                    # Platform-specific documentation & backups
│   ├── android/
│   │   └── README.md            # Android implementation notes
│   ├── windows/
│   │   └── README.md            # Windows development guide
│   └── README.md                # This file
│
├── assets/                       # Shared assets (images, fonts, etc.)
├── web/                          # Web platform files
├── ios/                          # iOS build files
├── linux/                        # Linux build files
└── macos/                        # macOS build files
```

## 🎯 Development Workflows

### Working on Android

**Current Status**: ✅ Stable production build

**Guidelines**:
- Android build is **STABLE** - do not modify
- All Android-specific code is finalized
- Build with: `flutter build apk --release`

**Files to modify** (only if fixing critical Android bugs):
- `android/` - Android build configuration
- `lib/` - Shared Dart code that affects Android

### Working on Windows

**Current Status**: 🚧 Under development

**Guidelines**:
- **CRITICAL**: Do NOT modify any files in `android/` directory!
- Modify `windows/` directory for Windows-specific features
- Update `lib/` for shared code changes
- Document Windows-specific changes in `platforms/windows/`

**Files to modify**:
- `windows/` - Windows build configuration and native code
- `lib/` - Shared Dart code (carefully, test on both platforms)
- `platforms/windows/` - Windows-specific documentation

**Build commands**:
```bash
# Run in development
flutter run -d windows

# Build release
flutter build windows --release
```

## 🔀 Shared Code Strategy

### What Goes in `lib/`

The `lib/` folder contains **shared Dart code** that works across both platforms:

- ✅ **UI Screens** - Flutter widgets that work on both platforms
- ✅ **Business Logic** - Core app functionality
- ✅ **Models** - Data structures
- ✅ **Services** - HTTP, file handling (with platform channels)
- ✅ **Utilities** - Helper functions

### Platform-Specific Code

When you need platform-specific functionality:

1. **Use Platform Channels**:
```dart
// In lib/
import 'dart:io' show Platform;

if (Platform.isAndroid) {
  // Android-specific code
} else if (Platform.isWindows) {
  // Windows-specific code
}
```

2. **Native Code**:
   - Android: Place in `android/app/src/main/kotlin/`
   - Windows: Place in `windows/runner/`

## 🚨 Critical Rules

### For Windows Development

1. ❌ **NEVER** modify `android/` directory
2. ❌ **NEVER** modify Android-specific Gradle files
3. ❌ **NEVER** change Android manifest or permissions
4. ✅ **DO** create new Windows-specific files in `windows/`
5. ✅ **DO** use conditional code in `lib/` if needed
6. ✅ **DO** test changes on Android if modifying shared `lib/` code

### For Shared Code Changes

If you need to modify `lib/` files:

1. **Test on Android first** - Ensure no regressions
2. **Use platform checks** - Wrap platform-specific code
3. **Document changes** - Update relevant README files
4. **Build both** - Verify both platforms build successfully

```dart
// Example of safe shared code modification
import 'dart:io';

Future<void> saveFile(String path, List<int> data) async {
  if (Platform.isAndroid) {
    // Use SAF on Android
    await _saveFileAndroid(path, data);
  } else if (Platform.isWindows) {
    // Use Windows file APIs
    await _saveFileWindows(path, data);
  }
}
```

## 📋 Pre-Commit Checklist

Before committing changes:

### For Windows Work
- [ ] No files in `android/` directory modified?
- [ ] Shared code changes tested on Android?
- [ ] Windows build successful?
- [ ] Platform checks in place for platform-specific code?
- [ ] Documentation updated in `platforms/windows/`?

### For Android Fixes (rare)
- [ ] Only critical bugs being fixed?
- [ ] Changes documented?
- [ ] Windows build still works?
- [ ] `STABLE_BUILD_DO_NOT_MODIFY.md` updated if major changes?

## 🛠️ Build Commands Reference

### Android
```bash
# Debug build
flutter run -d <android-device-id>

# Release APK
flutter build apk --release

# Release App Bundle (for Play Store)
flutter build appbundle --release
```

### Windows
```bash
# Debug build
flutter run -d windows

# Release build
flutter build windows --release

# Clean build
flutter clean && flutter pub get && flutter build windows --release
```

### Both Platforms
```bash
# Clean all builds
flutter clean

# Get dependencies
flutter pub get

# Run code generation (if using build_runner)
flutter pub run build_runner build

# Analyze code
flutter analyze

# Run tests
flutter test
```

## 📦 Dependencies Management

When adding new dependencies:

1. Add to `pubspec.yaml`
2. Note if dependency is platform-specific
3. Run `flutter pub get`
4. Test on both platforms
5. Update platform README if needed

```yaml
dependencies:
  # Cross-platform
  http: ^1.1.0
  
  # Platform-specific
  win32: ^5.0.0  # Windows only
  # (Android-specific deps already in place)
```

## 🔍 Debugging Tips

### Finding Platform-Specific Issues

```dart
import 'dart:io';

void debugPlatformInfo() {
  print('Platform: ${Platform.operatingSystem}');
  print('Version: ${Platform.operatingSystemVersion}');
  print('Is Android: ${Platform.isAndroid}');
  print('Is Windows: ${Platform.isWindows}');
}
```

### Android Issues
- Check `android/app/build.gradle.kts`
- View logcat: `flutter logs` or Android Studio Logcat
- Check permissions in `AndroidManifest.xml`

### Windows Issues
- Check `windows/runner/CMakeLists.txt`
- View debug output in VS Code Debug Console
- Check Windows-specific permissions

## 📚 Additional Resources

- [Flutter Platform Channels](https://docs.flutter.dev/development/platform-integration/platform-channels)
- [Android Development](./android/STABLE_BUILD_DO_NOT_MODIFY.md)
- [Windows Development](./windows/README.md)
- [Platform-Specific Plugins](https://pub.dev/flutter/packages?platform=android)

---

**Remember**: The goal is to maintain a stable Android app while developing the Windows version. Keep the platforms separate and the shared code compatible!
