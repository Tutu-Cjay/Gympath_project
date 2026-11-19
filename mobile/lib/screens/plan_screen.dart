import 'package:flutter/material.dart';

import '../models/progression.dart';
import '../models/routine.dart';
import '../models/training_stats.dart';
import '../models/workout_session.dart';
import '../services/routine_store.dart';
import '../services/workout_store.dart';
import '../theme/app_theme.dart';
import 'cable_track_screen.dart';

String restText(int sec) =>
    sec >= 60 ? '${sec ~/ 60}:${(sec % 60).toString().padLeft(2, '0')}' : '$sec s';

/// Pick a ready-made plan to follow.
class PlanScreen extends StatelessWidget {
  const PlanScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.darkBg,
      appBar: AppBar(title: const Text('Plans')),
      body: ValueListenableBuilder<ActivePlan?>(
        valueListenable: RoutineStore.instance.plan,
        builder: (context, active, _) => ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          children: [
            const Text(
              'Days are done in turn (A, B, A, …) on whatever days you '
              'train, so a missed day never breaks the plan. Each exercise '
              'has a rep range: when every set reaches the top of it, the '
              'app suggests more weight.',
              style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
            ),
            const SizedBox(height: 14),
            for (final r in starterRoutines)
              _RoutineCard(routine: r, active: active?.routine.id == r.id),
            if (active != null)
              TextButton(
                onPressed: () => RoutineStore.instance.stop(),
                style: TextButton.styleFrom(foregroundColor: AppTheme.textSecondary),
                child: const Text('Stop following a plan'),
              ),
          ],
        ),
      ),
    );
  }
}

class _RoutineCard extends StatelessWidget {
  final Routine routine;
  final bool active;
  const _RoutineCard({required this.routine, required this.active});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.cardBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
            color: active ? AppTheme.neonGreen : AppTheme.cardBgLight,
            width: active ? 2 : 1),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Text(routine.name,
                style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 17,
                    fontWeight: FontWeight.bold)),
          ),
          Text(routine.frequency,
              style: const TextStyle(color: AppTheme.neonGreen, fontSize: 12)),
        ]),
        const SizedBox(height: 4),
        Text(routine.description,
            style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
        const SizedBox(height: 10),
        for (final d in routine.days) ...[
          Text(routine.days.length > 1 ? 'DAY ${d.name.toUpperCase()}' : d.name.toUpperCase(),
              style: const TextStyle(
                  color: AppTheme.textMuted,
                  fontSize: 10,
                  letterSpacing: 1.1,
                  fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          for (final e in d.exercises)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Row(children: [
                Expanded(
                  child: Text(e.exercise,
                      style: const TextStyle(
                          color: AppTheme.textPrimary, fontSize: 13)),
                ),
                Text(e.target,
                    style: const TextStyle(
                        color: AppTheme.textSecondary, fontSize: 12)),
              ]),
            ),
          const SizedBox(height: 8),
        ],
        SizedBox(
          width: double.infinity,
          child: active
              ? OutlinedButton(
                  onPressed: () => Navigator.push(context,
                      MaterialPageRoute(builder: (_) => const PlanDayScreen())),
                  style: OutlinedButton.styleFrom(
                      foregroundColor: AppTheme.neonGreen,
                      side: const BorderSide(color: AppTheme.neonGreen)),
                  child: const Text('Your plan · open next day'),
                )
              : ElevatedButton(
                  onPressed: () async {
                    await RoutineStore.instance.choose(routine);
                    if (!context.mounted) return;
                    Navigator.pushReplacement(context,
                        MaterialPageRoute(builder: (_) => const PlanDayScreen()));
                  },
                  style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.neonGreen,
                      foregroundColor: Colors.black),
                  child: const Text('Follow this plan'),
                ),
        ),
      ]),
    );
  }
}

