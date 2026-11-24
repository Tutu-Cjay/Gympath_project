import 'package:flutter/material.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../theme/app_theme.dart';
import '../utils/responsive.dart';
import '../services/ble_service.dart';
import '../services/firmware_update_service.dart';
import '../widgets/ble_status_chip.dart';

enum _Phase { idle, checking, ready, upToDate, downloading, flashing, done, error }

/// Check the published firmware (GitHub release) for a newer tracker
/// version and install it over BLE.
class FirmwareUpdateScreen extends StatefulWidget {
  /// Install as soon as a newer version is confirmed (the user already said
  /// yes in the update pop-up), and finish without further taps.
  final bool autoInstall;

  const FirmwareUpdateScreen({super.key, this.autoInstall = false});

  /// True while the screen is up (the pop-up does not ask then).
  static bool isOpen = false;

  @override
  State<FirmwareUpdateScreen> createState() => _FirmwareUpdateScreenState();
}

class _FirmwareUpdateScreenState extends State<FirmwareUpdateScreen> {
  final BleService _ble = BleService.instance;
  final FirmwareUpdateService _fw = FirmwareUpdateService.instance;

  _Phase _phase = _Phase.idle;
  String? _deviceVersion;
  FirmwareManifest? _latest;
  double _progress = 0;
  String? _error;
  int _attempt = 0; // > 0 while retrying after a failed transfer

  bool get _busy =>
      _phase == _Phase.checking ||
      _phase == _Phase.downloading ||
      _phase == _Phase.flashing;

  @override
  void initState() {
    super.initState();
    FirmwareUpdateScreen.isOpen = true;
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
  }

  @override
  void dispose() {
    FirmwareUpdateScreen.isOpen = false;
    WakelockPlus.disable().catchError((_) {});
    super.dispose();
  }

  Future<void> _check() async {
    setState(() {
      _phase = _Phase.checking;
      _error = null;
    });
    try {
      if (!_ble.isConnected) await _ble.connect();
      if (!_ble.isConnected) {
        throw Exception('Tracker not connected. Turn it on, keep it close, '
            'and try again.');
      }
      if (!_ble.otaSupported.value) {
        throw Exception('This tracker firmware cannot update over the air. '
            'Flash Gympath_Track once over USB first.');
      }
      _deviceVersion = await _ble.readFirmwareVersion();
      _latest = await _fw.fetchManifest();
      final newer = _deviceVersion == null ||
          FirmwareUpdateService.isNewer(_latest!.version, _deviceVersion!);
      if (!mounted) return;
      setState(() => _phase = newer ? _Phase.ready : _Phase.upToDate);
      if (newer && widget.autoInstall) await _install();
    } catch (e) {
      _fail(e);
    }
  }

  Future<void> _install() async {
    final m = _latest;
    if (m == null) return;
    // The phone's screen going off (auto-lock after ~30 s) pauses or drops
    // Bluetooth on many phones, which stopped updates part-way: keep it on.
    WakelockPlus.enable().catchError((_) {});
    try {
      setState(() {
        _phase = _Phase.downloading;
        _progress = 0;
      });
      final image = await _fw.download(m);
      // A transfer that breaks off (radio hiccup, link drop, or the stall
      // check of firmware before 1.3.1 firing at a random point) leaves the
      // old firmware running; start again, reconnecting first if needed.
      const attempts = 6;
      for (_attempt = 0;; _attempt++) {
        if (!mounted) return;
        setState(() {
          _phase = _Phase.flashing;
          _progress = 0;
        });
        try {
          if (!_ble.isConnected || !_ble.otaSupported.value) {
            await _ble.connect();
            for (var i = 0; i < 20 && !_ble.otaSupported.value; i++) {
              await Future<void>.delayed(const Duration(milliseconds: 250));
            }
            if (!_ble.otaSupported.value) throw Exception('Tracker not reconnected');
          }
          await _fw.flash(image, onProgress: (p) {
            if (mounted) setState(() => _progress = p);
          });
          break;
        } catch (e) {
          if (_attempt + 1 >= attempts) {
            throw Exception('$e (after $attempts tries)'
                .replaceFirst('Exception: ', ''));
          }
          debugPrint('[OTA] try ${_attempt + 1} failed: $e');
          await Future<void>.delayed(const Duration(seconds: 2));
        }
      }
      if (!mounted) return;
      setState(() => _phase = _Phase.done);
    } catch (e) {
      _fail(e);
    } finally {
      WakelockPlus.disable().catchError((_) {});
    }
  }

