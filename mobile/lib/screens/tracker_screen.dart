import 'dart:async';

import 'package:flutter/material.dart';

import '../services/ble_service.dart';
import '../theme/app_theme.dart';
import 'firmware_update_screen.dart';

/// A rep screen look the tracker can show (firmware Gympath_Track 1.5+).
class TrackerTheme {
  final int id; // value sent to the tracker
  final String name;
  final String description;
  const TrackerTheme(this.id, this.name, this.description);

  String get image => 'assets/tracker/theme_$id.png';
}

/// How the rep count's digits look (firmware 1.6+): the same on every theme.
class TrackerDigits {
  final int id; // value sent to the tracker
  final String name;
  const TrackerDigits(this.id, this.name);

  String get image => 'assets/tracker/digits_$id.png';
}

const List<TrackerDigits> trackerDigitStyles = [
  TrackerDigits(0, 'Segment'),
  TrackerDigits(1, 'Rounded'),
  TrackerDigits(2, 'Bold'),
  TrackerDigits(3, 'Light'),
];

const List<TrackerTheme> trackerThemes = [
  TrackerTheme(0, 'Classic', 'Segment digits, ring coloured by speed'),
  TrackerTheme(1, 'Stroke', 'The ring fills with each rep\'s travel'),
  TrackerTheme(2, 'Tempo', 'Lift / lower, and each rep\'s up and down time'),
  TrackerTheme(3, 'Minimal', 'Big count, a dot per rep'),
];

/// Carousel axes, as the tracker's live preview numbers them.
const int themeAxis = 0, digitsAxis = 1;

/// The tracker: link, battery, firmware, and how its rep screen looks.
///
/// Themes are chosen by swiping sideways, number styles by swiping up and
/// down. On firmware 1.7+ the tracker follows the swipe live (the app sends
/// the carousel's position as it moves); the choice is saved when the
/// carousel comes to rest.
class TrackerScreen extends StatefulWidget {
  const TrackerScreen({super.key});

  @override
  State<TrackerScreen> createState() => _TrackerScreenState();
}

