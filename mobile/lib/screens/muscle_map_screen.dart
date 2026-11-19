import 'package:flutter/material.dart';

import '../models/cable_exercise.dart';
import '../models/training_stats.dart';
import '../services/workout_store.dart';
import '../theme/app_theme.dart';
import '../widgets/anatomy_viewer.dart';

/// Which muscles got the work: weekly sets per muscle group, painted on the
/// 3D body (a group reaches full colour at [fullSets] sets), or how
/// recovered each muscle is now.
class MuscleMapScreen extends StatefulWidget {
  /// Open in recovery mode.
  final bool recovery;

  const MuscleMapScreen({super.key, this.recovery = false});

  /// Sets per week at which a muscle shows at full strength (a common
  /// hypertrophy target is 10 to 20 hard sets per muscle per week).
  static const double fullSets = 10;

  @override
  State<MuscleMapScreen> createState() => _MuscleMapScreenState();
}

class _MuscleMapScreenState extends State<MuscleMapScreen> {
  final AnatomyViewerController _viewer = AnatomyViewerController();
  bool _ready = false;
  int _weeksBack = 0; // 0 = this week
  late bool _recovery = widget.recovery;

  // A standing pose with the arms down, seen from the front.
  static final CableExercise _pose = cableExerciseByName('Cable Bicep Curl')!;

  Map<String, double> _sets() {
    final start =
        weekStart(DateTime.now()).subtract(Duration(days: 7 * _weeksBack));
    return WorkoutStore.instance.training
        .muscleSets(start, start.add(const Duration(days: 7)));
  }

  Map<String, MuscleRecovery> _rec() =>
      WorkoutStore.instance.training.recovery(DateTime.now());

  void _paint() {
    if (_recovery) {
      final r = _rec();
      _viewer.setHeat({for (final g in muscleGroupLabels.keys) g: r[g]!.fatigue});
      return;
    }
    final sets = _sets();
    _viewer.setHeat({
      for (final g in muscleGroupLabels.keys)
        g: ((sets[g] ?? 0) / MuscleMapScreen.fullSets).clamp(0.0, 1.0),
    });
  }

  void _onStatus(double _, bool ready) {
    if (ready && !_ready) {
      setState(() => _ready = true);
      _viewer.pause();
      _viewer.seek(0);
      _paint();
    }
  }

  void _week(int delta) {
    setState(() => _weeksBack = (_weeksBack + delta).clamp(0, 52));
    _paint();
  }

  void _mode(bool recovery) {
    setState(() => _recovery = recovery);
    _paint();
  }

  String _recoveryText(MuscleRecovery r, DateTime now) {
    if (r.recovering) {
      final h = r.readyIn?.inHours ?? 0;
      return h <= 1 ? 'Recovering · ready within the hour' : 'Recovering · ready in $h h';
    }
    if (r.lastTrained == null) return 'Never trained';
    final days = now.difference(r.lastTrained!).inDays;
    if (r.untrained(now)) return 'Not trained for $days days';
    return days == 0 ? 'Ready · trained today' : 'Ready · trained $days d ago';
  }

