import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:model_viewer_plus/model_viewer_plus.dart';
import 'package:webview_flutter/webview_flutter.dart' show WebViewController;

import '../models/avatar.dart';
import '../models/cable_exercise.dart';
import '../services/avatar_store.dart';

/// Drives an [AnatomyViewer]: which exercise is shown, how it plays, and (in
/// live mode) which point of the repetition the figure is at.
class AnatomyViewerController {
  WebViewController? _web;
  CableExercise? _exercise;
  bool _live = false;
  double _progress = 0;

  void _run(String call) {
    _web?.runJavaScript('if (window.gp) { window.gp.$call; }');
  }

  static Map<String, Object> _config(CableExercise e) => {
        'animation': e.animation,
        'primary': e.primary,
        'secondary': e.secondary,
        'orbit': e.cameraOrbit,
        'target': e.cameraTarget,
      };

  void showExercise(CableExercise e) {
    _exercise = e;
    _run('exercise(${jsonEncode(_config(e))})');
  }

  void play() => _run('play()');
  void pause() => _run('pause()');
  void setSpeed(double v) => _run('speed($v)');

  /// Jump to rep time [t] (0..1) of the guide animation.
  void seek(double t) => _run('seek($t)');

  void setOrbit(String orbit) => _run('orbit(${jsonEncode(orbit)})');
  void resetCamera() {
    final e = _exercise;
    if (e != null) _run('camera(${jsonEncode(e.cameraOrbit)}, ${jsonEncode(e.cameraTarget)})');
  }

  /// Show only one muscle group at full strength (null = all).
  void setFocus(String? group) => _run('focus(${jsonEncode(group)})');
  void setSkin(bool on) => _run('skin($on)');

  /// Apply an avatar (head skin tone and hair). The viewer already follows
  /// the saved avatar; this is for live previews.
  void setAvatar(Avatar a) => _run('avatar(${jsonEncode(a.toJs())})');

  /// Heat-map mode: every muscle group is tinted by its value (0..1) instead
  /// of by the exercise, and the machine is hidden; null switches back.
  void setHeat(Map<String, double>? heat) =>
      _run('heat(${heat == null ? 'null' : jsonEncode(heat)})');

  /// Live mode: the clock stops and the figure follows [setProgress].
  void setLive(bool live) {
    _live = live;
    _run('live($live)');
    if (live) _run('progress($_progress)');
  }

  /// How far through the working phase the user is: 0 = start position,
  /// 1 = peak contraction. Only used in live mode.
  void setProgress(double progress) {
    _progress = progress.clamp(0.0, 1.0);
    if (_live) _run('progress(${_progress.toStringAsFixed(3)})');
  }
}

/// 3D figure performing a cable exercise, with the working muscles tinted.
///
/// The model (`assets/models/anatomy_cable.glb`, built by
/// tools/build_anatomy_model.py) holds skin over real muscle shapes plus the
/// machine: seat, handle, cables, pulleys and the weight stack with the
/// tracker on it. Each exercise is one animation clip.
class AnatomyViewer extends StatefulWidget {
  final CableExercise exercise;
  final AnatomyViewerController controller;

  /// Rep time (0..1) and model-loaded flag, about ten times a second.
  final void Function(double t, bool ready)? onStatus;

  /// Camera to open on; defaults to the exercise's own camera.
  final String? initialOrbit;
  final String? initialTarget;
  final String? initialFieldOfView;

  const AnatomyViewer({
    super.key,
    required this.exercise,
    required this.controller,
    this.onStatus,
    this.initialOrbit,
    this.initialTarget,
    this.initialFieldOfView,
  });

  static const Color background = Color(0xFF12171A);

  @override
  State<AnatomyViewer> createState() => _AnatomyViewerState();
}

class _AnatomyViewerState extends State<AnatomyViewer> {
  static const String _modelAsset = 'assets/models/anatomy_cable.glb';
  late final Widget _viewer;

  @override
  void initState() {
    super.initState();
    final e = widget.exercise;
    widget.controller._exercise = e;
    AvatarStore.instance.avatar.addListener(_onAvatar);
    // Built once: rebuilding ModelViewer with new arguments would reload the
    // whole model. Everything after this goes through JavaScript.
    _viewer = ModelViewer(
      id: 'gp',
      src: _modelAsset,
      alt: 'Figure performing a cable exercise',
      backgroundColor: AnatomyViewer.background,
      loading: Loading.eager,
      autoPlay: true,
      animationName: e.animation,
      cameraControls: true,
      cameraOrbit: widget.initialOrbit ?? e.cameraOrbit,
      cameraTarget: widget.initialTarget ?? e.cameraTarget,
      fieldOfView: widget.initialFieldOfView ?? '28deg',
      interactionPrompt: InteractionPrompt.none,
      touchAction: TouchAction.none,
      disableTap: true,
      ar: false,
      exposure: 1.0,
      shadowIntensity: 0.7,
      shadowSoftness: 0.9,
      debugLogging: false,
      relatedJs: _script(e, AvatarStore.instance.avatar.value.toJs()),
      javascriptChannels: {
        JavascriptChannel('GP', onMessageReceived: (m) => _onMessage(m.message)),
      },
      onWebViewCreated: (c) => widget.controller._web = c,
    );
  }

