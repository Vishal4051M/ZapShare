import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:zap_share/services/firebase_service.dart';
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

  Future<void> _pickCustomImage() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        allowMultiple: false,
      );
      if (result != null && result.files.single.path != null) {
        final path = result.files.single.path!;
        final appDir = await getApplicationDocumentsDirectory();
        final fileName = 'custom_avatar_${DateTime.now().millisecondsSinceEpoch}.png';
        final newFile = await File(path).copy('${appDir.path}/$fileName');
        
        setState(() {
          _selectedAvatar = newFile.path;
        });
        
        HapticFeedback.mediumImpact();
      }
    } catch (e) {
      print("Error picking custom avatar: $e");
    }
  }

  Future<void> _saveAvatar() async {
    if (_selectedAvatar == null) return;

    BuildContext? dialogContext;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        dialogContext = ctx;
        return const Center(
          child: CircularProgressIndicator(
            color: Color(0xFFFFD600),
          ),
        );
      },
    );

    try {
      String finalAvatar = _selectedAvatar!;
      final prefs = await SharedPreferences.getInstance();

      final user = FirebaseService().currentUser;
      if (user != null) {
        final isLocalFile = finalAvatar.startsWith('/') ||
            finalAvatar.contains(':\\') ||
            finalAvatar.startsWith('file://') ||
            File(finalAvatar).existsSync();

        if (isLocalFile) {
          final cleanPath = finalAvatar.replaceFirst('file://', '');
          final file = File(cleanPath);
          final uploadUrl = await FirebaseService().uploadCustomAvatarBase64(file);
          if (uploadUrl != null) {
            finalAvatar = uploadUrl;
          } else {
            throw Exception("Failed to process and encode avatar image.");
          }
        }

        // Sync to database
        await FirebaseService().saveUserProfile(
          username: prefs.getString('username') ?? (user.email?.split('@').first ?? 'user'),
          fullName: prefs.getString('device_name') ?? (user.userMetadata?['full_name'] ?? 'User'),
          avatarUrl: finalAvatar,
        );
      }

      await prefs.setString('custom_avatar', finalAvatar);

      if (dialogContext != null && dialogContext!.mounted) {
        Navigator.of(dialogContext!).pop(); // Dismiss loading spinner
      }

      if (mounted) {
        HapticFeedback.mediumImpact();
        Navigator.pop(context, finalAvatar);
      }
    } catch (e) {
      if (dialogContext != null && dialogContext!.mounted) {
        Navigator.of(dialogContext!).pop(); // Dismiss loading spinner
      }
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
              height: 240,
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
                  const SizedBox(height: 12),
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
                  const SizedBox(height: 8),
                  TextButton.icon(
                    onPressed: _pickCustomImage,
                    icon: const Icon(Icons.add_photo_alternate_rounded, color: Color(0xFFFFD600), size: 18),
                    label: Text(
                      'Upload Custom Photo',
                      style: GoogleFonts.outfit(
                        color: const Color(0xFFFFD600),
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    style: TextButton.styleFrom(
                      backgroundColor: Colors.white.withOpacity(0.05),
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(20),
                      ),
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
