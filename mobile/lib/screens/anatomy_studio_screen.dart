import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// First mobile vertical slice for coach-led movement guidance.
/// This is a procedural 2D rig; a licensed skinned 3D asset is a later step.
class AnatomyStudioScreen extends StatefulWidget {
  const AnatomyStudioScreen({super.key});
  @override
  State<AnatomyStudioScreen> createState() => _AnatomyStudioScreenState();
}

class _AnatomyStudioScreenState extends State<AnatomyStudioScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  bool _playing = true;
  bool _sideView = false;
  double _speed = 1.0;
  double _phase = 0.0;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this, duration: const Duration(seconds: 3),
    )..addListener(() {
        if (_playing) setState(() => _phase = _controller.value);
      });
    _controller.repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _togglePlayback() {
    setState(() => _playing = !_playing);
    if (_playing) {
      _controller.repeat();
    } else {
      _controller.stop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final depth = (1 - math.cos(_phase * math.pi * 2)) / 2;
    final phaseName = depth > .78
        ? 'BOTTOM POSITION'
        : depth < .22
            ? 'STANDING'
            : 'CONTROLLED DESCENT / ASCENT';
    return Scaffold(
      backgroundColor: AppTheme.darkBg,
      appBar: AppBar(
        title: const Text('Movement Studio'),
        actions: [
          IconButton(
            tooltip: 'Switch view',
            onPressed: () => setState(() => _sideView = !_sideView),
            icon: Icon(_sideView ? Icons.accessibility_new : Icons.person),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(18, 8, 18, 24),
          children: [
            Row(children: [
              Container(width: 7, height: 7,
                decoration: const BoxDecoration(
                  color: AppTheme.neonGreen, shape: BoxShape.circle)),
              const SizedBox(width: 8),
              const Text('EXERCISE GUIDE  /  SQUAT',
                style: TextStyle(color: AppTheme.neonGreen, fontSize: 11,
                  letterSpacing: 1.4, fontWeight: FontWeight.w700)),
              const Spacer(),
              const Text('PROTOTYPE',
                style: TextStyle(color: AppTheme.textMuted, fontSize: 10)),
            ]),
            const SizedBox(height: 14),
            Container(
              height: 390,
              decoration: BoxDecoration(
                color: const Color(0xFF151A19),
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: AppTheme.cardBgLight)),
              child: Stack(children: [
                Positioned.fill(child: CustomPaint(
                  painter: _AnatomyPainter(phase: depth, sideView: _sideView))),
                Positioned(left: 16, top: 16,
                  child: _viewChip(_sideView ? 'SIDE VIEW' : 'FRONT VIEW')),
                Positioned(right: 16, top: 16,
                  child: _viewChip('MUSCLE MAP')),
                Positioned(left: 16, right: 16, bottom: 16,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: .55),
                      borderRadius: BorderRadius.circular(12)),
                    child: Row(children: [
                      const Icon(Icons.motion_photos_on,
                        color: AppTheme.neonGreen, size: 17),
                      const SizedBox(width: 9),
                      Expanded(child: Text(phaseName,
                        style: const TextStyle(color: Colors.white, fontSize: 10,
                          letterSpacing: 1, fontWeight: FontWeight.w700))),
                      Text((depth * 100).round().toString() + '%',
                        style: const TextStyle(color: AppTheme.neonGreen,
                          fontWeight: FontWeight.bold)),
                    ]),
                  )),
              ]),
            ),
            const SizedBox(height: 14),
            Row(children: [
              Expanded(child: OutlinedButton.icon(
                onPressed: _togglePlayback,
                icon: Icon(_playing ? Icons.pause : Icons.play_arrow),
                label: Text(_playing ? 'Pause guide' : 'Play guide'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppTheme.neonGreen,
                  side: const BorderSide(color: AppTheme.neonGreen)))),
              const SizedBox(width: 10),
              PopupMenuButton<double>(
                initialValue: _speed,
                color: AppTheme.cardBg,
                onSelected: (v) {
                  setState(() => _speed = v);
                  _controller.duration =
                      Duration(milliseconds: (3000 / v).round());
                  if (_playing) _controller.repeat();
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: .5, child: Text('0.5×')),
                  PopupMenuItem(value: 1, child: Text('1.0×')),
                  PopupMenuItem(value: 1.5, child: Text('1.5×')),
                ],
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                  decoration: BoxDecoration(color: AppTheme.cardBg,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: AppTheme.cardBgLight)),
                  child: Text(_speed.toStringAsFixed(1) + '×',
                    style: const TextStyle(color: AppTheme.textPrimary,
                      fontWeight: FontWeight.w600)),
                )),
            ]),
            const SizedBox(height: 22),
            const _SectionTitle('TARGET MUSCLES'),
            const SizedBox(height: 10),
            const Wrap(spacing: 8, runSpacing: 8, children: [
              _MuscleTag('Quadriceps', true),
              _MuscleTag('Gluteus maximus', true),
              _MuscleTag('Core stabilizers', true),
              _MuscleTag('Hamstrings', false),
            ]),
            const SizedBox(height: 22),
            const _SectionTitle('COACH CUES'),
            const SizedBox(height: 10),
            const _CueTile('01', 'Brace your core',
              'Keep your trunk stable before initiating the descent.'),
            const _CueTile('02', 'Track knees over toes',
              'Keep both knees aligned with the direction of your feet.'),
            const _CueTile('03', 'Control the bottom position',
              'Use a smooth, controlled reversal without bouncing.'),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(13),
              decoration: BoxDecoration(
                color: const Color(0xFF292318),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFF6B542B))),
              child: const Text(
                'Prototype note: this screen uses a procedural 2D anatomy rig and illustrative muscle mapping. It does not yet use a true 3D model or camera-based pose estimation.',
                style: TextStyle(color: Color(0xFFE5C98E), fontSize: 11)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _viewChip(String label) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
    decoration: BoxDecoration(color: Colors.black.withValues(alpha: .55),
      borderRadius: BorderRadius.circular(8)),
    child: Text(label, style: const TextStyle(color: Colors.white70,
      fontSize: 9, letterSpacing: 1, fontWeight: FontWeight.w700)));
}

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);
  @override
  Widget build(BuildContext context) => Text(text,
    style: const TextStyle(color: AppTheme.textSecondary, fontSize: 11,
      letterSpacing: 1.3, fontWeight: FontWeight.w700));
}

