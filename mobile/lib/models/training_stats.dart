import 'dart:math' as math;

import 'cable_exercise.dart';
import 'workout_session.dart';

DateTime dayOf(DateTime t) => DateTime(t.year, t.month, t.day);

/// Monday 00:00 of the week [t] is in.
DateTime weekStart(DateTime t) =>
    DateTime(t.year, t.month, t.day - (t.weekday - DateTime.monday));

/// Weeks in a row (Monday to Sunday) with at least [goal] training days.
class WeekStreak {
  /// The current run. The week in progress does not break it before it is
  /// over: until it reaches the goal, the run up to last week counts.
  final int current;
  final int best;

  /// Training days so far this week.
  final int daysThisWeek;

  /// Which days of this week (Monday first) had training.
  final List<bool> thisWeek;

  const WeekStreak(
      {required this.current,
      required this.best,
      required this.daysThisWeek,
      required this.thisWeek});

  static WeekStreak of(Iterable<DateTime> trainingDays, DateTime now, int goal) {
    final days = trainingDays.map(dayOf).where((d) => !d.isAfter(now)).toSet();
    final perWeek = <DateTime, int>{};
    for (final d in days) {
      final w = weekStart(d);
      perWeek[w] = (perWeek[w] ?? 0) + 1;
    }
    DateTime back(DateTime w) => DateTime(w.year, w.month, w.day - 7);
    final thisWeek = weekStart(now);
    var cursor = (perWeek[thisWeek] ?? 0) >= goal ? thisWeek : back(thisWeek);
    var current = 0;
    while ((perWeek[cursor] ?? 0) >= goal) {
      current++;
      cursor = back(cursor);
    }
    final met = perWeek.keys.where((w) => perWeek[w]! >= goal).toList()..sort();
    var best = 0, run = 0;
    DateTime? prev;
    for (final w in met) {
      run = prev != null && back(w) == prev ? run + 1 : 1;
      if (run > best) best = run;
      prev = w;
    }
    return WeekStreak(
      current: current,
      best: best,
      daysThisWeek: perWeek[thisWeek] ?? 0,
      thisWeek: [
        for (var i = 0; i < 7; i++)
          days.contains(DateTime(thisWeek.year, thisWeek.month, thisWeek.day + i)),
      ],
    );
  }
}

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

/// How recovered one muscle group is.
class MuscleRecovery {
  /// 0 = fully recovered .. 1 = just trained hard.
  final double fatigue;

  /// When the group is ready again; null when it is ready now.
  final Duration? readyIn;

  /// Last set that worked it (as prime mover or assisting); null if never.
  final DateTime? lastTrained;

  const MuscleRecovery({required this.fatigue, this.readyIn, this.lastTrained});

  static const double readyBelow = 0.2;

  bool get recovering => fatigue >= readyBelow;

  /// Not worked in the last week.
  bool untrained(DateTime now) =>
      lastTrained == null || now.difference(lastTrained!).inDays >= 7;
}

/// Pulling vs pushing sets over a span.
class Balance {
  final int pullSets;
  final int pushSets;
  const Balance(this.pullSets, this.pushSets);

  /// pull : push, or null without push sets.
  double? get ratio => pushSets == 0 ? null : pullSets / pushSets;
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

  /// A set's work fades over [recoveryHours]. A muscle counts as recovering
  /// while what is left adds up to more than [MuscleRecovery.readyBelow] of
  /// [fatigueSets] hard sets (prime mover 1, assisting 0.5).
  static const double recoveryHours = 48;
  static const double fatigueSets = 6;

  Map<String, MuscleRecovery> recovery(DateTime now) {
    final left = <String, double>{};
    final last = <String, DateTime>{};
    final parts = <String, List<(double, double)>>{}; // (share, hours ago)
    for (final s in sets) {
      if (s.timestamp.isAfter(now)) continue;
      final e = cableExerciseByName(s.workoutName);
      if (e == null) continue;
      final ago = now.difference(s.timestamp).inMinutes / 60;
      for (final (groups, share) in [(e.primary, 1.0), (e.secondary, 0.5)]) {
        for (final g in groups) {
          last[g] = s.timestamp;
          if (ago >= recoveryHours) continue;
          left[g] = (left[g] ?? 0) + share * (1 - ago / recoveryHours);
          parts.putIfAbsent(g, () => []).add((share, ago));
        }
      }
    }
    final out = <String, MuscleRecovery>{};
    for (final g in muscleGroupLabels.keys) {
      final f = ((left[g] ?? 0) / fatigueSets).clamp(0.0, 1.0);
      Duration? readyIn;
      if (f >= MuscleRecovery.readyBelow) {
        // Step forward in hours until what is left falls under the line.
        for (var h = 1; h <= recoveryHours; h++) {
          final rest = parts[g]!.fold(
              0.0,
              (a, p) =>
                  a + p.$1 * math.max(0, 1 - (p.$2 + h) / recoveryHours));
          if (rest / fatigueSets < MuscleRecovery.readyBelow) {
            readyIn = Duration(hours: h);
            break;
          }
        }
      }
      out[g] = MuscleRecovery(fatigue: f, readyIn: readyIn, lastTrained: last[g]);
    }
    return out;
  }

  /// Muscle groups worked from [from] until [to] (one set as prime mover or
  /// two assisting), of [trainableMuscleGroups]. Same rule as the server.
  (int active, int total) muscleCoverage(DateTime from, DateTime to) {
    final m = muscleSets(from, to);
    final active = trainableMuscleGroups.where((g) => (m[g] ?? 0) >= 1).length;
    return (active, trainableMuscleGroups.length);
  }

  /// Sets per calendar day from [from] until [to].
  Map<DateTime, int> dailySets(DateTime from, DateTime to) {
    final out = <DateTime, int>{};
    for (final s in sets) {
      if (s.timestamp.isBefore(from) || !s.timestamp.isBefore(to)) continue;
      final d = dayOf(s.timestamp);
      out[d] = (out[d] ?? 0) + 1;
    }
    return out;
  }

  Balance balance(DateTime from, DateTime to) {
    var pull = 0, push = 0;
    for (final s in sets) {
      if (s.timestamp.isBefore(from) || !s.timestamp.isBefore(to)) continue;
      final e = cableExerciseByName(s.workoutName);
      if (e == null) continue;
      if (e.pattern == MovePattern.pull) {
        pull++;
      } else {
        push++;
      }
    }
    return Balance(pull, push);
  }

  /// Sets done today of [exercise].
  int setsToday(String exercise, DateTime now) => sets
      .where((s) => s.workoutName == exercise && dayOf(s.timestamp) == dayOf(now))
      .length;

  /// Weight to suggest for the next set of [exercise]: the last one used.
  double lastWeight(String exercise) {
    for (final s in sets.reversed) {
      if (s.workoutName == exercise && s.weightKg > 0) return s.weightKg;
    }
    return 0;
  }
}
