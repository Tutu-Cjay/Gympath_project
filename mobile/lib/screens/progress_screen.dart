import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/cable_exercise.dart';
import '../models/training_stats.dart';
import '../services/workout_store.dart';
import '../theme/app_theme.dart';
import '../widgets/activity_heatmap.dart';
import 'exercise_history_screen.dart';
import 'muscle_map_screen.dart';

/// Progress tab: this week's training, which muscles got the work, and the
/// trend of every exercise. Everything comes from the saved sets.
class ProgressScreen extends StatelessWidget {
  const ProgressScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ValueListenableBuilder<WorkoutStats>(
        valueListenable: WorkoutStore.instance.stats,
        builder: (context, _, __) {
          final training = WorkoutStore.instance.training;
          final now = DateTime.now();
          final week = training.thisWeek(now);
          final lastWeekStart = weekStart(now).subtract(const Duration(days: 7));
          final lastWeek = training.summary(lastWeekStart, weekStart(now));
          final muscles = training.muscleSets(weekStart(now), now.add(const Duration(days: 1)));
          final exercises = training.exercises();
          return ListView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
            children: [
              const Text('Progress',
                  style: TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: 24,
                      fontWeight: FontWeight.bold)),
              const SizedBox(height: 16),
              if (WorkoutStore.instance.simulatedCount > 0) ...[
                _SimulatedNotice(count: WorkoutStore.instance.simulatedCount),
                const SizedBox(height: 14),
              ],
              _WeekCard(week: week, lastWeek: lastWeek),
              const SizedBox(height: 14),
              _MuscleCard(muscles: muscles),
              const SizedBox(height: 14),
              _RecoveryCard(recovery: training.recovery(now), now: now),
              const SizedBox(height: 14),
              _ActivityCard(training: training, now: now),
              const SizedBox(height: 14),
              _BalanceCard(
                  balance: training.balance(
                      dayOf(now).subtract(const Duration(days: 27)),
                      now.add(const Duration(days: 1)))),
              const SizedBox(height: 22),
              const _Title('EXERCISES'),
              const SizedBox(height: 10),
              if (exercises.isEmpty)
                const _Empty()
              else
                for (final e in exercises) _ExerciseTile(name: e, training: training),
            ],
          );
        },
      ),
    );
  }
}

class _Title extends StatelessWidget {
  final String text;
  const _Title(this.text);
  @override
  Widget build(BuildContext context) => Text(text,
      style: const TextStyle(
          color: AppTheme.textSecondary,
          fontSize: 11,
          letterSpacing: 1.3,
          fontWeight: FontWeight.w700));
}

class _Card extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;
  const _Card({required this.child, this.padding = const EdgeInsets.all(16)});
  @override
  Widget build(BuildContext context) => Container(
        padding: padding,
        decoration: BoxDecoration(
          color: AppTheme.cardBg,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppTheme.cardBgLight),
        ),
        child: child,
      );
}

String formatVolume(double kg) => kg >= 10000
    ? '${(kg / 1000).toStringAsFixed(1)} t'
    : '${kg.round()} kg';

class _WeekCard extends StatelessWidget {
  final PeriodSummary week, lastWeek;
  const _WeekCard({required this.week, required this.lastWeek});

  @override
  Widget build(BuildContext context) {
    Widget cell(String label, String value) => Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(value,
                  style: const TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: 20,
                      fontWeight: FontWeight.w800)),
            ),
            Text(label,
                style: const TextStyle(
                    color: AppTheme.textSecondary, fontSize: 11)),
          ]),
        );
    String? change;
    if (lastWeek.volumeKg > 0) {
      final pct = ((week.volumeKg - lastWeek.volumeKg) / lastWeek.volumeKg * 100).round();
      change = '${pct >= 0 ? '+' : ''}$pct% volume vs last week';
    }
    return _Card(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const _Title('THIS WEEK'),
        const SizedBox(height: 12),
        Row(children: [
          cell('Days', '${week.workoutDays}'),
          cell('Sets', '${week.sets}'),
          cell('Reps', '${week.reps}'),
          cell('Volume', formatVolume(week.volumeKg)),
        ]),
        if (change != null) ...[
          const SizedBox(height: 10),
          Text(change,
              style: TextStyle(
                  color: week.volumeKg >= lastWeek.volumeKg
                      ? AppTheme.neonGreen
                      : AppTheme.textSecondary,
                  fontSize: 12,
                  fontWeight: FontWeight.w600)),
        ],
      ]),
    );
  }
}

class _MuscleCard extends StatelessWidget {
  final Map<String, double> muscles;
  const _MuscleCard({required this.muscles});

