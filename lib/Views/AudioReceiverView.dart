import 'package:flutter/material.dart';
import 'dart:io';
import '../Constants/AppColors.dart';
import '../Constants/AppStyles.dart';
import '../Constants/AudioReceiverWidgets.dart';
import '../Controllers/AudioReceiverController.dart';

class AudioReceiverView extends StatefulWidget {
  final String senderName;
  final String senderIp;
  final bool useLanAudio;
  final String? audioUrl;

  const AudioReceiverView({
    super.key,
    required this.senderName,
    required this.senderIp,
    this.useLanAudio = true,
    this.audioUrl,
  });

  @override
  State<AudioReceiverView> createState() => _AudioReceiverViewState();
}

class _AudioReceiverViewState extends State<AudioReceiverView>
    with SingleTickerProviderStateMixin {
  late AudioReceiverController _controller;
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AudioReceiverController(
      senderIp: widget.senderIp,
      useLanAudio: widget.useLanAudio,
      audioUrl: widget.audioUrl,
    );
    _controller.init();
    _controller.addListener(_update);

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);
    
    _pulseAnimation = Tween<double>(begin: 1.0, end: 1.5).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
  }

  void _update() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _controller.removeListener(_update);
    _controller.dispose();
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final isLandscape = media.orientation == Orientation.landscape;
    final isTvLayout = media.size.shortestSide >= 600;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: FocusTraversalGroup(
          policy: ReadingOrderTraversalPolicy(),
          child:
              isLandscape && isTvLayout
                  ? _buildTvLandscapeLayout(context)
                  : _buildDefaultLayout(context),
        ),
      ),
    );
  }

  Widget _buildDefaultLayout(BuildContext context) {
    return Column(
      children: [
        _buildHeader(),
        const Spacer(),
        AudioPulseIndicator(animation: _pulseAnimation),
        const SizedBox(height: 54),
        Text(
          _controller.isReceiving ? 'Live Stream Active' : 'Waiting for Signal',
          style: AppStyles.heading,
        ),
        const SizedBox(height: 8),
        Text('From ${widget.senderName}', style: AppStyles.subtitle),
        const SizedBox(height: 40),
        const StatusBadge(text: 'ZAP ULTRA LOW LATENCY'),
        const Spacer(),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: StabilityControl(
            currentCushion: _controller.cushionMs,
            onChanged: _controller.setCushion,
          ),
        ),
        const SizedBox(height: 24),
        if (Platform.isLinux || Platform.isWindows) _buildControlsOverlay(),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 32),
          child: _buildStopButton(),
        ),
      ],
    );
  }

  Widget _buildTvLandscapeLayout(BuildContext context) {
    final headingStyle = AppStyles.heading.copyWith(fontSize: 32);
    final subtitleStyle = AppStyles.subtitle.copyWith(fontSize: 18);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 32),
      child: Row(
        children: [
          Expanded(
            flex: 5,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildHeader(),
                const SizedBox(height: 32),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Transform.scale(
                        scale: 1.2,
                        alignment: Alignment.centerLeft,
                        child: AudioPulseIndicator(animation: _pulseAnimation),
                      ),
                      const SizedBox(height: 32),
                      Text(
                        _controller.isReceiving
                            ? 'Live Stream Active'
                            : 'Waiting for Signal',
                        style: headingStyle,
                      ),
                      const SizedBox(height: 12),
                      Text('From ${widget.senderName}', style: subtitleStyle),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 40),
          Expanded(
            flex: 4,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const StatusBadge(text: 'ZAP ULTRA LOW LATENCY'),
                const SizedBox(height: 28),
                StabilityControl(
                  currentCushion: _controller.cushionMs,
                  onChanged: _controller.setCushion,
                ),
                const SizedBox(height: 28),
                if (Platform.isLinux || Platform.isWindows) _buildControlsOverlay(),
                const Spacer(),
                _buildStopButton(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Row(
        children: [
          _buildHeaderButton(
            icon: Icons.arrow_back_ios_new_rounded,
            onTap: () => Navigator.pop(context),
          ),
          const SizedBox(width: 20),
          Text('Receiving Audio', style: AppStyles.title),
        ],
      ),
    );
  }

  Widget _buildHeaderButton({required IconData icon, required VoidCallback onTap}) {
    return _FocusSurface(
      onTap: onTap,
      builder: (isFocused) {
        return GestureDetector(
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: AppColors.cardBackground,
              shape: BoxShape.circle,
              border: Border.all(
                color:
                    isFocused
                        ? AppColors.primary
                        : Colors.white.withOpacity(0.05),
                width: isFocused ? 2 : 1,
              ),
            ),
            child: Icon(icon, color: AppColors.textPrimary, size: 20),
          ),
        );
      },
    );
  }

  Widget _buildControlsOverlay() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 24),
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
      decoration: BoxDecoration(
        color: AppColors.cardBackground,
        borderRadius: BorderRadius.circular(32),
        border: Border.all(color: Colors.white.withOpacity(0.05)),
      ),
      child: Row(
        children: [
          _buildControlButton(
            icon: _controller.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
            onTap: _controller.togglePlay,
            color: AppColors.primary,
            iconColor: Colors.black,
          ),
          Expanded(child: _buildVolumeSlider()),
        ],
      ),
    );
  }

  Widget _buildVolumeSlider() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24.0),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Icon(Icons.volume_down_rounded, color: AppColors.textMuted, size: 16),
              Text(
                '${_controller.volume.toInt()}%',
                style: AppStyles.badge.copyWith(letterSpacing: 0),
              ),
              const Icon(Icons.volume_up_rounded, color: AppColors.textMuted, size: 16),
            ],
          ),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: AppColors.primary,
              inactiveTrackColor: Colors.white10,
              thumbColor: Colors.white,
              trackHeight: 4,
            ),
            child: Slider(
              value: _controller.volume,
              min: 0, max: 100,
              onChanged: _controller.setVolume,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildControlButton({required IconData icon, required VoidCallback onTap, required Color color, required Color iconColor}) {
    return _FocusSurface(
      onTap: onTap,
      builder: (isFocused) {
        return GestureDetector(
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              border: Border.all(
                color:
                    isFocused
                        ? Colors.white
                        : Colors.transparent,
                width: isFocused ? 2 : 0,
              ),
            ),
            child: Icon(icon, color: iconColor, size: 28),
          ),
        );
      },
    );
  }

  Widget _buildStopButton() {
    return _FocusSurface(
      onTap: () => Navigator.pop(context),
      builder: (isFocused) {
        return AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(22),
            border: Border.all(
              color:
                  isFocused
                      ? AppColors.primary
                      : Colors.transparent,
              width: isFocused ? 2 : 0,
            ),
          ),
          child: SizedBox(
            width: double.infinity,
            height: 60,
            child: ElevatedButton(
              onPressed: () => Navigator.pop(context),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.cardBackground,
                foregroundColor: AppColors.textPrimary,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                  side: const BorderSide(color: Colors.white10),
                ),
              ),
              child: Text('DISCONNECT', style: AppStyles.button),
            ),
          ),
        );
      },
    );
  }
}

class _FocusSurface extends StatefulWidget {
  final Widget Function(bool isFocused) builder;
  final VoidCallback? onTap;

  const _FocusSurface({
    required this.builder,
    required this.onTap,
  });

  @override
  State<_FocusSurface> createState() => _FocusSurfaceState();
}

class _FocusSurfaceState extends State<_FocusSurface> {
  bool _isFocused = false;

  @override
  Widget build(BuildContext context) {
    return FocusableActionDetector(
      onFocusChange: (focused) => setState(() => _isFocused = focused),
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (intent) {
            widget.onTap?.call();
            return null;
          },
        ),
      },
      child: widget.builder(_isFocused),
    );
  }
}
