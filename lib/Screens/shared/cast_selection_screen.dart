import 'dart:io';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:zap_share/blocs/navigation/smooth_page_route.dart';
import 'package:zap_share/Screens/android/AndroidCastScreen.dart';
import 'package:zap_share/Screens/android/AndroidScreenMirrorScreen.dart';
import 'package:zap_share/Screens/windows/WindowsCastScreen.dart';
import 'package:zap_share/Screens/windows/WindowsScreenMirrorScreen.dart';
import 'package:zap_share/Screens/shared/audio_share_screen.dart';

enum CastTileTheme { white, black, yellow }

class _TileStyles {
  // Border and Radius Sizes
  static const double borderRadius = 32.0;
  static const double borderFocusedWidth = 2.0;
  static const double borderUnfocusedWidth = 1.0;

  // Gradients and Solid Colors
  static const Color blackGradientStart = Color(0xFF2C2C2E);
  static const Color blackGradientEnd = Color(0xFF1C1C1E);
  static const Color yellowGradientStart = Color(0xFFFFD84D);
  static const Color yellowGradientEnd = Color(0xFFF5C400);

  // Text Colors
  static const Color textLight = Colors.white;
  static const Color textLightSecondary = Colors.white70;
  static const Color textDark = Colors.black;
  static const Color textDarkSecondary = Colors.black54;

  // Highlights and Accents
  static const Color blackThemeAccent = Color(
    0xFFFFD600,
  ); // Yellow icon accent on black card
  static const Color screenBgColor = Color(
    0xFF000000,
  ); // Match the Android home dashboard background.

  // Focus Borders
  static final Color focusBorderBlack = Colors.white.withValues(alpha: 0.6);
  static final Color focusBorderLight = Colors.black.withValues(alpha: 0.6);
  static final Color unfocusBorderBlack = Colors.white.withValues(alpha: 0.08);
  static final Color unfocusBorderLight = Colors.black.withValues(alpha: 0.08);
}

class CastSelectionScreen extends StatelessWidget {
  const CastSelectionScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final isLandscape = media.orientation == Orientation.landscape;
    final isTvLayout = media.size.shortestSide >= 600;
    final useTvLayout = isLandscape && isTvLayout;

