import 'package:flutter/foundation.dart';
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
        final busy = state == BleConnectionState.scanning ||
            state == BleConnectionState.connecting;
        final usb = BleService.instance.testLink.value;
        final (color, label, icon) = usb && state == BleConnectionState.connected
            ? (const Color(0xFFFFC94D), 'USB test', Icons.usb_rounded)
            : _style(state);
        return InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: busy
              ? null
              : () {
                  if (state != BleConnectionState.connected) {
                    BleService.instance.connect();
                  }
                },
          // debug builds: long-press → USB test link via tools/serial_bridge.py
          onLongPress: kDebugMode && !busy ? () => _testLinkDialog(context) : null,
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

  Future<void> _testLinkDialog(BuildContext context) async {
    final ble = BleService.instance;
    if (ble.testLink.value) {
      await ble.disconnect();
      return;
    }
    final ctrl = TextEditingController(text: '10.0.2.2:7700');
    final addr = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('USB test link'),
        content: TextField(
          controller: ctrl,
          decoration: const InputDecoration(
            labelText: 'serial_bridge.py host:port',
            helperText: 'Emulator → 10.0.2.2 is this PC',
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: const Text('Connect')),
        ],
      ),
    );
    ctrl.dispose();
    if (addr == null || addr.isEmpty) return;
    final i = addr.lastIndexOf(':');
    final host = i > 0 ? addr.substring(0, i) : addr;
    final port = i > 0 ? int.tryParse(addr.substring(i + 1)) ?? 7700 : 7700;
    await ble.connectTestLink(host: host, port: port);
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
