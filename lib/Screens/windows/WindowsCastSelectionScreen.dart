import 'dart:io';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:zap_share/blocs/navigation/smooth_page_route.dart';
import 'package:zap_share/Screens/windows/WindowsCastScreen.dart';
import 'package:zap_share/Screens/windows/WindowsScreenMirrorScreen.dart';
import 'package:zap_share/Screens/shared/audio_share_screen.dart';

enum CastTileTheme { white, black, yellow }

class _TileStyles {
  static const double borderRadius = 32.0;
  static const double borderFocusedWidth = 2.0;
  static const double borderUnfocusedWidth = 1.0;

  static const Color blackGradientStart = Color(0xFF2C2C2E);
  static const Color blackGradientEnd = Color(0xFF1C1C1E);
  static const Color yellowGradientStart = Color(0xFFFFD84D);
  static const Color yellowGradientEnd = Color(0xFFF5C400);

  static const Color textLight = Colors.white;
  static const Color textLightSecondary = Colors.white70;
  static const Color textDark = Colors.black;
  static const Color textDarkSecondary = Colors.black54;

  static const Color blackThemeAccent = Color(0xFFFFD600);
  static const Color screenBgColor = Colors.black;

  static final Color focusBorderBlack = Colors.white.withOpacity(0.6);
  static final Color focusBorderLight = Colors.black.withOpacity(0.6);
  static final Color unfocusBorderBlack = Colors.white.withOpacity(0.08);
  static final Color unfocusBorderLight = Colors.black.withOpacity(0.08);
}