  void _onAvatar() => widget.controller.setAvatar(AvatarStore.instance.avatar.value);

  @override
  void dispose() {
    AvatarStore.instance.avatar.removeListener(_onAvatar);
    super.dispose();
  }

  void _onMessage(String raw) {
    if (!mounted) return;
    try {
      final data = jsonDecode(raw) as Map<String, dynamic>;
      widget.onStatus?.call((data['t'] as num).toDouble(), data['ready'] == true);
    } catch (_) {
      // A malformed message only costs one status update.
    }
  }

  /// Page script: tints the muscle materials every frame from the rep time and
  /// reports that time back. The timeline numbers mirror [RepTimeline].
  static String _script(CableExercise initial, Map<String, Object> avatar) => '''
(function () {
  const mv = document.querySelector('#gp');
  // Resting muscles: grey under the skin, anatomical red with the skin off.
  const UNDER_SKIN = [0.42, 0.43, 0.46];
  const BARE = [0.42, 0.22, 0.20];
  // The body is the same for everyone: see-through graphite skin over a
  // normal build. Only the head is the user's avatar: skin tone and hair.
  const BODY_SKIN = [0.30, 0.32, 0.36];
  const BODY_ALPHA = 0.49;
  const SHORTS = [0.05, 0.05, 0.06];
  let avatar = ${jsonEncode(avatar)};
  // Materials that are not muscles: body surface, clothing and the machine.
  const DRESS = ['skin', 'head', 'shorts', 'hair_buzz', 'hair_short'];
  // Neck bands between the see-through body and the solid head (neck1 just
  // under the head ... neckN lowest); each is a step more solid.
  const NECK_BANDS = 8;
  const FIXED = ['shorts', 'equipment', 'cable', 'tracker', 'pad'];
  const PRIMARY = [0.0, 1.0, 0.53];
  const SECONDARY = [1.0, 0.72, 0.20];
  const PULL = ${RepTimeline.pullStart}, HOLD = ${RepTimeline.holdStart};
  const RETURN = ${RepTimeline.returnStart}, REST = ${RepTimeline.restStart};
  let cfg = ${jsonEncode(AnatomyViewerController._config(initial))};
  // Resting muscles under the skin take on the body's skin colour.
  function underSkin() {
    return [0, 1, 2].map(function (i) {
      return BODY_SKIN[i] * 0.7 + UNDER_SKIN[i] * 0.3;
    });
  }
  let BASE = underSkin(), skinOn = true, dressDirty = true;
  let focus = null, last = {}, lastSent = 0, paused = false, heat = null;
  // Live mode: the figure eases towards the progress the tracker reports.
  let live = false, target = 0, shown = 0, lastFrame = 0;

  function smooth(x) { x = Math.min(1, Math.max(0, x)); return x * x * (3 - 2 * x); }
  function contraction(t) {
    if (t < PULL) return 0;
    if (t < HOLD) return smooth((t - PULL) / (HOLD - PULL));
    if (t < RETURN) return 1;
    if (t < REST) return 1 - smooth((t - RETURN) / (REST - RETURN));
    return 0;
  }
  // Rep time on the way up at which the contraction equals c.
  function timeFor(c) {
    c = Math.min(1, Math.max(0, c));
    return PULL + (0.5 - Math.sin(Math.asin(1 - 2 * c) / 3)) * (HOLD - PULL);
  }
  function repTime() {
    const d = mv.duration || 4;
    return (((mv.currentTime || 0) % d) + d) % d / d;
  }
  function paint() {
    if (!mv.model) return;
    const c = contraction(repTime());
    const skinAlpha = skinOn ? BODY_ALPHA : 0;
    const dress = dressDirty;
    dressDirty = false;
    for (const m of mv.model.materials) {
      const n = m.name;
      const neck = n.indexOf('neck') === 0 ? parseInt(n.slice(4), 10) : 0;
      if (DRESS.indexOf(n) >= 0 || neck > 0) {
        if (dress) {
          let k = BODY_SKIN, a = 1;
          if (n === 'skin') a = skinAlpha;
          else if (n === 'shorts') k = SHORTS;
          else if (n === 'head') k = avatar.skin;
          else if (neck > 0) {
            // The neck blends the avatar's solid head into the body's
            // see-through skin: colour and opacity both, band by band.
            let f = 1 - neck / (NECK_BANDS + 1);
            f = f * f * (3 - 2 * f);
            k = [0, 1, 2].map(function (i) {
              return BODY_SKIN[i] + (avatar.skin[i] - BODY_SKIN[i]) * f;
            });
            a = skinAlpha + (1 - skinAlpha) * f;
          } else {
            // Hair: only the chosen style shows.
            const on = n === avatar.hair;
            k = avatar.hairColor;
            a = on ? 1 : 0;
            m.setAlphaMode(on ? 'OPAQUE' : 'BLEND');
          }
          m.pbrMetallicRoughness.setBaseColorFactor([k[0], k[1], k[2], a]);
        }
        continue;
      }
      if (FIXED.indexOf(n) >= 0) continue;
      let k = 0, tone = PRIMARY;
      if (heat) { k = Math.min(1, Math.max(0, heat[n] || 0)); }
      else if (cfg.primary.indexOf(n) >= 0) { k = 0.55 + 0.45 * c; }
      else if (cfg.secondary.indexOf(n) >= 0) { k = 0.30 + 0.30 * c; tone = SECONDARY; }
      if (focus) { k = n === focus ? 1 : k * 0.15; }
      const key = Math.round(k * 40) + (tone === PRIMARY ? 'p' : 's');
      if (last[n] === key) continue;
      last[n] = key;
      m.pbrMetallicRoughness.setBaseColorFactor([
        BASE[0] + (tone[0] - BASE[0]) * k,
        BASE[1] + (tone[1] - BASE[1]) * k,
        BASE[2] + (tone[2] - BASE[2]) * k, 1]);
      // Glow strongly enough to read through the skin layer.
      const glow = skinAlpha > 0 ? k : k * 0.3;
      m.setEmissiveFactor([tone[0] * glow, tone[1] * glow, tone[2] * glow]);
      if (m.setEmissiveStrength) m.setEmissiveStrength(skinAlpha > 0 ? 2.0 : 1.0);
    }
  }
  // Show or hide the machine (everything but the body and the shorts).
  let original = null;
  function machine(on) {
    if (!mv.model) return;
    const parts = mv.model.materials.filter(function (m) {
      return FIXED.indexOf(m.name) >= 0 && m.name !== 'shorts';
    });
    if (!original) {
      original = {};
      for (const m of parts) original[m.name] = m.pbrMetallicRoughness.baseColorFactor.slice();
    }
    for (const m of parts) {
      const c = original[m.name];
      m.setAlphaMode(on ? 'OPAQUE' : 'BLEND');
      m.pbrMetallicRoughness.setBaseColorFactor([c[0], c[1], c[2], on ? c[3] : 0]);
      if (m.name === 'tracker') m.setEmissiveFactor(on ? [0, 1, 0.53] : [0, 0, 0]);
    }
  }
  function tick(now) {
    const dt = Math.min(200, now - lastFrame);
    lastFrame = now;
    if (live && mv.model) {
      // Ease by elapsed time, so slow phones do not lag behind the tracker.
      shown += (target - shown) * (1 - Math.exp(-dt / 55));
      if (Math.abs(target - shown) < 0.002) shown = target;
      mv.currentTime = timeFor(shown) * (mv.duration || 4);
    }
    paint();
    if (now - lastSent > 90 && window.GP) {
      lastSent = now;
      GP.postMessage(JSON.stringify({ t: repTime(), ready: !!mv.model }));
    }
    requestAnimationFrame(tick);
  }
  function resume() { if (live || paused) { mv.pause(); } else { mv.play(); } }
  mv.addEventListener('load', function () {
    last = {};
    dressDirty = true;
    original = null;
    if (heat) machine(false);
    mv.animationName = cfg.animation;
    resume();
  });
  window.gp = {
    exercise: function (c) {
      cfg = c; focus = null; last = {};
      mv.animationName = c.animation;
      mv.currentTime = 0;
      mv.cameraOrbit = c.orbit;
      mv.cameraTarget = c.target;
      resume();
    },
    play: function () { paused = false; resume(); },
    pause: function () { paused = true; mv.pause(); },
    speed: function (s) { mv.timeScale = s; },
    seek: function (f) { mv.currentTime = f * (mv.duration || 4); },
    orbit: function (o) { mv.cameraOrbit = o; },
    camera: function (o, t) { mv.cameraOrbit = o; mv.cameraTarget = t; },
    focus: function (g) { focus = g; last = {}; },
    heat: function (h) { heat = h; last = {}; machine(!h); },
    skin: function (on) {
      skinOn = on;
      BASE = on ? underSkin() : BARE;
      dressDirty = true;
      last = {};
    },
    avatar: function (a) { avatar = a; dressDirty = true; },
    live: function (on) { live = on; if (on) { shown = target; } resume(); },
    progress: function (p) { target = Math.min(1, Math.max(0, p)); }
  };
  requestAnimationFrame(tick);
})();
''';

  @override
  Widget build(BuildContext context) => _viewer;
}
