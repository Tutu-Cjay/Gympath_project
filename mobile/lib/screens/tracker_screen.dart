import 'package:flutter/material.dart';

import '../services/ble_service.dart';
import '../theme/app_theme.dart';
import 'firmware_update_screen.dart';

/// A rep screen look the tracker can show (firmware Gympath_Track 1.5+).
class TrackerTheme {
  final int id; // value sent to the tracker
  final String name;
  final String description;
  const TrackerTheme(this.id, this.name, this.description);

  String get image => 'assets/tracker/theme_$id.png';
}

/// How the rep count's digits look (firmware 1.6+): the same on every theme.
class TrackerDigits {
  final int id; // value sent to the tracker
  final String name;
  const TrackerDigits(this.id, this.name);

  String get image => 'assets/tracker/digits_$id.png';
}

const List<TrackerDigits> trackerDigitStyles = [
  TrackerDigits(0, 'Segment'),
  TrackerDigits(1, 'Rounded'),
  TrackerDigits(2, 'Bold'),
  TrackerDigits(3, 'Light'),
];

const List<TrackerTheme> trackerThemes = [
  TrackerTheme(0, 'Classic', 'Segment digits, ring coloured by speed'),
  TrackerTheme(1, 'Stroke', 'The ring fills with each rep\'s travel'),
  TrackerTheme(2, 'Tempo', 'Lift / lower, and each rep\'s up and down time'),
  TrackerTheme(3, 'Minimal', 'Big count, a dot per rep'),
];

/// The tracker: link, battery, firmware, and how its rep screen looks.
class TrackerScreen extends StatefulWidget {
  const TrackerScreen({super.key});

  @override
  State<TrackerScreen> createState() => _TrackerScreenState();
}

class _TrackerScreenState extends State<TrackerScreen> {
  final _ble = BleService.instance;
  String? _version;
  String? _saving; // 't<id>' / 'd<id>' while it is being sent

  @override
  void initState() {
    super.initState();
    _ble.connectionState.addListener(_readVersion);
    _readVersion();
  }

  @override
  void dispose() {
    _ble.connectionState.removeListener(_readVersion);
    super.dispose();
  }

  Future<void> _readVersion() async {
    if (!_ble.isConnected) {
      if (mounted) setState(() => _version = null);
      return;
    }
    final v = await _ble.readFirmwareVersion();
    if (mounted) setState(() => _version = v);
  }

