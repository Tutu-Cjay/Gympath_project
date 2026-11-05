import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../utils/responsive.dart';
import '../services/ble_service.dart';
import '../services/workout_store.dart';
import '../models/track_sample.dart';
import '../models/workout_session.dart';
import '../widgets/ble_status_chip.dart';

/// Live 1D cable-machine tracking.
///
/// Start → the device measures gravity where it sits, then streams the signed
/// position along the gravity axis (+ up / − down). The graph plots that
/// position (Y, cm) against time (X, s) as a scrolling tracking path.
class CableTrackScreen extends StatefulWidget {
  /// The workout being performed — every workout uses this tracking graph.
  final String workoutName;

  const CableTrackScreen({super.key, this.workoutName = 'Cable Workout'});

  @override
  State<CableTrackScreen> createState() => _CableTrackScreenState();
}

class _CableTrackScreenState extends State<CableTrackScreen> {
  final BleService _ble = BleService.instance;
  StreamSubscription<TrackSample>? _sub;

  static const double _windowSec = 10.0; // visible time span
  final List<Offset> _path = []; // (seconds since start, cm)
  int? _t0;
  TrackSample? _last;
  bool _running = false;
  DateTime? _startedAt;
  double _minCm = 0, _maxCm = 0; // range of motion during the set

