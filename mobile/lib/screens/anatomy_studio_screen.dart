import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import '../models/squat_rig.dart';
import '../theme/app_theme.dart';

/// Movement Studio: a rotatable 3D squat guide.
///
/// The figure is a procedural athletic body (see [SquatRig]) drawn with a
/// perspective camera: drag to orbit, pinch to zoom, double-tap to reset.
/// Muscle highlights and coach cues follow the repetition timeline.
/// A licensed skinned mesh and pose-pipeline animation data replace the
/// procedural rig in a later step.
class AnatomyStudioScreen extends StatefulWidget {
  const AnatomyStudioScreen({super.key});
  @override
  State<AnatomyStudioScreen> createState() => _AnatomyStudioScreenState();
}

class _AnatomyStudioScreenState extends State<AnatomyStudioScreen>
    with TickerProviderStateMixin {
  static const int _repMs = 4200;
  static const double _homeYaw = 0.62;
  static const double _homePitch = 0.20;

  late final AnimationController _rep;
  late final AnimationController _cam;

  bool _playing = true;
  bool _resumeAfterScrub = false;
  double _speed = 1.0;
  MuscleGroup? _focus;

  double _yaw = _homeYaw;
  double _pitch = _homePitch;
  double _zoom = 1.0;
  double _zoomAtPinchStart = 1.0;
  double _yawFrom = 0, _yawTo = 0;
  double _pitchFrom = 0, _pitchTo = 0;
  double _zoomFrom = 1, _zoomTo = 1;

  @override
  void initState() {
    super.initState();
    _rep = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: _repMs),
    )..addListener(_onFrame);
    _cam = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 420),
    )..addListener(_onCamera);
    _rep.repeat();
  }

  @override
  void dispose() {
    _rep.dispose();
    _cam.dispose();
    super.dispose();
  }

  void _onFrame() => setState(() {});

  void _onCamera() {
    final t = Curves.easeInOut.transform(_cam.value);
    setState(() {
      _yaw = _yawFrom + (_yawTo - _yawFrom) * t;
      _pitch = _pitchFrom + (_pitchTo - _pitchFrom) * t;
      _zoom = _zoomFrom + (_zoomTo - _zoomFrom) * t;
    });
  }

  static double _wrapAngle(double a) =>
      a - 2 * math.pi * ((a + math.pi) / (2 * math.pi)).floorToDouble();

  /// Sweeps the camera to a preset view along the shortest rotation.
  void _goTo(double yaw, double pitch) {
    _cam.stop();
    _yawFrom = _yaw;
    _yawTo = _yaw + _wrapAngle(yaw - _yaw);
    _pitchFrom = _pitch;
    _pitchTo = pitch;
    _zoomFrom = _zoom;
    _zoomTo = 1.0;
    _cam.forward(from: 0);
  }

  void _togglePlayback() {
    setState(() => _playing = !_playing);
    if (_playing) {
      _rep.repeat();
    } else {
      _rep.stop();
    }
  }

  void _setSpeed(double v) {
    setState(() => _speed = v);
    _rep.duration = Duration(milliseconds: (_repMs / v).round());
    if (_playing) _rep.repeat();
  }

  @override
  Widget build(BuildContext context) {
    final t = _rep.value;
    final depth = SquatRig.depthAt(t);
    final phase = SquatRig.phaseAt(t);
    final pose = SquatRig.solve(depth);

    return Scaffold(
      backgroundColor: AppTheme.darkBg,
      appBar: AppBar(
        title: const Text('Movement Studio'),
        actions: [
          IconButton(
            tooltip: 'Reset view',
            onPressed: () => _goTo(_homeYaw, _homePitch),
            icon: const Icon(Icons.center_focus_strong_rounded),
          ),
        ],
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, box) {
            final viewH = (box.maxHeight * 0.46).clamp(230.0, 520.0);
            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 4, 18, 10),
                  child: Row(children: [
                    Container(
                      width: 7,
                      height: 7,
                      decoration: const BoxDecoration(
                          color: AppTheme.neonGreen, shape: BoxShape.circle),
                    ),
                    const SizedBox(width: 8),
                    const Text('EXERCISE GUIDE  /  SQUAT',
                        style: TextStyle(
                            color: AppTheme.neonGreen,
                            fontSize: 11,
                            letterSpacing: 1.4,
                            fontWeight: FontWeight.w700)),
                    const Spacer(),
                    const Text('3D PROTOTYPE',
                        style:
                            TextStyle(color: AppTheme.textMuted, fontSize: 10)),
                  ]),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                  child: SizedBox(
                    height: viewH,
                    child: _buildViewport(pose, phase),
                  ),
                ),
                _buildTimeline(t, depth, phase),
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 0, 18, 10),
                  child: _buildControls(),
                ),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(18, 6, 18, 24),
                    children: _buildDetails(depth, phase),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildViewport(SquatPose pose, SquatPhase phase) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(22),
      child: Container(
        decoration: BoxDecoration(
          gradient: const RadialGradient(
            center: Alignment(0, -0.2),
            radius: 1.1,
            colors: [Color(0xFF1D2527), Color(0xFF101415)],
          ),
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: AppTheme.cardBgLight),
        ),
        child: Stack(children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onDoubleTap: () => _goTo(_homeYaw, _homePitch),
              onScaleStart: (_) {
                _cam.stop();
                _zoomAtPinchStart = _zoom;
              },
              onScaleUpdate: (d) {
                setState(() {
                  if (d.pointerCount > 1) {
                    _zoom = (_zoomAtPinchStart * d.scale).clamp(0.7, 2.4);
                  } else {
                    _yaw += d.focalPointDelta.dx * 0.011;
                    _pitch = (_pitch + d.focalPointDelta.dy * 0.006)
                        .clamp(-0.12, 1.15);
                  }
                });
              },
              child: CustomPaint(
                painter: _RigPainter(
                  pose: pose,
                  phase: phase,
                  yaw: _yaw,
                  pitch: _pitch,
                  zoom: _zoom,
                  focus: _focus,
                ),
              ),
            ),
          ),
          Positioned(
            left: 12,
            top: 12,
            child: Row(children: [
              _viewChip('FRONT', () => _goTo(0, 0.10)),
              _viewChip('SIDE', () => _goTo(math.pi / 2, 0.10)),
              _viewChip('BACK', () => _goTo(math.pi, 0.12)),
              _viewChip('3/4', () => _goTo(_homeYaw, _homePitch)),
            ]),
          ),
          Positioned(
            left: 12,
            bottom: 12,
            child: IgnorePointer(
              child: Row(children: [
                _angleChip('KNEE', pose.kneeFlexionDeg),
                _angleChip('HIP', pose.hipFlexionDeg),
                _angleChip('TORSO', pose.torsoLeanDeg),
              ]),
            ),
          ),
          const Positioned(
            right: 12,
            bottom: 14,
            child: IgnorePointer(
              child: Text('DRAG · PINCH',
                  style: TextStyle(
                      color: Colors.white30,
                      fontSize: 8,
                      letterSpacing: 1.1,
                      fontWeight: FontWeight.w600)),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _viewChip(String label, VoidCallback onTap) => Padding(
        padding: const EdgeInsets.only(right: 6),
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: .55),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.white12),
            ),
            child: Text(label,
                style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 9,
                    letterSpacing: 1,
                    fontWeight: FontWeight.w700)),
          ),
        ),
      );

  Widget _angleChip(String label, double degrees) => Container(
        margin: const EdgeInsets.only(right: 6),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: .55),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label,
                style: const TextStyle(
                    color: Colors.white54,
                    fontSize: 7.5,
                    letterSpacing: 1,
                    fontWeight: FontWeight.w700)),
            Text('${degrees.round()}°',
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w700)),
          ],
        ),
      );

  Widget _buildTimeline(double t, double depth, SquatPhase phase) {
    const flexes = [8, 37, 10, 37, 8];
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 0),
      child: Column(
        children: [
          Row(children: [
            const Icon(Icons.motion_photos_on,
                color: AppTheme.neonGreen, size: 16),
            const SizedBox(width: 8),
            Expanded(
              child: Text(phase.label,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      letterSpacing: 1,
                      fontWeight: FontWeight.w700)),
            ),
            Text('DEPTH ${(depth * 100).round()}%',
                style: const TextStyle(
                    color: AppTheme.neonGreen,
                    fontSize: 11,
                    fontWeight: FontWeight.w700)),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            for (final p in SquatPhase.values)
              Expanded(
                flex: flexes[p.index],
                child: Container(
                  height: 4,
                  margin: const EdgeInsets.symmetric(horizontal: 1.5),
                  decoration: BoxDecoration(
                    color: p == phase
                        ? AppTheme.neonGreen
                        : AppTheme.cardBgLight,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
          ]),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
              trackShape: const RectangularSliderTrackShape(),
            ),
            child: Slider(
              value: t.clamp(0.0, 1.0),
              activeColor: AppTheme.neonGreen,
              inactiveColor: AppTheme.cardBgLight,
              onChangeStart: (_) {
                _resumeAfterScrub = _playing;
                _rep.stop();
                setState(() => _playing = false);
              },
              onChanged: (v) => _rep.value = v,
              onChangeEnd: (_) {
                if (_resumeAfterScrub) {
                  setState(() => _playing = true);
                  _rep.repeat();
                }
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildControls() {
    return Row(children: [
      Expanded(
        child: OutlinedButton.icon(
          onPressed: _togglePlayback,
          icon: Icon(_playing ? Icons.pause : Icons.play_arrow),
          label: Text(_playing ? 'Pause guide' : 'Play guide'),
          style: OutlinedButton.styleFrom(
            foregroundColor: AppTheme.neonGreen,
            side: const BorderSide(color: AppTheme.neonGreen),
            padding: const EdgeInsets.symmetric(vertical: 12),
          ),
        ),
      ),
      const SizedBox(width: 10),
      PopupMenuButton<double>(
        initialValue: _speed,
        color: AppTheme.cardBg,
        onSelected: _setSpeed,
        itemBuilder: (_) => const [
          PopupMenuItem(value: 0.25, child: Text('0.25×')),
          PopupMenuItem(value: 0.5, child: Text('0.5×')),
          PopupMenuItem(value: 1.0, child: Text('1.0×')),
          PopupMenuItem(value: 1.5, child: Text('1.5×')),
        ],
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          decoration: BoxDecoration(
            color: AppTheme.cardBg,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppTheme.cardBgLight),
          ),
          child: Text('${_speed == 0.25 ? '0.25' : _speed.toStringAsFixed(1)}×',
              style: const TextStyle(
                  color: AppTheme.textPrimary, fontWeight: FontWeight.w600)),
        ),
      ),
    ]);
  }

  List<Widget> _buildDetails(double depth, SquatPhase phase) {
    Widget muscle(MuscleGroup g) => Expanded(
          child: _MuscleTile(
            label: g.label,
            activation: SquatRig.activation(g, depth, phase),
            selected: _focus == g,
            onTap: () => setState(() => _focus = _focus == g ? null : g),
          ),
        );
    return [
      const _SectionTitle('TARGET MUSCLES  ·  TAP TO ISOLATE'),
      const SizedBox(height: 10),
      Row(children: [
        muscle(MuscleGroup.quadriceps),
        const SizedBox(width: 8),
        muscle(MuscleGroup.glutes),
      ]),
      const SizedBox(height: 8),
      Row(children: [
        muscle(MuscleGroup.hamstrings),
        const SizedBox(width: 8),
        muscle(MuscleGroup.core),
      ]),
      const SizedBox(height: 22),
      const _SectionTitle('COACH CUES'),
      const SizedBox(height: 10),
      for (final p in SquatPhase.values)
        _CueTile(
          number: '0${p.index + 1}',
          title: p.cueTitle,
          detail: p.cueDetail,
          active: p == phase,
        ),
      const SizedBox(height: 16),
      Container(
        padding: const EdgeInsets.all(13),
        decoration: BoxDecoration(
          color: const Color(0xFF292318),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFF6B542B)),
        ),
        child: const Text(
          'Prototype note: the figure is a procedural 3D body and the muscle '
          'highlights are an illustrative teaching map tied to the movement '
          'phase. They are not EMG or a measurement of real muscle force, and '
          'the guide does not yet use camera-based pose tracking.',
          style: TextStyle(color: Color(0xFFE5C98E), fontSize: 11),
        ),
      ),
    ];
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);
  @override
  Widget build(BuildContext context) => Text(text,
      style: const TextStyle(
          color: AppTheme.textSecondary,
          fontSize: 11,
          letterSpacing: 1.3,
          fontWeight: FontWeight.w700));
}

