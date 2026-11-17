import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../utils/responsive.dart';
import '../services/ble_service.dart';
import '../services/workout_store.dart';
import '../models/cable_exercise.dart';
import '../models/motion_reconstructor.dart';
import '../models/track_sample.dart';
import '../models/workout_session.dart';
import '../widgets/anatomy_viewer.dart';
import '../widgets/ble_status_chip.dart';

/// Live cable-machine tracking, shown on the 3D figure.
///
/// The tracker sits on the weight stack and reports one number: how high the
/// stack is. Before Start the figure plays the exercise as a guide. After
/// Start it follows the user instead: [MotionReconstructor] turns the stack
/// height into progress through the rep, and the figure, the machine and the
/// muscle highlights move with it.
///
/// Works with the real tracker over Bluetooth, the USB test link, or the
/// built-in simulation when no tracker is around.
class CableTrackScreen extends StatefulWidget {
  /// The workout being performed; picks the exercise the figure shows.
  final String workoutName;

  const CableTrackScreen({super.key, this.workoutName = 'Cable Workout'});

  @override
  State<CableTrackScreen> createState() => _CableTrackScreenState();
}

class _CableTrackScreenState extends State<CableTrackScreen> {
  final BleService _ble = BleService.instance;
  final AnatomyViewerController _viewer = AnatomyViewerController();
  final MotionReconstructor _motion = MotionReconstructor();
  late final CableExercise _exercise;
  StreamSubscription<TrackSample>? _sub;

  TrackSample? _last;
  bool _running = false;
  bool _following = false; // the figure is driven by the tracker right now
  bool _modelReady = false;
  DateTime? _startedAt;
  double _minCm = 0, _maxCm = 0; // range of motion during the set
  int _lastPushMs = 0;

