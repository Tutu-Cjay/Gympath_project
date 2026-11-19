import 'cable_exercise.dart';

/// One exercise in a plan: how many sets, the rep range to aim for and the
/// rest between sets.
class PlannedExercise {
  final String exercise; // CableExercise.name
  final int sets;
  final int minReps;
  final int maxReps;
  final int restSec;

  const PlannedExercise(this.exercise,
      {required this.sets,
      required this.minReps,
      required this.maxReps,
      required this.restSec});

  String get target => '$sets × $minReps–$maxReps';
}

/// The plan used when an exercise is started outside a routine.
PlannedExercise defaultPlanFor(String exercise) {
  final e = cableExerciseByName(exercise);
  return (e?.compound ?? false)
      ? PlannedExercise(exercise, sets: 3, minReps: 8, maxReps: 12, restSec: 120)
      : PlannedExercise(exercise, sets: 3, minReps: 10, maxReps: 15, restSec: 75);
}

class RoutineDay {
  final String name;
  final List<PlannedExercise> exercises;
  const RoutineDay(this.name, this.exercises);

  int get totalSets => exercises.fold(0, (a, e) => a + e.sets);
}

/// A training plan: its days are done in turn (A, B, A, B, …) on whatever
/// days the user trains, so a missed day never breaks the plan.
class Routine {
  final String id;
  final String name;
  final String description;
  final String frequency;
  final List<RoutineDay> days;

  const Routine({
    required this.id,
    required this.name,
    required this.description,
    required this.frequency,
    required this.days,
  });
}

const _pulldown = 'Lat Pulldown';
const _row = 'Seated Cable Row';
const _pushdown = 'Tricep Pushdown';
const _curl = 'Cable Bicep Curl';
const _fly = 'Cable Chest Fly';
const _facePull = 'Face Pull';

/// Ready-made plans built from the cable exercises the app knows.
const List<Routine> starterRoutines = [
  Routine(
    id: 'starter',
    name: 'Starter',
    description: 'Every cable exercise, two sets each. Learn the movements '
        'and find your weights.',
    frequency: '2–3 days a week',
    days: [
      RoutineDay('Full body', [
        PlannedExercise(_pulldown, sets: 2, minReps: 10, maxReps: 15, restSec: 90),
        PlannedExercise(_fly, sets: 2, minReps: 10, maxReps: 15, restSec: 75),
        PlannedExercise(_row, sets: 2, minReps: 10, maxReps: 15, restSec: 90),
        PlannedExercise(_pushdown, sets: 2, minReps: 10, maxReps: 15, restSec: 60),
        PlannedExercise(_curl, sets: 2, minReps: 10, maxReps: 15, restSec: 60),
        PlannedExercise(_facePull, sets: 2, minReps: 12, maxReps: 15, restSec: 60),
      ]),
    ],
  ),
  Routine(
    id: 'full_ab',
    name: 'Full body A/B',
    description: 'Two alternating upper-body sessions: one pull-heavy, one '
        'with more chest and arms.',
    frequency: '3 days a week',
    days: [
      RoutineDay('A', [
        PlannedExercise(_pulldown, sets: 3, minReps: 8, maxReps: 12, restSec: 120),
        PlannedExercise(_fly, sets: 3, minReps: 10, maxReps: 15, restSec: 90),
        PlannedExercise(_facePull, sets: 3, minReps: 12, maxReps: 15, restSec: 60),
        PlannedExercise(_pushdown, sets: 2, minReps: 10, maxReps: 15, restSec: 60),
      ]),
      RoutineDay('B', [
        PlannedExercise(_row, sets: 3, minReps: 8, maxReps: 12, restSec: 120),
        PlannedExercise(_fly, sets: 3, minReps: 10, maxReps: 15, restSec: 90),
        PlannedExercise(_curl, sets: 3, minReps: 10, maxReps: 12, restSec: 60),
        PlannedExercise(_facePull, sets: 2, minReps: 12, maxReps: 15, restSec: 60),
      ]),
    ],
  ),
  Routine(
    id: 'pull_push',
    name: 'Pull / Push',
    description: 'Back and biceps one day, chest and triceps the next. More '
        'sets per muscle.',
    frequency: '4 days a week',
    days: [
      RoutineDay('Pull', [
        PlannedExercise(_pulldown, sets: 4, minReps: 6, maxReps: 10, restSec: 150),
        PlannedExercise(_row, sets: 3, minReps: 8, maxReps: 12, restSec: 120),
        PlannedExercise(_facePull, sets: 3, minReps: 12, maxReps: 15, restSec: 60),
        PlannedExercise(_curl, sets: 3, minReps: 10, maxReps: 12, restSec: 60),
      ]),
      RoutineDay('Push', [
        PlannedExercise(_fly, sets: 4, minReps: 10, maxReps: 15, restSec: 90),
        PlannedExercise(_pushdown, sets: 4, minReps: 10, maxReps: 15, restSec: 75),
        PlannedExercise(_facePull, sets: 2, minReps: 15, maxReps: 20, restSec: 60),
      ]),
    ],
  ),
];

Routine? routineById(String id) {
  for (final r in starterRoutines) {
    if (r.id == id) return r;
  }
  return null;
}
