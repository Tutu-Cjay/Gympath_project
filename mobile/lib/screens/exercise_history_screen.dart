import 'package:flutter/material.dart';

import '../models/training_stats.dart';
import '../models/workout_session.dart';
import '../services/workout_store.dart';
import '../theme/app_theme.dart';
import '../widgets/progress_chart.dart';
import '../widgets/rep_bars.dart';
import 'cable_track_screen.dart';

enum _Metric { oneRepMax, topWeight, volume, speed }

extension on _Metric {
  String get label => switch (this) {
        _Metric.oneRepMax => 'Est. 1RM',
        _Metric.topWeight => 'Top weight',
        _Metric.volume => 'Volume',
        _Metric.speed => 'Avg speed',
      };
}

/// One exercise over time: records, a chart of the chosen metric and every
/// set, grouped by day. A set can be deleted with a long press.
class ExerciseHistoryScreen extends StatefulWidget {
  final String exercise;
  const ExerciseHistoryScreen({super.key, required this.exercise});

  @override
  State<ExerciseHistoryScreen> createState() => _ExerciseHistoryScreenState();
}

class _ExerciseHistoryScreenState extends State<ExerciseHistoryScreen> {
  _Metric _metric = _Metric.oneRepMax;

  List<ChartPoint> _points(TrainingStats t) {
    if (_metric == _Metric.speed) {
      final byDay = <DateTime, List<double>>{};
      for (final s in t.setsOf(widget.exercise)) {
        if (s.meanVelocity <= 0) continue;
        byDay.putIfAbsent(dayOf(s.timestamp), () => []).add(s.meanVelocity);
      }
      final days = byDay.keys.toList()..sort();
      return [
        for (final d in days)
          ChartPoint(d, byDay[d]!.reduce((a, b) => a + b) / byDay[d]!.length),
      ];
    }
    return [
      for (final d in t.history(widget.exercise))
        if (_value(d) > 0) ChartPoint(d.day, _value(d)),
    ];
  }

  double _value(DayBest d) => switch (_metric) {
        _Metric.oneRepMax => d.estimatedOneRepMax,
        _Metric.topWeight => d.topWeightKg,
        _Metric.volume => d.volumeKg,
        _Metric.speed => 0,
      };

  Future<void> _delete(WorkoutSession s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.cardBg,
        title: const Text('Delete this set?'),
        content: Text(
            '${s.workoutName}, set ${s.setIndex}: ${_line(s)}. This cannot be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete',
                  style: TextStyle(color: Color(0xFFFF6B6B)))),
        ],
      ),
    );
    if (ok == true) await WorkoutStore.instance.removeSession(s);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.darkBg,
      appBar: AppBar(title: Text(widget.exercise)),
      body: ValueListenableBuilder<WorkoutStats>(
        valueListenable: WorkoutStore.instance.stats,
        builder: (context, _, __) {
          final t = WorkoutStore.instance.training;
          final sets = t.setsOf(widget.exercise).reversed.toList();
          final records = t.records(widget.exercise);
          final points = _points(t);
          final byDay = <DateTime, List<WorkoutSession>>{};
          for (final s in sets) {
            byDay.putIfAbsent(dayOf(s.timestamp), () => []).add(s);
          }
          return ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
            children: [
              if (!records.isEmpty) _Records(records: records),
              const SizedBox(height: 16),
              Wrap(spacing: 8, children: [
                for (final m in _Metric.values)
                  ChoiceChip(
                    label: Text(m.label),
                    selected: _metric == m,
                    onSelected: (_) => setState(() => _metric = m),
                    selectedColor: AppTheme.neonGreen,
                    backgroundColor: AppTheme.cardBg,
                    labelStyle: TextStyle(
                        color: _metric == m ? Colors.black : AppTheme.textSecondary,
                        fontSize: 12,
                        fontWeight: FontWeight.w600),
                    showCheckmark: false,
                  ),
              ]),
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.fromLTRB(8, 12, 8, 8),
                decoration: BoxDecoration(
                  color: AppTheme.cardBg,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: AppTheme.cardBgLight),
                ),
                child: ProgressChart(
                  points: points,
                  unit: _metric == _Metric.speed ? 'm/s' : 'kg',
                  decimals: _metric == _Metric.speed ? 2 : 0,
                ),
              ),
              if (_metric == _Metric.oneRepMax)
                const Padding(
                  padding: EdgeInsets.only(top: 6),
                  child: Text(
                    'Estimated one-rep max (Epley) from your best set of the day. '
                    'A guide to strength trends, not a weight to attempt.',
                    style: TextStyle(color: AppTheme.textMuted, fontSize: 11),
                  ),
                ),
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) =>
                              CableTrackScreen(workoutName: widget.exercise))),
                  icon: const Icon(Icons.play_arrow_rounded),
                  label: const Text('Train this exercise'),
                ),
              ),
              const SizedBox(height: 22),
              const Text('HISTORY  ·  LONG-PRESS A SET TO DELETE',
                  style: TextStyle(
                      color: AppTheme.textSecondary,
                      fontSize: 11,
                      letterSpacing: 1.3,
                      fontWeight: FontWeight.w700)),
              const SizedBox(height: 10),
              if (sets.isEmpty)
                const Text('No sets left for this exercise.',
                    style: TextStyle(color: AppTheme.textMuted, fontSize: 12)),
              for (final day in byDay.keys) ...[
                Padding(
                  padding: const EdgeInsets.only(top: 6, bottom: 6),
                  child: Text(_dayLabel(day),
                      style: const TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: 13,
                          fontWeight: FontWeight.w700)),
                ),
                for (final s in byDay[day]!.reversed)
                  _SetRow(set: s, onLongPress: () => _delete(s)),
              ],
            ],
          );
        },
      ),
    );
  }
}