  @override
  void initState() {
    super.initState();
    _exercise =
        cableExerciseByName(widget.workoutName) ?? cableExercises.first;
    _sub = _ble.trackStream.listen(_onSample);
    _ble.connectionState.addListener(_onLinkChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_ble.isConnected) _ble.connect();
    });
  }

  @override
  void dispose() {
    _ble.connectionState.removeListener(_onLinkChanged);
    _sub?.cancel();
    if (_running) _ble.sendCommand(TrackCommand.stop);
    super.dispose();
  }

  void _onLinkChanged() {
    if (!mounted) return;
    // Losing the link mid-set: hand the figure back to the guide animation.
    if (!_ble.isConnected && _following) _follow(false);
    setState(() {});
  }

  /// Switch the figure between the guide animation and following the tracker.
  void _follow(bool on) {
    _following = on;
    _viewer.setLive(on);
  }

  void _onSample(TrackSample s) {
    if (!mounted) return;
    final tracking = _running && s.state == TrackState.tracking;
    if (tracking) {
      if (!_following) {
        _motion.reset();
        _follow(true);
      }
      final progress = _motion.update(s.position);
      // The page eases between updates, so 25 a second is plenty.
      if (s.timestampMs - _lastPushMs >= 40 || s.timestampMs < _lastPushMs) {
        _lastPushMs = s.timestampMs;
        _viewer.setProgress(progress);
      }
    } else if (_following) {
      _follow(false);
    }
    setState(() {
      _last = s;
      if (!tracking) return;
      final cm = s.position * 100;
      _minCm = min(_minCm, cm);
      _maxCm = max(_maxCm, cm);
    });
  }

  Future<void> _start() async {
    final ok = await _ble.sendCommand(TrackCommand.start);
    if (!mounted) return;
    if (!ok) {
      _toast('Could not send Start. Check the connection.');
      return;
    }
    _motion.reset();
    setState(() {
      _running = true;
      _minCm = _maxCm = 0;
      _startedAt = DateTime.now();
    });
  }

  Future<void> _stop() async {
    await _ble.sendCommand(TrackCommand.stop);
    final reps = _last?.reps ?? 0;
    final dur = _startedAt == null
        ? 0
        : DateTime.now().difference(_startedAt!).inSeconds;
    final rangeCm = _maxCm - _minCm;
    // A simulated set is a demo: it must not count as training.
    final simulated = _ble.simulation.value;
    if (reps > 0 && !simulated) {
      await WorkoutStore.instance.addSession(WorkoutSession(
        workoutName: widget.workoutName,
        reps: reps,
        accuracy: 0,
        performance: '-',
        bonus: 0,
        durationSec: dur,
        timestamp: DateTime.now(),
      ));
    }
    if (!mounted) return;
    _follow(false);
    setState(() => _running = false);
    await _showSummary(reps, dur, rangeCm, simulated);
  }

  Future<void> _showSummary(
      int reps, int durSec, double rangeCm, bool simulated) {
    String mmss(int s) =>
        '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
    Widget cell(String label, String value) => Expanded(
          child: Column(
            children: [
              Text(value,
                  style: const TextStyle(
                      color: AppTheme.neonGreen,
                      fontSize: 22,
                      fontWeight: FontWeight.w800)),
              const SizedBox(height: 2),
              Text(label,
                  style: const TextStyle(
                      color: AppTheme.textSecondary, fontSize: 12)),
            ],
          ),
        );
    final String closeLabel;
    if (simulated) {
      closeLabel = 'Close (simulation, not saved)';
    } else {
      closeLabel = reps > 0 ? 'Saved. Done' : 'Close';
    }
    return showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: AppTheme.cardBg,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.emoji_events_rounded,
                  color: AppTheme.neonGreen, size: 48),
              const SizedBox(height: 8),
              Text(reps > 0 ? 'Set complete' : 'No reps recorded',
                  style: const TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: 20,
                      fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Text(widget.workoutName,
                  style: const TextStyle(
                      color: AppTheme.textSecondary, fontSize: 13)),
              const SizedBox(height: 20),
              Row(children: [
                cell('Reps', '$reps'),
                cell('Range', '${rangeCm.toStringAsFixed(0)} cm'),
                cell('Time', mmss(durSec)),
              ]),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: Text(closeLabel),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _zero() async {
    await _ble.sendCommand(TrackCommand.zero);
    _motion.reset();
  }

  void _toast(String m) => ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(m), behavior: SnackBarBehavior.floating));

  String get _statusText {
    final s = _last?.state;
    if (!_ble.isConnected) return 'No tracker connected';
    if (!_running) return 'Clip the tracker on the weight stack, then press Start';
    switch (s) {
      case TrackState.calibrating:
        return 'Hold still. Measuring gravity…';
      case TrackState.tracking:
        return _motion.peaks == 0
            ? 'Tracking. Do one full rep to set your range'
            : 'Tracking. The figure follows your movement';
      case TrackState.calibFailed:
        return 'The tracker moved during calibration. Press Start again';
      case TrackState.idle:
      case null:
        return 'Waiting for the tracker…';
    }
  }

  Color get _statusColor {
    if (!_ble.isConnected) return AppTheme.textSecondary;
    switch (_last?.state) {
      case TrackState.tracking:
        return AppTheme.neonGreen;
      case TrackState.calibrating:
        return const Color(0xFFFFC857);
      case TrackState.calibFailed:
        return const Color(0xFFFF6B6B);
      default:
        return AppTheme.textSecondary;
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = _last;
    final tracking = _running && s?.state == TrackState.tracking;
    final connected = _ble.isConnected;
    return Scaffold(
      backgroundColor: AppTheme.darkBg,
      appBar: AppBar(
        leading: IconButton(
          onPressed: () => Navigator.pop(context),
          icon: const Icon(Icons.arrow_back_ios_new_rounded),
        ),
        title: Text(widget.workoutName),
        actions: const [
          Padding(
            padding: EdgeInsets.only(right: 12, top: 10, bottom: 10),
            child: BleStatusChip(),
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: EdgeInsets.all(Responsive.w(context, 16)),
          child: ValueListenableBuilder<bool>(
            valueListenable: _ble.trackSupported,
            builder: (context, supported, _) {
              if (connected && !supported) {
                return const _Notice(
                  icon: Icons.memory_rounded,
                  text: 'This device firmware does not support live tracking.\n'
                      'Flash firmware/Gympath_Track to enable it.',
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Icon(Icons.circle, size: 10, color: _statusColor),
                      SizedBox(width: Responsive.w(context, 8)),
                      Expanded(
                        child: Text(_statusText,
                            style: TextStyle(
                                color: _statusColor,
                                fontSize: Responsive.sp(context, 13),
                                fontWeight: FontWeight.w600)),
                      ),
                    ],
                  ),
                  SizedBox(height: Responsive.h(context, 12)),
                  Row(
                    children: [
                      _Stat(label: 'Reps', value: '${s?.reps ?? 0}', big: true),
                      SizedBox(width: Responsive.w(context, 10)),
                      _Stat(
                          label: 'Stack height',
                          value: tracking
                              ? '${(_motion.heightM * 100).toStringAsFixed(0)} cm'
                              : '—'),
                      SizedBox(width: Responsive.w(context, 10)),
                      _Stat(
                          label: 'Velocity',
                          value: tracking
                              ? '${s!.velocity.toStringAsFixed(2)} m/s'
                              : '—'),
                    ],
                  ),
                  SizedBox(height: Responsive.h(context, 14)),
                  Expanded(child: _buildFigure(tracking)),
                  SizedBox(height: Responsive.h(context, 14)),
                  if (connected) _buildSetControls(tracking) else _buildLinkControls(),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  /// The 3D figure, with the stack-travel gauge beside it while tracking.
  Widget _buildFigure(bool tracking) {
    final radius = BorderRadius.circular(Responsive.r(context, 18));
    return ClipRRect(
      borderRadius: radius,
      child: Container(
        decoration: BoxDecoration(
          color: AnatomyViewer.background,
          borderRadius: radius,
          border: Border.all(color: AppTheme.cardBgLight),
        ),
        child: Stack(children: [
          Positioned.fill(
            child: AnatomyViewer(
              exercise: _exercise,
              controller: _viewer,
              onStatus: (_, ready) {
                if (ready != _modelReady) setState(() => _modelReady = ready);
              },
            ),
          ),
          if (!_modelReady)
            const Positioned.fill(
              child: ColoredBox(
                color: AnatomyViewer.background,
                child: Center(
                  child: SizedBox(
                    width: 26,
                    height: 26,
                    child: CircularProgressIndicator(
                        strokeWidth: 2.5, color: AppTheme.neonGreen),
                  ),
                ),
              ),
            ),
          Positioned(
            left: 12,
            top: 12,
            child: IgnorePointer(
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: .55),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                      color: tracking ? AppTheme.neonGreen : Colors.white12),
                ),
                child: Text(tracking ? 'LIVE · YOUR MOVEMENT' : 'GUIDE',
                    style: TextStyle(
                        color: tracking ? AppTheme.neonGreen : Colors.white70,
                        fontSize: 9,
                        letterSpacing: 1,
                        fontWeight: FontWeight.w700)),
              ),
            ),
          ),
          if (tracking)
            Positioned(
              right: 12,
              top: 12,
              bottom: 12,
              child: IgnorePointer(child: _TravelGauge(progress: _motion.progress)),
            ),
        ]),
      ),
    );
  }

  Widget _buildSetControls(bool tracking) {
    return Row(
      children: [
        Expanded(
          flex: 3,
          child: ElevatedButton.icon(
            onPressed: _running ? _stop : _start,
            icon: Icon(
                _running ? Icons.stop_rounded : Icons.play_arrow_rounded),
            label: Text(_running ? 'Stop' : 'Start'),
            style: ElevatedButton.styleFrom(
              backgroundColor:
                  _running ? const Color(0xFFFF5577) : AppTheme.neonGreen,
              foregroundColor: Colors.black,
              padding:
                  EdgeInsets.symmetric(vertical: Responsive.h(context, 15)),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(999)),
            ),
          ),
        ),
        SizedBox(width: Responsive.w(context, 10)),
        Expanded(
          flex: 2,
          child: OutlinedButton.icon(
            onPressed: tracking ? _zero : null,
            icon: const Icon(Icons.vertical_align_center_rounded),
            label: const Text('Zero'),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppTheme.neonGreen,
              side: BorderSide(
                  color: tracking ? AppTheme.neonGreen : AppTheme.cardBgLight),
              padding:
                  EdgeInsets.symmetric(vertical: Responsive.h(context, 15)),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(999)),
            ),
          ),
        ),
      ],
    );
  }

  /// No tracker yet: look for it, or run the built-in simulation.
  Widget _buildLinkControls() {
    final state = _ble.connectionState.value;
    final busy = state == BleConnectionState.scanning ||
        state == BleConnectionState.connecting;
    final error = _ble.lastError.value;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (error != null && !busy)
          Padding(
            padding: EdgeInsets.only(bottom: Responsive.h(context, 8)),
            child: Text(error,
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: const Color(0xFFFF6B6B),
                    fontSize: Responsive.sp(context, 12))),
          ),
        Row(
          children: [
            Expanded(
              flex: 3,
              child: ElevatedButton.icon(
                onPressed: busy ? null : () => _ble.connect(),
                icon: const Icon(Icons.bluetooth_searching_rounded),
                label: Text(busy ? 'Searching…' : 'Connect tracker'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.neonGreen,
                  foregroundColor: Colors.black,
                  padding: EdgeInsets.symmetric(
                      vertical: Responsive.h(context, 15)),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(999)),
                ),
              ),
            ),
            SizedBox(width: Responsive.w(context, 10)),
            Expanded(
              flex: 2,
              child: OutlinedButton.icon(
                onPressed: () => _ble.startSimulation(),
                icon: const Icon(Icons.science_rounded),
                label: const Text('Simulate'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFFFFC94D),
                  side: const BorderSide(color: Color(0xFFFFC94D)),
                  padding: EdgeInsets.symmetric(
                      vertical: Responsive.h(context, 15)),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(999)),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// Vertical bar: how far the weight stack is through the user's own range.
class _TravelGauge extends StatelessWidget {
  final double progress;
  const _TravelGauge({required this.progress});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text('${(progress * 100).round()}%',
            style: const TextStyle(
                color: AppTheme.neonGreen,
                fontSize: 11,
                fontWeight: FontWeight.w800)),
        const SizedBox(height: 6),
        Expanded(
          child: Container(
            width: 10,
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: .55),
              borderRadius: BorderRadius.circular(5),
              border: Border.all(color: Colors.white12),
            ),
            child: FractionallySizedBox(
              alignment: Alignment.bottomCenter,
              heightFactor: progress.clamp(0.02, 1.0),
              child: Container(
                decoration: BoxDecoration(
                  color: AppTheme.neonGreen,
                  borderRadius: BorderRadius.circular(5),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 6),
        const Text('STACK',
            style: TextStyle(
                color: Colors.white54,
                fontSize: 7.5,
                letterSpacing: 1,
                fontWeight: FontWeight.w700)),
      ],
    );
  }
}

class _Stat extends StatelessWidget {
  final String label;
  final String value;
  final bool big;

  const _Stat({required this.label, required this.value, this.big = false});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: EdgeInsets.symmetric(
            horizontal: Responsive.w(context, 12),
            vertical: Responsive.h(context, 10)),
        decoration: BoxDecoration(
          color: AppTheme.cardBg,
          borderRadius: BorderRadius.circular(Responsive.r(context, 12)),
          border: Border.all(color: AppTheme.cardBgLight),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label,
                style: TextStyle(
                    color: AppTheme.textSecondary,
                    fontSize: Responsive.sp(context, 11))),
            SizedBox(height: Responsive.h(context, 2)),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(value,
                  style: TextStyle(
                      color: big ? AppTheme.neonGreen : AppTheme.textPrimary,
                      fontSize: Responsive.sp(context, big ? 22 : 15),
                      fontWeight: FontWeight.w700)),
            ),
          ],
        ),
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  final IconData icon;
  final String text;

  const _Notice({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: AppTheme.textMuted, size: Responsive.r(context, 48)),
          SizedBox(height: Responsive.h(context, 12)),
          Text(text,
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: AppTheme.textSecondary,
                  fontSize: Responsive.sp(context, 14))),
        ],
      ),
    );
  }
}
