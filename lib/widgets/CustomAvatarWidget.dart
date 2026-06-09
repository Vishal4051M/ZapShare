import 'package:flutter/material.dart';
import 'dart:io';

class CustomAvatarWidget extends StatelessWidget {
  final String? avatarId;
  final double size;
  final bool showBorder;
  final Color? borderColor;

  final bool useBackground;

  const CustomAvatarWidget({
    super.key,
    this.avatarId,
    this.size = 48,
    this.showBorder = false,
    this.borderColor,
    this.useBackground = true,
  });

  // CATEGORIZED AVATAR LIST
  static Map<String, List<Map<String, dynamic>>> get categories => {
    'Faces': [
      {'id': 'face_1', 'emoji': '😀'},
      {'id': 'face_2', 'emoji': '😎'},
      {'id': 'face_3', 'emoji': '🤓'},
      {'id': 'face_4', 'emoji': '😇'},
      {'id': 'face_5', 'emoji': '🤩'},
      {'id': 'face_6', 'emoji': '🥳'},
      {'id': 'face_7', 'emoji': '😴'},
      {'id': 'face_8', 'emoji': '🤗'},
      {'id': 'face_9', 'emoji': '🥰'},
      {'id': 'face_10', 'emoji': '😜'},
      {'id': 'face_11', 'emoji': '🤔'},
      {'id': 'face_12', 'emoji': '🤫'},
      {'id': 'face_13', 'emoji': '🤠'},
      {'id': 'face_14', 'emoji': '🤡'},
      {'id': 'face_15', 'emoji': '👻'},
      {'id': 'face_16', 'emoji': '🤒'},
      {'id': 'face_17', 'emoji': '🥶'},
      {'id': 'face_18', 'emoji': '🤯'},
      {'id': 'face_19', 'emoji': '🥺'},
      {'id': 'face_20', 'emoji': '😍'},
    ],
    'Animals': [
      {'id': 'ani_1', 'emoji': '🐶'},
      {'id': 'ani_2', 'emoji': '🐱'},
      {'id': 'ani_3', 'emoji': '🐭'},
      {'id': 'ani_4', 'emoji': '🐹'},
      {'id': 'ani_5', 'emoji': '🐰'},
      {'id': 'ani_6', 'emoji': '🦊'},
      {'id': 'ani_7', 'emoji': '🐻'},
      {'id': 'ani_8', 'emoji': '🐼'},
      {'id': 'ani_9', 'emoji': '🐨'},
      {'id': 'ani_10', 'emoji': '🐯'},
      {'id': 'ani_11', 'emoji': '🦁'},
      {'id': 'ani_12', 'emoji': '🐮'},
      {'id': 'ani_13', 'emoji': '🐷'},
      {'id': 'ani_14', 'emoji': '🐸'},
      {'id': 'ani_15', 'emoji': '🐵'},
      {'id': 'ani_16', 'emoji': '🐔'},
      {'id': 'ani_17', 'emoji': '🦄'},
      {'id': 'ani_18', 'emoji': '🦋'},
      {'id': 'ani_19', 'emoji': '🐙'},
      {'id': 'ani_20', 'emoji': '🦈'},
      {'id': 'ani_21', 'emoji': '🦦'},
      {'id': 'ani_22', 'emoji': '🦥'},
      {'id': 'ani_23', 'emoji': '🐉'},
      {'id': 'ani_24', 'emoji': '🦕'},
      {'id': 'ani_25', 'emoji': '🦖'}, // T-Rex
      {'id': 'ani_26', 'emoji': '🐢'},
      {'id': 'ani_27', 'emoji': '🐊'},
      {'id': 'ani_28', 'emoji': '🐍'},
      {'id': 'ani_29', 'emoji': '🦎'},
    ],
    'Food': [
      {'id': 'food_1', 'emoji': '🍎'},
      {'id': 'food_2', 'emoji': '🍐'},
      {'id': 'food_3', 'emoji': '🍊'},
      {'id': 'food_4', 'emoji': '🍋'},
      {'id': 'food_5', 'emoji': '🍌'},
      {'id': 'food_6', 'emoji': '🍉'},
      {'id': 'food_7', 'emoji': '🍇'},
      {'id': 'food_8', 'emoji': '🍓'},
      {'id': 'food_9', 'emoji': '🫐'},
      {'id': 'food_10', 'emoji': '🍍'},
      {'id': 'food_11', 'emoji': '🥝'},
      {'id': 'food_12', 'emoji': '🥭'},
      {'id': 'food_13', 'emoji': '🥑'},
      {'id': 'food_14', 'emoji': '🍆'}, // Brinjal / Eggplant
      {'id': 'food_15', 'emoji': '🥦'},
      {'id': 'food_16', 'emoji': '🥕'},
      {'id': 'food_17', 'emoji': '🌽'}, // Corn
      {'id': 'food_18', 'emoji': '🍅'}, // Tomato
      {'id': 'food_19', 'emoji': '🥔'}, // Potato
      {'id': 'food_20', 'emoji': '🥒'}, // Cucumber
      {'id': 'food_21', 'emoji': '🥬'}, // Leafy Green/Salad
      {'id': 'food_22', 'emoji': '🌶️'},
      {'id': 'food_23', 'emoji': '🫑'}, // Bell Pepper
      {'id': 'food_24', 'emoji': '🧅'}, // Onion
      {'id': 'food_25', 'emoji': '🍕'},
      {'id': 'food_26', 'emoji': '🍔'},
      {'id': 'food_27', 'emoji': '🍟'},
      {'id': 'food_28', 'emoji': '🍪'},
      {'id': 'food_29', 'emoji': '🍩'},
      {'id': 'food_30', 'emoji': '🍦'},
      {'id': 'food_31', 'emoji': '🍰'},
      {'id': 'food_32', 'emoji': '☕'},
    ],
    'Activity': [
      {'id': 'act_1', 'emoji': '⚽'},
      {'id': 'act_2', 'emoji': '🏀'},
      {'id': 'act_3', 'emoji': '🏈'},
      {'id': 'act_4', 'emoji': '⚾'},
      {'id': 'act_5', 'emoji': '🎾'},
      {'id': 'act_6', 'emoji': '🏐'},
      {'id': 'act_7', 'emoji': '🏉'},
      {'id': 'act_8', 'emoji': '🎱'},
      {'id': 'act_9', 'emoji': '🏓'},
      {'id': 'act_10', 'emoji': '🏸'},
      {'id': 'act_11', 'emoji': '🥊'},
      {'id': 'act_12', 'emoji': '🎮'},
      {'id': 'act_13', 'emoji': '🎯'},
      {'id': 'act_14', 'emoji': '🎲'},
      {'id': 'act_15', 'emoji': '🎨'},
      {'id': 'act_16', 'emoji': '🎸'},
      {'id': 'act_17', 'emoji': '🎺'},
      {'id': 'act_18', 'emoji': '🎻'},
      {'id': 'act_19', 'emoji': '🎬'},
      {'id': 'act_20', 'emoji': '🎤'},
    ],
    'Travel': [
      {'id': 'veh_1', 'emoji': '🚗'},
      {'id': 'veh_2', 'emoji': '🚕'},
      {'id': 'veh_3', 'emoji': '🚙'},
      {'id': 'veh_4', 'emoji': '🚌'},
      {'id': 'veh_5', 'emoji': '🏎️'},
      {'id': 'veh_6', 'emoji': '🚓'},
      {'id': 'veh_7', 'emoji': '🚑'},
      {'id': 'veh_8', 'emoji': '🚒'},
      {'id': 'veh_9', 'emoji': '🚲'},
      {'id': 'veh_10', 'emoji': '🛵'},
      {'id': 'veh_11', 'emoji': '🚂'},
      {'id': 'veh_12', 'emoji': '✈️'},
      {'id': 'veh_13', 'emoji': '🚀'},
      {'id': 'veh_14', 'emoji': '🛸'},
      {'id': 'veh_15', 'emoji': '🚁'},
      {'id': 'veh_16', 'emoji': '🚢'},
      {'id': 'veh_17', 'emoji': '⛵️'},
      {'id': 'veh_18', 'emoji': '🚤'},
      {'id': 'veh_19', 'emoji': '🗺️'},
      {'id': 'veh_20', 'emoji': '🗽'},
    ],
    'Objects': [
      {'id': 'obj_1', 'emoji': '⌚'},
      {'id': 'obj_2', 'emoji': '📱'},
      {'id': 'obj_3', 'emoji': '💻'},
      {'id': 'obj_4', 'emoji': '🖥️'},
      {'id': 'obj_5', 'emoji': '💡'},
      {'id': 'obj_6', 'emoji': '🔦'},
      {'id': 'obj_7', 'emoji': '🔋'},
      {'id': 'obj_8', 'emoji': '🔑'},
      {'id': 'obj_9', 'emoji': '🎁'},
      {'id': 'obj_10', 'emoji': '🎈'},
      {'id': 'obj_11', 'emoji': '🎉'},
      {'id': 'obj_12', 'emoji': '❤️'},
      {'id': 'obj_13', 'emoji': '💰'},
      {'id': 'obj_14', 'emoji': '💎'},
      {'id': 'obj_15', 'emoji': '🔔'},
    ],
    'Nature': [
      {'id': 'nat_1', 'emoji': '🌵'},
      {'id': 'nat_2', 'emoji': '🌲'},
      {'id': 'nat_3', 'emoji': '🌳'},
      {'id': 'nat_4', 'emoji': '🌴'},
      {'id': 'nat_5', 'emoji': '🌱'},
      {'id': 'nat_6', 'emoji': '🌿'},
      {'id': 'nat_7', 'emoji': '🍀'},
      {'id': 'nat_8', 'emoji': '🍁'},
      {'id': 'nat_9', 'emoji': '🍄'},
      {'id': 'nat_10', 'emoji': '💐'},
      {'id': 'nat_11', 'emoji': '🌸'},
      {'id': 'nat_12', 'emoji': '🌹'},
      {'id': 'nat_13', 'emoji': '🌻'},
      {'id': 'nat_14', 'emoji': '🌺'},
      {'id': 'nat_15', 'emoji': '🌞'},
      {'id': 'nat_16', 'emoji': '⭐'},
      {'id': 'nat_17', 'emoji': '🌙'},
      {'id': 'nat_18', 'emoji': '⚡'},
      {'id': 'nat_19', 'emoji': '🌊'},
      {'id': 'nat_20', 'emoji': '🔥'},
    ],
    // Legacy support
    'Legacy': [
      {'id': 'avatar_1', 'emoji': '😀'},
    ],
  };