class _TrackerScreenState extends State<TrackerScreen>
    with WidgetsBindingObserver {
  final _ble = BleService.instance;
  late final PageController _themes;
  late final PageController _digits;
  String? _version;
  Timer? _keepAlive;
  bool _previewing = false;
  int _lastAxis = themeAxis;
  final Set<int> _dragging = {}; // axes the user is moving

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _themes = PageController(
        viewportFraction: 0.62, initialPage: _ble.trackerTheme.value ?? 0);
    _digits = PageController(
        viewportFraction: 0.42, initialPage: _ble.trackerDigits.value ?? 0);
    _themes.addListener(() => _moved(themeAxis));
    _digits.addListener(() => _moved(digitsAxis));
    _ble.connectionState.addListener(_onLink);
    _ble.trackerTheme.addListener(_syncTheme);
    _ble.trackerDigits.addListener(_syncDigits);
    _ble.trackerLivePreview.addListener(_startPreview);
    _onLink();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopPreview();
    _ble.connectionState.removeListener(_onLink);
    _ble.trackerTheme.removeListener(_syncTheme);
    _ble.trackerDigits.removeListener(_syncDigits);
    _ble.trackerLivePreview.removeListener(_startPreview);
    _themes.dispose();
    _digits.dispose();
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

  double _page(PageController c, int fallback) =>
      c.hasClients && c.position.haveDimensions ? (c.page ?? 0) : fallback.toDouble();

  void _send(int axis) {
    if (!_previewing) return;
    final page = axis == themeAxis
        ? _page(_themes, _ble.trackerTheme.value ?? 0)
        : _page(_digits, _ble.trackerDigits.value ?? 0);
    _ble.sendPreview(axis, page);
  }

  void _moved(int axis) {
    _lastAxis = axis;
    _send(axis);
  }

  // ---- saving the choice ----

  void _syncTheme() => _jumpTo(_themes, themeAxis, _ble.trackerTheme.value);
  void _syncDigits() => _jumpTo(_digits, digitsAxis, _ble.trackerDigits.value);

  /// The tracker's setting changed (read on connect, or saved): show it,
  /// unless the user is moving that carousel.
  void _jumpTo(PageController c, int axis, int? page) {
    if (page == null || _dragging.contains(axis) || !c.hasClients) return;
    if ((c.page ?? -1).round() != page) c.jumpToPage(page);
    if (mounted) setState(() {});
  }

  bool _onScroll(int axis, ScrollNotification n) {
    if (n.depth != 0) return false;
    if (n is ScrollStartNotification && n.dragDetails != null) {
      _dragging.add(axis);
    } else if (n is ScrollEndNotification) {
      _dragging.remove(axis);
      _settled(axis);
    }
    return false;
  }

  Future<void> _settled(int axis) async {
    final c = axis == themeAxis ? _themes : _digits;
    if (!c.hasClients) return;
    final page = (c.page ?? 0).round();
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
          return ValueListenableBuilder<bool>(
            valueListenable: _ble.trackerLivePreview,
            builder: (context, live, _) => ListView(
              padding: const EdgeInsets.fromLTRB(0, 8, 0, 24),
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: _statusCard(connected),
                ),
                const SizedBox(height: 22),
                _section(
                  'REP SCREEN',
                  connected && live
                      ? 'Swipe sideways — the tracker follows as you swipe.'
                      : 'Swipe sideways to choose what the tracker shows while '
                          'it counts your reps.',
                ),
                _themeCarousel(connected),
                const SizedBox(height: 22),
                _section(
                  'NUMBERS',
                  'Swipe up or down for the count\'s style, on every screen. '
                      'It always stays centred, however many digits.',
                ),
                _digitsCarousel(connected),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _section(String title, String hint) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title,
              style: const TextStyle(
                  color: AppTheme.textSecondary,
                  fontSize: 11,
                  letterSpacing: 1.2,
                  fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text(hint, style: const TextStyle(color: AppTheme.textMuted, fontSize: 12)),
        ]),
      );

  Widget _note(String text) => Container(
        width: double.infinity,
        margin: const EdgeInsets.fromLTRB(20, 0, 20, 12),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppTheme.cardBg,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(text,
            style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
      );

  Widget _themeCarousel(bool connected) {
    return ValueListenableBuilder<int?>(
      valueListenable: _ble.trackerTheme,
      builder: (context, saved, _) => Column(children: [
        if (!connected) _note('Connect the tracker to change its rep screen.'),
        if (connected && saved == null)
          _note('Update the tracker to firmware 1.5 or newer to choose its rep screen.'),
        SizedBox(
          height: 230,
          child: NotificationListener<ScrollNotification>(
            onNotification: (n) => _onScroll(themeAxis, n),
            child: PageView.builder(
              controller: _themes,
              itemCount: trackerThemes.length,
              itemBuilder: (context, i) => AnimatedBuilder(
                animation: _themes,
                builder: (context, child) {
                  final d = (_page(_themes, saved ?? 0) - i).abs().clamp(0.0, 1.0);
                  return Transform.scale(
                    scale: 1 - 0.18 * d,
                    child: Opacity(opacity: 1 - 0.45 * d, child: child),
                  );
                },
                child: _ThemeFace(theme: trackerThemes[i], selected: saved == i),
              ),
            ),
          ),
        ),
        const SizedBox(height: 10),
        AnimatedBuilder(
          animation: _themes,
          builder: (context, _) {
            final i = _page(_themes, saved ?? 0).round().clamp(0, trackerThemes.length - 1);
            final t = trackerThemes[i];
            return Column(children: [
              Text(t.name,
                  style: const TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: 16,
                      fontWeight: FontWeight.w700)),
              const SizedBox(height: 2),
              Text(t.description,
                  style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
              const SizedBox(height: 10),
              _dots(trackerThemes.length, _page(_themes, saved ?? 0)),
            ]);
          },
        ),
      ]),
    );
  }

  Widget _digitsCarousel(bool connected) {
    return ValueListenableBuilder<int?>(
      valueListenable: _ble.trackerDigits,
      builder: (context, saved, _) => Column(children: [
        if (connected && saved == null)
          _note('Update the tracker to firmware 1.6 or newer to choose its number style.'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Container(
            height: 230,
            decoration: BoxDecoration(
              color: AppTheme.cardBg,
              borderRadius: BorderRadius.circular(18),
            ),
            child: Row(children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(18),
                  child: NotificationListener<ScrollNotification>(
                    onNotification: (n) => _onScroll(digitsAxis, n),
                    child: PageView.builder(
                      controller: _digits,
                      scrollDirection: Axis.vertical,
                      itemCount: trackerDigitStyles.length,
                      itemBuilder: (context, i) => AnimatedBuilder(
                        animation: _digits,
                        builder: (context, child) {
                          final d = (_page(_digits, saved ?? 0) - i).abs().clamp(0.0, 1.0);
                          return Opacity(
                            opacity: 1 - 0.65 * d,
                            child: Transform.scale(scale: 1 - 0.15 * d, child: child),
                          );
                        },
                        child: _DigitsFace(
                            style: trackerDigitStyles[i], selected: saved == i),
                      ),
                    ),
                  ),
                ),
              ),
              // the styles, the current one lit; tap to scroll to one
              SizedBox(
                width: 112,
                child: AnimatedBuilder(
                  animation: _digits,
                  builder: (context, _) {
                    final cur = _page(_digits, saved ?? 0);
                    return Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final s in trackerDigitStyles)
                          InkWell(
                            onTap: () => _digits.animateToPage(s.id,
                                duration: const Duration(milliseconds: 380),
                                curve: Curves.easeOutCubic),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 7),
                              child: Row(children: [
                                Container(
                                  width: 3,
                                  height: 16,
                                  color: cur.round() == s.id
                                      ? AppTheme.neonGreen
                                      : Colors.transparent,
                                ),
                                const SizedBox(width: 8),
                                Text(s.name,
                                    style: TextStyle(
                                        color: Color.lerp(
                                            AppTheme.textPrimary,
                                            AppTheme.textMuted,
                                            (cur - s.id).abs().clamp(0.0, 1.0)),
                                        fontSize: 14,
                                        fontWeight: cur.round() == s.id
                                            ? FontWeight.w700
                                            : FontWeight.w500)),
                                if (saved == s.id) ...[
                                  const SizedBox(width: 4),
                                  const Icon(Icons.check_rounded,
                                      color: AppTheme.neonGreen, size: 14),
                                ],
                              ]),
                            ),
                          ),
                      ],
                    );
                  },
                ),
              ),
            ]),
          ),
        ),
      ]),
    );
  }

  Widget _dots(int n, double page) => Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (var i = 0; i < n; i++)
            Container(
              width: 6 + 10 * (1 - (page - i).abs().clamp(0.0, 1.0)),
              height: 6,
              margin: const EdgeInsets.symmetric(horizontal: 3),
              decoration: BoxDecoration(
                color: Color.lerp(AppTheme.neonGreen, AppTheme.cardBgLight,
                    (page - i).abs().clamp(0.0, 1.0)),
                borderRadius: BorderRadius.circular(3),
              ),
            ),
        ],
      );

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

