import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../services/device_discovery_service.dart';
import '../Constants/FocusSurface.dart';

class AudioShareDeviceList extends StatelessWidget {
  final bool isTvLayout;
  final List<DiscoveredDevice> devices;
  final Set<String> selectedTargets;
  final Function(String ipAddress) onDeviceSelect;

  const AudioShareDeviceList({
    super.key,
    required this.isTvLayout,
    required this.devices,
    required this.selectedTargets,
    required this.onDeviceSelect,
  });

  @override
  Widget build(BuildContext context) {
    final header = Padding(
      padding: EdgeInsets.symmetric(
        horizontal: isTvLayout ? 0 : 24,
        vertical: 8,
      ),
      child: Text(
        'DEVICES NEARBY',
        style: GoogleFonts.outfit(
          color: Colors.white24,
          fontSize: isTvLayout ? 14 : 12,
          fontWeight: FontWeight.w900,
          letterSpacing: 1.5,
        ),
      ),
    );

    if (!isTvLayout) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          header,
          if (devices.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 60),
              child: Center(
                child: CircularProgressIndicator(
                  color: Color(0xFFFFD600),
                  strokeWidth: 2,
                ),
              ),
            )
          else
            ...devices.map((device) => _buildDeviceCard(device, false)),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        header,
        Expanded(
          child:
              devices.isEmpty
                  ? const Center(
                    child: CircularProgressIndicator(
                      color: Color(0xFFFFD600),
                      strokeWidth: 2,
                    ),
                  )
                  : ListView.separated(
                    physics: const BouncingScrollPhysics(),
                    itemCount: devices.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 12),
                    itemBuilder: (context, index) {
                      return _buildDeviceCard(devices[index], true);
                    },
                  ),
        ),
      ],
    );
  }

  Widget _buildDeviceCard(DiscoveredDevice device, bool isTvLayout) {
    final isSelected = selectedTargets.contains(device.ipAddress);
    return FocusSurface(
      onTap: () => onDeviceSelect(device.ipAddress),
      builder: (isFocused) {
        return AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          margin: EdgeInsets.symmetric(
            horizontal: isTvLayout ? 0 : 24,
            vertical: isTvLayout ? 6 : 8,
          ),
          decoration: BoxDecoration(
            color: const Color(0xFF1C1C1E),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
              color:
                  isFocused
                      ? const Color(0xFFFFD600)
                      : isSelected
                      ? const Color(0xFFFFD600)
                      : Colors.white.withOpacity(0.05),
              width: isFocused || isSelected ? 2 : 1,
            ),
            boxShadow:
                isFocused
                    ? [
                      BoxShadow(
                        color: const Color(0xFFFFD600).withOpacity(0.3),
                        blurRadius: 12,
                        offset: const Offset(0, 6),
                      ),
                    ]
                    : null,
          ),
          child: ListTile(
            contentPadding: EdgeInsets.symmetric(
              horizontal: isTvLayout ? 24 : 20,
              vertical: isTvLayout ? 12 : 8,
            ),
            onTap: () => onDeviceSelect(device.ipAddress),
            leading: Container(
              width: isTvLayout ? 60 : 52,
              height: isTvLayout ? 60 : 52,
              decoration: BoxDecoration(
                color: Colors.black,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Icon(
                _getDeviceIcon(device.deviceName),
                color: isSelected ? const Color(0xFFFFD600) : Colors.white10,
                size: isTvLayout ? 30 : 26,
              ),
            ),
            title: Text(
              device.deviceName,
              style: GoogleFonts.outfit(
                color: Colors.white,
                fontWeight: FontWeight.w700,
                fontSize: isTvLayout ? 19 : 17,
              ),
            ),
            subtitle: Text(
              device.ipAddress,
              style: GoogleFonts.outfit(
                color: Colors.white12,
                fontSize: isTvLayout ? 14 : 13,
              ),
            ),
            trailing: Container(
              width: isTvLayout ? 28 : 24,
              height: isTvLayout ? 28 : 24,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: isSelected ? const Color(0xFFFFD600) : Colors.white10,
                  width: 2,
                ),
                color:
                    isSelected ? const Color(0xFFFFD600) : Colors.transparent,
              ),
              child:
                  isSelected
                      ? const Icon(Icons.check, size: 14, color: Colors.black)
                      : null,
            ),
          ),
        );
      },
    );
  }

  IconData _getDeviceIcon(String name) {
    final lower = name.toLowerCase();
    if (lower.contains('tv')) return Icons.tv_rounded;
    if (lower.contains('phone')) return Icons.smartphone_rounded;
    return Icons.laptop_rounded;
  }
}
