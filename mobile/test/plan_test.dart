import 'package:flutter_test/flutter_test.dart';
import 'package:gympath/models/cable_exercise.dart';
import 'package:gympath/models/progression.dart';
import 'package:gympath/models/routine.dart';
import 'package:gympath/models/training_stats.dart';
import 'package:gympath/models/workout_session.dart';
import 'package:gympath/services/routine_store.dart';
import 'package:gympath/widgets/activity_heatmap.dart';

final _t0 = DateTime(2026, 11, 2, 18); // a Monday

/// One workout of [exercise]: sets with these reps at [kg], [day] days after
/// _t0.
List<WorkoutSession> workout(int day, double kg, List<int> reps,
    {String exercise = 'Lat Pulldown', double range = 0, int? rir}) {
  final at = _t0.add(Duration(days: day));
  return [
    for (var i = 0; i < reps.length; i++)
      WorkoutSession(
        workoutName: exercise,
        reps: reps[i],
        weightKg: kg,
        repDetails: range > 0
            ? [
                for (var r = 0; r < reps[i]; r++)
                  RepMetrics(
                      rangeCm: range, meanVelocity: .5, peakVelocity: .7, durationSec: 2)
              ]
            : const [],
        workoutId: 'w$day',
        setIndex: i + 1,
        durationSec: 40,
        timestamp: at.add(Duration(minutes: 3 * i)),
        rir: i == reps.length - 1 ? rir : null,
      ),
  ];
}

const plan = PlannedExercise('Lat Pulldown', sets: 3, minReps: 8, maxReps: 12, restSec: 120);

