import 'dart:io';
import 'video_player_interface.dart';
import 'mpv_video_player.dart';
import 'exoplayer_video_player.dart';

import 'native_platform_mpv_player.dart';

/// Factory for creating platform-specific video players
///
/// - Windows: media_kit (libmpv library + Flutter TextureRegistry)
///   NOTE: Native child window approach (NativePlatformMpvPlayer) was abandoned
///   because creating ANY WS_CHILD window inside Flutter's ANGLE rendering
///   surface crashes the process — even with --vo=null and no D3D11 rendering.
///   The ANGLE compositor cannot coexist with child windows in its HWND tree.
///
/// - Android: ExoPlayer via video_player package
class PlatformVideoPlayerFactory {
  static PlatformVideoPlayer create() {
    if (Platform.isWindows) {
      // Use standard media_kit texture implementation.
      // The native hole-punching attempts (NativePlatformMpvPlayer) caused white screens/crashes.
      return NativePlatformMpvPlayer();
    } else if (Platform.isAndroid) {
      return ExoPlayerVideoPlayer();
    } else {
      return MpvVideoPlayer();
    }
  }
}