class _MuscleTile extends StatelessWidget {
  final String label;
  final double activation;
  final bool selected;
  final VoidCallback onTap;
  const _MuscleTile({
    required this.label,
    required this.activation,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = Color.lerp(
        const Color(0xFF5E8F80), AppTheme.neonGreen, activation)!;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.fromLTRB(11, 9, 11, 10),
        decoration: BoxDecoration(
          color: selected
              ? AppTheme.neonGreen.withValues(alpha: .12)
              : AppTheme.cardBg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
              color: selected ? AppTheme.neonGreen : AppTheme.cardBgLight),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Expanded(
                child: Text(label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600)),
              ),
              Text('${(activation * 100).round()}%',
                  style: TextStyle(
                      color: color,
                      fontSize: 11,
                      fontWeight: FontWeight.w700)),
            ]),
            const SizedBox(height: 7),
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: activation,
                minHeight: 4,
                backgroundColor: AppTheme.cardBgLight,
                valueColor: AlwaysStoppedAnimation<Color>(color),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CueTile extends StatelessWidget {
  final String number, title, detail;
  final bool active;
  const _CueTile({
    required this.number,
    required this.title,
    required this.detail,
    required this.active,
  });

  @override
  Widget build(BuildContext context) => AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(13),
        decoration: BoxDecoration(
          color: active
              ? AppTheme.neonGreen.withValues(alpha: .10)
              : AppTheme.cardBg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
              color: active ? AppTheme.neonGreen : AppTheme.cardBgLight),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(number,
              style: TextStyle(
                  color: active ? AppTheme.neonGreen : AppTheme.textMuted,
                  fontWeight: FontWeight.bold,
                  fontSize: 12)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: TextStyle(
                        color: active
                            ? AppTheme.textPrimary
                            : AppTheme.textSecondary,
                        fontWeight: FontWeight.w600,
                        fontSize: 13)),
                const SizedBox(height: 3),
                Text(detail,
                    style: const TextStyle(
                        color: AppTheme.textSecondary, fontSize: 11)),
              ],
            ),
          ),
        ]),
      );
}