/// The plan's next day: its exercises with today's sets and the suggested
/// weight for each. Tap one to train it; Finish day moves the plan on.
class PlanDayScreen extends StatelessWidget {
  const PlanDayScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ActivePlan?>(
      valueListenable: RoutineStore.instance.plan,
      builder: (context, plan, _) {
        if (plan == null) return const PlanScreen();
        return ValueListenableBuilder<WorkoutStats>(
          valueListenable: WorkoutStore.instance.stats,
          builder: (context, _, __) => _day(context, plan),
        );
      },
    );
  }

  Widget _day(BuildContext context, ActivePlan plan) {
    final t = WorkoutStore.instance.training;
    final now = DateTime.now();
    final day = plan.day;
    final done = day.exercises
        .fold<int>(0, (a, e) => a + t.setsToday(e.exercise, now).clamp(0, e.sets));
    final multi = plan.routine.days.length > 1;
    return Scaffold(
      backgroundColor: AppTheme.darkBg,
      appBar: AppBar(
        title: Text(multi ? '${plan.routine.name} · ${day.name}' : plan.routine.name),
        actions: [
          IconButton(
            tooltip: 'Change plan',
            icon: const Icon(Icons.swap_horiz_rounded),
            onPressed: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const PlanScreen())),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(children: [
          if (multi)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
              child: Row(children: [
                const Text('Day ',
                    style: TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
                for (var i = 0; i < plan.routine.days.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ChoiceChip(
                      label: Text(plan.routine.days[i].name),
                      selected: i == plan.nextDay,
                      onSelected: (_) => RoutineStore.instance.pickDay(i),
                    ),
                  ),
              ]),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 6),
            child: Row(children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: day.totalSets == 0 ? 0 : done / day.totalSets,
                    minHeight: 8,
                    backgroundColor: AppTheme.cardBgLight,
                    valueColor: const AlwaysStoppedAnimation(AppTheme.neonGreen),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Text('$done / ${day.totalSets} sets',
                  style: const TextStyle(
                      color: AppTheme.textSecondary, fontSize: 12)),
            ]),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 6, 20, 12),
              children: [
                for (final e in day.exercises)
                  _PlannedTile(
                    plan: e,
                    setsToday: t.setsToday(e.exercise, now),
                    suggestion: suggestNext(t.setsOf(e.exercise), e,
                        excludeWorkoutId: _todayWorkout(t.setsOf(e.exercise), now)),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
            child: SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: done == 0
                    ? null
                    : () async {
                        final next = plan.routine
                            .days[(plan.nextDay + 1) % plan.routine.days.length];
                        await RoutineStore.instance.finishDay();
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                          behavior: SnackBarBehavior.floating,
                          content: Text(multi
                              ? 'Day done. Next time: ${next.name}'
                              : 'Day done. Rest well.'),
                        ));
                        Navigator.pop(context);
                      },
                icon: const Icon(Icons.check_rounded),
                label: const Text('Finish day'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.neonGreen,
                  disabledBackgroundColor: AppTheme.cardBgLight,
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
            ),
          ),
        ]),
      ),
    );
  }

  /// Today's sets were done in this visit: compare with the visits before.
  static String? _todayWorkout(List<WorkoutSession> sets, DateTime now) {
    for (final s in sets.reversed) {
      if (dayOf(s.timestamp) == dayOf(now)) return s.workoutId;
    }
    return null;
  }
}

class _PlannedTile extends StatelessWidget {
  final PlannedExercise plan;
  final int setsToday;
  final Suggestion suggestion;
  const _PlannedTile(
      {required this.plan, required this.setsToday, required this.suggestion});

  @override
  Widget build(BuildContext context) {
    final complete = setsToday >= plan.sets;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
                builder: (_) =>
                    CableTrackScreen(workoutName: plan.exercise, plan: plan))),
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
          decoration: BoxDecoration(
            color: AppTheme.cardBg,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
                color: complete
                    ? AppTheme.neonGreen.withValues(alpha: .6)
                    : AppTheme.cardBgLight),
          ),
          child: Row(children: [
            Icon(complete ? Icons.check_circle_rounded : Icons.radio_button_unchecked,
                color: complete ? AppTheme.neonGreen : AppTheme.textMuted,
                size: 22),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(plan.exercise,
                    style: const TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 15,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text('${plan.target} reps · rest ${restText(plan.restSec)}',
                    style: const TextStyle(
                        color: AppTheme.textSecondary, fontSize: 12)),
                const SizedBox(height: 2),
                Text(suggestion.headline,
                    style: TextStyle(
                        color: suggestion.kind == ProgressionKind.increase
                            ? AppTheme.neonGreen
                            : AppTheme.textPrimary,
                        fontSize: 12,
                        fontWeight: FontWeight.w600)),
              ]),
            ),
            Text('${setsToday.clamp(0, 99)}/${plan.sets}',
                style: TextStyle(
                    color: complete ? AppTheme.neonGreen : AppTheme.textSecondary,
                    fontSize: 14,
                    fontWeight: FontWeight.w700)),
            const Icon(Icons.chevron_right_rounded, color: AppTheme.textMuted),
          ]),
        ),
      ),
    );
  }
}
