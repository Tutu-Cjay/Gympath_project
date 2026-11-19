import 'dart:math' as math;

import 'routine.dart';
import 'workout_session.dart';

enum ProgressionKind { start, increase, hold, decrease }

/// The weight to use next time on an exercise, and why.
class Suggestion {
  final ProgressionKind kind;

  /// Suggested weight on the stack (kg); 0 when there is no history yet.
  final double weightKg;

  /// Short line, e.g. "Add 2.5 kg → 42.5 kg".
  final String headline;

  /// The reasoning, in plain words.
  final String reason;

  /// The sets of the last workout of this exercise, in order.
  final List<WorkoutSession> lastSets;

  const Suggestion({
    required this.kind,
    required this.weightKg,
    required this.headline,
    required this.reason,
    this.lastSets = const [],
  });
}

String kg(double v) =>
    v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);

/// Double progression: keep the weight while the reps climb through the
/// plan's range; once every set reaches the top of the range, add weight.
///
/// - Missed reps never add load: a set under the range keeps the weight; two
///   workouts in a row under the range at the same weight take ~10% off.
/// - The tracker measures how far the stack travels. Reps much shorter than
///   the user's usual range do not count towards adding weight.
/// - When the last set felt easy (3+ reps in reserve) the jump is doubled.
///
/// [sets] are the exercise's saved sets (any order). Sets of
/// [excludeWorkoutId] (the workout in progress) are ignored.
Suggestion suggestNext(
  Iterable<WorkoutSession> sets,
  PlannedExercise plan, {
  double step = 2.5,
  String? excludeWorkoutId,
}) {
  final valid = sets
      .where((s) =>
          s.reps > 0 && s.weightKg > 0 && s.workoutId != excludeWorkoutId)
      .toList()
    ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
  final range = '${plan.minReps}–${plan.maxReps}';
  if (valid.isEmpty) {
    return Suggestion(
      kind: ProgressionKind.start,
      weightKg: 0,
      headline: 'Find your weight',
      reason: 'First time on this plan: pick a weight you can lift '
          '${plan.minReps} times with good form and about 2 reps left in '
          'the tank. From then on the app suggests the next weight.',
    );
  }

  // Workouts in order, each with its sets in set order.
  final order = <String>[];
  final byWorkout = <String, List<WorkoutSession>>{};
  for (final s in valid) {
    if (!byWorkout.containsKey(s.workoutId)) order.add(s.workoutId);
    byWorkout.putIfAbsent(s.workoutId, () => []).add(s);
  }
  for (final l in byWorkout.values) {
    l.sort((a, b) => a.setIndex.compareTo(b.setIndex));
  }
  final last = byWorkout[order.last]!;
  final w = last.map((s) => s.weightKg).reduce(math.max);
  final top = last.where((s) => s.weightKg == w).toList();
  final repsText = top.map((s) => s.reps).join(', ');
  double round(double v) => math.max(step, (v / step).round() * step);

  // Short reps: compare with the usual range of earlier workouts.
  final earlier = valid
      .where((s) => s.workoutId != order.last && s.meanRangeCm > 0)
      .map((s) => s.meanRangeCm)
      .toList()
    ..sort();
  final measured = top.where((s) => s.meanRangeCm > 0).toList();
  if (earlier.length >= 3 && measured.isNotEmpty) {
    final usual = earlier[earlier.length ~/ 2];
    final now =
        measured.fold(0.0, (a, s) => a + s.meanRangeCm) / measured.length;
    if (now < usual * 0.85) {
      return Suggestion(
        kind: ProgressionKind.hold,
        weightKg: w,
        headline: 'Stay at ${kg(w)} kg',
        reason: 'Last time the stack moved ${now.round()} cm per rep, '
            'shorter than your usual ${usual.round()} cm. Keep ${kg(w)} kg '
            'and use your full range before adding weight.',
        lastSets: last,
      );
    }
  }

  bool missedAt(List<WorkoutSession> workout, double weight) =>
      workout.any((s) => s.weightKg == weight && s.reps < plan.minReps);

  if (missedAt(last, w)) {
    final prev = order.length > 1 ? byWorkout[order[order.length - 2]]! : null;
    final prevW = prev?.map((s) => s.weightKg).reduce(math.max);
    if (prev != null && prevW == w && missedAt(prev, w)) {
      final down = math.min(round(w * 0.9), math.max(step, w - step));
      return Suggestion(
        kind: ProgressionKind.decrease,
        weightKg: down,
        headline: 'Drop to ${kg(down)} kg',
        reason: 'Two workouts in a row had sets under ${plan.minReps} reps at '
            '${kg(w)} kg. Take about 10% off, build the reps back up to '
            '${plan.maxReps}, then climb again.',
        lastSets: last,
      );
    }
    return Suggestion(
      kind: ProgressionKind.hold,
      weightKg: w,
      headline: 'Stay at ${kg(w)} kg',
      reason: 'A set fell under ${plan.minReps} reps (last time: $repsText). '
          'Missed reps never add weight: stay at ${kg(w)} kg until every set '
          'reaches ${plan.maxReps}.',
      lastSets: last,
    );
  }

  if (top.length >= plan.sets && top.every((s) => s.reps >= plan.maxReps)) {
    final easy = (top.last.rir ?? 0) >= 3;
    final up = w + (easy ? 2 * step : step);
    return Suggestion(
      kind: ProgressionKind.increase,
      weightKg: up,
      headline: 'Add ${kg(up - w)} kg → ${kg(up)} kg',
      reason: 'All ${plan.sets} sets reached ${plan.maxReps} reps at '
          '${kg(w)} kg${easy ? ' and the last one felt easy' : ''}. Add '
          '${kg(up - w)} kg: expect fewer reps (${plan.minReps} or more is '
          'fine) and build back up.',
      lastSets: last,
    );
  }

  return Suggestion(
    kind: ProgressionKind.hold,
    weightKg: w,
    headline: 'Stay at ${kg(w)} kg',
    reason: top.length < plan.sets
        ? 'Last time you did ${top.length} of ${plan.sets} sets at ${kg(w)} kg '
            '($repsText). Do all ${plan.sets} sets in the $range range; when '
            'each reaches ${plan.maxReps}, the weight goes up.'
        : 'Keep ${kg(w)} kg and beat last time ($repsText): one more rep per '
            'set. When all ${plan.sets} sets reach ${plan.maxReps}, the weight '
            'goes up.',
    lastSets: last,
  );
}
