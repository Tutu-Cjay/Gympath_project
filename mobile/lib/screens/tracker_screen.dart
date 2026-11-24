import 'dart:async';

import 'package:flutter/material.dart';

import '../services/ble_service.dart';
import '../theme/app_theme.dart';
import 'firmware_update_screen.dart';
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

/// The tracker: link, battery, firmware, and how its rep screen looks.
///
/// One round preview of the tracker: swipe sideways for the theme, up or
/// down for the count's number style (it slides inside its own spot in the
/// middle of the theme). On firmware 1.7+ the tracker follows the swipe
/// live; the choice is saved when the preview comes to rest.
class TrackerScreen extends StatefulWidget {
  const TrackerScreen({super.key});

  @override
  State<TrackerScreen> createState() => _TrackerScreenState();
}

class _TrackerScreenState extends State<TrackerScreen>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  final _ble = BleService.instance;
  late final AnimationController _settle;
  String? _version;
  Timer? _keepAlive;
  bool _previewing = false;

  // where the preview stands, in pages (fractions while moving)
  double _t = 0, _s = 0;
  int _lastAxis = themeAxis;
  int? _axis;                 // locked by the drag's first movement
  Offset _drag = Offset.zero; // since the drag started
  double _from = 0, _to = 0;  // settle animation along _axis
  double _startPos = 0;
  double _pageW = 1, _pageH = 1; // px per page sideways / up-down

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
    _ble.connectionState.addListener(_onLink);
    _ble.trackerTheme.addListener(_syncTheme);
    _ble.trackerDigits.addListener(_syncDigits);
    _ble.trackerLivePreview.addListener(_startPreview);
    _onLink();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    for (var t = 0; t < trackerThemes.length; t++) {
      for (var s = 0; s < trackerDigitStyles.length; s++) {
        precacheImage(AssetImage(trackerPage(t, s)), context);
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopPreview();
    _ble.connectionState.removeListener(_onLink);
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

  void _onLink() {
    _readVersion();
    _startPreview();
  }

  Future<void> _readVersion() async {
    if (!_ble.isConnected) {
      if (mounted) setState(() => _version = null);
      return;
    }
    final v = await _ble.readFirmwareVersion();
    if (mounted) setState(() => _version = v);
  }

  // ---- live preview on the tracker ----

  /// Shows the rep screen on the tracker while this screen is open.
  void _startPreview() {
    if (!mounted) return;
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

  // ---- moving ----

  int _count(int axis) =>
      axis == themeAxis ? trackerThemes.length : trackerDigitStyles.length;
  double _pos(int axis) => axis == themeAxis ? _t : _s;

  /// Moves one axis; the tracker gets the position clamped to real pages.
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

  void _onPanStart(DragStartDetails d) {
    if (_settle.isAnimating) {   // caught while settling: finish it first
      _settle.stop();
      _set(_lastAxis, _to);
      _saveAxis(_lastAxis);
    }
    _axis = null;
    _drag = Offset.zero;
  }

  void _onPanUpdate(DragUpdateDetails d) {
    _drag += d.delta;
    if (_axis == null) {
      if (_drag.distance < 8) return;          // which way: decided once
      _axis = _drag.dx.abs() >= _drag.dy.abs() ? themeAxis : digitsAxis;
      _startPos = _pos(_axis!);
    }
    final axis = _axis!;
    final n = _count(axis) - 1.0;
    // finger left / up = next page; the page follows the finger exactly
    var v = _startPos -
        (axis == themeAxis ? _drag.dx / _pageW : _drag.dy / _pageH);
    if (v < 0) v *= 0.3;                       // rubber band at the ends
    if (v > n) v = n + (v - n) * 0.3;
    _set(axis, v);
  }

  void _onPanEnd(DragEndDetails d) {
    final axis = _axis;
    _axis = null;
    if (axis == null) return;
    final pos = _pos(axis);
    final vel = axis == themeAxis
        ? -d.velocity.pixelsPerSecond.dx / _pageW
        : -d.velocity.pixelsPerSecond.dy / _pageH; // pages per second
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
    _settle.duration = Duration(milliseconds: (160 + 220 * dist).round().clamp(120, 420));
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
  /// unless the user is moving that axis.
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

  Future<void> _openUpdates() async {
    _stopPreview(); // the update screen needs the tracker's own screen
    await Navigator.push(
        context, MaterialPageRoute(builder: (_) => const FirmwareUpdateScreen()));
    _startPreview();
  }

  // ---- UI ----

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.darkBg,
      appBar: AppBar(title: const Text('Tracker')),
      body: ValueListenableBuilder<BleConnectionState>(
        valueListenable: _ble.connectionState,
        builder: (context, link, _) {
          final connected = link == BleConnectionState.connected;
          return ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
            children: [
              _statusCard(connected),
              const SizedBox(height: 22),
              const Text('REP SCREEN',
                  style: TextStyle(
                      color: AppTheme.textSecondary,
                      fontSize: 11,
                      letterSpacing: 1.2,
                      fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              Text(
                  connected && _ble.trackerLivePreview.value
                      ? 'Swipe sideways for the theme, up or down for the '
                          'numbers — the tracker follows as you swipe.'
                      : 'Swipe sideways for the theme, up or down for the numbers.',
                  style: const TextStyle(color: AppTheme.textMuted, fontSize: 12)),
              const SizedBox(height: 12),
              ..._notes(connected),
              _chooser(),
            ],
          );
        },
      ),
    );
  }

  List<Widget> _notes(bool connected) {
    final theme = _ble.trackerTheme.value, digits = _ble.trackerDigits.value;
    if (!connected) return [_note('Connect the tracker to change its rep screen.')];
    if (theme == null) {
      return [_note('Update the tracker to firmware 1.5 or newer to choose its rep screen.')];
    }
    if (digits == null) {
      return [_note('Update the tracker to firmware 1.6 or newer to choose its number style.')];
    }
    return const [];
  }

  Widget _note(String text) => Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppTheme.cardBg,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(text,
            style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
      );

  Widget _chooser() {
    final ti = _t.round().clamp(0, trackerThemes.length - 1);
    final si = _s.round().clamp(0, trackerDigitStyles.length - 1);
    final savedT = _ble.trackerTheme.value, savedS = _ble.trackerDigits.value;
    return Column(children: [
      LayoutBuilder(builder: (context, box) {
        final size = (box.maxWidth - 40).clamp(180.0, 300.0);
        _pageW = size;
        final win = trackerCountWindows[ti];
        _pageH = win[3] * size / 240;
        return Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          const SizedBox(width: 20),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanStart: _onPanStart,
            onPanUpdate: _onPanUpdate,
            onPanEnd: _onPanEnd,
            child: Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: const Color(0xFF333333), width: 2),
                boxShadow: [
                  BoxShadow(color: AppTheme.neonGreen.withValues(alpha: .10), blurRadius: 24),
                ],
              ),
              child: ClipOval(child: TrackerPreview(theme: _t, style: _s, size: size)),
            ),
          ),
          SizedBox(width: 20, child: _dots(trackerDigitStyles.length, _s, Axis.vertical)),
        ]);
      }),
      const SizedBox(height: 10),
      _dots(trackerThemes.length, _t, Axis.horizontal),
      const SizedBox(height: 12),
      Row(children: [
        Expanded(
          child: _label(Icons.swap_horiz_rounded, trackerThemes[ti].name,
              trackerThemes[ti].description, savedT == ti),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _label(Icons.swap_vert_rounded, trackerDigitStyles[si].name,
              'Number style', savedS == si),
        ),
      ]),
    ]);
  }

  Widget _label(IconData icon, String name, String sub, bool saved) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppTheme.cardBg,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, color: AppTheme.neonGreen, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Flexible(
                  child: Text(name,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: 14,
                          fontWeight: FontWeight.w700)),
                ),
                if (saved) ...[
                  const SizedBox(width: 4),
                  const Icon(Icons.check_circle_rounded, color: AppTheme.neonGreen, size: 14),
                ],
              ]),
              const SizedBox(height: 2),
              Text(sub,
                  maxLines: 2,
                  style: const TextStyle(color: AppTheme.textSecondary, fontSize: 11)),
            ]),
          ),
        ]),
      );

  Widget _dots(int n, double page, Axis axis) {
    final dots = [
      for (var i = 0; i < n; i++)
        Builder(builder: (_) {
          final d = (page - i).abs().clamp(0.0, 1.0);
          final long = 6 + 10 * (1 - d);
          return Container(
            width: axis == Axis.horizontal ? long : 6,
            height: axis == Axis.horizontal ? 6 : long,
            margin: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              color: Color.lerp(AppTheme.neonGreen, AppTheme.cardBgLight, d),
              borderRadius: BorderRadius.circular(3),
            ),
          );
        }),
    ];
    return axis == Axis.horizontal
        ? Row(mainAxisAlignment: MainAxisAlignment.center, children: dots)
        : Column(mainAxisSize: MainAxisSize.min, children: dots);
  }

  Widget _statusCard(bool connected) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.cardBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
            color: connected ? AppTheme.neonGreen.withValues(alpha: .5) : AppTheme.cardBgLight),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.watch_rounded,
              color: connected ? AppTheme.neonGreen : AppTheme.textMuted, size: 30),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(connected ? 'Connected' : 'Not connected',
                  style: const TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: 16,
                      fontWeight: FontWeight.bold)),
              Text(
                  connected
                      ? 'Firmware ${_version ?? '…'}'
                      : 'Turn the tracker on and tap the link button on Home',
                  style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
            ]),
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
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: _openUpdates,
            icon: const Icon(Icons.system_update_rounded, size: 18),
            label: const Text('Check for firmware updates'),
            style: OutlinedButton.styleFrom(
                foregroundColor: AppTheme.neonGreen,
                side: const BorderSide(color: AppTheme.cardBgLight)),
          ),
        ),
      ]),
    );
  }
}