  @override
  Widget build(BuildContext context) {
    final ranked = muscles.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final top = ranked.take(5).toList();
    final most = top.isEmpty ? 1.0 : math.max(top.first.value, 1.0);
    return _Card(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Expanded(child: _Title('MUSCLES TRAINED THIS WEEK (SETS)')),
          TextButton.icon(
            onPressed: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const MuscleMapScreen())),
            icon: const Icon(Icons.accessibility_new_rounded, size: 16),
            label: const Text('3D map'),
            style: TextButton.styleFrom(
                foregroundColor: AppTheme.neonGreen,
                padding: const EdgeInsets.symmetric(horizontal: 8)),
          ),
        ]),
        const SizedBox(height: 6),
        if (top.isEmpty)
          const Text('Train this week and the muscles you worked show up here.',
              style: TextStyle(color: AppTheme.textMuted, fontSize: 12))
        else
          for (final e in top)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(children: [
                SizedBox(
                  width: 120,
                  child: Text(muscleGroupLabels[e.key] ?? e.key,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: AppTheme.textPrimary, fontSize: 12)),
                ),
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: e.value / most,
                      minHeight: 6,
                      backgroundColor: AppTheme.cardBgLight,
                      valueColor:
                          const AlwaysStoppedAnimation(AppTheme.neonGreen),
                    ),
                  ),
                ),
                SizedBox(
                  width: 36,
                  child: Text(_sets(e.value),
                      textAlign: TextAlign.right,
                      style: const TextStyle(
                          color: AppTheme.textSecondary, fontSize: 12)),
                ),
              ]),
            ),
      ]),
    );
  }
}

/// Muscles still recovering from recent sets, and those left untrained.
class _RecoveryCard extends StatelessWidget {
  final Map<String, MuscleRecovery> recovery;
  final DateTime now;
  const _RecoveryCard({required this.recovery, required this.now});

  @override
  Widget build(BuildContext context) {
    final recovering = recovery.entries.where((e) => e.value.recovering).toList()
      ..sort((a, b) => b.value.fatigue.compareTo(a.value.fatigue));
    final untrained = recovery.entries
        .where((e) => !e.value.recovering && e.value.untrained(now))
        .map((e) => muscleGroupLabels[e.key] ?? e.key)
        .toList();
    Widget chip(String text, Color c) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: c.withValues(alpha: .12),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: c.withValues(alpha: .5)),
          ),
          child: Text(text, style: TextStyle(color: c, fontSize: 11)),
        );
    const amber = Color(0xFFFFC857);
    return _Card(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Expanded(child: _Title('RECOVERY NOW')),
          TextButton.icon(
            onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => const MuscleMapScreen(recovery: true))),
            icon: const Icon(Icons.accessibility_new_rounded, size: 16),
            label: const Text('3D map'),
            style: TextButton.styleFrom(
                foregroundColor: AppTheme.neonGreen,
                padding: const EdgeInsets.symmetric(horizontal: 8)),
          ),
        ]),
        const SizedBox(height: 4),
        if (recovering.isEmpty)
          const Text('Every muscle is recovered and ready to train.',
              style: TextStyle(color: AppTheme.textSecondary, fontSize: 12))
        else
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final e in recovering)
              chip(
                  '${muscleGroupLabels[e.key] ?? e.key}'
                  '${e.value.readyIn != null ? ' · ${e.value.readyIn!.inHours} h' : ''}',
                  amber),
          ]),
        if (untrained.isNotEmpty) ...[
          const SizedBox(height: 10),
          const Text('Not trained this past week',
              style: TextStyle(color: AppTheme.textMuted, fontSize: 11)),
          const SizedBox(height: 6),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final n in untrained) chip(n, AppTheme.textSecondary),
          ]),
        ],
      ]),
    );
  }
}

class _ActivityCard extends StatelessWidget {
  final TrainingStats training;
  final DateTime now;
  const _ActivityCard({required this.training, required this.now});

  static const int weeks = 26;

  @override
  Widget build(BuildContext context) {
    final from = ActivityHeatmap.firstDay(now, weeks);
    final days = training.dailySets(from, now.add(const Duration(days: 1)));
    final trained = days.values.where((n) => n > 0).length;
    return _Card(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Expanded(child: _Title('ACTIVITY · LAST 6 MONTHS')),
          Text('$trained training day${trained == 1 ? '' : 's'}',
              style: const TextStyle(color: AppTheme.textSecondary, fontSize: 11)),
        ]),
        const SizedBox(height: 10),
        ActivityHeatmap(sets: days, now: now, weeks: weeks),
      ]),
    );
  }
}

/// Pulling vs pushing sets over the last four weeks. Cable training is easy
/// to tilt towards pushing; a common guideline is at least as many pulling
/// sets as pushing sets for healthy shoulders.
class _BalanceCard extends StatelessWidget {
  final Balance balance;
  const _BalanceCard({required this.balance});

