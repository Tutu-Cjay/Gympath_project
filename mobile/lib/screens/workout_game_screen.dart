import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../utils/responsive.dart';
import '../services/ble_service.dart';
import '../services/workout_store.dart';
import '../services/wave_store.dart';
import '../models/motion_data.dart';
import '../models/workout_session.dart';
import '../models/movement_wave.dart';
import '../widgets/ble_status_chip.dart';
import 'motion_log_screen.dart';

class ExerciseProfile {
  final String repLabel;
  final double zMin;
  final double zMax;
  final double accTarget;
  final double accRange;
  final int repsPerLoop;

  const ExerciseProfile({
    required this.repLabel,
    required this.zMin,
    required this.zMax,
    required this.accTarget,
    required this.accRange,
    required this.repsPerLoop,
  });
}

ExerciseProfile profileForWorkout(String name) {
  final n = name.toLowerCase();
  if (n.contains('pull')) {
    return const ExerciseProfile(
      repLabel: 'Pull Ups',
      zMin: -0.35,
      zMax: 0.35,
      accTarget: 1.0,
      accRange: 1.4,
      repsPerLoop: 4,
    );
  }
  if (n.contains('squat')) {
    return const ExerciseProfile(
      repLabel: 'Squats',
      zMin: -0.50,
      zMax: 0.50,
      accTarget: 1.2,
      accRange: 1.8,
      repsPerLoop: 4,
    );
  }
  if (n.contains('bench')) {
    return const ExerciseProfile(
      repLabel: 'Bench',
      zMin: -0.25,
      zMax: 0.25,
      accTarget: 0.9,
      accRange: 1.2,
      repsPerLoop: 3,
    );
  }
  if (n.contains('dead')) {
    return const ExerciseProfile(
      repLabel: 'Deadlift',
      zMin: -0.45,
      zMax: 0.45,
      accTarget: 1.1,
      accRange: 1.6,
      repsPerLoop: 4,
    );
  }
  return const ExerciseProfile(
    repLabel: 'Reps',
    zMin: -0.40,
    zMax: 0.40,
    accTarget: 1.0,
    accRange: 1.6,
    repsPerLoop: 4,
  );
}

class WorkoutGameScreen extends StatefulWidget {
  final String workoutName;

  const WorkoutGameScreen({super.key, required this.workoutName});

  @override
  State<WorkoutGameScreen> createState() => _WorkoutGameScreenState();
}

class _WorkoutGameScreenState extends State<WorkoutGameScreen> {
  final BleService _ble = BleService.instance;
  StreamSubscription<MotionData>? _sub;
  Timer? _calibTimer; // M3: drives the calibration bar even without BLE data
  DateTime? _startTime;
  bool _saved = false;

  // Reference wave (recorded once, then followed during the workout)
  MovementWave? _reference;
  Timer? _waveTimer; // animates the guide dot along the reference wave
  double _wavePhase = 0.0; // 0..1 position of the guide dot
  static const double _wavePeriodSec = 2.5; // one sweep of the wave

  // Recording a new reference
  bool _recording = false;
  final List<double> _recordRaw = [];
  Timer? _recordTimer;
  int _recordRemaining = 0; // seconds left while recording
  static const int _recordSeconds = 8;

  late ExerciseProfile _profile;

  double _progress = 0.15;
  int _reps = 0;
  double _accuracy = 98.0;
  int _bonus = 5;
  String _performance = 'A';
  double _posZ = 0.0;
  double _liveNorm = 0.5; // live normalized posZ/displacement, 0..1

  // v2 (B8) live values
  bool _isV2 = false;
  double _dispMag = 0.0;
  double _roll = 0.0;
  double _pitch = 0.0;
  double _yaw = 0.0;
  int _repPhase = 0;

  // Calibration
  bool _calibrating = true;
  DateTime? _calibStart;
  double _calibMinZ = double.infinity;
  double _calibMaxZ = -double.infinity;
  double _calibMinEnv = double.infinity;
  double _calibMaxEnv = -double.infinity;
  double _calibMaxDisp = 0.0;

  // Active tuning values
  late double _zMin;
  late double _zMax;
  late double _accTarget;
  late double _accRange;
  late int _repsPerLoop;
  double _dispRange = 0.30; // [m] full-rep displacement scale (v2)

