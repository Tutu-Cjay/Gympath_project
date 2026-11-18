import 'dart:math' as math;

import 'cable_exercise.dart';
import 'workout_session.dart';

DateTime dayOf(DateTime t) => DateTime(t.year, t.month, t.day);

/// Monday 00:00 of the week [t] is in.
DateTime weekStart(DateTime t) =>
    dayOf(t).subtract(Duration(days: t.weekday - DateTime.monday));

/// Best values of one exercise on one day: a point on the progress charts.
class DayBest {
  final DateTime day;
  final double topWeightKg;
  final double estimatedOneRepMax;
  final double volumeKg;
  final int sets;
  final int reps;

  const DayBest({
    required this.day,
    required this.topWeightKg,
    required this.estimatedOneRepMax,
    required this.volumeKg,
    required this.sets,
    required this.reps,
  });
}

class PersonalRecords {
  final WorkoutSession? heaviest;
  final WorkoutSession? bestOneRepMax;
  final WorkoutSession? mostVolume;
  final WorkoutSession? fastest;

  const PersonalRecords({
    this.heaviest,
    this.bestOneRepMax,
    this.mostVolume,
    this.fastest,
  });

  bool get isEmpty =>
      heaviest == null && bestOneRepMax == null && mostVolume == null && fastest == null;
}

/// Totals for a span of days (usually one week).
class PeriodSummary {
  final int workoutDays;
  final int sets;
  final int reps;
  final double volumeKg;

  const PeriodSummary({
    required this.workoutDays,
    required this.sets,
    required this.reps,
    required this.volumeKg,
  });
}

/// Reading of the saved sets for the progress screens. Pure: no storage, no
/// clock (pass `now`), so it is easy to test.
class TrainingStats {
  final List<WorkoutSession> sets;
  TrainingStats(Iterable<WorkoutSession> sets)
      : sets = [...sets]..sort((a, b) => a.timestamp.compareTo(b.timestamp));

  /// Exercises that have at least one set, most recently trained first.
  List<String> exercises() {
    final last = <String, DateTime>{};
    for (final s in sets) {
      last[s.workoutName] = s.timestamp;
    }
    final names = last.keys.toList()
      ..sort((a, b) => last[b]!.compareTo(last[a]!));
    return names;
  }

  List<WorkoutSession> setsOf(String exercise) =>
      sets.where((s) => s.workoutName == exercise).toList();

  /// One point per training day of [exercise], oldest first.
  List<DayBest> history(String exercise) {
    final byDay = <DateTime, List<WorkoutSession>>{};
    for (final s in setsOf(exercise)) {
      byDay.putIfAbsent(dayOf(s.timestamp), () => []).add(s);
    }
    final days = byDay.keys.toList()..sort();
    return [
      for (final d in days)
        DayBest(
          day: d,
          topWeightKg: byDay[d]!.map((s) => s.weightKg).reduce(math.max),
          estimatedOneRepMax:
              byDay[d]!.map((s) => s.estimatedOneRepMax).reduce(math.max),
          volumeKg: byDay[d]!.fold(0.0, (a, s) => a + s.volumeKg),
          sets: byDay[d]!.length,
          reps: byDay[d]!.fold(0, (a, s) => a + s.reps),
        ),
    ];
  }

  PersonalRecords records(String exercise) {
    final list = setsOf(exercise);
    WorkoutSession? best(double Function(WorkoutSession) key) {
      WorkoutSession? top;
      for (final s in list) {
        if (key(s) <= 0) continue;
        // Ties go to the earlier set: that is when the record was set.
        if (top == null || key(s) > key(top)) top = s;
      }
      return top;
    }

    return PersonalRecords(
      heaviest: best((s) => s.reps > 0 ? s.weightKg : 0),
      bestOneRepMax: best((s) => s.estimatedOneRepMax),
      mostVolume: best((s) => s.volumeKg),
      fastest: best((s) => s.meanVelocity),
    );
  }

  /// True when [set] beat every earlier set of its exercise on weight or on
  /// estimated one-rep max. Used to celebrate a new record after a set.
  bool isRecord(WorkoutSession set) {
    final earlier = setsOf(set.workoutName)
        .where((s) => s.timestamp.isBefore(set.timestamp));
    if (set.weightKg <= 0 || set.reps <= 0 || earlier.isEmpty) return false;
    final topWeight = earlier.map((s) => s.reps > 0 ? s.weightKg : 0.0).reduce(math.max);
    final top1rm = earlier.map((s) => s.estimatedOneRepMax).reduce(math.max);
    return set.weightKg > topWeight || set.estimatedOneRepMax > top1rm + 1e-9;
  }

  PeriodSummary summary(DateTime from, DateTime to) {
    final inRange = sets.where(
        (s) => !s.timestamp.isBefore(from) && s.timestamp.isBefore(to));
    return PeriodSummary(
      workoutDays: inRange.map((s) => dayOf(s.timestamp)).toSet().length,
      sets: inRange.length,
      reps: inRange.fold(0, (a, s) => a + s.reps),
      volumeKg: inRange.fold(0.0, (a, s) => a + s.volumeKg),
    );
  }

  PeriodSummary thisWeek(DateTime now) =>
      summary(weekStart(now), weekStart(now).add(const Duration(days: 7)));

  /// Sets per muscle group from [from] until [to]: a set counts 1 for each
  /// prime mover of its exercise and 0.5 for each assisting muscle.
  Map<String, double> muscleSets(DateTime from, DateTime to) {
    final out = <String, double>{};
    for (final s in sets) {
      if (s.timestamp.isBefore(from) || !s.timestamp.isBefore(to)) continue;
      final e = cableExerciseByName(s.workoutName);
      if (e == null) continue;
      for (final g in e.primary) {
        out[g] = (out[g] ?? 0) + 1;
      }
      for (final g in e.secondary) {
        out[g] = (out[g] ?? 0) + 0.5;
      }
    }
    return out;
  }

  /// Weight to suggest for the next set of [exercise]: the last one used.
  double lastWeight(String exercise) {
    for (final s in sets.reversed) {
      if (s.workoutName == exercise && s.weightKg > 0) return s.weightKg;
    }
    return 0;
  }
}
