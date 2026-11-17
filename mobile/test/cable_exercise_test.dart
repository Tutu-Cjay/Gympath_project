import 'package:flutter_test/flutter_test.dart';
import 'package:gympath/models/cable_exercise.dart';

void main() {
  // The cable-only workout list (ChooseWorkoutScreen); each needs a 3D guide.
  const workouts = [
    'Lat Pulldown',
    'Seated Cable Row',
    'Tricep Pushdown',
    'Cable Bicep Curl',
    'Cable Chest Fly',
    'Face Pull',
  ];

  test('every cable workout has a guide', () {
    for (final w in workouts) {
      expect(cableExerciseByName(w), isNotNull, reason: w);
    }
    expect(cableExerciseByName('Squat'), isNull);
  });

  test('guides only reference muscle groups that exist in the model', () {
    for (final e in cableExercises) {
      expect(e.primary, isNotEmpty, reason: e.name);
      for (final g in [...e.primary, ...e.secondary]) {
        expect(muscleGroupLabels.containsKey(g), isTrue, reason: '${e.name}: $g');
      }
      expect(e.primary.toSet().intersection(e.secondary.toSet()), isEmpty,
          reason: e.name);
      expect(e.cueTitles.length, RepPhase.values.length, reason: e.name);
      expect(e.cueDetails.length, RepPhase.values.length, reason: e.name);
    }
    final animations = cableExercises.map((e) => e.animation).toSet();
    expect(animations.length, cableExercises.length);
  });

  test('rep timeline: contraction and phases', () {
    expect(RepTimeline.contractionAt(0), 0);
    expect(RepTimeline.contractionAt(0.5), 1);
    expect(RepTimeline.contractionAt(0.99), 0);
    expect(RepTimeline.contractionAt(0.3), inExclusiveRange(0, 1));
    expect(RepTimeline.phaseAt(0.02), RepPhase.ready);
    expect(RepTimeline.phaseAt(0.2), RepPhase.pull);
    expect(RepTimeline.phaseAt(0.5), RepPhase.squeeze);
    expect(RepTimeline.phaseAt(0.7), RepPhase.release);
    expect(RepTimeline.phaseAt(0.97), RepPhase.ready);
  });

  test('prime movers are highlighted more than assisting muscles', () {
    final curl = cableExerciseByName('Cable Bicep Curl')!;
    for (final t in [0.0, 0.3, 0.5, 0.8]) {
      expect(curl.activation('biceps', t),
          greaterThan(curl.activation('forearms', t)));
      expect(curl.activation('quads', t), 0);
    }
    expect(curl.activation('biceps', 0.5), 1);
    expect(curl.activation('biceps', 0.5),
        greaterThan(curl.activation('biceps', 0.0)));
  });
}
