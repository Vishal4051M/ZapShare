import 'dart:io';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:zap_share/blocs/navigation/smooth_page_route.dart';
import 'package:zap_share/Screens/android/AndroidCastScreen.dart';
import 'package:zap_share/Screens/windows/WindowsCastScreen.dart';
import 'package:zap_share/Screens/shared/audio_share_screen.dart';

class CastSelectionScreen extends StatelessWidget {
  const CastSelectionScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final isLandscape = media.orientation == Orientation.landscape;
    final isTvLayout = media.size.shortestSide >= 600;
    final useTvLayout = isLandscape && isTvLayout;

    return Scaffold(
      backgroundColor: Colors.white,
      body: Hero(
        tag: 'cast_card_container',
        createRectTween:
            (begin, end) => SmoothRectTween(begin: begin, end: end),
        child: Material(
          color: Colors.white,
          child: SafeArea(
            child: FocusTraversalGroup(
              policy: ReadingOrderTraversalPolicy(),
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: useTvLayout ? 56.0 : 24.0),
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
                        color: Colors.black38,
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

  Widget _buildDashboardStyleGrid(BuildContext context, {required bool useTvLayout}) {
    final showPhoneScreen = Platform.isAndroid;

    return Expanded(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final isCompact = constraints.maxHeight < 520;
          final spacing = useTvLayout ? 24.0 : (isCompact ? 12.0 : 16.0);
          final ratio = useTvLayout ? 1.05 : (isCompact ? 0.82 : 0.95);
          final columns = useTvLayout ? (showPhoneScreen ? 3 : 2) : 2;

          return GridView.count(
            crossAxisCount: columns,
            mainAxisSpacing: spacing,
            crossAxisSpacing: spacing,
            childAspectRatio: ratio,
            physics:
                useTvLayout
                    ? const NeverScrollableScrollPhysics()
                    : const BouncingScrollPhysics(),
            children: [
              _CastTile(
                title: 'Video Cast',
                subtitle: 'Stream movies',
                icon: Icons.movie_filter_rounded,
                color: const Color(0xFFFFD600),
                isMainFeature: true,
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
                        page: const WindowsCastScreen(),
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
                  color: const Color(0xFFC084FC),
                  isTvLayout: useTvLayout,
                  onTap: () {
                    Navigator.push(
                      context,
                      SmoothPageRoute.slideRight(
                        page: const AndroidCastScreen(
                          initialMode: CastMode.screenMirror,
                          heroTag: 'cast_screen_card',
                        ),
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
                color: const Color(0xFF38BDF8),
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
                color: Colors.black,
                letterSpacing: -0.5,
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
  final Color color;
  final bool isMainFeature;
  final bool isTvLayout;
  final VoidCallback? onTap;

  const _CastTile({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.color,
    this.isMainFeature = false,
    required this.isTvLayout,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final bool isEnabled = onTap != null;
    return _FocusableTile(
      enabled: isEnabled,
      autofocus: isMainFeature && isTvLayout,
      onTap: onTap,
      builder: (isFocused) {
        return LayoutBuilder(
          builder: (context, constraints) {
            final isCompact = constraints.maxHeight < 170;
            final scale = isTvLayout ? 1.2 : 1.0;
            final padding = (isCompact ? 12.0 : 20.0) * scale;
            final iconSize = (isCompact ? 18.0 : 24.0) * scale;
            final iconPadding = (isCompact ? 8.0 : 10.0) * scale;
            final titleSize = (isCompact ? 15.0 : 18.0) * scale;
            final subtitleSize = (isCompact ? 11.0 : 13.0) * scale;
            final bgIconSize = (isCompact ? 56.0 : 80.0) * scale;
            final gap = (isCompact ? 8.0 : 12.0) * scale;

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
                    color:
                        isMainFeature
                            ? const Color(0xFFFFD600)
                            : const Color(0xFFF3F4F6),
                    borderRadius: BorderRadius.circular(32),
                    border: Border.all(
                      color:
                          isFocused
                              ? Colors.black.withOpacity(0.6)
                              : Colors.black.withOpacity(0.05),
                      width: isFocused ? 2 : 1,
                    ),
                    boxShadow:
                        isFocused
                            ? [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.15),
                                blurRadius: 16,
                                offset: const Offset(0, 6),
                              ),
                            ]
                            : null,
                  ),
                  child: Stack(
                    children: [
                      Positioned(
                        bottom: -20,
                        right: -20,
                        child: Icon(
                          icon,
                          size: bgIconSize,
                          color:
                              isMainFeature
                                  ? Colors.black.withOpacity(0.03)
                                  : Colors.black.withOpacity(0.01),
                        ),
                      ),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            padding: EdgeInsets.all(iconPadding),
                            decoration: BoxDecoration(
                              color:
                                  isMainFeature
                                      ? Colors.black.withOpacity(0.1)
                                      : Colors.white,
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              icon,
                              color: isMainFeature ? Colors.black : color,
                              size: iconSize,
                            ),
                          ),
                          SizedBox(height: gap),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                Text(
                                  title,
                                  style: GoogleFonts.outfit(
                                    fontSize: titleSize,
                                    fontWeight: FontWeight.w900,
                                    color: Colors.black,
                                    letterSpacing: -0.5,
                                    height: 1.1,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  subtitle,
                                  style: GoogleFonts.outfit(
                                    fontSize: subtitleSize,
                                    color:
                                        isMainFeature
                                            ? Colors.black.withOpacity(0.6)
                                            : Colors.black38,
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
                      ? Colors.black.withOpacity(0.5)
                      : Colors.black.withOpacity(0.05),
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
