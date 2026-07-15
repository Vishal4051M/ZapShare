import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zap_share/widgets/tv_widgets.dart';
import 'package:zap_share/widgets/SearchPulseWidget.dart';
import 'package:zap_share/Views/TV/TvSendScreen.dart';
import 'package:zap_share/Views/TV/TvReceiveOptionsScreen.dart';
import 'package:zap_share/Views/TV/TvHistoryScreen.dart';
import 'package:zap_share/Views/TV/TvCastSelectionScreen.dart';
import 'package:zap_share/Views/TV/TvSettingsScreen.dart';

// Matches Android's card definitions exactly
class _TvCardDef {
  final String title;
  final String subtitle;
  final IconData icon;
  final Color backgroundColor;
  final Color textColor;
  final Color iconBgColor;
  final Color iconColor;
  final bool isMainFeature;
  final Widget Function()? screenBuilder;

  const _TvCardDef({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.backgroundColor,
    required this.textColor,
    required this.iconBgColor,
    required this.iconColor,
    this.isMainFeature = false,
    this.screenBuilder,
  });
}

class TvHomeScreen extends StatefulWidget {
  const TvHomeScreen({super.key});

  @override
  State<TvHomeScreen> createState() => _TvHomeScreenState();
}

class _TvHomeScreenState extends State<TvHomeScreen> {
  final FocusNode _firstFocusNode = FocusNode();
  String _deviceName = 'TV Device';
  String _customAvatar = '🦊';