  void _fail(Object e) {
    if (!mounted) return;
    setState(() {
      _phase = _Phase.error;
      _error = e.toString().replaceFirst('Exception: ', '');
    });
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_busy, // don't let the user leave mid-update
      child: Scaffold(
        backgroundColor: AppTheme.darkBg,
        appBar: AppBar(
          title: const Text('Firmware Update'),
          actions: const [
            Padding(
              padding: EdgeInsets.only(right: 12, top: 10, bottom: 10),
              child: BleStatusChip(),
            ),
          ],
        ),
        body: SafeArea(
          child: Padding(
            padding: EdgeInsets.all(Responsive.w(context, 20)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _VersionCard(
                  device: _deviceVersion ?? '—',
                  latest: _latest?.version ?? '—',
                  notes: _latest?.notes,
                ),
                SizedBox(height: Responsive.h(context, 24)),
                _buildStatus(context),
                const Spacer(),
                if (_phase == _Phase.flashing)
                  Padding(
                    padding: EdgeInsets.only(bottom: Responsive.h(context, 12)),
                    child: const Text(
                      'Keep the phone next to the tracker and this screen open.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: AppTheme.textSecondary, fontSize: 13),
                    ),
                  ),
                _buildButton(context),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildStatus(BuildContext context) {
    switch (_phase) {
      case _Phase.idle:
      case _Phase.checking:
        return const _StatusRow(
            icon: Icons.sync_rounded, text: 'Checking for updates…', busy: true);
      case _Phase.upToDate:
        return const _StatusRow(
            icon: Icons.check_circle_rounded,
            text: 'Your tracker is up to date.',
            color: AppTheme.neonGreen);
      case _Phase.ready:
        return const _StatusRow(
            icon: Icons.system_update_rounded,
            text: 'A new firmware version is available.',
            color: AppTheme.neonGreen);
      case _Phase.downloading:
        return const _StatusRow(
            icon: Icons.cloud_download_rounded,
            text: 'Downloading and verifying…',
            busy: true);
      case _Phase.flashing:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
                _attempt > 0
                    ? 'Interrupted, trying again (${_attempt + 1}/6)… '
                        '${(_progress * 100).toStringAsFixed(0)}%'
                    : 'Installing… ${(_progress * 100).toStringAsFixed(0)}%',
                style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w600)),
            SizedBox(height: Responsive.h(context, 10)),
            ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: LinearProgressIndicator(
                value: _progress,
                minHeight: Responsive.h(context, 10),
                backgroundColor: AppTheme.cardBgLight,
                valueColor: const AlwaysStoppedAnimation(AppTheme.neonGreen),
              ),
            ),
          ],
        );
      case _Phase.done:
        return const _StatusRow(
            icon: Icons.verified_rounded,
            text: 'Update installed. The tracker is restarting and will '
                'reconnect automatically.',
            color: AppTheme.neonGreen);
      case _Phase.error:
        return _StatusRow(
            icon: Icons.error_outline_rounded,
            text: _error ?? 'Update failed',
            color: const Color(0xFFFF6B6B));
    }
  }

  Widget _buildButton(BuildContext context) {
    final (label, action) = switch (_phase) {
      _Phase.ready => ('Install update', _install),
      _Phase.error => ('Try again', _check),
      _Phase.upToDate => ('Check again', _check),
      _Phase.done => ('Done', () => Navigator.pop(context)),
      _ => ('Please wait…', null),
    };
    return ElevatedButton(
      onPressed: action,
      style: ElevatedButton.styleFrom(
        backgroundColor: AppTheme.neonGreen,
        disabledBackgroundColor: AppTheme.cardBgLight,
        foregroundColor: Colors.black,
        padding: EdgeInsets.symmetric(vertical: Responsive.h(context, 16)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
      ),
      child: Text(label,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
    );
  }
}

class _VersionCard extends StatelessWidget {
  final String device;
  final String latest;
  final String? notes;

  const _VersionCard({required this.device, required this.latest, this.notes});

  @override
  Widget build(BuildContext context) {
    Widget row(String k, String v) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(k, style: const TextStyle(color: AppTheme.textSecondary)),
              Text(v,
                  style: const TextStyle(
                      color: AppTheme.textPrimary, fontWeight: FontWeight.w700)),
            ],
          ),
        );
    return Container(
      padding: EdgeInsets.all(Responsive.w(context, 18)),
      decoration: BoxDecoration(
        color: AppTheme.cardBg,
        borderRadius: BorderRadius.circular(Responsive.r(context, 16)),
        border: Border.all(color: AppTheme.cardBgLight),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Smart Tracker',
              style: TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 17,
                  fontWeight: FontWeight.w700)),
          const SizedBox(height: 10),
          row('Installed', device),
          row('Latest', latest),
          if (notes != null && notes!.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(notes!,
                style: const TextStyle(
                    color: AppTheme.textSecondary, fontSize: 13)),
          ],
        ],
      ),
    );
  }
}

class _StatusRow extends StatelessWidget {
  final IconData icon;
  final String text;
  final Color color;
  final bool busy;

  const _StatusRow({
    required this.icon,
    required this.text,
    this.color = AppTheme.textSecondary,
    this.busy = false,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        busy
            ? SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                    strokeWidth: 2.5, valueColor: AlwaysStoppedAnimation(color)))
            : Icon(icon, color: color, size: 24),
        const SizedBox(width: 12),
        Expanded(
          child: Text(text,
              style: TextStyle(color: color, fontSize: 15, height: 1.4)),
        ),
      ],
    );
  }
}