class _MuscleTag extends StatelessWidget {
  final String label;
  final bool active;
  const _MuscleTag(this.label, this.active);
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
    decoration: BoxDecoration(
      color: active ? AppTheme.neonGreen.withValues(alpha: .12) : AppTheme.cardBg,
      borderRadius: BorderRadius.circular(30),
      border: Border.all(color: active ? AppTheme.neonGreen : AppTheme.cardBgLight)),
    child: Text(label, style: TextStyle(
      color: active ? AppTheme.neonGreen : AppTheme.textSecondary, fontSize: 11)));
}

class _CueTile extends StatelessWidget {
  final String number, title, detail;
  const _CueTile(this.number, this.title, this.detail);
  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: 8),
    padding: const EdgeInsets.all(13),
    decoration: BoxDecoration(color: AppTheme.cardBg,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: AppTheme.cardBgLight)),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(number, style: const TextStyle(color: AppTheme.neonGreen,
        fontWeight: FontWeight.bold, fontSize: 12)),
      const SizedBox(width: 12),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: const TextStyle(color: AppTheme.textPrimary,
          fontWeight: FontWeight.w600, fontSize: 13)),
        const SizedBox(height: 3),
        Text(detail, style: const TextStyle(
          color: AppTheme.textSecondary, fontSize: 11)),
      ])),
    ]),
  );
}

/// Lightweight animated pose illustration. A skinned 3D rig replaces this later.
class _AnatomyPainter extends CustomPainter {
  final double phase;
  final bool sideView;
  _AnatomyPainter({required this.phase, required this.sideView});

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width * .5;
    final s = size.height / 390;
    final shift = phase * 24 * s;
    final limb = Paint()
      ..color = const Color(0xFFB9C8C2)
      ..strokeWidth = 8 * s
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    final joint = Paint()..color = const Color(0xFFD7E3DE);
    final active = Paint()..color = AppTheme.neonGreen;
    final inactive = Paint()..color = const Color(0xFF47665A);

    final head = Offset(cx, 73 * s + shift * .25);
    final shoulderY = 120 * s + shift * .35;
    final hipY = 225 * s + shift;
    final kneeY = 290 * s - phase * 28 * s;
    final ankleY = 345 * s;
    final leftHip = Offset(cx - 20 * s, hipY);
    final rightHip = Offset(cx + 20 * s, hipY);
    final leftKnee = Offset(cx - (sideView ? 27 : 23) * s, kneeY);
    final rightKnee = Offset(cx + (sideView ? 27 : 23) * s, kneeY);
    final leftAnkle = Offset(cx - 29 * s, ankleY);
    final rightAnkle = Offset(cx + 29 * s, ankleY);

    canvas.drawCircle(head, 19 * s, limb);
    canvas.drawLine(Offset(cx, 94 * s + shift * .25), Offset(cx, hipY), limb);
    final sl = Offset(cx - 34 * s, shoulderY);
    final sr = Offset(cx + 34 * s, shoulderY);
    canvas.drawLine(sl, sr, limb);
    canvas.drawLine(sl, Offset(cx - 57 * s, 185 * s + shift), limb);
    canvas.drawLine(sr, Offset(cx + 57 * s, 185 * s + shift), limb);
    canvas.drawOval(Rect.fromCenter(
      center: Offset(cx, 158 * s + shift * .55),
      width: 45 * s, height: 70 * s), inactive);
    canvas.drawOval(Rect.fromCenter(
      center: Offset(cx, 219 * s + shift), width: 58 * s, height: 32 * s), active);

    for (final pair in [
      [leftHip, leftKnee, leftAnkle],
      [rightHip, rightKnee, rightAnkle],
    ]) {
      final hip = pair[0], knee = pair[1], ankle = pair[2];
      canvas.drawLine(hip, knee, limb);
      canvas.drawOval(Rect.fromCenter(
        center: Offset((hip.dx + knee.dx) / 2, (hip.dy + knee.dy) / 2),
        width: 23 * s, height: 45 * s), active);
      canvas.drawCircle(knee, 8 * s, joint);
      canvas.drawLine(knee, ankle, limb);
      canvas.drawCircle(ankle, 6 * s, joint);
      canvas.drawLine(ankle, Offset(ankle.dx + 17 * s, ankle.dy), limb);
    }
    canvas.drawCircle(sl, 7 * s, joint);
    canvas.drawCircle(sr, 7 * s, joint);
    canvas.drawLine(Offset(cx - 90 * s, 354 * s),
      Offset(cx + 90 * s, 354 * s),
      Paint()..color = Colors.white.withValues(alpha: .16)..strokeWidth = 1);
  }

  @override
  bool shouldRepaint(covariant _AnatomyPainter old) =>
      old.phase != phase || old.sideView != sideView;
}
