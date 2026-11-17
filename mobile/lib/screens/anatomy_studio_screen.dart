import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:model_viewer_plus/model_viewer_plus.dart';
import 'package:webview_flutter/webview_flutter.dart' show WebViewController;

import '../models/cable_exercise.dart';
import '../theme/app_theme.dart';

/// Movement Studio: 3D muscle guide for the cable-machine workouts.
///
/// Shows a rigged anatomy model (real muscle shapes from BodyParts3D, see
/// tools/build_anatomy_model.py) performing the selected exercise. The
/// muscles that exercise trains are tinted on the model itself: green for
/// prime movers, amber for assisting muscles, brighter as they contract.
class AnatomyStudioScreen extends StatefulWidget {
  /// Workout to open on (a name from the workout list). Defaults to the first.
  final String? initialExercise;
  const AnatomyStudioScreen({super.key, this.initialExercise});

  @override
  State<AnatomyStudioScreen> createState() => _AnatomyStudioScreenState();
}

class _AnatomyStudioScreenState extends State<AnatomyStudioScreen> {
  static const Color _secondaryColor = Color(0xFFFFB833);
  static const String _modelAsset = 'assets/models/anatomy_cable.glb';

  late CableExercise _exercise;
  late final Widget _viewer;
  WebViewController? _web;

  bool _ready = false;
  bool _playing = true;
  double _speed = 1.0;
  double _t = 0;
  String? _focus;

  @override
  void initState() {
    super.initState();
    _exercise = cableExerciseByName(widget.initialExercise ?? '') ??
        cableExercises.first;
    // Built once: rebuilding the widget with new arguments would reload the
    // whole model. Everything after this goes through JavaScript.
    _viewer = ModelViewer(
      id: 'gp',
      src: _modelAsset,
      alt: 'Anatomy model performing a cable exercise',
      backgroundColor: const Color(0xFF12171A),
      loading: Loading.eager,
      autoPlay: true,
      animationName: _exercise.animation,
      cameraControls: true,
      cameraOrbit: _exercise.cameraOrbit,
      fieldOfView: '28deg',
      interactionPrompt: InteractionPrompt.none,
      touchAction: TouchAction.none,
      disableTap: true,
      ar: false,
      exposure: 1.15,
      shadowIntensity: 0.7,
      shadowSoftness: 0.9,
      debugLogging: false,
      relatedJs: _script(_exercise),
      javascriptChannels: {
        JavascriptChannel('GP', onMessageReceived: (m) => _onMessage(m.message)),
      },
      onWebViewCreated: (c) => _web = c,
    );
  }

  static Map<String, Object> _config(CableExercise e) => {
        'animation': e.animation,
        'primary': e.primary,
        'secondary': e.secondary,
        'orbit': e.cameraOrbit,
      };

  /// Page script: tints the muscle materials every frame from the rep time and
  /// reports that time back. The timeline numbers mirror [RepTimeline].
  static String _script(CableExercise initial) => '''
(function () {
  const mv = document.querySelector('#gp');
  const BASE = [0.36, 0.20, 0.19];
  const PRIMARY = [0.0, 1.0, 0.53];
  const SECONDARY = [1.0, 0.72, 0.20];
  let cfg = ${jsonEncode(_config(initial))};
  let focus = null, last = {}, lastSent = 0, paused = false;

  function smooth(x) { x = Math.min(1, Math.max(0, x)); return x * x * (3 - 2 * x); }
  function contraction(t) {
    if (t < ${RepTimeline.pullStart}) return 0;
    if (t < ${RepTimeline.holdStart}) return smooth((t - ${RepTimeline.pullStart}) / ${RepTimeline.holdStart - RepTimeline.pullStart});
    if (t < ${RepTimeline.returnStart}) return 1;
    if (t < ${RepTimeline.restStart}) return 1 - smooth((t - ${RepTimeline.returnStart}) / ${RepTimeline.restStart - RepTimeline.returnStart});
    return 0;
  }
  function repTime() {
    const d = mv.duration || 4;
    return (((mv.currentTime || 0) % d) + d) % d / d;
  }
  function paint() {
    if (!mv.model) return;
    const c = contraction(repTime());
    for (const m of mv.model.materials) {
      const n = m.name;
      if (n === 'bone') continue;
      let k = 0, tone = PRIMARY;
      if (cfg.primary.indexOf(n) >= 0) { k = 0.55 + 0.45 * c; }
      else if (cfg.secondary.indexOf(n) >= 0) { k = 0.30 + 0.30 * c; tone = SECONDARY; }
      if (focus) { k = n === focus ? 1 : k * 0.15; }
      const key = Math.round(k * 40) + (tone === PRIMARY ? 'p' : 's');
      if (last[n] === key) continue;
      last[n] = key;
      m.pbrMetallicRoughness.setBaseColorFactor([
        BASE[0] + (tone[0] - BASE[0]) * k,
        BASE[1] + (tone[1] - BASE[1]) * k,
        BASE[2] + (tone[2] - BASE[2]) * k, 1]);
      m.setEmissiveFactor([tone[0] * k * 0.16, tone[1] * k * 0.16, tone[2] * k * 0.16]);
    }
  }
  function tick(now) {
    paint();
    if (now - lastSent > 90 && window.GP) {
      lastSent = now;
      GP.postMessage(JSON.stringify({ t: repTime(), ready: !!mv.model }));
    }
    requestAnimationFrame(tick);
  }
  mv.addEventListener('load', function () {
    last = {};
    mv.animationName = cfg.animation;
    if (!paused) mv.play();
  });
  window.gp = {
    exercise: function (c) {
      cfg = c; focus = null; last = {};
      mv.animationName = c.animation;
      mv.currentTime = 0;
      mv.cameraOrbit = c.orbit;
      if (!paused) mv.play();
    },
    play: function () { paused = false; mv.play(); },
    pause: function () { paused = true; mv.pause(); },
    speed: function (s) { mv.timeScale = s; },
    seek: function (f) { mv.currentTime = f * (mv.duration || 4); },
    orbit: function (o) { mv.cameraOrbit = o; },
    focus: function (g) { focus = g; last = {}; }
  };
  requestAnimationFrame(tick);
})();
''';