  @override
  Widget build(BuildContext context) {
    final total = balance.pullSets + balance.pushSets;
    final ratio = balance.ratio;
    final String note;
    final Color color;
    if (total == 0) {
      note = 'No sets in the last 4 weeks.';
      color = AppTheme.textSecondary;
    } else if (ratio == null) {
      note = 'Only pulling so far. Add chest flies or pushdowns for balance.';
      color = const Color(0xFFFFC857);
    } else if (ratio < 1) {
      note = 'More pushing than pulling. Add rows or face pulls to balance '
          'your shoulders.';
      color = const Color(0xFFFFC857);
    } else if (ratio > 2.5) {
      note = 'Mostly pulling. Fine for posture, but chest and triceps work '
          'keeps you balanced.';
      color = AppTheme.textSecondary;
    } else {
      note = 'Balanced: at least as much pulling as pushing.';
      color = AppTheme.neonGreen;
    }
    final share = total == 0 ? .5 : balance.pullSets / total;
    return _Card(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Expanded(child: _Title('PULL : PUSH · LAST 4 WEEKS')),
          if (ratio != null)
            Text('${ratio.toStringAsFixed(1)} : 1',
                style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w800)),
        ]),
        const SizedBox(height: 10),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: SizedBox(
            height: 10,
            child: Row(children: [
              Expanded(
                  flex: (share * 1000).round().clamp(1, 999),
                  child: Container(color: AppTheme.neonGreen)),
              Expanded(
                  flex: ((1 - share) * 1000).round().clamp(1, 999),
                  child: Container(color: const Color(0xFF5B8DEF))),
            ]),
          ),
        ),
        const SizedBox(height: 6),
        Row(children: [
          Text('Pull ${balance.pullSets} sets',
              style: const TextStyle(color: AppTheme.neonGreen, fontSize: 11)),
          const Spacer(),
          Text('Push ${balance.pushSets} sets',
              style: const TextStyle(color: Color(0xFF5B8DEF), fontSize: 11)),
        ]),
        const SizedBox(height: 8),
        Text(note, style: TextStyle(color: color, fontSize: 12)),
      ]),
    );
  }
}

String _sets(double v) =>
    v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);

class _ExerciseTile extends StatelessWidget {
  final String name;
  final TrainingStats training;
  const _ExerciseTile({required this.name, required this.training});

  @override
  Widget build(BuildContext context) {
    final history = training.history(name);
    final last = history.last;
    final first = history.first;
    final ago = DateTime.now().difference(last.day).inDays;
    final when = ago == 0 ? 'today' : ago == 1 ? 'yesterday' : '$ago days ago';
    String? trend;
    if (history.length > 1 && first.estimatedOneRepMax > 0) {
      final d = last.estimatedOneRepMax - first.estimatedOneRepMax;
      trend = '${d >= 0 ? '+' : ''}${d.toStringAsFixed(1)} kg 1RM';
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
                builder: (_) => ExerciseHistoryScreen(exercise: name))),
        child: _Card(
          padding: const EdgeInsets.fromLTRB(16, 14, 10, 14),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(name,
                    style: const TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 15,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 3),
                Text(
                    last.topWeightKg > 0
                        ? 'Top ${_kg(last.topWeightKg)} kg · ${last.sets} sets · $when'
                        : '${last.sets} sets · $when',
                    style: const TextStyle(
                        color: AppTheme.textSecondary, fontSize: 12)),
              ]),
            ),
            if (trend != null)
              Text(trend,
                  style: TextStyle(
                      color: trend.startsWith('+')
                          ? AppTheme.neonGreen
                          : AppTheme.textSecondary,
                      fontSize: 12,
                      fontWeight: FontWeight.w700)),
            const Icon(Icons.chevron_right_rounded, color: AppTheme.textMuted),
          ]),
        ),
      ),
    );
  }
}

String _kg(double v) =>
    v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);

/// Shown while simulated sets are part of the numbers.
class _SimulatedNotice extends StatelessWidget {
  final int count;
  const _SimulatedNotice({required this.count});

  Future<void> _delete(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.cardBg,
        title: const Text('Delete simulated sets?'),
        content: Text('Removes the $count sets recorded in simulation mode. '
            'Sets from the real tracker stay.'),
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
    if (ok == true) await WorkoutStore.instance.removeSimulated();
  }

  @override
  Widget build(BuildContext context) {
    const amber = Color(0xFFFFC94D);
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
      decoration: BoxDecoration(
        color: amber.withValues(alpha: .08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: amber.withValues(alpha: .45)),
      ),
      child: Row(children: [
        const Icon(Icons.science_rounded, color: amber, size: 18),
        const SizedBox(width: 8),
        Expanded(
          child: Text('Includes $count simulated set${count == 1 ? '' : 's'}',
              style: const TextStyle(
                  color: amber, fontSize: 12, fontWeight: FontWeight.w600)),
        ),
        TextButton(
          onPressed: () => _delete(context),
          style: TextButton.styleFrom(foregroundColor: amber),
          child: const Text('Delete them'),
        ),
      ]),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty();
  @override
  Widget build(BuildContext context) => const _Card(
        child: Row(children: [
          Icon(Icons.insights_rounded, color: AppTheme.neonGreen),
          SizedBox(width: 12),
          Expanded(
            child: Text(
              'No sets yet. Do a set on any cable exercise and your history, '
              'records and charts appear here.',
              style: TextStyle(color: AppTheme.textSecondary, fontSize: 13),
            ),
          ),
        ]),
      );
}