/// One projected, depth-sortable volume.
class _Prim {
  final Offset a, b;
  final double ra, rb, z;
  final Color color;
  final double glow;
  const _Prim(this.a, this.ra, this.b, this.rb, this.z, this.color, this.glow);
}

/// Perspective renderer for the [SquatRig] body.
///
/// Every body part is a tapered capsule shaded with a gradient across its
/// width; parts are painted back-to-front (painter's algorithm).
class _RigPainter extends CustomPainter {
  final SquatPose pose;
  final SquatPhase phase;
  final double yaw, pitch, zoom;
  final MuscleGroup? focus;

  _RigPainter({
    required this.pose,
    required this.phase,
    required this.yaw,
    required this.pitch,
    required this.zoom,
    required this.focus,
  });

  static const Vec3 _target = Vec3(0, 0.76, -0.08);
  static const double _distance = 3.6;
  static const Offset _light = Offset(-0.6, -0.8);
  static const Color _skin = Color(0xFF7C8993);
  static const Color _definition = Color(0xFF8D9BA6);
  static const Color _muscleRest = Color(0xFF3A5852);

  late double _focal;
  late Offset _center;
  late double _cy, _sy, _cp, _sp;

  /// Camera-space depth of [p] (distance in front of the camera).
  double _depth(Vec3 p) {
    final q = p - _target;
    final z = -q.x * _sy + q.z * _cy;
    return _distance - (q.y * _sp + z * _cp);
  }