class WindowsCastSelectionScreen extends StatelessWidget {
  const WindowsCastSelectionScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _TileStyles.screenBgColor,
      body: Hero(
        tag: 'cast_card_container',
        createRectTween:
            (begin, end) => SmoothRectTween(begin: begin, end: end),
        child: Material(
          color: _TileStyles.screenBgColor,
          child: SafeArea(
            child: Container(
              padding: const EdgeInsets.fromLTRB(48, 48, 48, 48),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildHeader(context),
                  const SizedBox(height: 16),
                  Text(
                    'Choose how you want to share your media',
                    style: GoogleFonts.outfit(
                      fontSize: 18,
                      color: Colors.white60,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 48),
                  Expanded(
                    child: Center(
                      child: Container(
                        constraints: const BoxConstraints(maxWidth: 1000),
                        child: _buildGrid(context),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildGrid(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final spacing = 20.0;
        final ratio = constraints.maxWidth > 500 ? 1.1 : 0.95;

        return GridView.count(
          crossAxisCount: constraints.maxWidth > 500 ? 3 : 2,
          mainAxisSpacing: spacing,
          crossAxisSpacing: spacing,
          childAspectRatio: ratio,
          physics: const BouncingScrollPhysics(),
          children: [
            _CastTile(
              title: 'Audio Share',
              subtitle: 'Real-time sync',
              icon: Icons.waves_rounded,
              theme: CastTileTheme.yellow,
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
            _CastTile(
              title: 'Desktop Mirror',
              subtitle: 'Share screen',
              icon: Icons.laptop_chromebook_rounded,
              theme: CastTileTheme.black,
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
              title: 'Video Cast',
              subtitle: 'Stream movies',
              icon: Icons.movie_filter_rounded,
              theme: CastTileTheme.white,
              onTap: () {
                Navigator.push(
                  context,
                  SmoothPageRoute.slideRight(
                    page: const WindowsVideoCastScreen(),
                    duration: const Duration(milliseconds: 620),
                    reverseDuration: const Duration(milliseconds: 560),
                  ),
                );
              },
            ),
          ],
        );
      },
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Row(
      children: [
        _FocusIconButton(
          icon: Icons.arrow_back_ios_new_rounded,
          onTap: () => Navigator.pop(context),
          size: 48,
        ),
        const SizedBox(width: 16),
        Expanded(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              'Cast Options',
              style: GoogleFonts.outfit(
                fontSize: 28,
                fontWeight: FontWeight.w900,
                color: Colors.white,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildGuideStep({
    required String step,
    required String title,
    required String description,
  }) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF2C2C2E),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withOpacity(0.08), width: 1),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: const BoxDecoration(
              color: Color(0xFFFFD600),
              shape: BoxShape.circle,
            ),
            child: Text(
              step,
              style: GoogleFonts.robotoMono(
                color: Colors.black,
                fontWeight: FontWeight.bold,
                fontSize: 14,
              ),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: GoogleFonts.outfit(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  description,
                  style: GoogleFonts.outfit(
                    color: Colors.white70,
                    fontSize: 13,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CastTile extends StatefulWidget {
  final String title;
  final String subtitle;
  final IconData icon;
  final CastTileTheme theme;
  final VoidCallback onTap;

  const _CastTile({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.theme,
    required this.onTap,
  });

  @override
  State<_CastTile> createState() => _CastTileState();
}

class _CastTileState extends State<_CastTile> {
  bool _isFocused = false;

  @override
  Widget build(BuildContext context) {
    final double scale = 0.95;
    final padding = 16.0 * scale;
    final iconSize = 22.0 * scale;
    final iconPadding = 8.0 * scale;
    final titleSize = 16.0 * scale;
    final subtitleSize = 12.0 * scale;
    final bgIconSize = 72.0 * scale;

    final Color textColor;
    final Color subtitleColor;
    final Color iconColor;
    final Color iconBgColor;
    final Color bgIconColor;
    final List<Color> gradientColors;

    switch (widget.theme) {
      case CastTileTheme.white:
        textColor = _TileStyles.textDark;
        subtitleColor = _TileStyles.textDarkSecondary;
        iconColor = _TileStyles.textDark;
        iconBgColor = Colors.black.withOpacity(0.08);
        bgIconColor = Colors.black.withOpacity(0.08);
        gradientColors = [const Color(0xFFF0F0F0), const Color(0xFFE5E5E5)];
        break;
      case CastTileTheme.black:
        textColor = _TileStyles.textLight;
        subtitleColor = _TileStyles.textLightSecondary;
        iconColor = _TileStyles.blackThemeAccent;
        iconBgColor = Colors.white.withOpacity(0.1);
        bgIconColor = Colors.white.withOpacity(0.05);
        gradientColors = [
          _TileStyles.blackGradientStart,
          _TileStyles.blackGradientEnd,
        ];
        break;
      case CastTileTheme.yellow:
        textColor = _TileStyles.textDark;
        subtitleColor = _TileStyles.textDark.withOpacity(0.7);
        iconColor = _TileStyles.textDark;
        iconBgColor = Colors.black.withOpacity(0.1);
        bgIconColor = Colors.black.withOpacity(0.1);
        gradientColors = [
          _TileStyles.yellowGradientStart,
          _TileStyles.yellowGradientEnd,
        ];
        break;
    }

    final isFocusedBorderColor =
        widget.theme == CastTileTheme.black
            ? _TileStyles.focusBorderBlack
            : _TileStyles.focusBorderLight;
    final isUnfocusedBorderColor =
        widget.theme == CastTileTheme.black
            ? _TileStyles.unfocusBorderBlack
            : _TileStyles.unfocusBorderLight;

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
        child: AnimatedScale(
          duration: const Duration(milliseconds: 180),
          scale: _isFocused ? 1.03 : 1.0,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            padding: EdgeInsets.all(padding),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(_TileStyles.borderRadius),
              border: Border.all(
                color:
                    _isFocused
                        ? isFocusedBorderColor
                        : isUnfocusedBorderColor.withOpacity(0.65),
                width:
                    _isFocused
                        ? _TileStyles.borderFocusedWidth
                        : _TileStyles.borderUnfocusedWidth,
              ),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: gradientColors,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(_isFocused ? 0.25 : 0.18),
                  blurRadius: _isFocused ? 16 : 10,
                  offset: Offset(0, _isFocused ? 6 : 4),
                ),
              ],
            ),
            child: Stack(
              children: [
                Positioned(
                  bottom: -15,
                  right: -15,
                  child: Icon(
                    widget.icon,
                    size: bgIconSize,
                    color: bgIconColor,
                  ),
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
                          widget.icon,
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
                            widget.title,
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
                            widget.subtitle,
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
      ),
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
            color: const Color(0xFF1C1C1E),
            shape: BoxShape.circle,
            border: Border.all(
              color:
                  _isFocused
                      ? const Color(0xFFFFD600)
                      : Colors.white.withOpacity(0.08),
              width: _isFocused ? 2 : 1,
            ),
          ),
          child: Icon(widget.icon, color: Colors.white, size: 20),
        ),
      ),
    );
  }
}