void main() {
  group('double progression', () {
    test('no history: find your weight', () {
      final s = suggestNext(const [], plan);
      expect(s.kind, ProgressionKind.start);
      expect(s.weightKg, 0);
    });

    test('in the range: same weight, more reps', () {
      final s = suggestNext(workout(0, 40, [11, 10, 9]), plan);
      expect(s.kind, ProgressionKind.hold);
      expect(s.weightKg, 40);
      expect(s.reason, contains('11, 10, 9'));
      expect(s.lastSets.length, 3);
    });

    test('every set at the top of the range adds weight', () {
      final s = suggestNext(workout(0, 40, [12, 12, 13]), plan);
      expect(s.kind, ProgressionKind.increase);
      expect(s.weightKg, 42.5);
    });

    test('an easy last set doubles the jump', () {
      final s = suggestNext(workout(0, 40, [12, 12, 12], rir: 3), plan);
      expect(s.weightKg, 45);
    });

    test('too few sets at the top weight do not add weight', () {
      final s = suggestNext(workout(0, 40, [12, 12]), plan);
      expect(s.kind, ProgressionKind.hold);
      expect(s.reason, contains('2 of 3'));
    });

    test('missed reps never add load; twice in a row takes 10% off', () {
      final once = suggestNext(workout(0, 50, [12, 12, 6]), plan);
      expect(once.kind, ProgressionKind.hold);
      expect(once.weightKg, 50);
      final twice = suggestNext(
          [...workout(0, 50, [12, 12, 6]), ...workout(3, 50, [9, 7, 6])], plan);
      expect(twice.kind, ProgressionKind.decrease);
      expect(twice.weightKg, 45);
    });

    test('only the top weight of the last workout counts', () {
      final sets = [...workout(0, 40, [12, 12, 12]), ...workout(2, 42.5, [10, 9, 8])];
      expect(suggestNext(sets, plan).weightKg, 42.5);
      // A lighter back-off set below the range is not a miss.
      final backOff = workout(4, 42.5, [12, 12, 12]) +
          [workout(4, 30, [5]).single.withRir(null)];
      expect(suggestNext(backOff, plan).kind, ProgressionKind.increase);
    });

    test('reps much shorter than usual keep the weight', () {
      final sets = [
        ...workout(0, 40, [10, 10, 10], range: 50),
        ...workout(2, 40, [12, 12, 12], range: 35),
      ];
      final s = suggestNext(sets, plan);
      expect(s.kind, ProgressionKind.hold);
      expect(s.reason, contains('35 cm'));
      // Full range: weight goes up.
      final full = [
        ...workout(0, 40, [10, 10, 10], range: 50),
        ...workout(2, 40, [12, 12, 12], range: 48),
      ];
      expect(suggestNext(full, plan).kind, ProgressionKind.increase);
    });

    test('the workout in progress is left out', () {
      final sets = [...workout(0, 40, [12, 12, 12]), ...workout(2, 42.5, [8])];
      expect(suggestNext(sets, plan, excludeWorkoutId: 'w2').weightKg, 42.5);
      expect(suggestNext(sets, plan, excludeWorkoutId: 'w2').kind,
          ProgressionKind.increase);
    });
  });

  test('plans only use exercises the app knows', () {
    for (final r in starterRoutines) {
      expect(routineById(r.id), same(r));
      for (final d in r.days) {
        for (final e in d.exercises) {
          expect(cableExerciseByName(e.exercise), isNotNull, reason: e.exercise);
          expect(e.minReps, lessThan(e.maxReps));
        }
      }
    }
    expect(defaultPlanFor('Lat Pulldown').maxReps, 12);
    expect(defaultPlanFor('Face Pull').maxReps, 15);
  });

  test('active plan JSON round trip and bad values', () {
    final p = ActivePlan(starterRoutines[1], nextDay: 1, daysDone: 4, lastDone: _t0);
    final back = ActivePlan.fromJson(p.toJson())!;
    expect(back.routine.id, 'full_ab');
    expect(back.nextDay, 1);
    expect(back.daysDone, 4);
    expect(back.doneOn(_t0.add(const Duration(hours: 2))), isTrue);
    expect(back.doneOn(_t0.add(const Duration(days: 1))), isFalse);
    expect(ActivePlan.fromJson({'routine': 'nope'}), isNull);
    expect(ActivePlan.fromJson({'routine': 'starter', 'nextDay': 7})!.nextDay, 0);
  });

  test('reps in reserve are saved and clamped', () {
    final s = workout(0, 40, [10]).single.withRir(9);
    expect(s.rir, WorkoutSession.maxRir);
    expect(WorkoutSession.fromJson(s.toJson()).rir, WorkoutSession.maxRir);
    expect(WorkoutSession.fromJson(s.withRir(null).toJson()).rir, isNull);
  });

  group('recovery, activity and balance', () {
    final sets = [
      ...workout(0, 40, [10, 10, 10]), // Lat Pulldown: lats prime
      ...workout(0, 20, [12, 12], exercise: 'Tricep Pushdown'),
    ];
    final t = TrainingStats(sets);

    test('just trained muscles are recovering, then ready', () {
      final soon = t.recovery(_t0.add(const Duration(hours: 2)));
      expect(soon['lats']!.recovering, isTrue);
      expect(soon['lats']!.readyIn, isNotNull);
      expect(soon['lats']!.readyIn!.inHours, lessThanOrEqualTo(48));
      expect(soon['triceps']!.fatigue, lessThan(soon['lats']!.fatigue));
      expect(soon['pecs']!.fatigue, 0);
      expect(soon['pecs']!.untrained(_t0), isTrue);
      final later = t.recovery(_t0.add(const Duration(days: 3)));
      expect(later['lats']!.recovering, isFalse);
      expect(later['lats']!.untrained(_t0.add(const Duration(days: 3))), isFalse);
      expect(later['lats']!.untrained(_t0.add(const Duration(days: 8))), isTrue);
    });

    test('sets per day and pull : push', () {
      final days = t.dailySets(_t0.subtract(const Duration(days: 1)), _t0.add(const Duration(days: 1)));
      expect(days[dayOf(_t0)], 5);
      final b = t.balance(_t0.subtract(const Duration(days: 1)), _t0.add(const Duration(days: 1)));
      expect(b.pullSets, 3);
      expect(b.pushSets, 2);
      expect(b.ratio, 1.5);
      expect(const Balance(2, 0).ratio, isNull);
      expect(t.setsToday('Lat Pulldown', _t0.add(const Duration(hours: 1))), 3);
    });

    test('heatmap starts on a Monday', () {
      final first = ActivityHeatmap.firstDay(DateTime(2026, 11, 19), 26);
      expect(first.weekday, DateTime.monday);
      expect(DateTime(2026, 11, 16).difference(first).inDays, 7 * 25);
      expect(ActivityHeatmap.level(0), 0);
      expect(ActivityHeatmap.level(20), 1);
    });
  });
}
