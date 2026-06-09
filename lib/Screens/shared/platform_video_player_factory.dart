import 'dart:io';
import 'video_player_interface.dart';
import 'mpv_video_player.dart';
import 'exoplayer_video_player.dart';
import 'native_platform_mpv_player.dart';

/// Factory for creating platform-specific video players
///
/// - Windows: native MPV bridge (embedded in app window via platform plugin)
///
/// - Android / Android TV: Native ExoPlayer via platform channels
///   Uses Media3 ExoPlayer with full subtitle/audio track selection support
///   via native Kotlin ExoPlayerBridge. This is the most reliable approach
///   for Android TV since ExoPlayer uses the same MediaCodec API as VLC.
///
/// - Linux: native MPV bridge (embedded in app window via X11 wid)
/// - macOS: media_kit (libmpv)
class PlatformVideoPlayerFactory {
  static PlatformVideoPlayer create() {
    if (Platform.isWindows) {
      // Windows keeps native platform MPV integration.
      return NativePlatformMpvPlayer();
    } else if (Platform.isAndroid) {
      // Use native ExoPlayer with full track support on Android / Android TV.
      return ExoPlayerVideoPlayer();
    } else if (Platform.isLinux) {
      // PURE HARDWARE OVERLAY MODE for Linux.
      // Since composite textures are frame-droppy on this driver setup,
      // we use a native foreground window (NativePlatformMpvPlayer).
      // Controls are hidden on-screen and managed remotely via phone/sender.
      return NativePlatformMpvPlayer();
    } else {
      // macOS or others — use MPV via media_kit
      return MpvVideoPlayer();
    }
  }
}
