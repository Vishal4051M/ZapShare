# Platform-Specific Files

This directory contains platform-specific implementations and build configurations for ZapShare.

## Structure

- **android/** - Android-specific build files and native code
- **windows/** - Windows-specific build files and native code

## Important Notes

### Android Version
The `android/` folder contains the stable, production-ready Android implementation. This includes:
- Android build configuration
- Native Android code
- Android-specific assets and resources
- Android permissions and manifest

**Do not modify Android files when working on Windows version!**

### Windows Version
The `windows/` folder will contain the Windows implementation. Work on Windows-specific features should only modify files in this directory.

## Development Guidelines

1. **Working on Android**: Use files from `platforms/android/` or root `lib/` for shared code
2. **Working on Windows**: Use files from `platforms/windows/` or root `lib/` for shared code
3. **Shared Code**: Common Dart code stays in root `lib/` folder
4. **Platform-Specific Code**: Platform channels and native implementations go in respective platform folders

## Build Instructions

### Android
```bash
# From project root
flutter build apk --release
```

### Windows (Coming Soon)
```bash
# From project root
flutter build windows --release
```

## Migration Note

Platform-specific files have been moved here to maintain clear separation between Android and Windows implementations. The root `android/`, `windows/`, `ios/`, `linux/`, and `macos/` folders remain in place for Flutter's build system.
