import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:model_viewer_plus/model_viewer_plus.dart';
import 'package:webview_flutter/webview_flutter.dart' show WebViewController;

import '../models/avatar.dart';
import '../models/cable_exercise.dart';
import '../services/avatar_store.dart';
import 'web_bridge.dart';

/// Drives an [AnatomyViewer]: which exercise is shown, how it plays, and (in
/// live mode) which point of the repetition the figure is at.
class AnatomyViewerController {
  WebViewController? _web;
  String _id = 'gp';
  CableExercise? _exercise;
  bool _live = false;
  double _progress = 0;

  void _run(String call) {
    final js = 'if (window.gp_$_id) { window.gp_$_id.$call; }';
    if (kIsWeb) {
      runPageScript(js);
    } else {
      _web?.runJavaScript(js);
    }
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
  void setCamera(String orbit, String target, [String? fieldOfView]) => _run(
      'camera(${jsonEncode(orbit)}, ${jsonEncode(target)}, ${jsonEncode(fieldOfView)})');
  void resetCamera() {
    final e = _exercise;
    if (e != null) _run('camera(${jsonEncode(e.cameraOrbit)}, ${jsonEncode(e.cameraTarget)})');
  }

  /// Show only one muscle group at full strength (null = all).
  void setFocus(String? group) => _run('focus(${jsonEncode(group)})');
  void setSkin(bool on) => _run('skin($on)');

  /// Apply an avatar (skin tone, eye colour and hair). The viewer already follows
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
/// The model (`assets/models/anatomy_<sex>.glb`, built by
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
    this.avatar,
  });

  /// Avatar to show; defaults to the saved one (AvatarStore). The avatar
  /// editor passes its unsaved draft here for a live preview.
  final ValueListenable<Avatar>? avatar;

  static const Color background = Color(0xFF12171A);

  @override
  State<AnatomyViewer> createState() => _AnatomyViewerState();
}

class _AnatomyViewerState extends State<AnatomyViewer> {
  late Widget _viewer;
  late AvatarSex _sex;
  // Each model-viewer element gets its own id (a browser page can hold more
  // than one viewer; each phone WebView holds one).
  static int _count = 0;
  String _id = 'gp';

  ValueListenable<Avatar> get _avatar =>
      widget.avatar ?? AvatarStore.instance.avatar;

  @override
  void initState() {
    super.initState();
    widget.controller._exercise = widget.exercise;
    _avatar.addListener(_onAvatar);
    _sex = _avatar.value.sex;
    _viewer = _build();
  }

  /// One model per sex (assets/models/anatomy_<sex>.glb). The ModelViewer is
  /// built once per model: rebuilding it with new arguments would reload the
  /// whole model, so everything else goes through JavaScript.
  Widget _build() {
    final e = widget.controller._exercise ?? widget.exercise;
    if (kIsWeb) stopListening('GP_$_id');
    _id = 'gp${_count++}';
    widget.controller._id = _id;
    final script = _script(e, _avatar.value.toJs(), _id);
    if (kIsWeb) {
      // In a browser the page script is not run from the model-viewer's
      // HTML: start it here (it waits for its element) and listen to it.
      listenToPage('GP_$_id', _onMessage);
      runPageScript(script);
    }
    return ModelViewer(
      key: ValueKey(_id),
      id: _id,
      // In a browser: Flutter web serves bundled assets under assets/, and
      // the web build carries each model as glTF JSON (see web-preview.yml).
      src: kIsWeb
          ? 'assets/assets/models/anatomy_${_sex.name}.json'
          : 'assets/models/anatomy_${_sex.name}.glb',
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
      relatedJs: kIsWeb ? null : script,
      javascriptChannels: {
        JavascriptChannel('GP', onMessageReceived: (m) => _onMessage(m.message)),
      },
      onWebViewCreated: (c) => widget.controller._web = c,
    );
  }

  void _onAvatar() {
    final a = _avatar.value;
    if (a.sex != _sex) {
      // The other body: load its model.
      widget.onStatus?.call(0, false);
      setState(() {
        _sex = a.sex;
        _viewer = _build();
      });
    } else {
      widget.controller.setAvatar(a);
    }
  }