  void _js(String call) {
    _web?.runJavaScript('if (window.gp) { window.gp.$call; }');
  }

  void _onMessage(String raw) {
    if (!mounted) return;
    try {
      final data = jsonDecode(raw) as Map<String, dynamic>;
      final t = (data['t'] as num).toDouble();
      final ready = data['ready'] == true;
      if ((t - _t).abs() > 0.004 || ready != _ready) {
        setState(() {
          _t = t;
          _ready = ready;
        });
      }
    } catch (_) {
      // A malformed message only costs one UI update.
    }
  }

  void _select(CableExercise e) {
    if (e == _exercise) return;
    setState(() {
      _exercise = e;
      _focus = null;
      _t = 0;
    });
    _js('exercise(${jsonEncode(_config(e))})');
  }

  void _togglePlayback() {
    setState(() => _playing = !_playing);
    _js(_playing ? 'play()' : 'pause()');
  }

  void _setSpeed(double v) {
    setState(() => _speed = v);
    _js('speed($v)');
  }

  void _setFocus(String group) {
    setState(() => _focus = _focus == group ? null : group);
    _js('focus(${jsonEncode(_focus)})');
  }

  @override
  Widget build(BuildContext context) {
    final phase = RepTimeline.phaseAt(_t);
    return Scaffold(
      backgroundColor: AppTheme.darkBg,
      appBar: AppBar(title: const Text('Movement Studio')),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, box) {
            final viewH = (box.maxHeight * 0.44).clamp(220.0, 520.0);
            return Column(
              children: [
                _buildExerciseBar(),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                  child: SizedBox(height: viewH, child: _buildViewport()),
                ),
                _buildTimeline(phase),
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 0, 18, 8),
                  child: _buildControls(),
                ),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(18, 6, 18, 24),
                    children: _buildDetails(phase),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildExerciseBar() {
    return SizedBox(
      height: 46,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(18, 2, 18, 10),
        itemCount: cableExercises.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (_, i) {
          final e = cableExercises[i];
          final selected = e == _exercise;
          return GestureDetector(
            onTap: () => _select(e),
            child: Container(
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                color: selected ? AppTheme.neonGreen : AppTheme.cardBg,
                borderRadius: BorderRadius.circular(17),
                border: Border.all(
                    color:
                        selected ? AppTheme.neonGreen : AppTheme.cardBgLight),
              ),
              child: Text(e.name,
                  style: TextStyle(
                      color: selected ? Colors.black : AppTheme.textSecondary,
                      fontSize: 12,
                      fontWeight: FontWeight.w600)),
            ),
          );
        },
      ),
    );
  }

  Widget _buildViewport() {
    return ClipRRect(
      borderRadius: BorderRadius.circular(22),
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF12171A),
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: AppTheme.cardBgLight),
        ),
        child: Stack(children: [
          Positioned.fill(child: _viewer),
          if (!_ready)
            const Positioned.fill(
              child: ColoredBox(
                color: Color(0xFF12171A),
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 26,
                        height: 26,
                        child: CircularProgressIndicator(
                            strokeWidth: 2.5, color: AppTheme.neonGreen),
                      ),
                      SizedBox(height: 12),
                      Text('Loading 3D model…',
                          style: TextStyle(
                              color: AppTheme.textSecondary, fontSize: 12)),
                    ],
                  ),
                ),
              ),
            ),
          Positioned(
            left: 12,
            top: 12,
            child: Row(children: [
              _viewChip('FRONT', '0deg 80deg 118%'),
              _viewChip('SIDE', '90deg 80deg 118%'),
              _viewChip('BACK', '180deg 80deg 118%'),
              _viewChip('BEST', _exercise.cameraOrbit),
            ]),
          ),
          Positioned(
            left: 12,
            bottom: 12,
            child: IgnorePointer(
              child: Row(children: [
                _legendDot(AppTheme.neonGreen, 'PRIMARY'),
                const SizedBox(width: 10),
                _legendDot(_secondaryColor, 'ASSISTING'),
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

  Widget _viewChip(String label, String orbit) => Padding(
        padding: const EdgeInsets.only(right: 6),
        child: GestureDetector(
          onTap: () => _js('orbit(${jsonEncode(orbit)})'),
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

  Widget _legendDot(Color color, String label) => Row(children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 5),
        Text(label,
            style: const TextStyle(
                color: Colors.white60,
                fontSize: 8,
                letterSpacing: 1,
                fontWeight: FontWeight.w700)),
      ]);

  Widget _buildTimeline(RepPhase phase) {
    final effort = (RepTimeline.contractionAt(_t) * 100).round();
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
            Text('CONTRACTION $effort%',
                style: const TextStyle(
                    color: AppTheme.neonGreen,
                    fontSize: 11,
                    fontWeight: FontWeight.w700)),
          ]),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
            ),
            child: Slider(
              value: _t.clamp(0.0, 1.0),
              activeColor: AppTheme.neonGreen,
              inactiveColor: AppTheme.cardBgLight,
              onChangeStart: (_) => _js('pause()'),
              onChanged: (v) {
                setState(() => _t = v);
                _js('seek($v)');
              },
              onChangeEnd: (_) {
                if (_playing) _js('play()');
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
          child: Text('$_speed×',
              style: const TextStyle(
                  color: AppTheme.textPrimary, fontWeight: FontWeight.w600)),
        ),
      ),
    ]);
  }

  List<Widget> _buildDetails(RepPhase phase) {
    Widget tile(String group, Color color) => _MuscleTile(
          label: muscleGroupLabels[group] ?? group,
          color: color,
          activation: _exercise.activation(group, _t),
          selected: _focus == group,
          onTap: () => _setFocus(group),
        );
    return [
      Container(
        padding: const EdgeInsets.all(13),
        decoration: BoxDecoration(
          color: AppTheme.cardBg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.cardBgLight),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Icon(Icons.sensors_rounded,
              color: AppTheme.neonGreen, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(_exercise.setup,
                style: const TextStyle(
                    color: AppTheme.textSecondary, fontSize: 12)),
          ),
        ]),
      ),
      const SizedBox(height: 20),
      const _SectionTitle('PRIMARY MUSCLES  ·  TAP TO ISOLATE'),
      const SizedBox(height: 10),
      for (final g in _exercise.primary) tile(g, AppTheme.neonGreen),
      const SizedBox(height: 14),
      const _SectionTitle('ASSISTING MUSCLES'),
      const SizedBox(height: 10),
      for (final g in _exercise.secondary) tile(g, _secondaryColor),
      const SizedBox(height: 20),
      const _SectionTitle('COACH CUES'),
      const SizedBox(height: 10),
      for (final p in RepPhase.values)
        _CueTile(
          number: '0${p.index + 1}',
          title: _exercise.cueTitles[p.index],
          detail: _exercise.cueDetails[p.index],
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
          'The highlights show which muscles an exercise trains and when they '
          'shorten. They are a teaching map, not a measurement of your own '
          'muscle activity.\n\n'
          '3D anatomy: BodyParts3D, © The Database Center for Life Science, '
          'licensed under CC Attribution-Share Alike 2.1 Japan.',
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
  final Color color;
  final double activation;
  final bool selected;
  final VoidCallback onTap;
  const _MuscleTile({
    required this.label,
    required this.color,
    required this.activation,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 11),
        decoration: BoxDecoration(
          color: selected ? color.withValues(alpha: .12) : AppTheme.cardBg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: selected ? color : AppTheme.cardBgLight),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Container(
                width: 9,
                height: 9,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Text(label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w600)),
              ),
              Text('${(activation * 100).round()}%',
                  style: TextStyle(
                      color: color, fontSize: 12, fontWeight: FontWeight.w700)),
            ]),
            const SizedBox(height: 8),
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
