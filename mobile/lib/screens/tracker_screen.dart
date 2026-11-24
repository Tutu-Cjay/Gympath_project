import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/ble_service.dart';
import '../theme/app_theme.dart';
import 'tracker_preview_data.dart';

/// A rep screen look the tracker can show (firmware Gympath_Track 1.5+).
class TrackerTheme {
  final int id; // value sent to the tracker
  final String name;
  final String description;
  const TrackerTheme(this.id, this.name, this.description);
}

/// How the rep count's digits look (firmware 1.6+): the same on every theme.
class TrackerDigits {
  final int id; // value sent to the tracker
  final String name;
  const TrackerDigits(this.id, this.name);
}

const List<TrackerDigits> trackerDigitStyles = [
  TrackerDigits(0, 'Segment'),
  TrackerDigits(1, 'Rounded'),
  TrackerDigits(2, 'Bold'),
  TrackerDigits(3, 'Light'),
];

const List<TrackerTheme> trackerThemes = [
  TrackerTheme(0, 'Classic', 'The ring and the count show your speed'),
  TrackerTheme(1, 'Stroke', 'The ring fills with each rep\'s travel'),
  TrackerTheme(2, 'Tempo', 'Lift / lower, and each rep\'s up and down time'),
  TrackerTheme(3, 'Minimal', 'Big count, a dot per rep'),
];

/// The tracker screen for a theme and number style, as the firmware's live
/// preview draws it (tools/render_tracker_themes.py).
String trackerPage(int theme, int style) => 'assets/tracker/page_${theme}_$style.png';

/// Live preview axes, as the tracker numbers them.
const int themeAxis = 0, digitsAxis = 1;

/// The tracker: link, battery, and how its rep screen looks.
///
/// Themes stand along the front of a very large wheel: swipe sideways to
/// turn it. The number styles are a wheel of their own: swipe up or down.
/// The tracker follows the swipe live (firmware 1.7+); the choice is saved
/// when the wheel comes to rest. Firmware updates are offered only by the
/// pop-up on connect (FirmwareAutoCheck).
class TrackerScreen extends StatefulWidget {
  const TrackerScreen({super.key});

  @override
  State<TrackerScreen> createState() => _TrackerScreenState();
}