  Widget _modeChips() => Padding(
        padding: const EdgeInsets.fromLTRB(20, 6, 20, 2),
        child: Row(children: [
          for (final (label, rec) in [('Weekly sets', false), ('Recovery', true)])
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text(label),
                selected: _recovery == rec,
                onSelected: (_) => _mode(rec),
              ),
            ),
        ]),
      );

  Widget _recoveryList() {
    final now = DateTime.now();
    final r = _rec();
    final ranked = muscleGroupLabels.keys.toList()
      ..sort((a, b) {
        final c = r[b]!.fatigue.compareTo(r[a]!.fatigue);
        if (c != 0) return c;
        // Then the longest untrained first.
        final la = r[a]!.lastTrained, lb = r[b]!.lastTrained;
        if (la == null || lb == null) {
          return la == lb ? 0 : (la == null ? -1 : 1);
        }
        return la.compareTo(lb);
      });
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
      children: [
        for (final g in ranked)
          Padding(
            padding: const EdgeInsets.only(bottom: 7),
            child: Row(children: [
              Icon(
                  r[g]!.recovering
                      ? Icons.hourglass_bottom_rounded
                      : r[g]!.untrained(now)
                          ? Icons.remove_circle_outline_rounded
                          : Icons.check_circle_outline_rounded,
                  size: 15,
                  color: r[g]!.recovering
                      ? const Color(0xFFFFC857)
                      : r[g]!.untrained(now)
                          ? AppTheme.textMuted
                          : AppTheme.neonGreen),
              const SizedBox(width: 8),
              SizedBox(
                width: 120,
                child: Text(muscleGroupLabels[g]!,
                    style: const TextStyle(color: AppTheme.textPrimary, fontSize: 12)),
              ),
              Expanded(
                child: Text(_recoveryText(r[g]!, now),
                    textAlign: TextAlign.right,
                    style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
              ),
            ]),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final sets = _sets();
    final ranked = muscleGroupLabels.keys.toList()
      ..sort((a, b) => (sets[b] ?? 0).compareTo(sets[a] ?? 0));
    final label = _weeksBack == 0
        ? 'This week'
        : _weeksBack == 1
            ? 'Last week'
            : '$_weeksBack weeks ago';
    return Scaffold(
      backgroundColor: AppTheme.darkBg,
      appBar: AppBar(title: const Text('Muscle map')),
      body: SafeArea(
        child: Column(children: [
          _modeChips(),
          if (!_recovery)
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            IconButton(
                onPressed: () => _week(1),
                icon: const Icon(Icons.chevron_left_rounded)),
            SizedBox(
              width: 120,
              child: Text(label,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      color: AppTheme.textPrimary,
                      fontWeight: FontWeight.w700)),
            ),
            IconButton(
                onPressed: _weeksBack == 0 ? null : () => _week(-1),
                icon: const Icon(Icons.chevron_right_rounded)),
          ]),
          Expanded(
            flex: 5,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(22),
                child: Stack(children: [
                  Positioned.fill(
                    child: AnatomyViewer(
                      exercise: _pose,
                      controller: _viewer,
                      onStatus: _onStatus,
                      initialOrbit: '0deg 82deg 4.6m',
                      initialTarget: '0m 1.0m 0m',
                    ),
                  ),
                  if (!_ready)
                    const Positioned.fill(
                      child: ColoredBox(
                        color: AnatomyViewer.background,
                        child: Center(
                          child: CircularProgressIndicator(
                              strokeWidth: 2.5, color: AppTheme.neonGreen),
                        ),
                      ),
                    ),
                  Positioned(
                    left: 12,
                    top: 12,
                    child: Row(children: [
                      _chip('FRONT', '0deg 82deg 4.6m'),
                      _chip('BACK', '180deg 82deg 4.6m'),
                    ]),
                  ),
                ]),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 4),
            child: Text(
              _recovery
                  ? 'Brighter = still recovering. A hard set takes about two '
                      'days to wear off; assisting muscles count half.'
                  : 'Brighter = more sets. Prime movers count 1 set, assisting '
                      'muscles half. Full colour at 10 sets a week.',
              style: const TextStyle(color: AppTheme.textMuted, fontSize: 11),
            ),
          ),
          Expanded(
            flex: 3,
            child: _recovery ? _recoveryList() : ListView(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
              children: [
                for (final g in ranked)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 7),
                    child: Row(children: [
                      SizedBox(
                        width: 140,
                        child: Text(muscleGroupLabels[g]!,
                            style: TextStyle(
                                color: (sets[g] ?? 0) > 0
                                    ? AppTheme.textPrimary
                                    : AppTheme.textMuted,
                                fontSize: 12)),
                      ),
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(3),
                          child: LinearProgressIndicator(
                            value: ((sets[g] ?? 0) / MuscleMapScreen.fullSets)
                                .clamp(0.0, 1.0),
                            minHeight: 6,
                            backgroundColor: AppTheme.cardBgLight,
                            valueColor: const AlwaysStoppedAnimation(
                                AppTheme.neonGreen),
                          ),
                        ),
                      ),
                      SizedBox(
                        width: 40,
                        child: Text(_fmt(sets[g] ?? 0),
                            textAlign: TextAlign.right,
                            style: const TextStyle(
                                color: AppTheme.textSecondary, fontSize: 12)),
                      ),
                    ]),
                  ),
              ],
            ),
          ),
        ]),
      ),
    );
  }

  Widget _chip(String label, String orbit) => Padding(
        padding: const EdgeInsets.only(right: 6),
        child: GestureDetector(
          onTap: () => _viewer.setOrbit(orbit),
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
}

String _fmt(double v) =>
    v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