  @override
  void initState() {
    super.initState();
    _profile = profileForWorkout(widget.workoutName);
    _zMin = _profile.zMin;
    _zMax = _profile.zMax;
    _accTarget = _profile.accTarget;
    _accRange = _profile.accRange;
    _repsPerLoop = max(1, _profile.repsPerLoop);

    _calibStart = DateTime.now();
    _startTime = DateTime.now();
    _sub = _ble.motionStream.listen(_onMotion);
    // M3: tick the UI during calibration so the progress bar advances and the
    // calibration phase ends on time even if no BLE packets arrive.
    _calibTimer = Timer.periodic(const Duration(milliseconds: 60), (_) {
      if (!_calibrating) return;
      final elapsed =
          DateTime.now().difference(_calibStart ?? DateTime.now());
      if (elapsed.inMilliseconds >= 2500) {
        _calibrating = false;
        _applyCalibration();
        _calibTimer?.cancel();
      }
      if (mounted) setState(() {});
    });
    // Load the previously recorded reference wave for this exercise.
    _reference = WaveStore.instance.forExercise(widget.workoutName);

    // Animate the guide dot continuously along the reference wave so it acts
    // as a pacing guide the user follows.
    _waveTimer = Timer.periodic(const Duration(milliseconds: 33), (_) {
      if (_recording) return;
      _wavePhase += 0.033 / _wavePeriodSec;
      if (_wavePhase > 1.0) _wavePhase -= 1.0;
      if (mounted) setState(() {});
    });

    // Defer connect() out of initState: it synchronously flips
    // BleService.connectionState, which would rebuild the home BleStatusChip
    // mid-build → "setState() called during build".
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_ble.isConnected) _ble.connect();
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _calibTimer?.cancel();
    _waveTimer?.cancel();
    _recordTimer?.cancel();
    super.dispose();
  }

  void _startRecording() {
    setState(() {
      _recording = true;
      _recordRaw.clear();
      _recordRemaining = _recordSeconds;
    });
    _recordTimer?.cancel();
    _recordTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _recordRemaining--);
      if (_recordRemaining <= 0) _stopRecording();
    });
  }

  Future<void> _stopRecording() async {
    _recordTimer?.cancel();
    final wave = MovementWave.fromCapture(
      name: '${widget.workoutName} reference',
      exerciseKey: widget.workoutName.toLowerCase(),
      raw: List<double>.from(_recordRaw),
    );
    if (wave != null) {
      await WaveStore.instance.save(wave);
    }
    if (!mounted) return;
    setState(() {
      _recording = false;
      _reference = wave ?? _reference;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(wave != null
            ? 'Reference wave saved — follow the green guide'
            : 'Not enough movement captured — try again'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _saveSession() {
    if (_saved) return; // guard against double-save (Finish + back button)
    _saved = true;
    final dur = _startTime == null
        ? 0
        : DateTime.now().difference(_startTime!).inSeconds;
    WorkoutStore.instance.addSession(WorkoutSession(
      workoutName: widget.workoutName,
      reps: _reps,
      accuracy: _accuracy,
      performance: _performance,
      bonus: _bonus,
      durationSec: dur,
      timestamp: DateTime.now(),
    ));
  }

  void _applyCalibration() {
    final zRange = _calibMaxZ - _calibMinZ;
    final envRange = _calibMaxEnv - _calibMinEnv;
    if (zRange > 0.05) {
      final pad = max(0.03, zRange * 0.1);
      _zMin = _calibMinZ - pad;
      _zMax = _calibMaxZ + pad;
    }
    if (envRange > 0.1) {
      _accTarget = (_calibMinEnv + _calibMaxEnv) / 2;
      _accRange = max(0.6, envRange * 0.75);
    }
    if (_calibMaxDisp > 0.10) {
      _dispRange = max(0.15, _calibMaxDisp * 1.1);
    }
  }

  void _onMotion(MotionData data) {
    // capture the live posZ trajectory while recording a reference
    if (_recording) {
      _recordRaw.add(data.posZ);
    }
    if (_calibrating) {
      _calibMinZ = min(_calibMinZ, data.posZ);
      _calibMaxZ = max(_calibMaxZ, data.posZ);
      _calibMinEnv = min(_calibMinEnv, data.accEnv);
      _calibMaxEnv = max(_calibMaxEnv, data.accEnv);
      _calibMaxDisp = max(_calibMaxDisp, data.dispMag);
      final elapsed = DateTime.now().difference(_calibStart ?? DateTime.now());
      if (elapsed.inMilliseconds >= 2500) {
        _calibrating = false;
        _applyCalibration();
      }
    }

    // v2 (B8): rep progress from 3D displacement off the ZUPT origin —
    // works on any exercise axis. Fall back to posZ for v1 firmware.
    final normalized = data.isV2
        ? (data.dispMag / _dispRange).clamp(0.0, 1.0)
        : ((data.posZ - _zMin) / (_zMax - _zMin)).clamp(0.0, 1.0);
    final repIndex = data.motionCount % _repsPerLoop;
    final target = (repIndex + normalized) / _repsPerLoop;

    final acc = _calcAccuracy(data.accEnv, _accTarget, _accRange);
    final perf = _calcPerformance(acc);
    final bonus = acc >= 95 ? 5 : 0;

    setState(() {
      _progress = _lerp(_progress, target, 0.25);
      _reps = data.motionCount;
      _accuracy = acc;
      _performance = perf;
      _bonus = bonus;
      _posZ = data.posZ;
      _isV2 = data.isV2;
      _dispMag = data.dispMag;
      _roll = data.roll;
      _pitch = data.pitch;
      _yaw = data.yaw;
      _repPhase = data.repPhase;
      _liveNorm = normalized;
    });
  }

  Future<void> _onFinish() async {
    _saveSession();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.7),
      builder: (ctx) => Dialog(
        backgroundColor: AppTheme.cardBg,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Responsive.r(ctx, 20)),
        ),
        child: Padding(
          padding: EdgeInsets.all(Responsive.w(ctx, 24)),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.emoji_events_rounded,
                  color: AppTheme.neonGreen, size: Responsive.r(ctx, 56)),
              SizedBox(height: Responsive.h(ctx, 12)),
              Text('Workout Complete!',
                  style: TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: Responsive.sp(ctx, 20),
                      fontWeight: FontWeight.bold)),
              SizedBox(height: Responsive.h(ctx, 4)),
              Text(widget.workoutName,
                  style: TextStyle(
                      color: AppTheme.textSecondary,
                      fontSize: Responsive.sp(ctx, 13))),
              SizedBox(height: Responsive.h(ctx, 20)),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _ScorePill(label: 'Reps', value: '$_reps'),
                  _ScorePill(
                      label: 'Accuracy',
                      value: '${_accuracy.toStringAsFixed(0)}%'),
                  _ScorePill(label: 'Grade', value: _performance),
                  _ScorePill(label: 'Bonus', value: '+$_bonus'),
                ],
              ),
              SizedBox(height: Responsive.h(ctx, 20)),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Done'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (mounted) Navigator.pop(context);
  }

  double _lerp(double a, double b, double t) => a + (b - a) * t;

  double _calcAccuracy(double accEnv, double target, double range) {
    if (range <= 0.01) return 0;
    final score = 1.0 - ((accEnv - target).abs() / range);
    return (score.clamp(0.0, 1.0) * 100.0);
  }

  String _calcPerformance(double accuracy) {
    if (accuracy >= 97) return 'S';
    if (accuracy >= 92) return 'A';
    if (accuracy >= 85) return 'B';
    return 'C';
  }

  @override
  Widget build(BuildContext context) {
    final double calibPct = _calibStart == null
        ? 0
        : (DateTime.now().difference(_calibStart!).inMilliseconds / 2500)
            .clamp(0.0, 1.0)
            .toDouble();

    return Scaffold(
      backgroundColor: AppTheme.darkBg,
      appBar: AppBar(
        leading: IconButton(
          onPressed: () => Navigator.pop(context),
          icon: const Icon(Icons.arrow_back_ios_new_rounded),
        ),
        title: Text(widget.workoutName),
        actions: [
          // US1: connection status visible during the workout
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 10),
            child: BleStatusChip(),
          ),
          // Record / re-record the reference wave for this exercise
          IconButton(
            tooltip: _recording ? 'Stop recording' : 'Record reference wave',
            onPressed: _recording ? _stopRecording : _startRecording,
            icon: Icon(
              _recording
                  ? Icons.stop_circle_rounded
                  : Icons.fiber_manual_record_rounded,
              color: _recording ? const Color(0xFFFF5577) : null,
            ),
          ),
          IconButton(
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const MotionLogScreen()),
              );
            },
            icon: const Icon(Icons.show_chart_rounded),
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: EdgeInsets.all(Responsive.w(context, 20)),
          child: Column(
            children: [
              // Top score + progress
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _ScorePill(
                    label: _profile.repLabel,
                    value: _reps.toString(),
                  ),
                  Expanded(
                    child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: Responsive.w(context, 12)),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(999),
                        child: LinearProgressIndicator(
                          value: _progress,
                          minHeight: Responsive.h(context, 8),
                          backgroundColor: AppTheme.cardBgLight,
                          valueColor: const AlwaysStoppedAnimation(AppTheme.neonGreen),
                        ),
                      ),
                    ),
                  ),
                  _ScorePill(
                    label: 'Bonus',
                    value: '+$_bonus',
                  ),
                ],
              ),
              SizedBox(height: Responsive.h(context, 24)),
              // Track area
              Expanded(
                child: Container(
                  width: double.infinity,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(Responsive.r(context, 24)),
                    color: const Color(0xFF121212),
                    border: Border.all(color: AppTheme.cardBgLight),
                  ),
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Positioned.fill(
                        child: Opacity(
                          opacity: 0.18,
                          child: Container(
                            decoration: const BoxDecoration(
                              gradient: RadialGradient(
                                center: Alignment.topLeft,
                                radius: 1.2,
                                colors: [
                                  Color(0xFF203326),
                                  Color(0xFF101010),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                      CustomPaint(
                        size: Size.infinite,
                        painter: _WavePainter(
                          reference: _reference?.samples,
                          phase: _wavePhase,
                          recording: _recording,
                          recordRaw: _recordRaw,
                          liveNorm: _liveNorm,
                        ),
                      ),
                      // recording badge with countdown
                      if (_recording)
                        Positioned(
                          left: Responsive.w(context, 20),
                          top: Responsive.h(context, 16),
                          child: Container(
                            padding: EdgeInsets.symmetric(
                              horizontal: Responsive.w(context, 10),
                              vertical: Responsive.h(context, 5),
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xFFFF5577).withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(999),
                              border: Border.all(color: const Color(0xFFFF5577)),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.fiber_manual_record_rounded,
                                    color: Color(0xFFFF5577), size: 14),
                                SizedBox(width: Responsive.w(context, 6)),
                                Text(
                                  'REC  ${_recordRemaining}s — do one clean rep',
                                  style: const TextStyle(
                                      color: Color(0xFFFF8FA3), fontSize: 12),
                                ),
                              ],
                            ),
                          ),
                        ),
                      // hint when there is no reference yet
                      if (_reference == null && !_recording && !_calibrating)
                        Positioned(
                          left: Responsive.w(context, 20),
                          bottom: Responsive.h(context, 20),
                          child: Row(
                            children: [
                              const Icon(Icons.fiber_manual_record_rounded,
                                  color: Color(0xFFFF5577), size: 16),
                              SizedBox(width: Responsive.w(context, 6)),
                              Text(
                                'Tap ● to record a reference wave',
                                style: TextStyle(
                                  color: AppTheme.textSecondary,
                                  fontSize: Responsive.sp(context, 12),
                                ),
                              ),
                            ],
                          ),
                        ),
                      Positioned(
                        right: Responsive.w(context, 24),
                        top: Responsive.h(context, 90),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(Icons.check_circle_rounded,
                                    color: AppTheme.neonGreen,
                                    size: Responsive.r(context, 16)),
                                SizedBox(width: Responsive.w(context, 6)),
                                Text(
                                  '${_accuracy.toStringAsFixed(0)}% Accuracy',
                                  style: TextStyle(
                                    color: AppTheme.textPrimary,
                                    fontSize: Responsive.sp(context, 14),
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                            SizedBox(height: Responsive.h(context, 8)),
                            Row(
                              children: [
                                Icon(Icons.local_fire_department_rounded,
                                    color: AppTheme.neonGreen,
                                    size: Responsive.r(context, 16)),
                                SizedBox(width: Responsive.w(context, 6)),
                                Text(
                                  '+$_bonus High Accuracy Bonus',
                                  style: TextStyle(
                                    color: AppTheme.textSecondary,
                                    fontSize: Responsive.sp(context, 12),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      if (_calibrating)
                        Positioned.fill(
                          child: Container(
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha:0.55),
                              borderRadius: BorderRadius.circular(Responsive.r(context, 24)),
                            ),
                            child: Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    'Calibrating...'
                                    ,
                                    style: TextStyle(
                                      color: AppTheme.textPrimary,
                                      fontSize: Responsive.sp(context, 18),
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  SizedBox(height: Responsive.h(context, 12)),
                                  SizedBox(
                                    width: Responsive.w(context, 180),
                                    child: LinearProgressIndicator(
                                      value: calibPct,
                                      backgroundColor: AppTheme.cardBgLight,
                                      valueColor: const AlwaysStoppedAnimation(AppTheme.neonGreen),
                                    ),
                                  ),
                                  SizedBox(height: Responsive.h(context, 8)),
                                  Text(
                                    'Move through a full rep range',
                                    style: TextStyle(
                                      color: AppTheme.textSecondary,
                                      fontSize: Responsive.sp(context, 12),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              SizedBox(height: Responsive.h(context, 16)),
              // Performance row
              Row(
                children: [
                  _MetricChip(label: 'Performance', value: _performance),
                  SizedBox(width: Responsive.w(context, 12)),
                  _MetricChip(label: 'Accuracy', value: '${_accuracy.toStringAsFixed(0)}%'),
                  SizedBox(width: Responsive.w(context, 12)),
                  _MetricChip(label: 'Streak', value: '+$_bonus'),
                ],
              ),
              SizedBox(height: Responsive.h(context, 8)),
              // Live stats row
              Row(
                children: [
                  _isV2
                      ? _MetricChip(
                          label: _repPhase == 1 ? 'Disp · ACTIVE' : 'Disp · REST',
                          value: '${(_dispMag * 100).toStringAsFixed(0)} cm')
                      : _MetricChip(label: 'posZ', value: _posZ.toStringAsFixed(2)),
                  SizedBox(width: Responsive.w(context, 12)),
                  _MetricChip(label: 'Target', value: _accTarget.toStringAsFixed(2)),
                  SizedBox(width: Responsive.w(context, 12)),
                  _MetricChip(label: 'Range', value: _accRange.toStringAsFixed(2)),
                ],
              ),
              if (_isV2) ...[
                SizedBox(height: Responsive.h(context, 8)),
                // Pose row (B8): device orientation during the exercise
                Row(
                  children: [
                    _MetricChip(label: 'Roll', value: '${_roll.toStringAsFixed(0)}°'),
                    SizedBox(width: Responsive.w(context, 12)),
                    _MetricChip(label: 'Pitch', value: '${_pitch.toStringAsFixed(0)}°'),
                    SizedBox(width: Responsive.w(context, 12)),
                    _MetricChip(label: 'Yaw', value: '${_yaw.toStringAsFixed(0)}°'),
                  ],
                ),
              ],
              SizedBox(height: Responsive.h(context, 16)),
              // Finish button
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: _onFinish,
                  icon: const Icon(Icons.check_rounded),
                  label: const Text('Finish'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.neonGreen,
                    foregroundColor: Colors.black,
                    padding: EdgeInsets.symmetric(vertical: Responsive.h(context, 16)),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(Responsive.r(context, 999)),
                    ),
                  ),
                ),
              ),
              SizedBox(height: Responsive.h(context, 8)),
            ],
          ),
        ),
      ),
    );
  }
}

class _ScorePill extends StatelessWidget {
  final String label;
  final String value;

  const _ScorePill({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: Responsive.w(context, 12),
        vertical: Responsive.h(context, 8),
      ),
      decoration: BoxDecoration(
        color: AppTheme.cardBg,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: AppTheme.cardBgLight),
      ),
      child: Column(
        children: [
          Text(
            value,
            style: TextStyle(
              color: AppTheme.neonGreen,
              fontSize: Responsive.sp(context, 18),
              fontWeight: FontWeight.bold,
            ),
          ),
          Text(
            label,
            style: TextStyle(
              color: AppTheme.textSecondary,
              fontSize: Responsive.sp(context, 10),
            ),
          ),
        ],
      ),
    );
  }
}

class _MetricChip extends StatelessWidget {
  final String label;
  final String value;

  const _MetricChip({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: Responsive.w(context, 12),
          vertical: Responsive.h(context, 12),
        ),
        decoration: BoxDecoration(
          color: AppTheme.cardBg,
          borderRadius: BorderRadius.circular(Responsive.r(context, 12)),
          border: Border.all(color: AppTheme.cardBgLight),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: TextStyle(
                color: AppTheme.textSecondary,
                fontSize: Responsive.sp(context, 10),
              ),
            ),
            Text(
              value,
              style: TextStyle(
                color: AppTheme.textPrimary,
                fontSize: Responsive.sp(context, 16),
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Draws the recorded reference wave and a guide dot that rides along it; while
/// recording, draws the live posZ capture instead so the user sees it building.
class _WavePainter extends CustomPainter {
  final List<double>? reference; // normalized 0..1 samples
  final double phase; // 0..1 guide-dot position
  final bool recording;
  final List<double> recordRaw; // raw posZ captured so far
  final double liveNorm; // live normalized posZ 0..1

  _WavePainter({
    required this.reference,
    required this.phase,
    required this.recording,
    required this.recordRaw,
    required this.liveNorm,
  });

  double _yOf(double v, Size size) {
    final pad = size.height * 0.15;
    return pad + (1 - v.clamp(0.0, 1.0)) * (size.height - 2 * pad);
  }

  double _sampleAt(List<double> s, double t) {
    if (s.isEmpty) return 0.5;
    final x = t.clamp(0.0, 1.0) * (s.length - 1);
    final i = x.floor();
    final f = x - i;
    if (i >= s.length - 1) return s.last;
    return s[i] * (1 - f) + s[i + 1] * f;
  }

  @override
  void paint(Canvas canvas, Size size) {
    // baseline
    canvas.drawLine(
      Offset(0, size.height / 2),
      Offset(size.width, size.height / 2),
      Paint()..color = const Color(0x22FFFFFF),
    );

    if (recording) {
      _paintLiveCapture(canvas, size);
      return;
    }
    final ref = reference;
    if (ref == null || ref.length < 2) return;

    // reference wave polyline + glow
    final path = Path();
    for (int i = 0; i < ref.length; i++) {
      final x = i / (ref.length - 1) * size.width;
      final y = _yOf(ref[i], size);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = AppTheme.neonGreen.withValues(alpha: 0.25)
        ..style = PaintingStyle.stroke
        ..strokeWidth = size.width * 0.05
        ..strokeCap = StrokeCap.round
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 14),
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = AppTheme.neonGreen
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round,
    );

    // faint marker of the user's current level, to help them follow
    final liveY = _yOf(liveNorm, size);
    canvas.drawLine(
      Offset(0, liveY),
      Offset(size.width, liveY),
      Paint()
        ..color = Colors.white.withValues(alpha: 0.15)
        ..strokeWidth = 1,
    );

    // guide dot riding the reference wave at the current phase
    final dx = phase * size.width;
    final dy = _yOf(_sampleAt(ref, phase), size);
    canvas.drawCircle(
      Offset(dx, dy),
      size.width * 0.05,
      Paint()
        ..color = AppTheme.neonGreen.withValues(alpha: 0.35)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12),
    );
    canvas.drawCircle(
      Offset(dx, dy),
      size.width * 0.028,
      Paint()..color = AppTheme.neonGreen,
    );
  }

  void _paintLiveCapture(Canvas canvas, Size size) {
    if (recordRaw.length < 2) return;
    double lo = recordRaw.first, hi = recordRaw.first;
    for (final v in recordRaw) {
      lo = v < lo ? v : lo;
      hi = v > hi ? v : hi;
    }
    final range = (hi - lo).abs() < 1e-4 ? 1.0 : hi - lo;
    final path = Path();
    for (int i = 0; i < recordRaw.length; i++) {
      final x = i / (recordRaw.length - 1) * size.width;
      final y = _yOf((recordRaw[i] - lo) / range, size);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = const Color(0xFFFFAA33)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(covariant _WavePainter oldDelegate) => true;
}