class _TrackerScreenState extends State<TrackerScreen>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  final _ble = BleService.instance;
  late final AnimationController _settle;
  Timer? _keepAlive;
  bool _previewing = false;

  // where each wheel stands, in pages (fractions while it turns)
  double _t = 0, _s = 0;
  int _lastAxis = themeAxis;
  int? _axis;                    // the wheel being dragged
  double _drag = 0, _startPos = 0;
  double _from = 0, _to = 0;     // settle animation of _lastAxis
  double _pageW = 1, _pageH = 1; // px of finger travel per page

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _t = (_ble.trackerTheme.value ?? 0).toDouble();
    _s = (_ble.trackerDigits.value ?? 0).toDouble();
    _settle = AnimationController(vsync: this)
      ..addListener(_settleTick)
      ..addStatusListener((st) {
        if (st == AnimationStatus.completed) _saveAxis(_lastAxis);
      });
    _ble.connectionState.addListener(_startPreview);
    _ble.trackerTheme.addListener(_syncTheme);
    _ble.trackerDigits.addListener(_syncDigits);
    _ble.trackerLivePreview.addListener(_startPreview);
    _startPreview();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    for (var t = 0; t < trackerThemes.length; t++) {
      precacheImage(AssetImage('assets/tracker/bg_$t.png'), context);
      for (var s = 0; s < trackerDigitStyles.length; s++) {
        precacheImage(AssetImage(trackerPage(t, s)), context);
        precacheImage(AssetImage('assets/tracker/count_${t}_$s.png'), context);
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopPreview();
    _ble.connectionState.removeListener(_startPreview);
    _ble.trackerTheme.removeListener(_syncTheme);
    _ble.trackerDigits.removeListener(_syncDigits);
    _ble.trackerLivePreview.removeListener(_startPreview);
    _settle.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _startPreview();
    } else if (state == AppLifecycleState.paused) {
      _stopPreview();
    }
  }

  // ---- live preview on the tracker ----

  /// Shows the rep screen on the tracker while this screen is open.
  void _startPreview() {
    if (!mounted) return;
    setState(() {}); // connection / support changed
    if (!_ble.isConnected || !_ble.trackerLivePreview.value) {
      _keepAlive?.cancel(); // link gone: start over when it is back
      _keepAlive = null;
      _previewing = false;
      return;
    }
    if (!_previewing) {
      _previewing = true;
      _ble.requestHighThroughput(); // shorter link interval: smoother follow
      _send(_lastAxis);
    }
    _keepAlive ??=
        Timer.periodic(const Duration(seconds: 2), (_) => _send(_lastAxis));
  }

  void _stopPreview() {
    _keepAlive?.cancel();
    _keepAlive = null;
    if (_previewing) {
      _previewing = false;
      _ble.endPreview();
    }
  }

  void _send(int axis) {
    if (!_previewing) return;
    _ble.sendPreview(axis, axis == themeAxis ? _t : _s);
  }

  // ---- turning the wheels ----

  int _count(int axis) =>
      axis == themeAxis ? trackerThemes.length : trackerDigitStyles.length;
  double _pos(int axis) => axis == themeAxis ? _t : _s;

  /// Moves one wheel; the tracker gets the position clamped to real pages.
  void _set(int axis, double v) {
    setState(() {
      if (axis == themeAxis) {
        _t = v;
      } else {
        _s = v;
      }
    });
    _lastAxis = axis;
    if (_previewing) {
      _ble.sendPreview(axis, v.clamp(0.0, _count(axis) - 1.0));
    }
  }

  void _dragStart(int axis) {
    if (_settle.isAnimating) {   // caught while settling: finish it first
      _settle.stop();
      _set(_lastAxis, _to);
      _saveAxis(_lastAxis);
    }
    _axis = axis;
    _drag = 0;
    _startPos = _pos(axis);
  }

  void _dragUpdate(int axis, double delta) {
    if (_axis != axis) return;
    _drag += delta;
    final n = _count(axis) - 1.0;
    // finger left / up = next page; the front item follows the finger
    var v = _startPos - _drag / (axis == themeAxis ? _pageW : _pageH);
    if (v < 0) v *= 0.3;                       // rubber band at the ends
    if (v > n) v = n + (v - n) * 0.3;
    _set(axis, v);
  }

  void _dragEnd(int axis, double velocityPx) {
    if (_axis != axis) return;
    _axis = null;
    final pos = _pos(axis);
    final vel = -velocityPx / (axis == themeAxis ? _pageW : _pageH); // pages/s
    final start = _startPos.round();
    var target = (pos + vel * 0.12).round();
    target = target.clamp(start - 1, start + 1).clamp(0, _count(axis) - 1);
    _animateTo(axis, target);
  }

  void _animateTo(int axis, int target) {
    _lastAxis = axis;
    _from = _pos(axis);
    _to = target.toDouble();
    final dist = (_to - _from).abs();
    _settle.duration = Duration(milliseconds: (170 + 230 * dist).round().clamp(120, 450));
    _settle.forward(from: 0);
  }

  void _settleTick() {
    final k = Curves.easeOutCubic.transform(_settle.value);
    _set(_lastAxis, _from + (_to - _from) * k);
  }

  // ---- saving the choice ----

  void _syncTheme() => _syncFrom(themeAxis, _ble.trackerTheme.value);
  void _syncDigits() => _syncFrom(digitsAxis, _ble.trackerDigits.value);

  /// The tracker's setting changed (read on connect, or saved): show it,
  /// unless the user is turning that wheel.
  void _syncFrom(int axis, int? page) {
    if (page == null || !mounted) return;
    final busy = _axis == axis || (_settle.isAnimating && _lastAxis == axis);
    setState(() {
      if (busy || _pos(axis) == page) return;
      if (axis == themeAxis) {
        _t = page.toDouble();
      } else {
        _s = page.toDouble();
      }
    });
  }

  Future<void> _saveAxis(int axis) async {
    final page = _pos(axis).round();
    final saved = axis == themeAxis ? _ble.trackerTheme.value : _ble.trackerDigits.value;
    if (saved == null || saved == page) return; // not supported, or no change
    final ok = axis == themeAxis
        ? await _ble.setTrackerScreen(theme: page)
        : await _ble.setTrackerScreen(digits: page);
    if (!mounted) return;
    setState(() {});
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        behavior: SnackBarBehavior.floating,
        content: Text('Could not change the tracker screen. Is it connected?'),
      ));
    }
  }

  // ---- UI ----

  @override
  Widget build(BuildContext context) {
    final connected = _ble.isConnected;
    final ti = _t.round().clamp(0, trackerThemes.length - 1);
    final si = _s.round().clamp(0, trackerDigitStyles.length - 1);
    final savedT = _ble.trackerTheme.value, savedS = _ble.trackerDigits.value;
    return Scaffold(
      backgroundColor: AppTheme.darkBg,
      appBar: AppBar(title: const Text('Tracker')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(0, 8, 0, 24),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: _statusCard(connected),
          ),
          const SizedBox(height: 20),
          _heading('REP SCREEN', '←→ theme   ↑↓ numbers'),
          LayoutBuilder(builder: (context, box) {
            final arc = ThemeArc.layoutFor(box.maxWidth);
            _pageW = arc.step;
            _pageH = arc.slot(ti);
            // sideways turns the theme wheel, up / down the number wheel on
            // its front face (each drag has its own direction, so the
            // vertical one also wins over the page's scrolling)
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onHorizontalDragStart: (_) => _dragStart(themeAxis),
              onHorizontalDragUpdate: (d) => _dragUpdate(themeAxis, d.delta.dx),
              onHorizontalDragEnd: (d) =>
                  _dragEnd(themeAxis, d.velocity.pixelsPerSecond.dx),
              onVerticalDragStart: (_) => _dragStart(digitsAxis),
              onVerticalDragUpdate: (d) => _dragUpdate(digitsAxis, d.delta.dy),
              onVerticalDragEnd: (d) =>
                  _dragEnd(digitsAxis, d.velocity.pixelsPerSecond.dy),
              child: ThemeArc(theme: _t, style: _s, layout: arc),
            );
          }),
          const SizedBox(height: 4),
          Row(children: [
            Expanded(
                child: _caption(trackerThemes[ti].name,
                    trackerThemes[ti].description, savedT == ti)),
            Expanded(
                child: _caption(trackerDigitStyles[si].name, 'Number style',
                    savedS == si)),
          ]),
          if (!connected)
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 14, 20, 0),
              child: Text('Connect the tracker to change its screen.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AppTheme.textMuted, fontSize: 12)),
            ),
        ],
      ),
    );
  }

  Widget _heading(String title, String hint) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
        child: Row(children: [
          Text(title,
              style: const TextStyle(
                  color: AppTheme.textSecondary,
                  fontSize: 11,
                  letterSpacing: 1.2,
                  fontWeight: FontWeight.w700)),
          const Spacer(),
          Text(hint, style: const TextStyle(color: AppTheme.textMuted, fontSize: 12)),
        ]),
      );

  Widget _caption(String name, String sub, bool saved) => Column(children: [
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Text(name,
              style: const TextStyle(
                  color: AppTheme.textPrimary, fontSize: 16, fontWeight: FontWeight.w700)),
          if (saved) ...[
            const SizedBox(width: 6),
            const Icon(Icons.check_circle_rounded, color: AppTheme.neonGreen, size: 16),
          ],
        ]),
        const SizedBox(height: 2),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Text(sub,
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
        ),
      ]);

  Widget _statusCard(bool connected) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: AppTheme.cardBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
            color: connected ? AppTheme.neonGreen.withValues(alpha: .5) : AppTheme.cardBgLight),
      ),
      child: Row(children: [
        Icon(Icons.watch_rounded,
            color: connected ? AppTheme.neonGreen : AppTheme.textMuted, size: 28),
        const SizedBox(width: 12),
        Expanded(
          child: Text(connected ? 'Connected' : 'Not connected',
              style: const TextStyle(
                  color: AppTheme.textPrimary, fontSize: 16, fontWeight: FontWeight.bold)),
        ),
        ValueListenableBuilder<int?>(
          valueListenable: _ble.batteryPercent,
          builder: (context, b, _) => ValueListenableBuilder<bool>(
            valueListenable: _ble.batteryCharging,
            builder: (context, charging, _) => b == null || !connected
                ? const SizedBox.shrink()
                : Row(children: [
                    Icon(
                        charging
                            ? Icons.battery_charging_full_rounded
                            : Icons.battery_std_rounded,
                        color: b > 20 ? AppTheme.neonGreen : Colors.redAccent,
                        size: 20),
                    Text(' $b%',
                        style: const TextStyle(
                            color: AppTheme.textPrimary, fontWeight: FontWeight.w600)),
                  ]),
          ),
        ),
      ]),
    );
  }
}

