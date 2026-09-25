import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../utils/responsive.dart';
import '../services/ble_service.dart';

/// Small pill showing the live BLE link state. Tapping it triggers a connect
/// attempt when disconnected, so the user can always see and act on the link.
class BleStatusChip extends StatelessWidget {
  const BleStatusChip({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<BleConnectionState>(
      valueListenable: BleService.instance.connectionState,
      builder: (context, state, _) {
        final (color, label, icon) = _style(state);
        final busy = state == BleConnectionState.scanning ||
            state == BleConnectionState.connecting;
        return InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: busy
              ? null
              : () {
                  if (state != BleConnectionState.connected) {
                    BleService.instance.connect();
                  }
                },
          child: Container(
            padding: EdgeInsets.symmetric(
              horizontal: Responsive.w(context, 12),
              vertical: Responsive.h(context, 6),
            ),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: color.withValues(alpha: 0.5)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (busy)
                  SizedBox(
                    width: Responsive.r(context, 12),
                    height: Responsive.r(context, 12),
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation(color),
                    ),
                  )
                else
                  Icon(icon, color: color, size: Responsive.r(context, 14)),
                SizedBox(width: Responsive.w(context, 6)),
                // When connected, append the live packet count so data flow is
                // visible at a glance (climbs ~50/s while the device streams).
                ValueListenableBuilder<int>(
                  valueListenable: BleService.instance.packetCount,
                  builder: (context, pkts, _) => Text(
                    state == BleConnectionState.connected && pkts > 0
                        ? '$label · $pkts'
                        : label,
                    style: TextStyle(
                      color: color,
                      fontSize: Responsive.sp(context, 12),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  (Color, String, IconData) _style(BleConnectionState state) {
    switch (state) {
      case BleConnectionState.connected:
        return (AppTheme.neonGreen, 'Connected', Icons.bluetooth_connected_rounded);
      case BleConnectionState.scanning:
        return (AppTheme.neonGreen, 'Scanning', Icons.bluetooth_searching_rounded);
      case BleConnectionState.connecting:
        return (AppTheme.neonGreen, 'Connecting', Icons.bluetooth_searching_rounded);
      case BleConnectionState.error:
        return (const Color(0xFFFF6B6B), 'No device', Icons.bluetooth_disabled_rounded);
      case BleConnectionState.disconnected:
        return (AppTheme.textMuted, 'Connect', Icons.bluetooth_rounded);
    }
  }
}