  Offset _project(Vec3 p) {
    final q = p - _target;
    final x = q.x * _cy + q.z * _sy;
    final z = -q.x * _sy + q.z * _cy;
    final y = q.y * _cp - z * _sp;
    final depth = _distance - (q.y * _sp + z * _cp);
    final k = _focal / depth;
    return Offset(_center.dx + x * k, _center.dy - y * k);
  }

  @override
  void paint(Canvas canvas, Size size) {
    _focal = math.min(size.height, size.width * 1.15) * 1.5 * zoom;
    _center = Offset(size.width / 2, size.height * 0.52);
    _cy = math.cos(yaw);
    _sy = math.sin(yaw);
    _cp = math.cos(pitch);
    _sp = math.sin(pitch);

    _paintFloor(canvas);

    final prims = <_Prim>[];
    void add(Vec3 a, double ra, Vec3 b, double rb, Color color, double glow) {
      final za = _depth(a), zb = _depth(b);
      prims.add(_Prim(
        _project(a),
        ra * _focal / za,
        _project(b),
        rb * _focal / zb,
        (za + zb) / 2,
        color,
        glow,
      ));
    }

    for (final s in pose.body) {
      add(s.a, s.ra, s.b, s.rb, s.definition ? _definition : _skin, 0);
    }
    for (final m in pose.muscles) {
      var act = SquatRig.activation(m.group, pose.depth, phase);
      if (focus != null) {
        act = m.group == focus ? math.max(act, 0.8) : 0.04;
      }
      final color = Color.lerp(_muscleRest, AppTheme.neonGreen, act)!;
      add(m.a, m.radius, m.b, m.radius, color, act > 0.6 ? act - 0.6 : 0);
    }
    prims.sort((p, q) => q.z.compareTo(p.z));

    // One dark silhouette behind everything, so the parts read as one body.
    final outline = Paint()..color = const Color(0xFF07090A);
    for (final p in prims) {
      _capsule(canvas, p.a, p.ra + 1.6, p.b, p.rb + 1.6, outline);
    }
    final glow = Paint()
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 7);
    final fill = Paint();
    for (final p in prims) {
      if (p.glow > 0) {
        glow.color = AppTheme.neonGreen.withValues(alpha: p.glow * 0.9);
        _capsule(canvas, p.a, p.ra * 1.15, p.b, p.rb * 1.15, glow);
      }
      fill.shader = _shade(p);
      _capsule(canvas, p.a, p.ra, p.b, p.rb, fill);
    }
  }

  void _paintFloor(Canvas canvas) {
    final grid = Paint()
      ..color = Colors.white.withValues(alpha: .07)
      ..strokeWidth = 1;
    for (var i = -5; i <= 5; i++) {
      final v = i * 0.25;
      canvas.drawLine(
          _project(Vec3(v, 0, -1.25)), _project(Vec3(v, 0, 1.25)), grid);
      canvas.drawLine(
          _project(Vec3(-1.25, 0, v)), _project(Vec3(1.25, 0, v)), grid);
    }
    // Soft contact shadow under the hips.
    final pelvis = pose[Joint.pelvis];
    final shadow = Path();
    for (var i = 0; i < 20; i++) {
      final a = i * math.pi / 10;
      final o = _project(Vec3(
        pelvis.x + math.cos(a) * 0.34,
        0,
        pelvis.z * 0.5 + math.sin(a) * 0.30,
      ));
      if (i == 0) {
        shadow.moveTo(o.dx, o.dy);
      } else {
        shadow.lineTo(o.dx, o.dy);
      }
    }
    shadow.close();
    canvas.drawPath(
      shadow,
      Paint()
        ..color = Colors.black.withValues(alpha: .45)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10),
    );
  }

  /// Fills a tapered capsule (two circles joined by their side walls).
  void _capsule(
      Canvas canvas, Offset a, double ra, Offset b, double rb, Paint paint) {
    canvas.drawCircle(a, ra, paint);
    final d = b - a;
    final len = d.distance;
    if (len < 0.5) return;
    canvas.drawCircle(b, rb, paint);
    final n = Offset(-d.dy / len, d.dx / len);
    canvas.drawPath(
      Path()
        ..moveTo(a.dx + n.dx * ra, a.dy + n.dy * ra)
        ..lineTo(b.dx + n.dx * rb, b.dy + n.dy * rb)
        ..lineTo(b.dx - n.dx * rb, b.dy - n.dy * rb)
        ..lineTo(a.dx - n.dx * ra, a.dy - n.dy * ra)
        ..close(),
      paint,
    );
  }

  /// Gradient across the width of a part: lit from the upper left.
  ui.Gradient _shade(_Prim p) {
    final hi = Color.lerp(p.color, Colors.white, 0.32)!;
    final lo = Color.lerp(p.color, Colors.black, 0.52)!;
    final r = math.max(p.ra, p.rb);
    final d = p.b - p.a;
    final len = d.distance;
    if (len < 0.5) {
      return ui.Gradient.radial(
        p.a + Offset(-r * 0.35, -r * 0.42),
        r * 1.55,
        [hi, p.color, lo],
        const [0.0, 0.45, 1.0],
      );
    }
    var n = Offset(-d.dy / len, d.dx / len);
    if (n.dx * _light.dx + n.dy * _light.dy < 0) n = -n;
    final mid = (p.a + p.b) / 2.0;
    return ui.Gradient.linear(
      mid + n * r,
      mid - n * r,
      [hi, p.color, lo],
      const [0.0, 0.42, 1.0],
    );
  }

  @override
  bool shouldRepaint(covariant _RigPainter old) => true;
}
