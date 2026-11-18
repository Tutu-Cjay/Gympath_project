import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/app_theme.dart';
import '../utils/responsive.dart';
import '../services/ble_service.dart';
import '../services/raw_export.dart';
import '../services/workout_store.dart';
import '../models/cable_exercise.dart';
import '../models/motion_reconstructor.dart';
import '../models/rep_analyzer.dart';
import '../models/track_sample.dart';
import '../models/workout_session.dart';
import '../widgets/anatomy_viewer.dart';
import '../widgets/ble_status_chip.dart';
import '../widgets/rep_bars.dart';
import '../widgets/set_summary_sheet.dart';

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
  static const int _defaultRestSec = 90;
  static const double _weightStep = 2.5;
  static const int _maxRawSamples = 60000; // 20 min at 50 Hz

  final BleService _ble = BleService.instance;
  final AnatomyViewerController _viewer = AnatomyViewerController();
  final MotionReconstructor _motion = MotionReconstructor();
  final RepAnalyzer _analyzer = RepAnalyzer();
  final List<TrackSample> _raw = [];
  late final CableExercise _exercise;
  late final String _workoutId;
  StreamSubscription<TrackSample>? _sub;

  TrackSample? _last;
  bool _running = false;
  bool _following = false; // the figure is driven by the tracker right now
  bool _modelReady = false;
  DateTime? _startedAt;
  int _lastPushMs = 0;

  double _weightKg = 20;
  int _setIndex = 1;
  int _savedSets = 0;

  Timer? _restTimer;
  int _restLeft = 0; // seconds; 0 = not resting

  @override
  void initState() {
    super.initState();
    _exercise =
        cableExerciseByName(widget.workoutName) ?? cableExercises.first;
    _workoutId = DateTime.now().millisecondsSinceEpoch.toString();
    final last = WorkoutStore.instance.training.lastWeight(widget.workoutName);
    if (last > 0) _weightKg = last;
    _sub = _ble.trackStream.listen(_onSample);
    _ble.connectionState.addListener(_onLinkChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_ble.isConnected) _ble.connect();
    });
  }

  @override
  void dispose() {
    _restTimer?.cancel();
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
    if (_running && _raw.length < _maxRawSamples) _raw.add(s);
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
      if (_analyzer.add(s) != null) HapticFeedback.lightImpact();
    } else if (_following) {
      _follow(false);
    }
    setState(() => _last = s);
  }

  Future<void> _start() async {
    _stopRest();
    final ok = await _ble.sendCommand(TrackCommand.start);
    if (!mounted) return;
    if (!ok) {
      _toast('Could not send Start. Check the connection.');
      return;
    }
    _motion.reset();
    _analyzer.reset();
    _raw.clear();
    setState(() {
      _running = true;
      _startedAt = DateTime.now();
    });
  }

  Future<void> _stop() async {
    await _ble.sendCommand(TrackCommand.stop);
    final reps = _last?.reps ?? 0;
    final dur = _startedAt == null
        ? 0
        : DateTime.now().difference(_startedAt!).inSeconds;
    final simulated = _ble.simulation.value;
    final set = WorkoutSession(
      workoutName: widget.workoutName,
      reps: reps,
      weightKg: _weightKg,
      repDetails: _analyzer.reps,
      workoutId: _workoutId,
      setIndex: _setIndex,
      durationSec: dur,
      timestamp: DateTime.now(),
      simulated: simulated,
    );
    // Simulated sets go into the history only when the user chose so; they
    // are marked, so they can be told apart and deleted in one go.
    final store = WorkoutStore.instance;
    final save = reps > 0 && (!simulated || store.saveSimulated.value);
    final record = save && store.training.isRecord(set);
    if (save) await store.addSession(set);
    if (!mounted) return;
    _follow(false);
    setState(() {
      _running = false;
      if (save) {
        _savedSets++;
        _setIndex++;
      }
    });
    if (record) HapticFeedback.heavyImpact();
    final raw = List<TrackSample>.of(_raw);
    while (mounted) {
      final action = await SetSummarySheet.show(
        context,
        set: set,
        saved: save,
        simulated: simulated,
        isRecord: record,
        canExport: raw.isNotEmpty,
      );
      if (!mounted) return;
      if (action == SetSummaryAction.export) {
        await _export(raw, simulated, set.timestamp);
        continue; // back to the summary
      }
      if (action == SetSummaryAction.finish) {
        Navigator.pop(context);
      } else if (save) {
        _startRest(_defaultRestSec); // next set (also when swiped away)
      }
      return;
    }
  }

  Future<void> _export(
      List<TrackSample> raw, bool simulated, DateTime at) async {
    final csv = RawExport.toCsv(raw,
        exercise: widget.workoutName,
        weightKg: _weightKg,
        simulated: simulated,
        recordedAt: at);
    try {
      await RawExport.share(csv, RawExport.fileName(widget.workoutName, at));
    } catch (e) {
      _toast('Export failed: $e');
    }
  }

  void _startRest(int seconds) {
    _restTimer?.cancel();
    setState(() => _restLeft = seconds);
    _restTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return t.cancel();
      setState(() => _restLeft--);
      if (_restLeft <= 3 && _restLeft > 0) HapticFeedback.selectionClick();
      if (_restLeft <= 0) {
        t.cancel();
        HapticFeedback.heavyImpact();
        _toast('Rest over. Ready for set $_setIndex');
      }
    });
  }

  void _stopRest() {
    _restTimer?.cancel();
    if (_restLeft != 0) setState(() => _restLeft = 0);
  }

  Future<void> _zero() async {
    await _ble.sendCommand(TrackCommand.zero);
    _motion.reset();
  }

  Future<void> _editWeight() async {
    final ctrl = TextEditingController(text: _fmtKg(_weightKg));
    final v = await showDialog<double>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.cardBg,
        title: const Text('Weight on the stack'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(suffixText: 'kg'),
          onSubmitted: (t) =>
              Navigator.pop(ctx, double.tryParse(t.replaceAll(',', '.'))),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(
                  ctx, double.tryParse(ctrl.text.replaceAll(',', '.'))),
              child: const Text('OK')),
        ],
      ),
    );
    if (v != null && v >= 0 && v <= 500) setState(() => _weightKg = v);
  }

  void _stepWeight(int dir) => setState(() =>
      _weightKg = (_weightKg + dir * _weightStep).clamp(0.0, 500.0).toDouble());

  Future<bool> _confirmLeave() async {
    if (!_running) return true;
    final leave = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.cardBg,
        title: const Text('Set in progress'),
        content: const Text('Stop tracking and leave? This set is not saved.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Keep going')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Leave')),
        ],
      ),
    );
    return leave == true;
  }

  void _toast(String m) => ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(m), behavior: SnackBarBehavior.floating));

  String get _statusText {
    final s = _last?.state;
    if (!_ble.isConnected) return 'No tracker connected';
    if (!_running) {
      return _restLeft > 0
          ? 'Resting before set $_setIndex'
          : 'Clip the tracker on the weight stack, set the weight, press Start';
    }
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
    final reps = _analyzer.reps;
    final lastRep = reps.isEmpty ? null : reps.last;
    return PopScope(
      canPop: !_running,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _confirmLeave() && mounted) {
          await _ble.sendCommand(TrackCommand.stop);
          if (!mounted) return;
          setState(() => _running = false);
          Navigator.pop(context);
        }
      },
      child: Scaffold(
        backgroundColor: AppTheme.darkBg,
        appBar: AppBar(
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
            padding: EdgeInsets.fromLTRB(Responsive.w(context, 16),
                Responsive.h(context, 8), Responsive.w(context, 16),
                Responsive.h(context, 14)),
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
                    SizedBox(height: Responsive.h(context, 10)),
                    _buildSetBar(),
                    if (connected && _ble.simulation.value) ...[
                      SizedBox(height: Responsive.h(context, 8)),
                      _buildSimulationSave(),
                    ],
                    SizedBox(height: Responsive.h(context, 10)),
                    Row(
                      children: [
                        _Stat(label: 'Reps', value: '${s?.reps ?? 0}', big: true),
                        SizedBox(width: Responsive.w(context, 8)),
                        _Stat(
                            label: 'Last rep speed',
                            value: lastRep == null
                                ? '—'
                                : '${lastRep.meanVelocity.toStringAsFixed(2)} m/s'),
                        SizedBox(width: Responsive.w(context, 8)),
                        _Stat(
                            label: 'Last rep range',
                            value: lastRep == null
                                ? (tracking
                                    ? '${(_motion.heightM * 100).toStringAsFixed(0)} cm'
                                    : '—')
                                : '${lastRep.rangeCm.toStringAsFixed(0)} cm'),
                      ],
                    ),
                    SizedBox(height: Responsive.h(context, 10)),
                    Expanded(child: _buildFigure(tracking)),
                    if (_running) ...[
                      SizedBox(height: Responsive.h(context, 8)),
                      RepBars(reps: reps, height: Responsive.h(context, 48)),
                    ],
                    if (_restLeft > 0) ...[
                      SizedBox(height: Responsive.h(context, 10)),
                      _buildRest(),
                    ],
                    SizedBox(height: Responsive.h(context, 12)),
                    if (connected) _buildSetControls(tracking) else _buildLinkControls(),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  /// Set number and the weight on the stack (locked while a set runs).
  Widget _buildSetBar() {
    final locked = _running;
    Widget stepBtn(IconData icon, int dir) => InkWell(
          onTap: locked ? null : () => _stepWeight(dir),
          borderRadius: BorderRadius.circular(10),
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Icon(icon,
                size: 20,
                color: locked ? AppTheme.textMuted : AppTheme.neonGreen),
          ),
        );
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: AppTheme.cardBg,
        borderRadius: BorderRadius.circular(Responsive.r(context, 12)),
        border: Border.all(color: AppTheme.cardBgLight),
      ),
      child: Row(children: [
        Text('SET $_setIndex',
            style: const TextStyle(
                color: AppTheme.neonGreen,
                fontSize: 13,
                letterSpacing: 1,
                fontWeight: FontWeight.w800)),
        if (_savedSets > 0)
          Text('  ·  $_savedSets done',
              style: const TextStyle(
                  color: AppTheme.textSecondary, fontSize: 12)),
        const Spacer(),
        stepBtn(Icons.remove_rounded, -1),
        GestureDetector(
          onTap: locked ? null : _editWeight,
          child: Container(
            constraints: const BoxConstraints(minWidth: 78),
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Text('${_fmtKg(_weightKg)} kg',
                style: TextStyle(
                    color: locked ? AppTheme.textSecondary : AppTheme.textPrimary,
                    fontSize: 17,
                    fontWeight: FontWeight.w700)),
          ),
        ),
        stepBtn(Icons.add_rounded, 1),
      ]),
    );
  }

  /// Simulation only: save the simulated sets to the history or not.
  Widget _buildSimulationSave() {
    const amber = Color(0xFFFFC94D);
    return ValueListenableBuilder<bool>(
      valueListenable: WorkoutStore.instance.saveSimulated,
      builder: (context, on, _) => Container(
        padding: const EdgeInsets.fromLTRB(12, 2, 4, 2),
        decoration: BoxDecoration(
          color: amber.withValues(alpha: .08),
          borderRadius: BorderRadius.circular(Responsive.r(context, 12)),
          border: Border.all(color: amber.withValues(alpha: .45)),
        ),
        child: Row(children: [
          const Icon(Icons.science_rounded, color: amber, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
                on
                    ? 'Simulation: sets are saved (marked SIM)'
                    : 'Simulation: sets are not saved',
                style: const TextStyle(
                    color: amber, fontSize: 12, fontWeight: FontWeight.w600)),
          ),
          Switch(
            value: on,
            onChanged: _running
                ? null
                : (v) => WorkoutStore.instance.setSaveSimulated(v),
            activeColor: amber,
          ),
        ]),
      ),
    );
  }

  Widget _buildRest() {
    final m = _restLeft ~/ 60, sec = _restLeft % 60;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
      decoration: BoxDecoration(
        color: AppTheme.neonGreen.withValues(alpha: .10),
        borderRadius: BorderRadius.circular(Responsive.r(context, 12)),
        border: Border.all(color: AppTheme.neonGreen.withValues(alpha: .5)),
      ),
      child: Row(children: [
        const Icon(Icons.timer_outlined, color: AppTheme.neonGreen, size: 20),
        const SizedBox(width: 8),
        Text('Rest $m:${sec.toString().padLeft(2, '0')}',
            style: const TextStyle(
                color: AppTheme.neonGreen,
                fontSize: 18,
                fontWeight: FontWeight.w800,
                fontFeatures: [FontFeature.tabularFigures()])),
        const Spacer(),
        TextButton(
          onPressed: () => setState(() => _restLeft += 15),
          child: const Text('+15 s'),
        ),
        TextButton(onPressed: _stopRest, child: const Text('Skip')),
      ]),
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

String _fmtKg(double v) =>
    v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