  Future<void> _pick({int? theme, int? digits}) async {
    setState(() => _saving = theme != null ? 't$theme' : 'd$digits');
    final ok = await _ble.setTrackerScreen(theme: theme, digits: digits);
    if (!mounted) return;
    setState(() => _saving = null);
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        behavior: SnackBarBehavior.floating,
        content: Text('Could not change the tracker screen. Is it connected?'),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.darkBg,
      appBar: AppBar(title: const Text('Tracker')),
      body: ValueListenableBuilder<BleConnectionState>(
        valueListenable: _ble.connectionState,
        builder: (context, link, _) {
          final connected = link == BleConnectionState.connected;
          return ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
            children: [
              _statusCard(connected),
              const SizedBox(height: 22),
              _heading('REP SCREEN'),
              const SizedBox(height: 4),
              const Text('What the tracker shows while it counts your reps.',
                  style: TextStyle(color: AppTheme.textMuted, fontSize: 12)),
              const SizedBox(height: 12),
              ValueListenableBuilder<int?>(
                valueListenable: _ble.trackerTheme,
                builder: (context, current, _) {
                  final supported = connected && current != null;
                  return Column(children: [
                    if (connected && current == null)
                      _note('Update the tracker to firmware 1.5 or newer to '
                          'choose its rep screen.'),
                    if (!connected)
                      _note('Connect the tracker to change its rep screen.'),
                    GridView.count(
                      crossAxisCount: 2,
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      mainAxisSpacing: 12,
                      crossAxisSpacing: 12,
                      childAspectRatio: 0.78,
                      children: [
                        for (final t in trackerThemes)
                          _OptionCard(
                            image: t.image,
                            name: t.name,
                            description: t.description,
                            selected: current == t.id,
                            busy: _saving == 't${t.id}',
                            enabled: supported && _saving == null,
                            onTap: () => _pick(theme: t.id),
                          ),
                      ],
                    ),
                  ]);
                },
              ),
              const SizedBox(height: 22),
              _heading('NUMBERS'),
              const SizedBox(height: 4),
              const Text('The style of the rep count, on every screen. It '
                  'always stays centred, however many digits.',
                  style: TextStyle(color: AppTheme.textMuted, fontSize: 12)),
              const SizedBox(height: 12),
              ValueListenableBuilder<int?>(
                valueListenable: _ble.trackerDigits,
                builder: (context, current, _) {
                  final supported = connected && current != null;
                  return Column(children: [
                    if (connected && current == null)
                      _note('Update the tracker to firmware 1.6 or newer to '
                          'choose its number style.'),
                    GridView.count(
                      crossAxisCount: 4,
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      mainAxisSpacing: 8,
                      crossAxisSpacing: 8,
                      childAspectRatio: 0.72,
                      children: [
                        for (final d in trackerDigitStyles)
                          _OptionCard(
                            image: d.image,
                            name: d.name,
                            selected: current == d.id,
                            busy: _saving == 'd${d.id}',
                            enabled: supported && _saving == null,
                            onTap: () => _pick(digits: d.id),
                            compact: true,
                          ),
                      ],
                    ),
                  ]);
                },
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _heading(String text) => Text(text,
      style: const TextStyle(
          color: AppTheme.textSecondary,
          fontSize: 11,
          letterSpacing: 1.2,
          fontWeight: FontWeight.w700));

  Widget _note(String text) => Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppTheme.cardBg,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(text,
            style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
      );

  Widget _statusCard(bool connected) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.cardBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
            color: connected ? AppTheme.neonGreen.withValues(alpha: .5) : AppTheme.cardBgLight),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.watch_rounded,
              color: connected ? AppTheme.neonGreen : AppTheme.textMuted, size: 30),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(connected ? 'Connected' : 'Not connected',
                  style: const TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: 16,
                      fontWeight: FontWeight.bold)),
              Text(
                  connected
                      ? 'Firmware ${_version ?? '…'}'
                      : 'Turn the tracker on and tap the link button on Home',
                  style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
            ]),
          ),
          ValueListenableBuilder<int?>(
            valueListenable: _ble.batteryPercent,
            builder: (context, b, _) => ValueListenableBuilder<bool>(
              valueListenable: _ble.batteryCharging,
              builder: (context, charging, _) => b == null || !connected
                  ? const SizedBox.shrink()
                  : Row(children: [
                      Icon(
                          charging
                              ? Icons.battery_charging_full_rounded
                              : Icons.battery_std_rounded,
                          color: b > 20 ? AppTheme.neonGreen : Colors.redAccent,
                          size: 20),
                      Text(' $b%',
                          style: const TextStyle(
                              color: AppTheme.textPrimary, fontWeight: FontWeight.w600)),
                    ]),
            ),
          ),
        ]),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const FirmwareUpdateScreen())),
            icon: const Icon(Icons.system_update_rounded, size: 18),
            label: const Text('Check for firmware updates'),
            style: OutlinedButton.styleFrom(
                foregroundColor: AppTheme.neonGreen,
                side: const BorderSide(color: AppTheme.cardBgLight)),
          ),
        ),
      ]),
    );
  }
}

class _OptionCard extends StatelessWidget {
  final String image, name;
  final String? description;
  final bool selected, busy, enabled, compact;
  final VoidCallback onTap;
  const _OptionCard(
      {required this.image,
      required this.name,
      this.description,
      required this.selected,
      required this.busy,
      required this.enabled,
      required this.onTap,
      this.compact = false});

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: enabled || selected ? 1 : 0.55,
      child: InkWell(
        borderRadius: BorderRadius.circular(compact ? 12 : 16),
        onTap: enabled && !selected ? onTap : null,
        child: Container(
          padding: EdgeInsets.all(compact ? 6 : 10),
          decoration: BoxDecoration(
            color: AppTheme.cardBg,
            borderRadius: BorderRadius.circular(compact ? 12 : 16),
            border: Border.all(
                color: selected ? AppTheme.neonGreen : AppTheme.cardBgLight,
                width: selected ? 2 : 1),
          ),
          child: Column(children: [
            Expanded(
              child: Stack(alignment: Alignment.center, children: [
                Image.asset(image, fit: BoxFit.contain),
                if (busy)
                  const CircularProgressIndicator(color: AppTheme.neonGreen),
                if (selected)
                  Positioned(
                    right: 0,
                    top: 0,
                    child: Icon(Icons.check_circle_rounded,
                        color: AppTheme.neonGreen, size: compact ? 16 : 22),
                  ),
              ]),
            ),
            SizedBox(height: compact ? 4 : 8),
            Text(name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: compact ? 12 : 14,
                    fontWeight: FontWeight.w700)),
            if (description != null) ...[
              const SizedBox(height: 2),
              Text(description!,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  style: const TextStyle(color: AppTheme.textSecondary, fontSize: 11)),
            ],
          ]),
        ),
      ),
    );
  }
}
