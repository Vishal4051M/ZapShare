# ZapShare Windows

This directory will contain Windows-specific implementation files for ZapShare.

## Status

🚧 **Under Development** 🚧

The Windows version is currently being developed. This directory will contain:

## Planned Contents

- Windows-specific UI adaptations
- Native Windows APIs for file handling
- Windows desktop integration
- Platform channels for Windows
- Windows-specific build configurations

## Development Guidelines

1. **Shared Code**: Use the shared Dart code from root `lib/` folder
2. **Windows-Specific**: Windows-only features go here
3. **Do Not Touch**: Leave Android files (`android/` and `platforms/android/`) unchanged

## Windows Features (Planned)

- [ ] Windows-native file picker
- [ ] Windows notification system
- [ ] Windows system tray integration
- [ ] Windows Firewall configuration helper
- [ ] Windows-specific UI/UX optimizations
- [ ] Windows network discovery
- [ ] Drag & drop file support
- [ ] Windows file associations

## Build Commands (Coming Soon)

```bash
# Development build
flutter run -d windows

# Release build
flutter build windows --release
```

## Notes

- Windows implementation will share most Dart code with Android
- Platform-specific code will use Flutter platform channels
- UI will be adapted for desktop with larger screens
- File handling will use Windows APIs instead of Android SAF