// ======================= theme wheel =======================

/// Sizes of the theme wheel for a given width.
class ArcLayout {
  final double width, face, step, radius, top, height;
  const ArcLayout(this.width, this.face, this.step, this.radius, this.top, this.height);

  /// Tracker px → screen px on the front face.
  double get k => face / 240;

  /// Spacing of the number wheel on theme [theme]'s front face, px.
  double slot(int theme) => trackerCountWindows[theme][3] * k * 0.86;
}

/// The themes stand along a very large wheel and only its front is in
/// view: the chosen theme faces you, its neighbours curve away at the
/// sides (smaller, darker, turned), the rest are round the back, out of
/// sight. The faces stand on a glossy floor and reflect in it.
///
/// On the front face, centred on the count, the number styles turn on a
/// wheel of their own (up / down): the chosen one in place, one neighbour
/// above and one below, smaller and faint, over the face.
class ThemeArc extends StatelessWidget {
  final double theme, style;
  final ArcLayout layout;
  const ThemeArc({super.key, required this.theme, required this.style, required this.layout});

  static ArcLayout layoutFor(double width) {
    final face = (width * 0.6).clamp(150.0, 260.0);
    final step = face * 0.74;          // front distance between neighbours
    final radius = width * 2.6;        // the wheel: far larger than the screen
    const top = 10.0;
    return ArcLayout(width, face, step, radius, top, top + face * 1.30);
  }