    return Scaffold(
      backgroundColor: _TileStyles.screenBgColor,
      body: Hero(
        tag: 'cast_card_container',
        createRectTween:
            (begin, end) => SmoothRectTween(begin: begin, end: end),
        child: Material(
          color: _TileStyles.screenBgColor,
          child: SafeArea(
            child: FocusTraversalGroup(
              policy: ReadingOrderTraversalPolicy(),
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: useTvLayout ? 56.0 : 24.0,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(height: useTvLayout ? 32 : 24),
                    // Header
                    _buildHeader(context, useTvLayout: useTvLayout),
                    SizedBox(height: useTvLayout ? 18 : 12),
                    Text(
                      'Choose how you want to share your media',
                      style: GoogleFonts.outfit(
                        fontSize: useTvLayout ? 18 : 15,
                        color: Colors.white60,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    SizedBox(height: useTvLayout ? 44 : 40),

                    _buildDashboardStyleGrid(context, useTvLayout: useTvLayout),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDashboardStyleGrid(
    BuildContext context, {
    required bool useTvLayout,
  }) {
    final showPhoneScreen = Platform.isAndroid;

    return Expanded(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final isCompact = constraints.maxHeight < 520;
          final spacing = useTvLayout ? 24.0 : (isCompact ? 12.0 : 16.0);

          // Width based column count: 3 columns if wide screen, otherwise 2
          final isWide = constraints.maxWidth > 600;
          final columns = isWide ? 3 : 2;
          final ratio = isWide ? 1.05 : (isCompact ? 0.85 : 1.15);

          return GridView.count(
            crossAxisCount: columns,
            mainAxisSpacing: spacing,
            crossAxisSpacing: spacing,
            childAspectRatio: ratio,
            physics:
                isWide
                    ? const NeverScrollableScrollPhysics()
                    : const BouncingScrollPhysics(),
            children: [
              _CastTile(
                title: 'Video Cast',
                subtitle: 'Stream movies',
                icon: Icons.movie_filter_rounded,
                theme: CastTileTheme.yellow,
                isTvLayout: useTvLayout,
                onTap: () {
                  if (Platform.isAndroid) {
                    Navigator.push(
                      context,
                      SmoothPageRoute.slideRight(
                        page: const AndroidCastScreen(
                          initialMode: CastMode.video,
                          heroTag: 'cast_video_card',
                        ),
                        duration: const Duration(milliseconds: 620),
                        reverseDuration: const Duration(milliseconds: 560),
                      ),
                    );
                  } else {
                    Navigator.push(
                      context,
                      SmoothPageRoute.slideRight(
                        page: const WindowsVideoCastScreen(),
                        duration: const Duration(milliseconds: 620),
                        reverseDuration: const Duration(milliseconds: 560),
                      ),
                    );
                  }
                },
              ),
              if (showPhoneScreen)
                _CastTile(
                  title: 'Phone Screen',
                  subtitle: 'Mirror Screen',
                  icon: Icons.screen_share_rounded,
                  theme: CastTileTheme.black,
                  isTvLayout: useTvLayout,
                  onTap: () {
                    Navigator.push(
                      context,
                      SmoothPageRoute.slideRight(
                        page: const AndroidScreenMirrorScreen(),
                        duration: const Duration(milliseconds: 620),
                        reverseDuration: const Duration(milliseconds: 560),
                      ),
                    );
                  },
                ),
              if (!showPhoneScreen) // Windows desktop mirroring screen
                _CastTile(
                  title: 'Desktop Mirror',
                  subtitle: 'Share screen',
                  icon: Icons.laptop_chromebook_rounded,
                  theme: CastTileTheme.black,
                  isTvLayout: useTvLayout,
                  onTap: () {
                    Navigator.push(
                      context,
                      SmoothPageRoute.slideRight(
                        page: const WindowsScreenMirrorScreen(),
                        duration: const Duration(milliseconds: 620),
                        reverseDuration: const Duration(milliseconds: 560),
                      ),
                    );
                  },
                ),
              _CastTile(
                title: 'Audio Share',
                subtitle: 'Real-time sync',
                icon: Icons.waves_rounded,
                theme: CastTileTheme.white,
                isTvLayout: useTvLayout,
                onTap: () {
                  Navigator.push(
                    context,
                    SmoothPageRoute.slideRight(
                      page: const AudioShareScreen(),
                      duration: const Duration(milliseconds: 620),
                      reverseDuration: const Duration(milliseconds: 560),
                    ),
                  );
                },
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildHeader(BuildContext context, {required bool useTvLayout}) {
    return Row(
      children: [
        _FocusIconButton(
          icon: Icons.arrow_back_ios_new_rounded,
          onTap: () => Navigator.pop(context),
          size: useTvLayout ? 56 : 48,
        ),
        const SizedBox(width: 16),
        Expanded(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              'Cast Options',
              style: GoogleFonts.outfit(
                fontSize: useTvLayout ? 34 : 28,
                fontWeight: FontWeight.w900,
                color: Colors.white,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _CastTile extends StatelessWidget {
  final String title;
  final String subtitle;
  final IconData icon;
  final CastTileTheme theme;
  final bool isTvLayout;
  final VoidCallback? onTap;

  const _CastTile({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.theme,
    required this.isTvLayout,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final bool isEnabled = onTap != null;
    return _FocusableTile(
      enabled: isEnabled,
      autofocus: theme == CastTileTheme.yellow && isTvLayout,
      onTap: onTap,
      builder: (isFocused) {
        return LayoutBuilder(
          builder: (context, constraints) {
            final isCompact = constraints.maxHeight < 170;
            final scale = isTvLayout ? 1.1 : 0.9;
            final padding = (isCompact ? 12.0 : 16.0) * scale;
            final iconSize = (isCompact ? 18.0 : 22.0) * scale;
            final iconPadding = (isCompact ? 6.0 : 8.0) * scale;
            final titleSize = (isCompact ? 14.0 : 16.0) * scale;
            final subtitleSize = (isCompact ? 10.0 : 12.0) * scale;
            final bgIconSize = (isCompact ? 48.0 : 72.0) * scale;

            final Color textColor;
            final Color subtitleColor;
            final Color iconColor;
            final Color iconBgColor;
            final Color bgIconColor;
            final List<Color> gradientColors;

            switch (theme) {
              case CastTileTheme.white:
                textColor = _TileStyles.textDark;
                subtitleColor = _TileStyles.textDarkSecondary;
                iconColor = _TileStyles.textDark;
                iconBgColor = Colors.black.withValues(alpha: 0.08);
                bgIconColor = Colors.black.withValues(alpha: 0.08);
                gradientColors = [
                  const Color(0xFFF0F0F0),
                  const Color(0xFFE5E5E5),
                ];
                break;
              case CastTileTheme.black:
                textColor = _TileStyles.textLight;
                subtitleColor = _TileStyles.textLightSecondary;
                iconColor = _TileStyles.blackThemeAccent;
                iconBgColor = Colors.white.withValues(alpha: 0.1);
                bgIconColor = Colors.white.withValues(alpha: 0.05);
                gradientColors = [
                  _TileStyles.blackGradientStart,
                  _TileStyles.blackGradientEnd,
                ];
                break;
              case CastTileTheme.yellow:
                textColor = _TileStyles.textDark;
                subtitleColor = _TileStyles.textDark.withValues(alpha: 0.7);
                iconColor = _TileStyles.textDark;
                iconBgColor = Colors.black.withValues(alpha: 0.1);
                bgIconColor = Colors.black.withValues(alpha: 0.1);
                gradientColors = [
                  _TileStyles.yellowGradientStart,
                  _TileStyles.yellowGradientEnd,
                ];
                break;
            }

            final isFocusedBorderColor =
                theme == CastTileTheme.black
                    ? _TileStyles.focusBorderBlack
                    : _TileStyles.focusBorderLight;
            final isUnfocusedBorderColor =
                theme == CastTileTheme.black
                    ? _TileStyles.unfocusBorderBlack
                    : _TileStyles.unfocusBorderLight;

            return AnimatedOpacity(
              duration: const Duration(milliseconds: 200),
              opacity: isEnabled ? 1.0 : 0.4,
              child: AnimatedScale(
                duration: const Duration(milliseconds: 180),
                scale: isFocused ? 1.03 : 1.0,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  padding: EdgeInsets.all(padding),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(
                      _TileStyles.borderRadius,
                    ),
                    border: Border.all(
                      color:
                          isFocused
                              ? isFocusedBorderColor
                              : isUnfocusedBorderColor.withValues(alpha: 0.65),
                      width:
                          isFocused
                              ? _TileStyles.borderFocusedWidth
                              : _TileStyles.borderUnfocusedWidth,
                    ),
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: gradientColors,
                    ),
                    boxShadow:
                        isFocused
                            ? [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.15),
                                blurRadius: 16,
                                offset: const Offset(0, 6),
                              ),
                            ]
                            : [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.18),
                                blurRadius: 10,
                                offset: const Offset(0, 4),
                              ),
                            ],
                  ),
                  child: Stack(
                    children: [
                      Positioned(
                        bottom: -15,
                        right: -15,
                        child: Icon(icon, size: bgIconSize, color: bgIconColor),
                      ),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Align(
                            alignment: Alignment.topLeft,
                            child: Container(
                              padding: EdgeInsets.all(iconPadding),
                              decoration: BoxDecoration(
                                color: iconBgColor,
                                shape: BoxShape.circle,
                              ),
                              child: Icon(
                                icon,
                                color: iconColor,
                                size: iconSize,
                              ),
                            ),
                          ),
                          Flexible(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisAlignment: MainAxisAlignment.end,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  title,
                                  style: GoogleFonts.outfit(
                                    fontSize: titleSize,
                                    fontWeight: FontWeight.w800,
                                    color: textColor,
                                    height: 1.1,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  subtitle,
                                  style: GoogleFonts.outfit(
                                    fontSize: subtitleSize,
                                    color: subtitleColor,
                                    fontWeight: FontWeight.w500,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _FocusIconButton extends StatefulWidget {
  final IconData icon;
  final VoidCallback onTap;
  final double size;

  const _FocusIconButton({
    required this.icon,
    required this.onTap,
    required this.size,
  });

  @override
  State<_FocusIconButton> createState() => _FocusIconButtonState();
}

class _FocusIconButtonState extends State<_FocusIconButton> {
  bool _isFocused = false;

  @override
  Widget build(BuildContext context) {
    return FocusableActionDetector(
      onFocusChange: (focused) => setState(() => _isFocused = focused),
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (intent) {
            widget.onTap();
            return null;
          },
        ),
      },
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: widget.size,
          height: widget.size,
          decoration: BoxDecoration(
            color: const Color(0xFFF3F4F6),
            shape: BoxShape.circle,
            border: Border.all(
              color:
                  _isFocused
                      ? const Color(0xFFFFD600)
                      : Colors.white.withValues(alpha: 0.08),
              width: _isFocused ? 2 : 1,
            ),
          ),
          child: Icon(widget.icon, color: Colors.black, size: 20),
        ),
      ),
    );
  }
}

class _FocusableTile extends StatefulWidget {
  final bool enabled;
  final bool autofocus;
  final VoidCallback? onTap;
  final Widget Function(bool isFocused) builder;

  const _FocusableTile({
    required this.enabled,
    required this.autofocus,
    required this.onTap,
    required this.builder,
  });

  @override
  State<_FocusableTile> createState() => _FocusableTileState();
}

class _FocusableTileState extends State<_FocusableTile> {
  bool _isFocused = false;

  @override
  Widget build(BuildContext context) {
    return FocusableActionDetector(
      enabled: widget.enabled,
      autofocus: widget.autofocus,
      onFocusChange: (focused) => setState(() => _isFocused = focused),
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (intent) {
            widget.onTap?.call();
            return null;
          },
        ),
      },
      child: GestureDetector(
        onTap: widget.onTap,
        child: widget.builder(_isFocused),
      ),
    );
  }
}