  @override
  void initState() {
    super.initState();
    _sub = _ble.trackStream.listen(_onSample);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_ble.isConnected) _ble.connect();
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    if (_running) _ble.sendCommand(TrackCommand.stop);
    super.dispose();
  }

  void _onSample(TrackSample s) {
    if (!mounted) return;
    setState(() {
      _last = s;
      if (s.state != TrackState.tracking) return;
      _t0 ??= s.timestampMs;
      final t = (s.timestampMs - _t0!) / 1000.0;
      final cm = s.position * 100;
      _path.add(Offset(t, cm));
      _minCm = min(_minCm, cm);
      _maxCm = max(_maxCm, cm);
      // keep a little more than the visible window
      while (_path.isNotEmpty && _path.first.dx < t - _windowSec - 1) {
        _path.removeAt(0);
      }
    });
  }

  Future<void> _start() async {
    final ok = await _ble.sendCommand(TrackCommand.start);
    if (!mounted) return;
    if (!ok) {
      _toast('Could not send Start — check the connection');
      return;
    }
    setState(() {
      _running = true;
      _path.clear();
      _t0 = null;
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
    if (reps > 0) {
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
    setState(() => _running = false);
    await _showSummary(reps, dur, rangeCm);
  }

  Future<void> _showSummary(int reps, int durSec, double rangeCm) {
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
                  child: Text(reps > 0 ? 'Saved — Done' : 'Close'),
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
    setState(() {
      _path.clear();
      _t0 = null;
    });
  }

  void _toast(String m) => ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(m), behavior: SnackBarBehavior.floating));

  String get _statusText {
    final s = _last?.state;
    if (!_running) return 'Place the device, then press Start';
    switch (s) {
      case TrackState.calibrating:
        return 'Hold still — measuring gravity…';
      case TrackState.tracking:
        return _last!.still ? 'Tracking · still' : 'Tracking';
      case TrackState.calibFailed:
        return 'Device moved during calibration — press Start again';
      case TrackState.idle:
      case null:
        return 'Waiting for device…';
    }
  }

  Color get _statusColor {
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
              if (_ble.isConnected && !supported) {
                return _Notice(
                  icon: Icons.memory_rounded,
                  text: 'This device firmware does not support live tracking.\n'
                      'Flash firmware/Gympath_Track to enable it.',
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // status line
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
                  // stats
                  Row(
                    children: [
                      _Stat(label: 'Reps', value: '${s?.reps ?? 0}', big: true),
                      SizedBox(width: Responsive.w(context, 10)),
                      _Stat(
                          label: 'Position',
                          value: tracking
                              ? '${(s!.position * 100).toStringAsFixed(1)} cm'
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
                  // tracking path graph
                  Expanded(
                    child: Container(
                      decoration: BoxDecoration(
                        color: AppTheme.cardBg,
                        borderRadius:
                            BorderRadius.circular(Responsive.r(context, 18)),
                        border: Border.all(color: AppTheme.cardBgLight),
                      ),
                      child: ClipRRect(
                        borderRadius:
                            BorderRadius.circular(Responsive.r(context, 18)),
                        child: CustomPaint(
                          painter: _TrackPathPainter(
                            path: _path,
                            windowSec: _windowSec,
                          ),
                          child: const SizedBox.expand(),
                        ),
                      ),
                    ),
                  ),
                  SizedBox(height: Responsive.h(context, 14)),
                  // controls
                  Row(
                    children: [
                      Expanded(
                        flex: 3,
                        child: ElevatedButton.icon(
                          onPressed: !_ble.isConnected
                              ? null
                              : (_running ? _stop : _start),
                          icon: Icon(_running
                              ? Icons.stop_rounded
                              : Icons.play_arrow_rounded),
                          label: Text(_running ? 'Stop' : 'Start'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: _running
                                ? const Color(0xFFFF5577)
                                : AppTheme.neonGreen,
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
                          onPressed: tracking ? _zero : null,
                          icon: const Icon(Icons.vertical_align_center_rounded),
                          label: const Text('Zero'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: AppTheme.neonGreen,
                            side: BorderSide(
                                color: tracking
                                    ? AppTheme.neonGreen
                                    : AppTheme.cardBgLight),
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
            },
          ),
        ),
      ),
    );
  }
}

/// Scrolling position-vs-time plot. Zero line = START position; up is +.
class _TrackPathPainter extends CustomPainter {
  final List<Offset> path; // (s, cm)
  final double windowSec;

  _TrackPathPainter({required this.path, required this.windowSec});

  @override
  void paint(Canvas canvas, Size size) {
    const padL = 44.0, padR = 12.0, padT = 14.0, padB = 26.0;
    final plot = Rect.fromLTRB(padL, padT, size.width - padR, size.height - padB);

    // symmetric Y range around 0, at least ±10 cm, rounded to a nice step
    double maxAbs = 10;
    for (final o in path) {
      maxAbs = max(maxAbs, o.dy.abs());
    }
    final step = _niceStep(maxAbs * 1.15 / 3);
    final yMax = (maxAbs * 1.15 / step).ceil() * step;

    final tNow = path.isEmpty ? windowSec : max(windowSec, path.last.dx);
    final tMin = tNow - windowSec;

    double xOf(double t) => plot.left + (t - tMin) / windowSec * plot.width;
    double yOf(double cm) => plot.center.dy - cm / yMax * plot.height / 2;

    final gridPaint = Paint()
      ..color = const Color(0x22FFFFFF)
      ..strokeWidth = 1;
    final label = TextStyle(color: AppTheme.textMuted, fontSize: 10);

    // horizontal grid + Y labels
    for (double v = -yMax; v <= yMax + 1e-6; v += step) {
      final y = yOf(v);
      canvas.drawLine(Offset(plot.left, y), Offset(plot.right, y),
          v == 0 ? (Paint()
            ..color = const Color(0x66FFFFFF)
            ..strokeWidth = 1.2) : gridPaint);
      _text(canvas, '${v > 0 ? '+' : ''}${v.toStringAsFixed(0)}',
          Offset(plot.left - 6, y), label, alignRight: true);
    }
    _text(canvas, 'cm', Offset(plot.right - 2, plot.top + 6), label,
        alignRight: true);
    _text(canvas, '▲ up', Offset(plot.left + 6, plot.top + 6),
        TextStyle(color: AppTheme.neonGreen.withValues(alpha: 0.7), fontSize: 10));
    _text(canvas, '▼ down', Offset(plot.left + 6, plot.bottom - 8),
        TextStyle(color: const Color(0xFF6EA8FF).withValues(alpha: 0.8), fontSize: 10));

    // vertical grid + time labels every 2 s
    final firstTick = (tMin / 2).ceil() * 2.0;
    for (double t = firstTick; t <= tNow + 1e-6; t += 2) {
      final x = xOf(t);
      canvas.drawLine(Offset(x, plot.top), Offset(x, plot.bottom), gridPaint);
      _text(canvas, '${t.toStringAsFixed(0)}s',
          Offset(x, plot.bottom + 12), label, center: true);
    }

    if (path.length < 2) {
      _text(canvas, 'Press Start to begin tracking', plot.center,
          TextStyle(color: AppTheme.textSecondary, fontSize: 13), center: true);
      return;
    }

    canvas.save();
    canvas.clipRect(plot);
    final line = Path();
    bool started = false;
    for (final o in path) {
      if (o.dx < tMin - 0.1) continue;
      final pt = Offset(xOf(o.dx), yOf(o.dy));
      if (!started) {
        line.moveTo(pt.dx, pt.dy);
        started = true;
      } else {
        line.lineTo(pt.dx, pt.dy);
      }
    }
    canvas.drawPath(
        line,
        Paint()
          ..color = AppTheme.neonGreen.withValues(alpha: 0.25)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 7
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6));
    canvas.drawPath(
        line,
        Paint()
          ..color = AppTheme.neonGreen
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5
          ..strokeJoin = StrokeJoin.round);
    final cur = Offset(xOf(path.last.dx), yOf(path.last.dy));
    canvas.drawCircle(cur, 6, Paint()..color = AppTheme.neonGreen);
    canvas.restore();
  }

  static double _niceStep(double raw) {
    if (raw <= 0) return 5;
    final mag = pow(10, (log(raw) / ln10).floor()).toDouble();
    final n = raw / mag;
    final nice = n <= 1 ? 1 : n <= 2 ? 2 : n <= 5 ? 5 : 10;
    return nice * mag;
  }

  void _text(Canvas c, String s, Offset at, TextStyle st,
      {bool alignRight = false, bool center = false}) {
    final tp = TextPainter(
        text: TextSpan(text: s, style: st), textDirection: TextDirection.ltr)
      ..layout();
    double dx = at.dx;
    if (alignRight) dx -= tp.width;
    if (center) dx -= tp.width / 2;
    tp.paint(c, Offset(dx, at.dy - tp.height / 2));
  }

  @override
  bool shouldRepaint(covariant _TrackPathPainter old) => true;
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
