import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:zap_share/Screens/shared/TransferHistoryScreen.dart';
import 'package:zap_share/Screens/shared/DeviceSettingsScreen.dart';
import 'MacOSFileShareScreen.dart';
import 'MacOSReceiveScreen.dart';

// macOS Design Constants
const Color kMacOSBackground = Color(0xFF1E1E1E);
const Color kMacOSSidebar = Color(0xFF2B2B2B);
const Color kMacOSContent = Color(0xFF252525);
const Color kMacOSAccent = Color(0xFFFFD84D);
const Color kMacOSAccentDark = Color(0xFFF5C400);
const Color kMacOSTextPrimary = Color(0xFFE5E5E7);
const Color kMacOSTextSecondary = Color(0xFF98989D);
const Color kMacOSBorder = Color(0xFF3A3A3C);

class MacOSHomeScreen extends StatefulWidget {
  const MacOSHomeScreen({super.key});

  @override
  State<MacOSHomeScreen> createState() => _MacOSHomeScreenState();
}

class _MacOSHomeScreenState extends State<MacOSHomeScreen> {
  int _selectedIndex = 0;
  int _hoveredIndex = -1;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kMacOSBackground,
      body: Column(
        children: [
          // macOS-style Toolbar
          _buildToolbar(),
          
          // Main Content with Sidebar
          Expanded(
            child: Row(
              children: [
                // Sidebar
                _buildSidebar(),
                
                // Content Area
                Expanded(
                  child: _buildContent(),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildToolbar() {
    return Container(
      height: 52,
      decoration: const BoxDecoration(
        color: kMacOSSidebar,
        border: Border(
          bottom: BorderSide(color: kMacOSBorder, width: 1),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Row(
          children: [
            // Logo and Title
            Row(
              children: [
                Image.asset(
                  'assets/images/logo.png',
                  height: 28,
                  fit: BoxFit.contain,
                ),
                const SizedBox(width: 12),
                const Text(
                  'ZapShare',
                  style: TextStyle(
                    color: kMacOSTextPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.3,
                  ),
                ),
              ],
            ),
            
            const Spacer(),
            
            // Toolbar Actions
            _buildToolbarButton(
              icon: CupertinoIcons.gear_alt,
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => const DeviceSettingsScreen(),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildToolbarButton({required IconData icon, required VoidCallback onTap}) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.05),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Icon(
            icon,
            color: kMacOSTextSecondary,
            size: 18,
          ),
        ),
      ),
    );
  }

  Widget _buildSidebar() {
    return Container(
      width: 220,
      decoration: const BoxDecoration(
        color: kMacOSSidebar,
        border: Border(
          right: BorderSide(color: kMacOSBorder, width: 1),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 24, 20, 12),
            child: Text(
              'NAVIGATION',
              style: TextStyle(
                color: kMacOSTextSecondary,
                fontSize: 11,
                fontWeight: FontWeight.w600,
                letterSpacing: 1.2,
              ),
            ),
          ),
          
          _buildSidebarItem(
            index: 0,
            icon: CupertinoIcons.arrow_up_circle_fill,
            label: 'Send Files',
          ),
          _buildSidebarItem(
            index: 1,
            icon: CupertinoIcons.arrow_down_circle_fill,
            label: 'Receive Files',
          ),
          _buildSidebarItem(
            index: 2,
            icon: CupertinoIcons.clock_fill,
            label: 'Transfer History',
          ),
          
          const Spacer(),
          
          // Status Indicator at Bottom
          Padding(
            padding: const EdgeInsets.all(20),
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.03),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: Colors.white.withOpacity(0.05),
                ),
              ),
              child: Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: const Color(0xFF34C759),
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFF34C759).withOpacity(0.5),
                          blurRadius: 8,
                          spreadRadius: 2,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      'Online',
                      style: TextStyle(
                        color: kMacOSTextSecondary,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSidebarItem({
    required int index,
    required IconData icon,
    required String label,
  }) {
    final isSelected = _selectedIndex == index;
    final isHovered = _hoveredIndex == index;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hoveredIndex = index),
      onExit: (_) => setState(() => _hoveredIndex = -1),
      child: GestureDetector(
        onTap: () => setState(() => _selectedIndex = index),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: isSelected
                ? kMacOSAccent.withOpacity(0.15)
                : isHovered
                    ? Colors.white.withOpacity(0.05)
                    : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            border: isSelected
                ? Border.all(color: kMacOSAccent.withOpacity(0.3), width: 1)
                : null,
          ),
          child: Row(
            children: [
              Icon(
                icon,
                color: isSelected ? kMacOSAccent : kMacOSTextSecondary,
                size: 20,
              ),
              const SizedBox(width: 12),
              Text(
                label,
                style: TextStyle(
                  color: isSelected ? kMacOSAccent : kMacOSTextPrimary,
                  fontSize: 13,
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildContent() {
    // Show appropriate screen based on selection
    if (_selectedIndex == 0) {
      return const MacOSFileShareScreen();
    } else if (_selectedIndex == 1) {
      return const MacOSReceiveScreen();
    } else {
      return const TransferHistoryScreen();
    }
  }
}