/// The tracker's round screen at a preview position, drawn the way the
/// firmware's live preview composes it: [theme] between two themes slides
/// the whole screen sideways; [style] between two styles slides only the
/// count, up and down inside its own window in the middle of the theme.
class TrackerPreview extends StatelessWidget {
  final double theme, style, size;
  const TrackerPreview({super.key, required this.theme, required this.style, required this.size});

  @override
  Widget build(BuildContext context) {
    final nt = trackerThemes.length, ns = trackerDigitStyles.length;
    final t = theme.clamp(0.0, nt - 1.0), s = style.clamp(0.0, ns - 1.0);
    final ta = t.floor().clamp(0, nt - 1), sa = s.floor().clamp(0, ns - 1);
    final tf = t - ta, sf = s - sa;
    final k = size / 240;
    Widget page(int th, int st) => Image.asset(trackerPage(th, st),
        width: size, height: size, fit: BoxFit.fill,
        gaplessPlayback: true, filterQuality: FilterQuality.medium);

    final children = <Widget>[
      // themes, side by side
      for (final i in [ta, if (tf > 0 && ta + 1 < nt) ta + 1])
        Positioned(left: (i - t) * size, top: 0, child: page(i, s.round())),
    ];
    if (sf > 0 && tf == 0 && sa + 1 < ns) {
      // number styles: one above the other inside the count's window
      final w = trackerCountWindows[ta];
      final wx = w[0] * k, wy = w[1] * k, ww = w[2] * k, wh = w[3] * k;
      children.add(Positioned(
        left: wx,
        top: wy,
        width: ww,
        height: wh,
        child: ClipRect(
          child: Stack(clipBehavior: Clip.none, children: [
            Positioned(left: -wx, top: -wy - sf * wh, child: page(ta, sa)),
            Positioned(left: -wx, top: -wy + (1 - sf) * wh, child: page(ta, sa + 1)),
          ]),
        ),
      ));
    }
    return SizedBox(
      width: size,
      height: size,
      child: ColoredBox(
        color: Colors.black,
        child: Stack(clipBehavior: Clip.hardEdge, children: children),
      ),
    );
  }
}