String _kg(double v) =>
    v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);

String _line(WorkoutSession s) =>
    s.weightKg > 0 ? '${_kg(s.weightKg)} kg × ${s.reps}' : '${s.reps} reps';

String _dayLabel(DateTime d) {
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug',
      'Sep', 'Oct', 'Nov', 'Dec'];
  final today = dayOf(DateTime.now());
  if (d == today) return 'Today';
  if (d == today.subtract(const Duration(days: 1))) return 'Yesterday';
  return '${months[d.month - 1]} ${d.day}, ${d.year}';
}

class _Records extends StatelessWidget {
  final PersonalRecords records;
  const _Records({required this.records});

  @override
  Widget build(BuildContext context) {
    Widget tile(String label, WorkoutSession? s, String Function(WorkoutSession) value) =>
        Expanded(
          child: Container(
            padding: const EdgeInsets.all(10),
            margin: const EdgeInsets.symmetric(horizontal: 3),
            decoration: BoxDecoration(
              color: AppTheme.cardBg,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppTheme.cardBgLight),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label,
                  style: const TextStyle(
                      color: AppTheme.textSecondary, fontSize: 10)),
              const SizedBox(height: 3),
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(s == null ? '—' : value(s),
                    style: const TextStyle(
                        color: AppTheme.neonGreen,
                        fontSize: 16,
                        fontWeight: FontWeight.w800)),
              ),
            ]),
          ),
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Row(children: [
        Icon(Icons.emoji_events_rounded, color: AppTheme.neonGreen, size: 16),
        SizedBox(width: 6),
        Text('PERSONAL RECORDS',
            style: TextStyle(
                color: AppTheme.textSecondary,
                fontSize: 11,
                letterSpacing: 1.3,
                fontWeight: FontWeight.w700)),
      ]),
      const SizedBox(height: 8),
      Row(children: [
        tile('Heaviest', records.heaviest, (s) => '${_kg(s.weightKg)} kg'),
        tile('Est. 1RM', records.bestOneRepMax,
            (s) => '${s.estimatedOneRepMax.toStringAsFixed(1)} kg'),
      ]),
      const SizedBox(height: 6),
      Row(children: [
        tile('Best set volume', records.mostVolume, (s) => '${s.volumeKg.round()} kg'),
        tile('Fastest set', records.fastest,
            (s) => '${s.meanVelocity.toStringAsFixed(2)} m/s'),
      ]),
    ]);
  }
}

class _SetRow extends StatelessWidget {
  final WorkoutSession set;
  final VoidCallback onLongPress;
  const _SetRow({required this.set, required this.onLongPress});

  @override
  Widget build(BuildContext context) {
    final loss = set.velocityLoss;
    return GestureDetector(
      onLongPress: onLongPress,
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        decoration: BoxDecoration(
          color: AppTheme.cardBg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.cardBgLight),
        ),
        child: Row(children: [
          SizedBox(
            width: 44,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('SET ${set.setIndex}',
                  style: const TextStyle(
                      color: AppTheme.textMuted,
                      fontSize: 10,
                      fontWeight: FontWeight.w800)),
              if (set.simulated)
                const Text('SIM',
                    style: TextStyle(
                        color: Color(0xFFFFC94D),
                        fontSize: 9,
                        fontWeight: FontWeight.w800)),
            ]),
          ),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(_line(set),
                  style: const TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: 14,
                      fontWeight: FontWeight.w600)),
              if (set.meanVelocity > 0)
                Text(
                    '${set.meanVelocity.toStringAsFixed(2)} m/s avg'
                    '${set.meanRangeCm > 0 ? ' · ${set.meanRangeCm.round()} cm range' : ''}'
                    '${loss != null ? ' · ${(loss * 100).round()}% speed loss' : ''}',
                    style: const TextStyle(
                        color: AppTheme.textSecondary, fontSize: 11)),
            ]),
          ),
          if (set.repDetails.isNotEmpty)
            SizedBox(
              width: 64,
              child: RepBars(reps: set.repDetails, height: 26, showValues: false),
            ),
        ]),
      ),
    );
  }
}
