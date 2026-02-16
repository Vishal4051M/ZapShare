import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:zap_share/blocs/navigation/smooth_page_route.dart';
import 'AndroidReceiveScreen.dart';
import 'WebReceiveScreen.dart';

class AndroidReceiveOptionsScreen extends StatefulWidget {
  const AndroidReceiveOptionsScreen({super.key});

  @override
  State<AndroidReceiveOptionsScreen> createState() =>
      _AndroidReceiveOptionsScreenState();
}

class _AndroidReceiveOptionsScreenState
    extends State<AndroidReceiveOptionsScreen>
    with SingleTickerProviderStateMixin {
  bool _isLoading = true;
  late AnimationController _shimmerController;

  @override
  void initState() {
    super.initState();
    _shimmerController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat();

    // Simulate loading for shimmer effect
    Future.delayed(const Duration(milliseconds: 800), () {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    });
  }

  @override
  void dispose() {
    _shimmerController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Hero(
          tag: 'receive_card_container',
          createRectTween: (begin, end) {
            return RectTween(begin: begin, end: end);
          },
          child: Material(
            type: MaterialType.transparency,
            child: Container(
              color: Colors.black,
              child: SafeArea(
                child:
                    _isLoading ? _buildLoadingState() : _buildContent(context),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLoadingState() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 26, 24, 24),
      children: [
        // Header Shimmer (Icon + Text)
        Row(
          children: [
            _buildShimmerBlock(width: 48, height: 48, radius: 24),
            const SizedBox(width: 16),
            Expanded(child: _buildShimmerBlock(height: 32, radius: 8)),
          ],
        ),

        const SizedBox(height: 32),

        // Title Shimmer
        _buildShimmerBlock(width: 120, height: 14, radius: 4),
        const SizedBox(height: 20),

        // Cards Shimmer
        SizedBox(
          height: 180,
          child: Row(
            children: [
              Expanded(child: _buildShimmerBlock(height: 180, radius: 32)),
              const SizedBox(width: 16),
              Expanded(child: _buildShimmerBlock(height: 180, radius: 32)),
            ],
          ),
        ),
        const SizedBox(height: 32),

        // Tips Title Shimmer
        _buildShimmerBlock(width: 100, height: 14, radius: 4),
        const SizedBox(height: 16),

        // Tips Container Shimmer
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.02),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Column(
            children: List.generate(
              3,
              (index) => Padding(
                padding: EdgeInsets.only(bottom: index == 2 ? 0 : 24),
                child: Row(
                  children: [
                    _buildShimmerBlock(width: 36, height: 36, radius: 18),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _buildShimmerBlock(width: 100, height: 14, radius: 4),
                          const SizedBox(height: 8),
                          _buildShimmerBlock(
                            width: double.infinity,
                            height: 12,
                            radius: 4,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildShimmerBlock({
    double? width,
    double? height,
    required double radius,
  }) {
    return AnimatedBuilder(
      animation: _shimmerController,
      builder: (context, child) {
        return Container(
          width: width,
          height: height,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(radius),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Colors.white.withOpacity(0.05),
                Colors.white.withOpacity(0.1),
                Colors.white.withOpacity(0.05),
              ],
              stops: [
                0.0,
                0.5 + 0.5 * _shimmerController.value, // Animate the highlight
                1.0,
              ],
            ),
          ),
        );
      },
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
      padding: const EdgeInsets.fromLTRB(24, 26, 24, 24),
      children: [
        // Header
        _buildHeader(context),

        const SizedBox(height: 32),

        // Section Title
        _buildSectionTitle('RECEIVE OPTIONS'),
        const SizedBox(height: 20),

        // Cards in row
        SizedBox(
          height: 180,
          child: Row(
            children: [
              // Receive by Code Card
              Expanded(
                child: _buildCard(
                  title: 'By Code',
                  subtitle: 'Enter Code',
                  icon: Icons.dialpad_rounded,
                  backgroundColor: const Color(0xFFF5C400),
                  textColor: Colors.black,
                  iconBgColor: Colors.black.withOpacity(0.1),
                  iconColor: Colors.black,
                  onTap:
                      () => _navigateToScreen(context, AndroidReceiveScreen()),
                  isMainFeature: true,
                ),
              ),
              const SizedBox(width: 16),
              // Web Receive Card
              Expanded(
                child: _buildCard(
                  title: 'Web',
                  subtitle: 'Browser Upload',
                  icon: Icons.language_rounded,
                  backgroundColor: const Color(0xFF1C1C1E),
                  textColor: Colors.white,
                  iconBgColor: Colors.white.withOpacity(0.1),
                  iconColor: const Color(0xFFFFD600),
                  onTap: () => _navigateToScreen(context, WebReceiveScreen()),
                ),
              ),
            ],
          ),
        ),

        const SizedBox(height: 32),

        // Tips Section
        _buildSectionTitle('HOW IT WORKS'),
        const SizedBox(height: 16),

        // Tips grid
        _buildTipsGrid(),
      ],
    );
  }

  Widget _buildLandscapeContent(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return Row(
          children: [
            // Left Panel - Receive Options
            Expanded(
              flex: 3,
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  border: Border(
                    right: BorderSide(
                      color: Colors.white.withOpacity(0.1),
                      width: 1,
                    ),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildHeader(context),
                    const SizedBox(height: 12),
                    _buildSectionTitle('RECEIVE OPTIONS'),
                    const SizedBox(height: 12),
                    Expanded(
                      child: Row(
                        children: [
                          Expanded(
                            child: _buildCard(
                              title: 'By Code',
                              subtitle: 'Enter Code',
                              icon: Icons.dialpad_rounded,
                              backgroundColor: const Color(0xFFF5C400),
                              textColor: Colors.black,
                              iconBgColor: Colors.black.withOpacity(0.1),
                              iconColor: Colors.black,
                              onTap:
                                  () => _navigateToScreen(
                                    context,
                                    AndroidReceiveScreen(),
                                  ),
                              isMainFeature: true,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: _buildCard(
                              title: 'Web',
                              subtitle: 'Browser Upload',
                              icon: Icons.language_rounded,
                              backgroundColor: const Color(0xFF1C1C1E),
                              textColor: Colors.white,
                              iconBgColor: Colors.white.withOpacity(0.1),
                              iconColor: const Color(0xFFFFD600),
                              onTap:
                                  () => _navigateToScreen(
                                    context,
                                    WebReceiveScreen(),
                                  ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            // Right Panel - Tips
            Expanded(
              flex: 2,
              child: Container(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 48),
                    _buildSectionTitle('HOW IT WORKS'),
                    const SizedBox(height: 12),
                    Expanded(
                      child: SingleChildScrollView(child: _buildTipsGrid()),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  // Section title - matching Home Screen style
  Widget _buildSectionTitle(String title) {
    return Text(
      title,
      style: GoogleFonts.outfit(
        color: Colors.grey[300],
        fontSize: 12,
        fontWeight: FontWeight.w800,
        letterSpacing: 1.2,
      ),
    );
  }

  // Card widget - matching Home Screen style exactly
  Widget _buildCard({
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

    return Container(
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(32),
        boxShadow: null,
        gradient:
            isMainFeature
                ? LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [const Color(0xFFFFD84D), const Color(0xFFF5C400)],
                )
                : LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [const Color(0xFF2C2C2E), const Color(0xFF1C1C1E)],
                ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(32),
        child: Stack(
          children: [
            // Background Pattern
            Positioned(
              bottom: -30,
              right: -30,
              child: Icon(
                icon,
                size: 120,
                color:
                    isMainFeature
                        ? Colors.black.withOpacity(0.1)
                        : Colors.white.withOpacity(0.05),
              ),
            ),
            // Content
            Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: () {
                  HapticFeedback.mediumImpact();
                  onTap();
                },
                child: Padding(
                  padding: EdgeInsets.all(isCompact ? 12.0 : 16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    mainAxisSize: MainAxisSize.max,
                    children: [
                      Align(
                        alignment: Alignment.topLeft,
                        child: Container(
                          padding: EdgeInsets.all(isCompact ? 8.0 : 10.0),
                          decoration: BoxDecoration(
                            color: iconBgColor,
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            icon,
                            color: iconColor,
                            size: isCompact ? 22 : 26,
                          ),
                        ),
                      ),
                      Flexible(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              title,
                              style: GoogleFonts.outfit(
                                color: textColor,
                                fontSize: isCompact ? 18 : 20,
                                fontWeight: FontWeight.w800,
                                letterSpacing: -0.5,
                                height: 1.1,
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            SizedBox(height: isCompact ? 3 : 4),
                            Text(
                              subtitle,
                              style: GoogleFonts.outfit(
                                color: textColor.withOpacity(0.7),
                                fontSize: isCompact ? 13 : 15,
                                fontWeight: FontWeight.w500,
                                height: 1.2,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Tips grid - matching Home Screen style exactly
  Widget _buildTipsGrid() {
    final tips = [
      {
        'icon': Icons.dialpad_rounded,
        'title': 'Receive by Code',
        'text': 'Enter the 8-11 digit code from sender.',
      },
      {
        'icon': Icons.language_rounded,
        'title': 'Web Receive',
        'text': 'Any browser can upload files to you.',
      },
      {
        'icon': Icons.wifi_rounded,
        'title': 'Same Network',
        'text': 'Both devices need same WiFi for web.',
      },
    ];

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1C1C1E).withOpacity(0.4),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withOpacity(0.05)),
      ),
      child: Column(
        children:
            tips.asMap().entries.map((entry) {
              final index = entry.key;
              final tip = entry.value;
              return Column(
                children: [
                  _buildTipCard(tip),
                  if (index < tips.length - 1)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Divider(
                        color: Colors.white.withOpacity(0.12),
                        height: 1,
                      ),
                    ),
                ],
              );
            }).toList(),
      ),
    );
  }

  Widget _buildTipCard(Map<String, dynamic> tip) {
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: const Color(0xFFFFD600).withOpacity(0.15),
            shape: BoxShape.circle,
          ),
          child: Icon(
            tip['icon'] as IconData,
            color: const Color(0xFFFFD600),
            size: 18,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                tip['title'] as String,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.outfit(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                tip['text'] as String,
                style: GoogleFonts.outfit(
                  color: Colors.grey[500],
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  height: 1.3,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ],
    );
  }

  // Removed old _buildCard method - replaced with _buildReceiveCard above

  // Removed _buildHowItWorksContainer and _buildMethodCard - replaced with simpler _buildQuickTip

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
            onPressed: () => context.navigateBack(),
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Text(
            'Receive Files',
            style: GoogleFonts.outfit(
              color: Colors.white,
              fontSize: 28,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.5,
            ),
          ),
        ),
      ],
    );
  }

  void _navigateToScreen(BuildContext context, Widget targetScreen) {
    // Use smooth slide navigation
    context.navigateSlideRight(targetScreen);
  }
}
