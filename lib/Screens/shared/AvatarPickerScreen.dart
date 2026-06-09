import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zap_share/services/supabase_service.dart';
import 'package:zap_share/widgets/CustomAvatarWidget.dart';

class AvatarPickerScreen extends StatefulWidget {
  final String? currentAvatar;

  const AvatarPickerScreen({super.key, this.currentAvatar});

  @override
  State<AvatarPickerScreen> createState() => _AvatarPickerScreenState();
}

class _AvatarPickerScreenState extends State<AvatarPickerScreen>
    with SingleTickerProviderStateMixin {
  String? _selectedAvatar;
  late TabController _tabController;
  final List<String> _categories =
      CustomAvatarWidget.categories.keys.where((k) => k != 'Legacy').toList();

  @override
  void initState() {
    super.initState();
    _selectedAvatar = widget.currentAvatar;
    _tabController = TabController(length: _categories.length, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _saveAvatar() async {
    if (_selectedAvatar == null) return;

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('custom_avatar', _selectedAvatar!);

      final user = SupabaseService().currentUser;
      if (user != null) {
        await SupabaseService().updateUserProfile(avatarUrl: _selectedAvatar);
      }

      if (mounted) {
        HapticFeedback.mediumImpact();
        Navigator.pop(context, _selectedAvatar);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error saving avatar: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          'Choose Avatar',
          style: GoogleFonts.outfit(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.w700,
          ),
        ),
        actions: [
          TextButton(
            onPressed: _selectedAvatar != null ? _saveAvatar : null,
            child: Text(
              'Save',
              style: GoogleFonts.outfit(
                color:
                    _selectedAvatar != null
                        ? const Color(0xFFFFD600)
                        : Colors.grey,
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            // Expanded Preview Section with nice aesthetic
            Container(
              height: 200,
              width: double.infinity,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.white.withOpacity(0.05), Colors.transparent],
                ),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _buildAvatarPreview(),
                  const SizedBox(height: 16),
                  Text(
                    _selectedAvatar != null
                        ? 'Looking good!'
                        : 'Pick your style',
                    style: GoogleFonts.outfit(
                      color: Colors.white70,
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),

            // Tabs Header - Compact and Nice
            Container(
              height: 50,
              margin: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.08),
                borderRadius: BorderRadius.circular(25),
              ),
              child: TabBar(
                controller: _tabController,
                isScrollable: true,
                tabAlignment: TabAlignment.start, // Align start for scrollable
                indicator: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(25),
                ),
                labelColor: Colors.black,
                unselectedLabelColor: Colors.grey,
                labelStyle: GoogleFonts.outfit(
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                ),
                unselectedLabelStyle: GoogleFonts.outfit(
                  fontWeight: FontWeight.w500,
                  fontSize: 13,
                ),
                dividerColor: Colors.transparent, // Remove underlining
                overlayColor: MaterialStateProperty.all(Colors.transparent),
                padding: const EdgeInsets.all(4),
                tabs:
                    _categories.map((category) {
                      return Tab(
                        height: 36,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: Text(category),
                        ),
                      );
                    }).toList(),
              ),
            ),

            const SizedBox(height: 16),

            // Swipable Content (PageView via TabBarView) wrapped in a "Box"
            Expanded(
              child: Container(
                width: double.infinity,
                margin: const EdgeInsets.only(
                  top: 0,
                  bottom: 24,
                  left: 16,
                  right: 16,
                ),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(
                    0.03,
                  ), // Distinct box background
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: Colors.white.withOpacity(0.05)),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(24),
                  child: TabBarView(
                    controller: _tabController,
                    physics: const PageScrollPhysics(
                      parent: BouncingScrollPhysics(),
                    ), // Smoother swipe
                    children:
                        _categories.map((category) {
                          final avatars =
                              CustomAvatarWidget.categories[category]!;
                          return GridView.builder(
                            physics:
                                const BouncingScrollPhysics(), // Smoother list scroll
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 16,
                            ),
                            gridDelegate:
                                const SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: 5,
                                  crossAxisSpacing:
                                      12, // Adjusted for container width
                                  mainAxisSpacing: 16,
                                ),
                            itemCount: avatars.length,
                            itemBuilder: (context, index) {
                              final avatar = avatars[index];
                              final avatarId = avatar['id'] as String;
                              final isSelected = _selectedAvatar == avatarId;

                              return GestureDetector(
                                onTap: () {
                                  setState(() => _selectedAvatar = avatarId);
                                  HapticFeedback.selectionClick();
                                },
                                child: AnimatedContainer(
                                  duration: const Duration(milliseconds: 200),
                                  width: 50,
                                  height: 50,
                                  decoration: BoxDecoration(
                                    color: Colors.transparent,
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color:
                                          isSelected
                                              ? Colors.white
                                              : Colors.transparent,
                                      width: 2,
                                    ),
                                  ),
                                  padding:
                                      EdgeInsets
                                          .zero, // Remove padding to prevent offset
                                  alignment: Alignment.center,
                                  child: CustomAvatarWidget(
                                    avatarId: avatarId,
                                    size:
                                        42, // Adjusted size slightly to provide natural spacing
                                    useBackground: false,
                                  ),
                                ),
                              );
                            },
                          );
                        }).toList(),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAvatarPreview() {
    // Large centered preview
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutBack,
      width: 140, // Nice and Big
      height: 140,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.transparent, // Widget handles its own background now
        boxShadow:
            _selectedAvatar != null
                ? [
                  BoxShadow(
                    color: Colors.white.withOpacity(0.1),
                    blurRadius: 40,
                    spreadRadius: -10,
                  ),
                ]
                : [],
      ),
      child:
          _selectedAvatar != null
              ? CustomAvatarWidget(
                avatarId: _selectedAvatar,
                size: 130, // Huge emoji for impact
                showBorder: false,
              )
              : Icon(Icons.person, size: 80, color: Colors.white24),
    );
  }
}