  @override
  Widget build(BuildContext context) {
    if (avatarId == null || !_avatarMap.containsKey(avatarId)) {
      return Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color:
              useBackground
                  ? Colors.white.withOpacity(0.08)
                  : Colors.transparent,
          shape: BoxShape.circle,
        ),
        child: Icon(Icons.person, color: Colors.white, size: size * 0.6),
      );
    }

    final avatar = _avatarMap[avatarId]!;
    final emoji = avatar['emoji'] as String;

    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        // Only show glassy background if requested
        color:
            useBackground ? Colors.white.withOpacity(0.08) : Colors.transparent,
        shape: BoxShape.circle,
        border:
            showBorder
                ? Border.all(
                  color: borderColor ?? Colors.white.withOpacity(0.2),
                  width: 2,
                )
                : null,
      ),
      child: Center(
        child: Transform.translate(
          // Only nudge left in Grid Mode (!useBackground) where visual centering is tricky.
          // In Preview Mode (useBackground), standard centering works best.
          offset: _getAvatarOffset(size, useBackground, avatarId!),
          child: Text(
            emoji,
            style: TextStyle(
              fontSize: size * (useBackground ? 0.55 : 0.85),
              height: Platform.isWindows ? 1.0 : 1.15,
              fontFamilyFallback: [
                'Apple Color Emoji',
                'Segoe UI Emoji',
                'Noto Color Emoji',
              ],
              color: const Color(0xFFFFFFFF),
            ),
            textAlign: TextAlign.center,
          ),
        ),
      ),
    );
  }

  Offset _getAvatarOffset(double size, bool useBackground, String currentId) {
    // 1. Horizontal Correction
    // Only nudge left in Grid Mode (!useBackground) where visual centering is tricky.
    // In Preview Mode (useBackground), standard centering works best.
    double dx = useBackground ? 0 : -size * 0.05;

    // 2. Vertical Correction
    // Some "flat" emojis (cars, boats) render low on the baseline. Lift them up.
    // Exceptions: Plane, Rocket, Train, Scooter, UFO are usually fine.

    // Windows often renders emojis a bit lower, so we might need to lift them up slightly
    // independent of the vehicle logic.
    if (Platform.isWindows && useBackground) {
      // Windows specific adjustment for centered circles
      return Offset(dx, -size * 0.08);
    }

    // List of IDs that need lifting (Cars, Trucks, Bikes, Boats)
    const lowVehicles = {
      'veh_1',
      'veh_2',
      'veh_3',
      'veh_4',
      'veh_5',
      'veh_6',
      'veh_7',
      'veh_8',
      'veh_9',
      'veh_15',
      'veh_16',
      'veh_17',
      'veh_18',
    };

    double dy = 0;
    if (lowVehicles.contains(currentId)) {
      dy = -size * 0.1; // Lift up by 10%
    }

    return Offset(dx, dy);
  }

  // Helper to get category icon
  static IconData getCategoryIcon(String category) {
    switch (category) {
      case 'Faces':
        return Icons.sentiment_satisfied_alt_rounded;
      case 'Animals':
        return Icons.pets_rounded;
      case 'Food':
        return Icons.fastfood_rounded;
      case 'Activity':
        return Icons.sports_esports_rounded;
      case 'Travel':
        return Icons.flight_takeoff_rounded;
      case 'Objects':
        return Icons.category_rounded;
      case 'Nature':
        return Icons.eco_rounded;
      default:
        return Icons.grid_view_rounded;
    }
  }

  // Flattened list for backward compatibility
  static List<Map<String, dynamic>> get avatars {
    final List<Map<String, dynamic>> all = [];
    categories.forEach((key, value) {
      if (key != 'Legacy') {
        all.addAll(value);
      }
    });
    // Add legacy if needed or ensure IDs are unique.
    return all;
  }

  static Map<String, Map<String, dynamic>> get _avatarMap {
    return {for (var a in avatars) a['id'] as String: a};
  }
}