  @override
  Widget build(BuildContext context) {
    final lo = layout;
    final st = style.round().clamp(0, trackerDigitStyles.length - 1);
    final front0 = theme.round().clamp(0, trackerThemes.length - 1);
    // the number wheel shows while the theme wheel stands still
    final still = (theme - front0).abs() < 1e-4;
    final items = <({double near, Widget w})>[];
    for (var i = 0; i < trackerThemes.length; i++) {
      final d = i - theme;                       // pages from the front
      if (d.abs() > 2.3) continue;               // round the back: unseen
      final phi = d * lo.step / lo.radius;       // angle on the wheel
      final x = lo.radius * math.sin(phi);
      final depth = lo.radius * (1 - math.cos(phi));
      final scale = (1 / (1 + depth / (lo.face * 1.6))) * (1 - 0.14 * d.abs().clamp(0.0, 1.5));
      final size = lo.face * scale;
      final dim = (d.abs() * 0.42).clamp(0.0, 0.85);
      final front = 1 - d.abs().clamp(0.0, 1.0);
      final whole = _face(trackerPage(i, st), size);
      final face = still && i == front0 ? _face('assets/tracker/bg_$i.png', size) : whole;
      items.add((
        near: -d.abs(),
        w: Positioned(
          left: lo.width / 2 + x - size / 2,
          top: lo.top + (lo.face - size) / 2,
          width: size,
          child: Opacity(
            opacity: (1.0 - (d.abs() - 1.6).clamp(0.0, 0.7) / 0.7).clamp(0.0, 1.0),
            child: Transform(
              alignment: Alignment.center,
              transform: Matrix4.identity()
                ..setEntry(3, 2, 0.0011)
                ..rotateY(-phi * 3.2),             // facing the wheel's axis
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                _Shade(amount: dim, child: _rim(face, size, front)),
                SizedBox(height: size * 0.05),
                _Reflection(size: size, strength: 0.30 * (1 - dim), child: whole),
              ]),
            ),
          ),
        ),
      ));
    }
    items.sort((a, b) => a.near.compareTo(b.near)); // far ones first
    return SizedBox(
      width: lo.width,
      height: lo.height,
      child: Stack(clipBehavior: Clip.hardEdge, children: [
        // the glossy floor
        Positioned(
          left: 0,
          right: 0,
          top: lo.top + lo.face * 0.99,
          height: lo.face * 0.32,
          child: const DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: Alignment.topCenter,
                radius: 1.2,
                colors: [Color(0x1F00FF88), Color(0x00000000)],
              ),
            ),
          ),
        ),
        for (final it in items) it.w,
        if (still) ..._numberWheel(front0),
      ]),
    );
  }

  /// The number styles' wheel over the front face, centred on its count.
  List<Widget> _numberWheel(int th) {
    final lo = layout;
    final k = lo.k;
    final w = trackerCountWindows[th];
    final ww = w[2] * k, wh = w[3] * k;
    final left = lo.width / 2 - lo.face / 2 + w[0] * k;
    final top = lo.top + w[1] * k;
    final slot = lo.slot(th);
    final items = <({double near, Widget w})>[];
    for (var j = 0; j < trackerDigitStyles.length; j++) {
      final d = j - style;                       // slots from the middle
      if (d.abs() >= 1.6) continue;              // the near three only
      final a = d * 0.7;                         // tilt on the wheel
      final y = slot * math.sin(a) / math.sin(0.7); // ±1 slot at d = ±1
      final scale = 1 - 0.42 * d.abs().clamp(0.0, 1.0);
      final opacity = d.abs() <= 1
          ? 1 - 0.66 * d.abs()
          : 0.34 * (1.6 - d.abs()) / 0.6;        // the next one fades in
      items.add((
        near: -d.abs(),
        w: Positioned(
          left: left,
          top: top + y,
          width: ww,
          height: wh,
          child: IgnorePointer(
            child: Opacity(
              opacity: opacity.clamp(0.0, 1.0),
              child: Transform(
                alignment: Alignment.center,
                transform: Matrix4.identity()
                  ..setEntry(3, 2, 0.003)
                  ..rotateX(a)
                  ..scale(scale, scale),
                child: Image.asset('assets/tracker/count_${th}_$j.png',
                    width: ww, height: wh, fit: BoxFit.fill,
                    gaplessPlayback: true, filterQuality: FilterQuality.medium),
              ),
            ),
          ),
        ),
      ));
    }
    items.sort((a, b) => a.near.compareTo(b.near));
    return [for (final it in items) it.w];
  }

  Widget _face(String image, double size) => SizedBox(
        width: size,
        height: size,
        child: ColoredBox(
          color: Colors.black,
          child: Image.asset(image,
              width: size, height: size, fit: BoxFit.fill,
              gaplessPlayback: true, filterQuality: FilterQuality.medium),
        ),
      );

  Widget _rim(Widget face, double size, double front) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
              color: Color.lerp(const Color(0xFF333333), AppTheme.neonGreen, front * 0.55)!,
              width: 2),
          boxShadow: [
            BoxShadow(color: AppTheme.neonGreen.withValues(alpha: .16 * front), blurRadius: 22),
          ],
        ),
        child: ClipOval(child: face),
      );
}

/// Darkens what has turned away.
class _Shade extends StatelessWidget {
  final double amount;
  final Widget child;
  const _Shade({required this.amount, required this.child});

  @override
  Widget build(BuildContext context) {
    if (amount <= 0.01) return child;
    return ColorFiltered(
      colorFilter: ColorFilter.mode(
          Colors.black.withValues(alpha: amount.clamp(0.0, 1.0)), BlendMode.srcATop),
      child: child,
    );
  }
}

/// A face mirrored on the glossy floor, fading out.
class _Reflection extends StatelessWidget {
  final double size, strength;
  final Widget child;
  const _Reflection({required this.size, required this.strength, required this.child});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size * 0.26,
      child: ClipRect(
        child: Opacity(
          opacity: strength.clamp(0.0, 1.0),
          child: ShaderMask(
            blendMode: BlendMode.dstIn,
            shaderCallback: (r) => const LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Colors.white, Colors.transparent],
            ).createShader(r),
            child: OverflowBox(
              alignment: Alignment.topCenter,
              minHeight: size,
              maxHeight: size,
              child: Transform.flip(
                flipY: true,
                child: ClipOval(child: SizedBox(width: size, height: size, child: child)),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
