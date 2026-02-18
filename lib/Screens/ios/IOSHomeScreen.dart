import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:ui'; 
import 'package:zap_share/widgets/LiquidGlassContainer.dart';
import 'package:zap_share/Screens/shared/TransferHistoryScreen.dart';
import 'package:zap_share/Screens/shared/DeviceSettingsScreen.dart';
import 'IOSFileShareScreen.dart';
import 'IOSReceiveOptionsScreen.dart';

// Modern Color Constants
const Color kZapPrimary = Color(0xFFFFD84D); // Logo Yellow Light
const Color kZapPrimaryDark = Color(0xFFF5C400); // Logo Yellow Dark
const Color kZapBackgroundTop = Color(0xFF0E1116); // Soft Charcoal Top
const Color kZapBackgroundBottom = Color(0xFF07090D); // Soft Charcoal Bottom
const Color kZapSurface = Color(0xFF1C1C1E); // Keep generic surface for now/falback
const Color kZapSecondaryBlue = Color(0xFF5865F2); // Subtle Blue 

class IOSHomeScreen extends StatefulWidget {
  const IOSHomeScreen({super.key});

  @override
  State<IOSHomeScreen> createState() => _IOSHomeScreenState();
}

class _IOSHomeScreenState extends State<IOSHomeScreen> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _fadeAnimation;
  int _selectedIndex = 0;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    );
    _fadeAnimation = CurvedAnimation(parent: _controller, curve: Curves.easeOut);
    _controller.forward();
  }

  bool _isSearchActive = false;
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();

  @override
  void dispose() {
    _controller.dispose();
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Dock Width Calculation
    final double screenWidth = MediaQuery.of(context).size.width;
    // Normal Dock: Capsule (0.73) + Gap (12) + Circle (80)
    // Search Dock: Full width (0.92)
    
    return Scaffold(
      extendBody: true,
      resizeToAvoidBottomInset: false, // Prevent keyboard from shifting background
      body: Stack(
        alignment: Alignment.bottomCenter,
        children: [
          // 1. Main Content Layer
          Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [kZapBackgroundTop, kZapBackgroundBottom],
              ),
            ),
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 300),
              child: _isSearchActive 
                 ? _buildSearchSuggestions()
                 : KeyedSubtree(
                    key: ValueKey<int>(_selectedIndex),
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 0), 
                      child: _getPage(_selectedIndex),
                    ),
                  ),
            ),
          ),
          
          // 2. Dimming Overlay (When searching)
          if (_isSearchActive)
            Positioned.fill(
              child: GestureDetector(
                onTap: () {
                   // Tap outside to close search
                   setState(() {
                     _isSearchActive = false;
                     FocusScope.of(context).unfocus();
                     _searchController.clear();
                   });
                },
                child: Container(
                  color: Colors.black.withOpacity(0.2), // Subtle dim
                ),
              ),
            ),

          // 3. Floating Liquid Dock (Animated Row)
          Positioned(
            bottom: _isSearchActive ? MediaQuery.of(context).viewInsets.bottom + 20 : 0, 
            left: 0,
            right: 0,
            child: Center(
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12), // Safe margins
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      // A. Left Container (Menu -> Home)
                      GestureDetector(
                        onTap: () {
                          if (_isSearchActive) {
                            // If in search mode, tapping Home closes search
                            HapticFeedback.lightImpact();
                            setState(() {
                              _isSearchActive = false;
                              FocusScope.of(context).unfocus();
                              _searchController.clear();
                              _selectedIndex = 0; // Go to Home
                            });
                          }
                        },
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 400),
                          curve: Curves.easeOutBack,
                          height: 80,
                          width: _isSearchActive ? 80 : MediaQuery.of(context).size.width * 0.70, // Shrink or Expand
                          decoration: BoxDecoration(
                            boxShadow: [
                               BoxShadow(
                                 color: Colors.black.withOpacity(0.3),
                                 blurRadius: 30,
                                 offset: const Offset(0, 10),
                               ),
                            ],
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(44),
                            child: BackdropFilter(
                              filter: ImageFilter.blur(sigmaX: 25, sigmaY: 25),
                              child: Container(
                                padding: const EdgeInsets.all(4), // Reduced padding for circle mode
                                decoration: BoxDecoration(
                                  color: Colors.black.withOpacity(0.4),
                                  borderRadius: BorderRadius.circular(44),
                                  border: Border.all(
                                    color: _isSearchActive ? kZapPrimary.withOpacity(0.3) : Colors.white.withOpacity(0.12),
                                    width: 1.2,
                                  ),
                                  gradient: LinearGradient(
                                    begin: Alignment.topCenter,
                                    end: Alignment.bottomCenter,
                                    colors: [
                                      Colors.white.withOpacity(0.15),
                                      Colors.white.withOpacity(0.02),
                                    ],
                                  ),
                                ),
                                child: _isSearchActive 
                                  // State B: Home Button (Circle)
                                  ? Center(
                                      child: Icon(Icons.home_rounded, color: kZapPrimary, size: 30),
                                    )
                                  // State A: Full Menu (Row)
                                  : Row(
                                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                                      children: [
                                        _buildCapsuleItem(0, "Home", Icons.home_filled),  // Changed to standard Home icon
                                        _buildCapsuleItem(1, "Send", Icons.arrow_upward_rounded), 
                                        _buildCapsuleItem(2, "Receive", Icons.arrow_downward_rounded),   
                                        _buildCapsuleItem(3, "History", Icons.history_rounded), 
                                      ],
                                    ),
                              ),
                            ),
                          ),
                        ),
                      ),

                      const SizedBox(width: 12),

                      // B. Right Container (Search Icon -> Search Bar)
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 400),
                        curve: Curves.easeOutBack,
                        height: 80,
                        width: _isSearchActive ? MediaQuery.of(context).size.width * 0.70 : 80, // Expand or Shrink
                        decoration: BoxDecoration(
                          boxShadow: [
                             BoxShadow(
                               color: Colors.black.withOpacity(0.3),
                               blurRadius: 30,
                               offset: const Offset(0, 10),
                             ),
                          ],
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(44),
                          child: BackdropFilter(
                            filter: ImageFilter.blur(sigmaX: 25, sigmaY: 25),
                            child: AnimatedSwitcher(
                              duration: const Duration(milliseconds: 300),
                              child: _isSearchActive
                                ? _buildEmbeddedSearchBar() // State B: Expansion
                                : GestureDetector( // State A: Search Bubble
                                    onTap: () {
                                       HapticFeedback.selectionClick();
                                       setState(() {
                                         _isSearchActive = true;
                                         // NO auto-focus as requested
                                       });
                                    },
                                    child: Container(
                                      key: const ValueKey("SearchIcon"),
                                      width: double.infinity,
                                      height: double.infinity,
                                      decoration: BoxDecoration(
                                        color: Colors.black.withOpacity(0.4),
                                        borderRadius: BorderRadius.circular(44),
                                        border: Border.all(
                                          color: Colors.white.withOpacity(0.12),
                                          width: 1.2,
                                        ),
                                        gradient: LinearGradient(
                                          begin: Alignment.topLeft,
                                          end: Alignment.bottomRight,
                                          colors: [
                                             Colors.white.withOpacity(0.2),
                                             Colors.white.withOpacity(0.05),
                                          ],
                                        ),
                                      ),
                                      child: const Icon(
                                        Icons.search_rounded,
                                        color: Colors.white,
                                        size: 30,
                                      ),
                                    ),
                                  ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // New helper for the expanded search bar content
  Widget _buildEmbeddedSearchBar() {
    return Container(
      key: const ValueKey("SearchBar"),
      padding: const EdgeInsets.symmetric(horizontal: 20),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.4), 
        borderRadius: BorderRadius.circular(44), // Full pill
        border: Border.all(
          color: Colors.white.withOpacity(0.12),
          width: 1.2,
        ),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Colors.white.withOpacity(0.15),
            Colors.white.withOpacity(0.02),
          ],
        ),
      ),
      child: Center(
        child: Theme(
          data: Theme.of(context).copyWith(
            textSelectionTheme: const TextSelectionThemeData(
              cursorColor: kZapPrimary,
              selectionColor: Color(0x66FFD84D),
              selectionHandleColor: kZapPrimary,
            ),
          ),
          child: TextField(
            controller: _searchController,
            focusNode: _searchFocusNode,
            style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w500),
            keyboardAppearance: Brightness.dark,
            cursorColor: kZapPrimary,
            cursorWidth: 2.5, // The "Yellow Line"
            decoration: InputDecoration(
              hintText: "Search Games, Apps and More",
              hintStyle: TextStyle(color: Colors.white.withOpacity(0.4), fontSize: 20),
              prefixIcon: const Icon(Icons.search_rounded, color: Colors.white70, size: 28),
              prefixIconConstraints: const BoxConstraints(minWidth: 40),
              suffixIcon: _searchController.text.isNotEmpty 
                  ? GestureDetector(
                      onTap: () => _searchController.clear(),
                      child: const Icon(Icons.close_rounded, color: Colors.white54, size: 24),
                    )
                  : null,
              border: InputBorder.none,
              isCollapsed: true,
              contentPadding: const EdgeInsets.symmetric(vertical: 12),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSearchSuggestions() {
      return SafeArea(
        child: Column(
          children: [
            Padding(
               padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
               child: Row(
                 children: [
                   const Icon(Icons.search, color: Colors.white54),
                   const SizedBox(width: 12),
                   Text("Suggestions", style: TextStyle(color: Colors.white.withOpacity(0.5), fontSize: 18, fontWeight: FontWeight.bold)),
                 ],
               ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                children: [
                   // Mock Suggestions
                   _buildSuggestionItem("Send Files", Icons.arrow_upward_rounded),
                   _buildSuggestionItem("Receive Files", Icons.arrow_downward_rounded),
                   _buildSuggestionItem("History", Icons.history_rounded),
                   _buildSuggestionItem("Device Settings", Icons.settings_rounded),
                   const SizedBox(height: 20),
                   Text("  Recent Files", style: TextStyle(color: Colors.white.withOpacity(0.3), fontSize: 14, fontWeight: FontWeight.bold)),
                   const SizedBox(height: 10),
                   _buildSuggestionItem("Vacation_Photo.jpg", Icons.image_rounded),
                   _buildSuggestionItem("Project_Proposal.pdf", Icons.description_rounded),
                   _buildSuggestionItem("Demo_Video.mp4", Icons.movie_rounded),
                ],
              ),
            ),
            const SizedBox(height: 100), // Space for bottom dock
          ],
        ),
      );
  }

  Widget _buildSuggestionItem(String title, IconData icon) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      child: LiquidGlassContainer(
        height: 60,
        opacity: 0.1,
        borderRadius: 20,
        onTap: () {
           // Mock Navigation
           setState(() {
             _searchController.text = title;
             _isSearchActive = false;
             FocusScope.of(context).unfocus();
           });
           ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Selected: $title"), duration: const Duration(milliseconds: 500)));
        },
        child: Row(
          children: [
            Icon(icon, color: Colors.white70),
            const SizedBox(width: 16),
            Text(title, style: const TextStyle(color: Colors.white, fontSize: 16)),
            const Spacer(),
            Icon(Icons.arrow_forward_ios_rounded, color: Colors.white.withOpacity(0.3), size: 14),
          ],
        ),
      ),
    );
  }

  Widget _getPage(int index) {
    switch (index) {
      case 0:
        return _buildDashboard();
      case 1:
        // Ensure child screens don't have conflicting bottom navs or assume no bottom padding
        return Padding(
          padding: const EdgeInsets.only(bottom: 120),
          child: IOSFileShareScreen(
            onBack: () => setState(() => _selectedIndex = 0),
          ),
        );
      case 2:
        return Padding(
          padding: const EdgeInsets.only(bottom: 120),
          child: IOSReceiveOptionsScreen(
            onBack: () => setState(() => _selectedIndex = 0),
          ),
        );
      case 3:
        return Padding(
          padding: const EdgeInsets.only(bottom: 120),
          child: TransferHistoryScreen(
            onBack: () => setState(() => _selectedIndex = 0),
          ),
        );
      default:
        return _buildDashboard();
    }
  }

  // The "Capsule Item" visual
  Widget _buildCapsuleItem(int index, String label, IconData icon) {
    final bool isSelected = _selectedIndex == index;
    // Zap Yellow for active
    const Color activeColor = kZapPrimary;

    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        setState(() => _selectedIndex = index);
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
          // Active item gets a subtle lighter background pill with yellowish tint
          color: isSelected 
              ? activeColor.withOpacity(0.15) 
              : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              color: isSelected ? activeColor : Colors.white.withOpacity(0.8),
              size: 26,
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                color: isSelected ? activeColor : Colors.white.withOpacity(0.6),
                fontSize: 10,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
/*
  Widget _buildDockItem({
...
*/
  Widget _buildDashboard() {
    return SafeArea(
      bottom: false,
      child: FadeTransition(
        opacity: _fadeAnimation,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            _buildHeader(),

            Expanded(
              child: ListView(
                // Add bottom padding to accommodate the dock height (85 + safe area ~ 20-30)
                padding: const EdgeInsets.fromLTRB(24, 10, 24, 120),
                physics: const BouncingScrollPhysics(),
                children: [
                  const Text(
                    "DASHBOARD",
                    style: TextStyle(
                      color: Colors.grey,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.5,
                    ),
                  ),
                  const SizedBox(height: 20),

                  // Bento Grid Layout
                  Row(
                    children: [
                      Expanded(
                        child: _buildBentoCard(
                          title: "Send",
                          subtitle: "Share Files",
                          icon: Icons.arrow_upward_rounded,
                          color: kZapPrimary,
                          iconColor: Colors.black,
                          height: 304,
                          heroTag: "send_fab",
                          onTap: () => setState(() => _selectedIndex = 1),
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          children: [
                            _buildBentoCard(
                              title: "Receive",
                              subtitle: "Get Files",
                              icon: Icons.arrow_downward_rounded,
                              color: kZapSurface,
                              iconColor: Colors.white,
                              height: 144,
                              heroTag: "receive_fab",
                              onTap: () => setState(() => _selectedIndex = 2),
                              backgroundEmoji: "📂",
                            ),
                            _buildBentoCard(
                              title: "History",
                              subtitle: "Recent",
                              icon: Icons.history_rounded,
                              color: kZapSurface,
                              iconColor: Colors.white,
                              height: 144,
                              heroTag: "history_fab",
                              onTap: () => setState(() => _selectedIndex = 3),
                              backgroundIcon: Icons.history_rounded,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  
                  const SizedBox(height: 24),

                  // Stats / Info Section
                  const Text(
                    "STATUS",
                    style: TextStyle(
                      color: Colors.grey,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.5,
                    ),
                  ),
                  const SizedBox(height: 16),
                  
                  _buildStatusCard(),
              ],
            ),
          ),
        ],
      ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
               Row(
                 children: [
                   Image.asset(
                     'assets/images/logo.png',
                     height: 50,
                     fit: BoxFit.contain,
                   ),
                   const SizedBox(width: 8),
                   const Text(
                    "ZapShare",
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                      letterSpacing: -0.5,
                    ),
                  ),
                 ],
               ),
            ],
          ),
          
          InkWell(
            onTap: () {
              HapticFeedback.lightImpact();
               Navigator.push(
                 context,
                 MaterialPageRoute(builder: (context) => const DeviceSettingsScreen()),
               );
            },
            borderRadius: BorderRadius.circular(30),
            child: Container(
              padding: const EdgeInsets.all(2), // Border width
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  colors: [Colors.white.withOpacity(0.2), Colors.transparent],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
              ),
              child: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: kZapSurface,
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.settings_outlined,
                  color: Colors.white,
                  size: 20,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBentoCard({
    required String title,
    required String subtitle,
    required IconData icon,
    required Color color, // Used to determine if primary or secondary
    required Color iconColor,
    required double height,
    required VoidCallback onTap,
    required String heroTag,
    String? backgroundEmoji,
    IconData? backgroundIcon,
  }) {
    final isPrimary = color == kZapPrimary;

    return GestureDetector(
      onTap: () {
        HapticFeedback.mediumImpact();
        onTap();
      },
      child: Container(
        height: height,
        clipBehavior: Clip.antiAlias, // For the background icon decoration
        decoration: BoxDecoration(
          gradient: isPrimary
              ? const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [kZapPrimary, kZapPrimaryDark],
                )
              : LinearGradient( // Dark Glassy Gradient for secondary
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    const Color(0xFF1C1C1E).withOpacity(0.8),
                    const Color(0xFF1C1C1E).withOpacity(0.4),
                  ],
                ),
          color: isPrimary ? null : Colors.black, // Fallback
          borderRadius: BorderRadius.circular(32),
          border: Border.all(
            color: isPrimary 
                ? Colors.white.withOpacity(0.1) 
                : Colors.white.withOpacity(0.08),
            width: 1,
          ),
          boxShadow: [
            if (isPrimary)
              BoxShadow(
                color: kZapPrimary.withOpacity(0.25),
                blurRadius: 30,
                offset: const Offset(0, 10),
              ),
          ],
        ),
        child: Stack(
          children: [
            // Decorative Big Icon for Depth (Only on Primary)
            if (isPrimary)
              Positioned(
                right: -20,
                bottom: -20,
                child: Icon(
                  icon,
                  size: 140,
                  color: Colors.black.withOpacity(0.05),
                ),
              ),
            
            // Decorative Emoji (If provided)
            if (backgroundEmoji != null)
              Positioned(
                right: -25,
                bottom: -25,
                child: Opacity(
                  opacity: 0.1,
                  child: Text(
                    backgroundEmoji,
                    style: const TextStyle(fontSize: 120),
                  ),
                ),
              ),

            // Decorative Icon (If provided)
            if (backgroundIcon != null)
              Positioned(
                right: -45,
                bottom: -35,
                child: Icon(
                  backgroundIcon,
                  size: 140,
                  color: Colors.white.withOpacity(0.05),
                ),
              ),

            Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  // Icon Pill
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: isPrimary 
                              ? Colors.black.withOpacity(0.1) 
                              : Colors.white.withOpacity(0.05),
                          shape: BoxShape.circle,
                        ),
                        child: Hero(
                          tag: heroTag,
                          child: Icon(
                            icon, 
                            color: isPrimary ? Colors.black : kZapPrimary, 
                            size: 24
                          ),
                        ),
                      ),
                      // Optional: Add an arrow icon for secondary cards? 
                      // Let's keep it clean for now.
                    ],
                  ),
                  
                  // Text Content
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          color: isPrimary ? const Color(0xFF0B0D10) : Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.5,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        subtitle,
                        style: TextStyle(
                          color: isPrimary 
                              ? const Color(0xFF0B0D10).withOpacity(0.7) 
                              : const Color(0xFF9CA3AF),
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  )
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusCard() {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: const Color.fromRGBO(255, 255, 255, 0.04),
        borderRadius: BorderRadius.circular(32),
        border: Border.all(color: const Color.fromRGBO(255, 255, 255, 0.06)),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: kZapPrimary.withOpacity(0.1),
              borderRadius: BorderRadius.circular(16),
            ),
            child: const Icon(Icons.wifi_tethering_rounded, color: kZapPrimary, size: 28),
          ),
          const SizedBox(width: 20),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  "Ready to Share",
                  style: TextStyle(
                    color: Color(0xFFD1D5DB), // Primary Text
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  "Devices on the same Wi-Fi can discover each other automatically.",
                  style: TextStyle(
                    color: Color(0xFF9CA3AF), // Secondary Text
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