  late final List<_TvCardDef> _cards;

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _cards = [
      _TvCardDef(
        title: 'Send',
        subtitle: 'Share Files',
        icon: Icons.arrow_upward_rounded,
        backgroundColor: const Color(0xFFF5C400),
        textColor: Colors.black,
        iconBgColor: Colors.black.withValues(alpha: 0.1),
        iconColor: Colors.black,
        isMainFeature: true,
        screenBuilder: () => const TvSendScreen(),
      ),
      _TvCardDef(
        title: 'Receive',
        subtitle: 'Get Files',
        icon: Icons.arrow_downward_rounded,
        backgroundColor: const Color(0xFF1C1C1E),
        textColor: Colors.white,
        iconBgColor: Colors.white.withValues(alpha: 0.1),
        iconColor: const Color(0xFFFFD600),
        screenBuilder: () => const TvReceiveOptionsScreen(),
      ),
      _TvCardDef(
        title: 'History',
        subtitle: 'Recent',
        icon: Icons.history_rounded,
        backgroundColor: const Color(0xFF1C1C1E),
        textColor: Colors.white,
        iconBgColor: Colors.white.withValues(alpha: 0.1),
        iconColor: const Color(0xFFFFD600),
        screenBuilder: () => const TvHistoryScreen(),
      ),
      _TvCardDef(
        title: 'Cast',
        subtitle: 'Media/Audio/Mirror',
        icon: Icons.cast_rounded,
        backgroundColor: const Color(0xFFEDEDED),
        textColor: const Color(0xFF2C2C2E),
        iconBgColor: Colors.black.withValues(alpha: 0.08),
        iconColor: Colors.black,
        screenBuilder: () => const TvCastSelectionScreen(),
      ),
    ];
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _deviceName = prefs.getString('device_name') ?? 'TV Device';
        _customAvatar = prefs.getString('custom_avatar') ?? '🦊';
      });
    }
  }

  @override
  void dispose() {
    _firstFocusNode.dispose();
    super.dispose();
  }

  void _navigateTo(Widget screen) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
    _loadSettings();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFF0E0E10), Color(0xFF08080A)],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: 48.0,
              vertical: 28.0,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ── Header Row ──
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    // Logo + Title
                    Row(
                      children: [
                        Container(
                          height: 46,
                          width: 46,
                          decoration: const BoxDecoration(
                            color: Color(0xFF1C1C1E),
                            shape: BoxShape.circle,
                          ),
                          child: ClipOval(
                            child: Image.asset(
                              'assets/images/logo.png',
                              fit: BoxFit.cover,
                              errorBuilder:
                                  (_, __, ___) => const Icon(
                                    Icons.bolt_rounded,
                                    color: Color(0xFFFFD600),
                                    size: 26,
                                  ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 14),
                        RichText(
                          text: TextSpan(
                            children: [
                              TextSpan(
                                text: 'Zap',
                                style: GoogleFonts.outfit(
                                  color: const Color(0xFFFFD600),
                                  fontSize: 30,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              TextSpan(
                                text: 'Share',
                                style: GoogleFonts.outfit(
                                  color: Colors.white,
                                  fontSize: 30,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    // Profile + Settings
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 9,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFF1C1C1E),
                            borderRadius: BorderRadius.circular(22),
                            border: Border.all(
                              color: Colors.white.withValues(alpha: 0.08),
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                _customAvatar,
                                style: const TextStyle(fontSize: 18),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                _deviceName,
                                style: GoogleFonts.outfit(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 14,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        TVFocusableButton(
                          onPressed:
                              () => _navigateTo(const TvSettingsScreen()),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 10,
                          ),
                          borderRadius: BorderRadius.circular(22),
                          backgroundColor: const Color(0xFF1C1C1E),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.settings_rounded,
                                color: Colors.white,
                                size: 18,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                'Settings',
                                style: GoogleFonts.outfit(
                                  color: Colors.white,
                                  fontSize: 14,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ],
                ),

                const SizedBox(height: 36),

                // ── Section Label ──
                Text(
                  'DASHBOARD',
                  style: GoogleFonts.outfit(
                    color: Colors.grey[400],
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.8,
                  ),
                ),
                const SizedBox(height: 16),

                // ── Grid of Cards ──
                Expanded(
                  child: GridView.count(
                    crossAxisCount: 4,
                    crossAxisSpacing: 20,
                    mainAxisSpacing: 20,
                    childAspectRatio: 1,
                    physics: const NeverScrollableScrollPhysics(),
                    children: List.generate(_cards.length, (i) {
                      final def = _cards[i];
                      const cardRadius = BorderRadius.all(Radius.circular(28));
                      return AspectRatio(
                        aspectRatio: 1,
                        child: TVFocusableCard(
                          focusNode: i == 0 ? _firstFocusNode : null,
                          autofocus: i == 0,
                          backgroundColor: Colors.transparent,
                          borderRadius: cardRadius,
                          onPressed:
                              def.screenBuilder != null
                                  ? () => _navigateTo(def.screenBuilder!())
                                  : null,
                          child: _buildCardContent(def),
                        ),
                      );
                    }),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCardContent(_TvCardDef def) {
    // Matches Android's gradient logic exactly
    final gradient =
        def.isMainFeature
            ? const LinearGradient(
              colors: [Color(0xFFFFD84D), Color(0xFFF5C400)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            )
            : def.backgroundColor == const Color(0xFFEDEDED) ||
                def.backgroundColor == const Color(0xFFF5F5F7) ||
                def.backgroundColor == Colors.white
            ? const LinearGradient(
              colors: [Color(0xFFF0F0F0), Color(0xFFE5E5E5)],
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
      ),
      child: ClipRRect(
        borderRadius: const BorderRadius.all(Radius.circular(28)),
        child: Stack(
          children: [
            // Faded background element — matches Android exactly
            Positioned(
              bottom: -28,
              right: -28,
              child:
                  def.title == 'Send'
                      ? IgnorePointer(
                        child: SearchPulseWidget(
                          size: 130,
                          color: Colors.black,
                          showCenterDot: false,
                        ),
                      )
                      : def.title == 'Receive'
                      ? Opacity(
                        opacity: 0.10,
                        child: ColorFiltered(
                          colorFilter: const ColorFilter.matrix(<double>[
                            0.2126,
                            0.7152,
                            0.0722,
                            0,
                            0,
                            0.2126,
                            0.7152,
                            0.0722,
                            0,
                            0,
                            0.2126,
                            0.7152,
                            0.0722,
                            0,
                            0,
                            0,
                            0,
                            0,
                            1,
                            0,
                          ]),
                          child: const Text(
                            '📂',
                            style: TextStyle(fontSize: 100),
                          ),
                        ),
                      )
                      : Icon(
                        def.icon,
                        size: 110,
                        color:
                            def.backgroundColor == const Color(0xFFEDEDED)
                                ? Colors.black.withValues(alpha: 0.04)
                                : Colors.white.withValues(alpha: 0.03),
                      ),
            ),
            // Content — responsive layout like Android
            LayoutBuilder(
              builder: (context, constraints) {
                final isCompact = constraints.maxHeight < 180;
                final isTight = constraints.maxHeight < 160;
                final isTiny = constraints.maxHeight < 130;
                final sizeFactor =
                    isTiny ? 0.72 : (isTight ? 0.82 : (isCompact ? 0.9 : 1.0));
                final padding = 18.0 * sizeFactor;
                final iconPadding = 10.0 * sizeFactor;
                final iconSize = 24.0 * sizeFactor;
                final titleSize = 20.0 * sizeFactor;
                final subtitleSize = 12.0 * sizeFactor;

                return Padding(
                  padding: EdgeInsets.all(padding),
                  child:
                      isTiny
                          ? Center(
                            child: Container(
                              padding: EdgeInsets.all(iconPadding),
                              decoration: BoxDecoration(
                                color: def.iconBgColor,
                                shape: BoxShape.circle,
                              ),
                              child: Icon(
                                def.icon,
                                color: def.iconColor,
                                size: iconSize,
                              ),
                            ),
                          )
                          : Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Container(
                                padding: EdgeInsets.all(iconPadding),
                                decoration: BoxDecoration(
                                  color: def.iconBgColor,
                                  shape: BoxShape.circle,
                                ),
                                child: Icon(
                                  def.icon,
                                  color: def.iconColor,
                                  size: iconSize,
                                ),
                              ),
                              const Spacer(),
                              Text(
                                def.title,
                                style: GoogleFonts.outfit(
                                  color: def.textColor,
                                  fontSize: titleSize,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: -0.5,
                                  height: 1.1,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              if (!isTight) ...[
                                SizedBox(height: 3 * sizeFactor),
                                Text(
                                  def.subtitle,
                                  style: GoogleFonts.outfit(
                                    color: def.textColor.withValues(
                                      alpha: 0.65,
                                    ),
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
          ],
        ),
      ),
    );
  }
}
