import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:zap_share/blocs/navigation/smooth_page_route.dart';
import 'package:zap_share/Screens/android/AndroidCastScreen.dart';
import 'package:zap_share/Screens/android/AndroidScreenMirrorScreen.dart';
import 'package:zap_share/Screens/shared/audio_share_screen.dart';

class AndroidCastSelectionScreen extends StatelessWidget {
  const AndroidCastSelectionScreen({super.key});

  double _uiScale(BuildContext context) {
    return 1.0;
  }

  double _scaled(BuildContext context, double value) {
    return value * _uiScale(context);
  }

  EdgeInsets _pagePadding(BuildContext context) {
    final scale = _uiScale(context);
    return EdgeInsets.fromLTRB(24 * scale, 26 * scale, 24 * scale, 24 * scale);
  }

  double _squareCardSize(
    BuildContext context,
    double maxWidth, {
    double? maxHeight,
    required double spacing,
  }) {
    var size = (maxWidth - spacing) / 2;
    final heightLimit = MediaQuery.of(context).size.height * 0.32;
    if (maxHeight != null && size > maxHeight) {
      size = maxHeight;
    }
    if (size > heightLimit) {
      size = heightLimit;
    }
    return size.clamp(0.0, 260.0);
  }

  Widget _buildSquareCardRow({
    required BuildContext context,
    required Widget left,
    required Widget right,
    required double maxWidth,
    double? maxHeight,
    required double spacing,
  }) {
    final size = _squareCardSize(
      context,
      maxWidth,
      maxHeight: maxHeight,
      spacing: spacing,
    );
    final totalWidth = size * 2 + spacing;

    return Align(
      alignment: Alignment.centerLeft,
      child: SizedBox(
        width: totalWidth,
        height: size,
        child: Row(
          children: [
            SizedBox(width: size, height: size, child: left),
            SizedBox(width: spacing),
            SizedBox(width: size, height: size, child: right),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Hero(
        tag: 'cast_card_container',
        createRectTween:
            (begin, end) => SmoothRectTween(begin: begin, end: end),
        child: Material(
          color: Colors.black,
          child: SafeArea(child: _buildContent(context)),
        ),
      ),
    );
  }

  Widget _buildContent(BuildContext context) {
    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;
    final isTV = MediaQuery.of(context).size.width > 1000;

    if (isLandscape || isTV) {
      return _buildLandscapeContent(context);
    }

    return _buildPortraitContent(context);
  }

  Widget _buildPortraitContent(BuildContext context) {
    return ListView(
      padding: _pagePadding(context),
      physics: const BouncingScrollPhysics(),
      children: [
        _buildHeader(context),
        SizedBox(height: _scaled(context, 32)),
        _buildSectionTitle(context, 'CAST OPTIONS'),
        SizedBox(height: _scaled(context, 20)),
        LayoutBuilder(
          builder: (context, constraints) {
            final spacing = _scaled(context, 16);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildSquareCardRow(
                  context: context,
                  maxWidth: constraints.maxWidth,
                  spacing: spacing,
                  left: _buildCard(
                    context: context,
                    title: 'Audio Share',
                    subtitle: 'Real-time sync',
                    icon: Icons.waves_rounded,
                    backgroundColor: const Color(0xFFF5C400),
                    textColor: Colors.black,
                    iconBgColor: Colors.black.withOpacity(0.1),
                    iconColor: Colors.black,
                    isMainFeature: true,
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
                  right: _buildCard(
                    context: context,
                    title: 'Phone Screen',
                    subtitle: 'Mirror Screen',
                    icon: Icons.screen_share_rounded,
                    backgroundColor: const Color(0xFF1C1C1E),
                    textColor: Colors.white,
                    iconBgColor: Colors.white.withOpacity(0.1),
                    iconColor: const Color(0xFFFFD600),
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
                ),
                SizedBox(height: spacing),
                _buildSquareCardRow(
                  context: context,
                  maxWidth: constraints.maxWidth,
                  spacing: spacing,
                  left: _buildCard(
                    context: context,
                    title: 'Video Cast',
                    subtitle: 'Stream movies',
                    icon: Icons.movie_filter_rounded,
                    backgroundColor: const Color(0xFFEDEDED),
                    textColor: const Color(0xFF2C2C2E),
                    iconBgColor: Colors.black.withOpacity(0.08),
                    iconColor: Colors.black,
                    onTap: () {
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
                    },
                  ),
                  right:
                      const SizedBox(), // Empty slot to match receive options layout
                ),
              ],
            );
          },
        ),
      ],
    );
  }

  Widget _buildLandscapeContent(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return Container(
          padding: EdgeInsets.all(_scaled(context, 12)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildHeader(context),
              SizedBox(height: _scaled(context, 12)),
              _buildSectionTitle(context, 'CAST OPTIONS'),
              SizedBox(height: _scaled(context, 12)),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final spacing = _scaled(context, 12);
                    return SingleChildScrollView(
                      physics: const BouncingScrollPhysics(),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _buildSquareCardRow(
                            context: context,
                            maxWidth: constraints.maxWidth,
                            maxHeight: constraints.maxHeight,
                            spacing: spacing,
                            left: _buildCard(
                              context: context,
                              title: 'Audio Share',
                              subtitle: 'Real-time sync',
                              icon: Icons.waves_rounded,
                              backgroundColor: const Color(0xFFF5C400),
                              textColor: Colors.black,
                              iconBgColor: Colors.black.withOpacity(0.1),
                              iconColor: Colors.black,
                              isMainFeature: true,
                              onTap: () {
                                Navigator.push(
                                  context,
                                  SmoothPageRoute.slideRight(
                                    page: const AudioShareScreen(),
                                    duration: const Duration(milliseconds: 620),
                                    reverseDuration: const Duration(
                                      milliseconds: 560,
                                    ),
                                  ),
                                );
                              },
                            ),
                            right: _buildCard(
                              context: context,
                              title: 'Phone Screen',
                              subtitle: 'Mirror Screen',
                              icon: Icons.screen_share_rounded,
                              backgroundColor: const Color(0xFF1C1C1E),
                              textColor: Colors.white,
                              iconBgColor: Colors.white.withOpacity(0.1),
                              iconColor: const Color(0xFFFFD600),
                              onTap: () {
                                Navigator.push(
                                  context,
                                  SmoothPageRoute.slideRight(
                                    page: const AndroidScreenMirrorScreen(),
                                    duration: const Duration(milliseconds: 620),
                                    reverseDuration: const Duration(
                                      milliseconds: 560,
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                          SizedBox(height: spacing),
                          _buildSquareCardRow(
                            context: context,
                            maxWidth: constraints.maxWidth,
                            maxHeight: constraints.maxHeight,
                            spacing: spacing,
                            left: _buildCard(
                              context: context,
                              title: 'Video Cast',
                              subtitle: 'Stream movies',
                              icon: Icons.movie_filter_rounded,
                              backgroundColor: const Color(0xFFEDEDED),
                              textColor: const Color(0xFF2C2C2E),
                              iconBgColor: Colors.black.withOpacity(0.08),
                              iconColor: Colors.black,
                              onTap: () {
                                Navigator.push(
                                  context,
                                  SmoothPageRoute.slideRight(
                                    page: const AndroidCastScreen(
                                      initialMode: CastMode.video,
                                      heroTag: 'cast_video_card',
                                    ),
                                    duration: const Duration(milliseconds: 620),
                                    reverseDuration: const Duration(
                                      milliseconds: 560,
                                    ),
                                  ),
                                );
                              },
                            ),
                            right: const SizedBox(),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildSectionTitle(BuildContext context, String title) {
    return Text(
      title,
      style: GoogleFonts.outfit(
        color: Colors.grey[300],
        fontSize: _scaled(context, 12),
        fontWeight: FontWeight.w800,
        letterSpacing: _scaled(context, 1.2),
      ),
    );
  }

  Widget _buildCard({
    required BuildContext context,
    required String title,
    required String subtitle,
    required IconData icon,
    required Color backgroundColor,
    required Color textColor,
    required Color iconBgColor,
    required Color iconColor,
    required VoidCallback onTap,
    bool isMainFeature = false,
  }) {
    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;
    final isTV = MediaQuery.of(context).size.width > 1000;
    final isCompact = isLandscape || isTV;
    final scale = _uiScale(context);

    final isWhiteBg =
        backgroundColor == Colors.white ||
        backgroundColor == const Color(0xFFF5F5F7) ||
        backgroundColor == const Color(0xFFEDEDED);

    return Container(
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(32 * scale),
        border:
            isMainFeature
                ? null
                : Border.all(
                  color:
                      isWhiteBg
                          ? Colors.black.withOpacity(0.05)
                          : Colors.white.withOpacity(0.05),
                ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(32 * scale),
        child: Stack(
          children: [
            Positioned(
              bottom: -30,
              right: -30,
              child: Icon(
                icon,
                size: 120 * scale,
                color:
                    isMainFeature
                        ? Colors.black.withOpacity(0.05)
                        : isWhiteBg
                        ? Colors.black.withOpacity(0.04)
                        : Colors.white.withOpacity(0.02),
              ),
            ),
            Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: () {
                  HapticFeedback.mediumImpact();
                  onTap();
                },
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final isTight = constraints.maxHeight < 150;
                    final isUltraTight = constraints.maxHeight < 130;
                    final isTiny = constraints.maxHeight < 110;
                    final sizeFactor =
                        isTiny
                            ? 0.7
                            : (isUltraTight ? 0.78 : (isTight ? 0.85 : 1.0));
                    final showSubtitle = !isUltraTight;
                    final showTitle = !isTiny;
                    final padding =
                        (isCompact ? 12.0 : 16.0) * scale * sizeFactor;
                    final iconPadding =
                        (isCompact ? 8.0 : 10.0) * scale * sizeFactor;
                    final iconSize =
                        (isCompact ? 22.0 : 26.0) * scale * sizeFactor;
                    final titleSize =
                        (isCompact ? 18.0 : 20.0) * scale * sizeFactor;
                    final subtitleSize =
                        (isCompact ? 13.0 : 15.0) * scale * sizeFactor;
                    final gap = (isCompact ? 3.0 : 4.0) * scale * sizeFactor;
                    final textTopGap = isUltraTight ? gap * 0.5 : gap;

                    return Padding(
                      padding: EdgeInsets.all(padding),
                      child:
                          isTiny
                              ? Center(
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
                              )
                              : Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
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
                                  const Spacer(),
                                  if (showTitle)
                                    Text(
                                      title,
                                      style: GoogleFonts.outfit(
                                        color: textColor,
                                        fontSize: titleSize,
                                        fontWeight: FontWeight.w800,
                                        letterSpacing: -0.5 * scale,
                                        height: 1.1,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  if (showSubtitle) ...[
                                    SizedBox(height: textTopGap),
                                    Text(
                                      subtitle,
                                      style: GoogleFonts.outfit(
                                        color: textColor.withOpacity(0.7),
                                        fontSize: subtitleSize,
                                        fontWeight: FontWeight.w500,
                                        height: 1.2,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ],
                                ],
                              ),
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: const Color(0xFF1C1C1E),
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white.withOpacity(0.05)),
          ),
          child: IconButton(
            icon: const Icon(
              Icons.arrow_back_ios_new_rounded,
              color: Colors.white,
              size: 20,
            ),
            onPressed: () => Navigator.pop(context),
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: RichText(
            text: TextSpan(
              children: [
                TextSpan(
                  text: "Cast ",
                  style: GoogleFonts.outfit(
                    color: const Color(0xFFFFD600),
                    fontSize: 26,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.5,
                  ),
                ),
                TextSpan(
                  text: "Options",
                  style: GoogleFonts.outfit(
                    color: Colors.white,
                    fontSize: 26,
                    fontWeight: FontWeight.bold,
                    letterSpacing: -0.5,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
