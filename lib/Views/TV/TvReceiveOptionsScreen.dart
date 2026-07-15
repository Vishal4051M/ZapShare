import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:zap_share/widgets/tv_widgets.dart';
import 'package:zap_share/widgets/SearchPulseWidget.dart';
import 'package:zap_share/Views/TV/TvReceiveScreen.dart';
import 'TvWebReceiveScreen.dart';

class TvReceiveOptionsScreen extends StatefulWidget {
  const TvReceiveOptionsScreen({super.key});

  @override
  State<TvReceiveOptionsScreen> createState() => _TvReceiveOptionsScreenState();
}

class _TvReceiveOptionsScreenState extends State<TvReceiveOptionsScreen> {
  void _navigateTo(Widget screen) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFF0E0E10), Color(0xFF08080A)],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 48.0, vertical: 24.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // ── Android-style custom header ──
                    _buildHeader(),
                    const SizedBox(height: 32),

                    // ── Section label — matches Android ──
                    Text(
                      'RECEIVE OPTIONS',
                      style: GoogleFonts.outfit(
                        color: Colors.grey[400],
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.2,
                      ),
                    ),
                    const SizedBox(height: 20),

                    // ── Two-column square card row ──
                    Expanded(
                      child: Center(
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            final cardSize = (constraints.maxHeight).clamp(0.0, (constraints.maxWidth - 20) / 2);
                            return Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                SizedBox(
                                  width: cardSize,
                                  height: cardSize,
                                  child: AspectRatio(
                                    aspectRatio: 1,
                                    child: TVFocusableCard(
                                      autofocus: true,
                                      backgroundColor: Colors.transparent,
                                      borderRadius: const BorderRadius.all(Radius.circular(28)),
                                      onPressed: () => _navigateTo(const TvReceiveScreen()),
                                      child: _buildCardContent(
                                        title: 'By Code',
                                        subtitle: 'Enter Code',
                                        icon: Icons.dialpad_rounded,
                                        backgroundColor: const Color(0xFFF5C400),
                                        textColor: Colors.black,
                                        iconBgColor: Colors.black.withValues(alpha: 0.1),
                                        iconColor: Colors.black,
                                        isMainFeature: true,
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 20),
                                SizedBox(
                                  width: cardSize,
                                  height: cardSize,
                                  child: AspectRatio(
                                    aspectRatio: 1,
                                    child: TVFocusableCard(
                                      backgroundColor: Colors.transparent,
                                      borderRadius: const BorderRadius.all(Radius.circular(28)),
                                      onPressed: () => _navigateTo(const TvWebReceiveScreen()),
                                      child: _buildCardContent(
                                        title: 'Web Upload',
                                        subtitle: 'Browser Upload',
                                        icon: Icons.language_rounded,
                                        backgroundColor: const Color(0xFF1C1C1E),
                                        textColor: Colors.white,
                                        iconBgColor: Colors.white.withValues(alpha: 0.1),
                                        iconColor: const Color(0xFFFFD600),
                                        isMainFeature: false,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            );
                          },
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  /// Matches AndroidReceiveOptionsScreen._buildHeader()
  Widget _buildHeader() {
    return Row(
      children: [
        Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: const Color(0xFF1C1C1E),
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
          ),
          child: TVFocusableButton(
            borderRadius: BorderRadius.circular(24),
            padding: EdgeInsets.zero,
            onPressed: () => Navigator.of(context).pop(),
            child: const Icon(
              Icons.arrow_back_ios_new_rounded,
              color: Colors.white,
              size: 20,
            ),
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: RichText(
            text: TextSpan(
              children: [
                TextSpan(
                  text: 'Receive ',
                  style: GoogleFonts.outfit(
                    color: const Color(0xFFFFD600),
                    fontSize: 26,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.5,
                  ),
                ),
                TextSpan(
                  text: 'Files',
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

  Widget _buildCardContent({
    required String title,
    required String subtitle,
    required IconData icon,
    required Color backgroundColor,
    required Color textColor,
    required Color iconBgColor,
    required Color iconColor,
    required bool isMainFeature,
  }) {
    final gradient = isMainFeature
        ? const LinearGradient(
            colors: [Color(0xFFFFD84D), Color(0xFFF5C400)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          )
        : const LinearGradient(
            colors: [Color(0xFF2C2C2E), Color(0xFF1C1C1E)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          );

    return Container(
      width: double.infinity,
      height: double.infinity,
      decoration: BoxDecoration(
        gradient: gradient,
        borderRadius: const BorderRadius.all(Radius.circular(28)),
        border: isMainFeature
            ? null
            : Border.all(color: Colors.white.withValues(alpha: 0.05)),
      ),
      child: ClipRRect(
        borderRadius: const BorderRadius.all(Radius.circular(28)),
        child: Stack(
          children: [
            Positioned(
              bottom: -28,
              right: -28,
              child: isMainFeature
                  ? IgnorePointer(
                      child: SearchPulseWidget(
                        size: 140,
                        color: Colors.black,
                        showCenterDot: false,
                      ),
                    )
                  : Icon(
                      icon,
                      size: 120,
                      color: Colors.white.withValues(alpha: 0.03),
                    ),
            ),
            LayoutBuilder(
              builder: (context, constraints) {
                final isCompact = constraints.maxHeight < 180;
                final sizeFactor = isCompact ? 0.85 : 1.0;
                final padding = 20.0 * sizeFactor;
                final iconPadding = 10.0 * sizeFactor;

                return Padding(
                  padding: EdgeInsets.all(padding),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        padding: EdgeInsets.all(iconPadding),
                        decoration: BoxDecoration(
                          color: iconBgColor,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(icon, color: iconColor, size: 26 * sizeFactor),
                      ),
                      const Spacer(),
                      Text(
                        title,
                        style: GoogleFonts.outfit(
                          color: textColor,
                          fontSize: 20 * sizeFactor,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.5,
                          height: 1.1,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      SizedBox(height: 3 * sizeFactor),
                      Text(
                        subtitle,
                        style: GoogleFonts.outfit(
                          color: textColor.withValues(alpha: 0.7),
                          fontSize: 14 * sizeFactor,
                          fontWeight: FontWeight.w500,
                          height: 1.2,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
