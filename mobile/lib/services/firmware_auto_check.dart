import 'dart:async';

import 'package:flutter/material.dart';

import '../models/track_sample.dart';
import '../screens/firmware_update_screen.dart';
import '../theme/app_theme.dart';
import 'ble_service.dart';
import 'firmware_update_service.dart';

/// The app's navigator, so services can show dialogs (set on MaterialApp).
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

/// When the tracker connects, looks for newer firmware and asks the user
/// whether to install it; "Update" opens the update screen, which installs
/// it to the end.
///
/// - Asks once per version per app run ("Later" waits for the next launch).
/// - Never interrupts a set: waits until the tracker is idle.
/// - Stays quiet on errors (offline, no update server): the manual check on
///   the update screen still reports them.
class FirmwareAutoCheck {
  FirmwareAutoCheck._();
  static final FirmwareAutoCheck instance = FirmwareAutoCheck._();

  final _ble = BleService.instance;
  final _fw = FirmwareUpdateService.instance;
  final Set<String> _asked = {};
  TrackState _deviceState = TrackState.idle;
  StreamSubscription<TrackSample>? _trackSub;
  bool _started = false;
  bool _checking = false;

  void start() {
    if (_started) return;
    _started = true;
    _ble.otaSupported.addListener(_onOta);
    _trackSub = _ble.trackStream.listen((s) => _deviceState = s.state);
  }

  void _onOta() {
    if (_ble.otaSupported.value) {
      // let the connection settle (subscriptions, day summary) first
      Future.delayed(const Duration(seconds: 2), check);
    }
  }

  /// Whether to offer [latest] to a tracker running [installed].
  static bool shouldOffer(String? installed, String latest, Set<String> asked) =>
      installed != null &&
      installed.isNotEmpty &&
      !asked.contains(latest) &&
      FirmwareUpdateService.isNewer(latest, installed);

  Future<void> check() async {
    if (_checking || !_ble.otaSupported.value || _ble.simulation.value) return;
    if (FirmwareUpdateScreen.isOpen) return;
    _checking = true;
    try {
      final installed = await _ble.readFirmwareVersion();
      final FirmwareManifest latest;
      try {
        latest = await _fw.fetchManifest();
      } catch (_) {
        return; // offline or no server: try again on the next connection
      }
      if (!_ble.otaSupported.value) return; // disconnected meanwhile
      if (!shouldOffer(installed, latest.version, _asked)) return;
      // never in the middle of a set
      for (var i = 0; i < 120 && _deviceState != TrackState.idle; i++) {
        await Future<void>.delayed(const Duration(seconds: 5));
        if (!_ble.otaSupported.value) return;
      }
      if (_deviceState != TrackState.idle || !_ble.otaSupported.value) return;
      if (FirmwareUpdateScreen.isOpen) return;
      final ctx = appNavigatorKey.currentContext;
      if (ctx == null || !ctx.mounted) return;
      _asked.add(latest.version);
      final yes = await showDialog<bool>(
        context: ctx,
        builder: (c) => AlertDialog(
          backgroundColor: AppTheme.cardBg,
          icon: const Icon(Icons.system_update_rounded,
              color: AppTheme.neonGreen, size: 32),
          title: const Text('Tracker update available'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('$installed  →  ${latest.version}',
                    style: const TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 16,
                        fontWeight: FontWeight.w700)),
                if (latest.notes.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Text(_firstNote(latest.notes),
                      style: const TextStyle(
                          color: AppTheme.textSecondary, fontSize: 13)),
                ],
                const SizedBox(height: 10),
                const Text(
                    'Takes about a minute over Bluetooth. Keep the phone '
                    'next to the tracker.',
                    style: TextStyle(color: AppTheme.textMuted, fontSize: 12)),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(c, false),
                child: const Text('Later')),
            ElevatedButton(
              onPressed: () => Navigator.pop(c, true),
              style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.neonGreen,
                  foregroundColor: Colors.black),
              child: const Text('Update'),
            ),
          ],
        ),
      );
      if (yes != true) return;
      final nav = appNavigatorKey.currentState;
      if (nav == null || FirmwareUpdateScreen.isOpen) return;
      await nav.push(MaterialPageRoute(
          builder: (_) => const FirmwareUpdateScreen(autoInstall: true)));
    } finally {
      _checking = false;
    }
  }

  /// The newest release's notes only (the manifest lists every version).
  static String _firstNote(String notes) {
    final i = notes.indexOf(RegExp(r' \d+\.\d+\.\d+: '), 1);
    return i > 0 ? notes.substring(0, i) : notes;
  }

  void dispose() => _trackSub?.cancel();
}
