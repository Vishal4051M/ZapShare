import 'package:flutter/material.dart';
import 'AppColors.dart';
import 'AppStyles.dart';

class AudioPulseIndicator extends StatelessWidget {
  final Animation<double> animation;

  const AudioPulseIndicator({super.key, required this.animation});

  @override
  Widget build(BuildContext context) {
    return Hero(
      tag: 'audio_receiver_pulse',
      child: Stack(
        alignment: Alignment.center,
        children: [
          AnimatedBuilder(
            animation: animation,
            builder: (context, child) {
              return Container(
                width: 120 * animation.value,
                height: 120 * animation.value,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: AppColors.primary.withOpacity(
                      0.3 * (2.0 - animation.value),
                    ),
                    width: 2,
                  ),
                ),
              );
            },
          ),
          Container(
            width: 110,
            height: 110,
            decoration: const BoxDecoration(
              color: AppColors.primary,
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.waves_rounded,
              color: Colors.black,
              size: 48,
            ),
          ),
        ],
      ),
    );
  }
}

class StatusBadge extends StatelessWidget {
  final String text;
  const StatusBadge({super.key, required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.cardBackground,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withOpacity(0.05)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.bolt_rounded, color: AppColors.primary, size: 16),
          const SizedBox(width: 8),
          Text(text, style: AppStyles.badge),
        ],
      ),
    );
  }
}

class StabilityControl extends StatelessWidget {
  final int currentCushion;
  final ValueChanged<int> onChanged;

  const StabilityControl({
    super.key,
    required this.currentCushion,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.cardBackground,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.speed_rounded,
                color: AppColors.primary,
                size: 18,
              ),
              const SizedBox(width: 8),
              Text(
                'Stability Mode',
                style: AppStyles.subtitle.copyWith(
                  color: AppColors.textPrimary,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              _buildOption('Low Latency', 12),
              const SizedBox(width: 8),
              _buildOption('Balanced', 20),
              const SizedBox(width: 8),
              _buildOption('Stable', 40),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildOption(String label, int value) {
    final isSelected = currentCushion == value;
    return Expanded(
      child: GestureDetector(
        onTap: () => onChanged(value),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color:
                isSelected ? AppColors.primary : Colors.white.withOpacity(0.05),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Center(
            child: Text(
              label,
              style: AppStyles.badge.copyWith(
                color: isSelected ? Colors.black : Colors.white60,
                fontSize: 10,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
