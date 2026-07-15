import 'package:flutter/material.dart';

class AvatarSelectionDialog extends StatefulWidget {
  final String currentMode;
  final String currentEmoji;
  final String? googlePhotoUrl;
  final Function(String mode, String emoji) onSave;

  const AvatarSelectionDialog({
    super.key,
    required this.currentMode,
    required this.currentEmoji,
    this.googlePhotoUrl,
    required this.onSave,
  });

  @override
  State<AvatarSelectionDialog> createState() => _AvatarSelectionDialogState();
}

class _AvatarSelectionDialogState extends State<AvatarSelectionDialog> {
  late String _selectedMode;
  late String _selectedEmoji;

  final List<String> _emojis = [
    '🚀',
    '🛸',
    '🛰️',
    '⚡',
    '🔥',
    '💎',
    '🎨',
    '🎮',
    '🐱',
    '🐶',
    '🦊',
    '🐼',
    '🦁',
    '🦄',
    '🍎',
    '🍕',
    '🍩',
    '🥑',
    '👻',
    '🤖',
    '👾',
    '🌈',
    '🌍',
    '🍿',
  ];

  @override
  void initState() {
    super.initState();
    _selectedMode = widget.currentMode;
    _selectedEmoji = widget.currentEmoji;
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF1E1E2E),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              "Configure Avatar",
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 20),
            // Mode Selectors
            Row(
              children: [
                Expanded(
                  child: _buildModeTab("emoji", "Emoji", Icons.emoji_emotions),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _buildModeTab(
                    "image",
                    "Google Image",
                    Icons.account_circle,
                    disabled: widget.googlePhotoUrl == null,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            if (_selectedMode == 'emoji') ...[
              const Text(
                "Choose an Emoji Persona:",
                style: TextStyle(fontSize: 14, color: Color(0xFFA0A0C0)),
              ),
              const SizedBox(height: 10),
              SizedBox(
                height: 180,
                child: GridView.builder(
                  shrinkWrap: true,
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 6,
                    mainAxisSpacing: 8,
                    crossAxisSpacing: 8,
                  ),
                  itemCount: _emojis.length,
                  itemBuilder: (context, index) {
                    final emoji = _emojis[index];
                    final isSelected = _selectedEmoji == emoji;
                    return InkWell(
                      onTap: () {
                        setState(() {
                          _selectedEmoji = emoji;
                        });
                      },
                      borderRadius: BorderRadius.circular(10),
                      child: Container(
                        decoration: BoxDecoration(
                          color:
                              isSelected
                                  ? const Color(0xFF3B3B5E)
                                  : Colors.transparent,
                          borderRadius: BorderRadius.circular(10),
                          border:
                              isSelected
                                  ? Border.all(
                                    color: const Color(0xFF34D399),
                                    width: 1.5,
                                  )
                                  : null,
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          emoji,
                          style: const TextStyle(fontSize: 24),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ] else ...[
              Center(
                child: Container(
                  width: 100,
                  height: 100,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: const Color(0xFF34D399),
                      width: 2,
                    ),
                    image:
                        widget.googlePhotoUrl != null
                            ? DecorationImage(
                              image: NetworkImage(widget.googlePhotoUrl!),
                              fit: BoxFit.cover,
                            )
                            : null,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                "Your authenticated Google profile picture will be shown to connected devices.",
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: Color(0xFFA0A0C0)),
              ),
            ],
            const SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text(
                    "Cancel",
                    style: TextStyle(color: Colors.grey),
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: () {
                    widget.onSave(_selectedMode, _selectedEmoji);
                    Navigator.pop(context);
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF34D399),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: const Text(
                    "Save",
                    style: TextStyle(color: Colors.black),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildModeTab(
    String mode,
    String label,
    IconData icon, {
    bool disabled = false,
  }) {
    final isSelected = _selectedMode == mode;
    return InkWell(
      onTap:
          disabled
              ? null
              : () {
                setState(() {
                  _selectedMode = mode;
                });
              },
      borderRadius: BorderRadius.circular(12),
      child: Opacity(
        opacity: disabled ? 0.4 : 1.0,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            color:
                isSelected ? const Color(0xFF27273F) : const Color(0xFF141424),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color:
                  isSelected
                      ? const Color(0xFF34D399)
                      : const Color(0xFF27273F),
              width: 1.5,
            ),
          ),
          child: Column(
            children: [
              Icon(
                icon,
                color: isSelected ? const Color(0xFF34D399) : Colors.white70,
              ),
              const SizedBox(height: 4),
              Text(
                label,
                style: TextStyle(
                  color: isSelected ? Colors.white : Colors.white54,
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
