import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'AppColors.dart';

class AppStyles {
  static TextStyle title = GoogleFonts.outfit(
    fontSize: 22,
    fontWeight: FontWeight.w800,
    color: AppColors.textPrimary,
  );

  static TextStyle subtitle = GoogleFonts.outfit(
    fontSize: 16,
    color: AppColors.textMuted,
    fontWeight: FontWeight.w500,
  );

  static TextStyle heading = GoogleFonts.outfit(
    fontSize: 22,
    fontWeight: FontWeight.w900,
    color: AppColors.textPrimary,
    letterSpacing: -0.5,
  );

  static TextStyle badge = GoogleFonts.outfit(
    fontSize: 11,
    color: AppColors.textPrimary,
    fontWeight: FontWeight.w800,
    letterSpacing: 1.2,
  );

  static TextStyle button = GoogleFonts.outfit(
    color: AppColors.textPrimary,
    fontWeight: FontWeight.w800,
    letterSpacing: 1.5,
  );
}