/// One theme in the carousel: the tracker's round screen.
class _ThemeFace extends StatelessWidget {
  final TrackerTheme theme;
  final bool selected;
  const _ThemeFace({required this.theme, required this.selected});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: AspectRatio(
        aspectRatio: 1,
        child: Container(
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: const Color(0xFF1F1F1F),
            border: Border.all(
                color: selected ? AppTheme.neonGreen : const Color(0xFF333333),
                width: selected ? 2.5 : 1.5),
            boxShadow: selected
                ? [BoxShadow(color: AppTheme.neonGreen.withValues(alpha: .18), blurRadius: 18)]
                : null,
          ),
          child: ClipOval(child: Image.asset(theme.image, fit: BoxFit.cover)),
        ),
      ),
    );
  }
}

/// One number style in the vertical carousel: the count's band of the
/// tracker screen.
class _DigitsFace extends StatelessWidget {
  final TrackerDigits style;
  final bool selected;
  const _DigitsFace({required this.style, required this.selected});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.black,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
              color: selected ? AppTheme.neonGreen : const Color(0xFF2E2E2E),
              width: selected ? 2 : 1),
        ),
        clipBehavior: Clip.antiAlias,
        child: Image.asset(style.image, fit: BoxFit.cover, alignment: Alignment.center),
      ),
    );
  }
}
