# Quick Start: Platform Video Players

## What Changed?

Your video player now uses **native implementations** for each platform:
- **Windows**: MPV with Win32 native window (zero-copy rendering)
- **Android**: ExoPlayer (native Android video stack)

Both share the same Flutter UI controls and features!

## Usage (No Changes Needed!)

The VideoPlayerScreen API remains **exactly the same**:

```dart
Navigator.push(
  context,
  MaterialPageRoute(
    builder: (_) => VideoPlayerScreen(
      videoSource: '/path/to/video.mp4',
      title: 'My Video',
      subtitlePath: '/path/to/subtitle.srt', // Optional
    ),
  ),
);
```

## What You Get

### Windows
✅ MPV native rendering (same as before, still smooth!)  
✅ Hardware acceleration (d3d11va, dxva2)  
✅ HDR support with tone-mapping  
✅ High-quality scaling (spline36)  
✅ All MPV features preserved  

### Android (NEW!)
✅ ExoPlayer - Native Android video player  
✅ Hardware-accelerated decoding  
✅ Better battery life  
✅ Lower memory usage  
✅ Smooth 60fps playback  
✅ Native buffering & caching  

## File Structure

```
lib/Screens/shared/
├── VideoPlayerScreen.dart              # Your main player UI (refactored)
├── video_player_interface.dart         # Common interface
├── mpv_video_player.dart               # Windows implementation
├── exoplayer_video_player.dart         # Android implementation  
└── platform_video_player_factory.dart  # Auto-selects platform
```

## How It Works Internally

```dart
// 1. Factory creates the right player for your platform
_player = PlatformVideoPlayerFactory.create();
//   → Windows: Returns MpvVideoPlayer (media_kit backend)
//   → Android: Returns ExoPlayerVideoPlayer (video_player backend)

// 2. Open video (platform handles configuration automatically)
await _player.open(
  'https://example.com/video.mp4',
  subtitlePath: 'path/to/subtitle.srt',
);

// 3. Control playback (same API for both platforms)
await _player.play();
await _player.pause();
await _player.seek(Duration(seconds: 30));
await _player.setRate(1.5); // 1.5x speed

// 4. Listen to state changes
_player.positionStream.listen((position) {
  print('Current position: $position');
});
```

## Testing Locally

### Windows
1. Run: `flutter run -d windows`
2. Open any video file
3. Verify MPV rendering is smooth
4. Test keyboard shortcuts (Space, arrows, F, M, etc.)

### Android
1. Connect device or start emulator
2. Run: `flutter run -d <device-name>`
3. Open any video file
4. **Look for ExoPlayer in logs**: Should see ExoPlayer initialization
5. Verify smooth playback & low battery drain

## Troubleshooting

### Windows: "Player error" or black screen
- Check logs for MPV errors
- Ensure `media_kit_libs_windows_video` is installed
- Try: `flutter clean && flutter pub get && flutter run`

### Android: "Failed to open video"
- Check if `video_player` is installed: `flutter pub get`
- Verify permissions in AndroidManifest.xml (INTERNET, storage)
- Check logs for ExoPlayer errors

### Both platforms: Subtitles not loading
- Ensure subtitle file exists at subtitlePath
- Check file encoding (UTF-8 recommended)
- Verify subtitle format (.srt, .ass, .vtt)

## Advanced: Customizing Platform Players

### Windows (MPV Configuration)
Edit `mpv_video_player.dart` → `open()` method:
```dart
await np.setProperty('scale', 'ewa_lanczos'); // Change scaling
await np.setProperty('deband', 'no');         // Disable deband
```

### Android (ExoPlayer Configuration)
Edit `exoplayer_video_player.dart` → `open()` method:
```dart
_controller = vp.VideoPlayerController.networkUrl(
  Uri.parse(source),
  videoPlayerOptions: vp.VideoPlayerOptions(
    mixWithOthers: true,  // Allow background audio
    allowBackgroundPlayback: true,
  ),
);
```

## Performance Tips

### Windows
- Default config is already optimized (256 MB buffer, spline36 scaling)
- For 4K HDR: Config already includes HDR tone-mapping
- For low-end PCs: Reduce buffer size in `mpv_video_player.dart`

### Android
- ExoPlayer auto-adjusts buffer based on network conditions
- Hardware decoding is automatic (no config needed)
- For low-end devices: ExoPlayer will fallback to lower resolutions automatically

## Migration Notes

### If you have custom MPV properties:
**Before** (in VideoPlayerScreen):
```dart
await np.setProperty('my-property', 'value');
```

**After** (in mpv_video_player.dart → open()):
```dart
await np.setProperty('my-property', 'value');
```

### If you're using SubtitleTrack directly:
**Before**:
```dart
SubtitleTrack.no()
SubtitleTrack.uri(path)
```

**After**:
```dart
SubtitleTrackInfo.none
// URI loading now done via subtitlePath parameter
```

## Need Help?

- Check: `PLATFORM_VIDEO_PLAYER_IMPLEMENTATION.md` for full details
- Logs: Look for "MPV" (Windows) or "ExoPlayer" (Android) in console
- Issues: Check GitHub issues or create a new one

---

**TL;DR**: Your video player now uses **MPV on Windows** (same as before) and **ExoPlayer on Android** (new, better performance). The UI and API remain unchanged!