  @override
  void dispose() {
    _avatar.removeListener(_onAvatar);
    if (kIsWeb) stopListening('GP_$_id');
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
  static String _script(CableExercise initial, Map<String, Object> avatar, String id) => '''
(function () {
const ID = ${jsonEncode(id)};
function start(mv) {
  const channel = function () { return window['GP_' + ID] || window.GP; };
  // The body is opaque; each muscle group is a region of its skin. Resting,
  // a region is just skin; working, it lights up in its own shape and keeps
  // the skin's shading. With the skin "off" every region shows in
  // anatomical red, a full muscle map.
  const BARE = [0.42, 0.13, 0.11];
  const SHORTS = [0.05, 0.05, 0.06];
  let avatar = ${jsonEncode(avatar)};
  // Not muscles: skin, underwear, eyes, brows, hair styles (only the chosen
  // one shows) and the machine. A group's region over the underwear is
  // "<group>_cloth": it lights up like the group, from the cloth's colour.
  const DRESS = ['skin', 'shorts', 'iris', 'brows'];
  const FIXED = ['equipment', 'cable', 'tracker', 'pad', 'sclera', 'pupil'];
  const PRIMARY = [0.0, 1.0, 0.53];
  const SECONDARY = [1.0, 0.72, 0.20];
  const PULL = ${RepTimeline.pullStart}, HOLD = ${RepTimeline.holdStart};
  const RETURN = ${RepTimeline.returnStart}, REST = ${RepTimeline.restStart};
  let cfg = ${jsonEncode(AnatomyViewerController._config(initial))};
  function mix(a, b, t) {
    return [0, 1, 2].map(function (i) { return a[i] + (b[i] - a[i]) * t; });
  }
  function restingRegion() { return skinOn ? avatar.skin : BARE; }
  // Body shape: the model's morph targets, set from the avatar's sliders
  // (model-viewer has no API for them, so through its three.js scene).
  function applyBody() {
    try {
      const sym = Object.getOwnPropertySymbols(mv).find(function (s) {
        return s.description === 'scene';
      });
      const scene = sym ? mv[sym] : null;
      if (!scene || !scene.traverse) return;
      const body = avatar.body || {};
      scene.traverse(function (o) {
        const dict = o.morphTargetDictionary;
        if (!dict || !o.morphTargetInfluences) return;
        for (const name in dict) {
          o.morphTargetInfluences[dict[name]] = body[name] || 0;
        }
      });
      if (scene.queueRender) scene.queueRender();
    } catch (e) { /* keep the default build */ }
  }
  let skinOn = true, dressDirty = true, BASE = null;
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
    const dress = dressDirty;
    dressDirty = false;
    if (dress) { BASE = restingRegion(); last = {}; }
    for (const m of mv.model.materials) {
      const n = m.name;
      const hair = n.indexOf('hair_') === 0;
      if (DRESS.indexOf(n) >= 0 || hair) {
        if (dress) {
          let k = avatar.skin, a = 1;
          if (n === 'iris') k = avatar.eyeColor;
          else if (n === 'shorts') k = SHORTS;
          else if (n === 'brows') k = mix(avatar.hairColor, [0, 0, 0], 0.2);
          else if (hair) {
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
      const cloth = n.slice(-6) === '_cloth';
      const g = cloth ? n.slice(0, -6) : n;
      let k = 0, tone = PRIMARY;
      if (heat) { k = Math.min(1, Math.max(0, heat[g] || 0)); }
      else if (cfg.primary.indexOf(g) >= 0) { k = 0.55 + 0.45 * c; }
      else if (cfg.secondary.indexOf(g) >= 0) { k = 0.30 + 0.30 * c; tone = SECONDARY; }
      if (focus) { k = g === focus ? 1 : k * 0.15; }
      if (cloth) k *= 0.8;
      const key = Math.round(k * 40) + (tone === PRIMARY ? 'p' : 's');
      if (last[n] === key) continue;
      last[n] = key;
      const col = mix(cloth ? (skinOn ? SHORTS : BARE) : BASE, tone, k * 0.8);
      m.pbrMetallicRoughness.setBaseColorFactor([col[0], col[1], col[2], 1]);
      const glow = k * 0.22;
      m.setEmissiveFactor([tone[0] * glow, tone[1] * glow, tone[2] * glow]);
    }
  }
  // Show or hide the machine (everything but the body).
  let original = null;
  function machine(on) {
    if (!mv.model) return;
    const parts = mv.model.materials.filter(function (m) {
      return ['equipment', 'cable', 'tracker', 'pad'].indexOf(m.name) >= 0;
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
    if (!mv.isConnected) return;        // its view was closed
    if (now - lastSent > 90 && channel()) {
      lastSent = now;
      channel().postMessage(JSON.stringify({ t: repTime(), ready: !!mv.model }));
    }
    requestAnimationFrame(tick);
  }
  function resume() { if (live || paused) { mv.pause(); } else { mv.play(); } }
  function onLoad() {
    last = {};
    dressDirty = true;
    original = null;
    applyBody();
    if (heat) machine(false);
    mv.animationName = cfg.animation;
    resume();
  }
  const api = {
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
    camera: function (o, t, f) {
      mv.cameraOrbit = o; mv.cameraTarget = t;
      if (f) mv.fieldOfView = f;
    },
    focus: function (g) { focus = g; last = {}; },
    heat: function (h) { heat = h; last = {}; machine(!h); },
    skin: function (on) { skinOn = on; dressDirty = true; },
    avatar: function (a) { avatar = a; dressDirty = true; applyBody(); },
    live: function (on) { live = on; if (on) { shown = target; } resume(); },
    progress: function (p) { target = Math.min(1, Math.max(0, p)); }
  };
  window['gp_' + ID] = api;
  window.gp = api;
  mv.addEventListener('load', onLoad);
  if (mv.loaded) onLoad();
  requestAnimationFrame(tick);
}
// Wait for the element (in a browser it is attached after this runs).
function deepFind(root) {
  const el = root.querySelector('#' + ID);
  if (el) return el;
  for (const n of root.querySelectorAll('*')) {
    if (n.shadowRoot) { const r = deepFind(n.shadowRoot); if (r) return r; }
  }
  return null;
}
(function find() {
  const el = document.getElementById(ID) || deepFind(document);
  if (el) start(el); else setTimeout(find, 100);
})();
})();
''';

  @override
  Widget build(BuildContext context) => _viewer;
}
