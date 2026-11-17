/// Cable-machine exercise guides for the Movement Studio.
///
/// Each exercise names an animation baked into
/// `assets/models/anatomy_cable.glb` and the muscle groups it trains. A group
/// id is the name of a material in that model (one material per muscle group,
/// see tools/build_anatomy_model.py), so highlighting a group tints the real
/// muscle geometry.
library;

import 'dart:math' as math;

/// Phases of one repetition. The boundaries match the animation timeline in
/// tools/build_anatomy_model.py (T_PULL, T_HOLD, T_RETURN, T_REST).
enum RepPhase { ready, pull, squeeze, release }

extension RepPhaseLabel on RepPhase {
  String get label {
    switch (this) {
      case RepPhase.ready:
        return 'START POSITION';
      case RepPhase.pull:
        return 'WORK PHASE (CONCENTRIC)';
      case RepPhase.squeeze:
        return 'PEAK CONTRACTION';
      case RepPhase.release:
        return 'CONTROLLED RETURN (ECCENTRIC)';
    }
  }
}

class RepTimeline {
  RepTimeline._();

  static const double pullStart = 0.10;
  static const double holdStart = 0.45;
  static const double returnStart = 0.55;
  static const double restStart = 0.92;

  static double _smooth(double t) {
    final c = t.clamp(0.0, 1.0);
    return c * c * (3 - 2 * c);
  }

  /// Muscle contraction (0 = start position, 1 = peak) at rep time [t] 0..1.
  static double contractionAt(double t) {
    final u = t.clamp(0.0, 1.0);
    if (u < pullStart) return 0;
    if (u < holdStart) {
      return _smooth((u - pullStart) / (holdStart - pullStart));
    }
    if (u < returnStart) return 1;
    if (u < restStart) {
      return 1 - _smooth((u - returnStart) / (restStart - returnStart));
    }
    return 0;
  }

  /// Rep time (0..1) on the way up at which the contraction equals [c].
  /// Used to pose the model from a measured position instead of a clock.
  static double timeForContraction(double c) {
    final k = c.clamp(0.0, 1.0);
    // Inverse of the smoothstep used in [contractionAt].
    final u = 0.5 - math.sin(math.asin(1 - 2 * k) / 3);
    return pullStart + u * (holdStart - pullStart);
  }

  static RepPhase phaseAt(double t) {
    final u = t.clamp(0.0, 1.0);
    if (u < pullStart) return RepPhase.ready;
    if (u < holdStart) return RepPhase.pull;
    if (u < returnStart) return RepPhase.squeeze;
    if (u < restStart) return RepPhase.release;
    return RepPhase.ready;
  }
}

/// Display names of the muscle groups (material names) in the model.
const Map<String, String> muscleGroupLabels = {
  'lats': 'Latissimus dorsi',
  'traps': 'Trapezius',
  'rhomboids': 'Rhomboids',
  'rear_delts': 'Rear deltoid',
  'side_delts': 'Side deltoid',
  'front_delts': 'Front deltoid',
  'rotator_cuff': 'Rotator cuff',
  'pecs': 'Pectoralis major',
  'biceps': 'Biceps & brachialis',
  'triceps': 'Triceps',
  'forearms': 'Forearms',
  'abs': 'Rectus abdominis',
  'obliques': 'Obliques',
  'serratus': 'Serratus anterior',
  'erectors': 'Spinal erectors',
  'glutes': 'Glutes',
  'quads': 'Quadriceps',
  'hamstrings': 'Hamstrings',
  'calves': 'Calves',
};

class CableExercise {
  /// Workout name, as used in the workout list and saved sessions.
  final String name;

  /// Animation clip in the model.
  final String animation;

  /// Prime movers and assisting muscle groups (ids from [muscleGroupLabels]).
  final List<String> primary;
  final List<String> secondary;

  /// Where the Gympath tracker goes and how to set the machine up.
  final String setup;

  /// One coaching cue per [RepPhase], in enum order.
  final List<String> cueTitles;
  final List<String> cueDetails;

  /// Camera that shows the working muscles and the machine best
  /// (model-viewer orbit and target; the figure stands at the origin, y is
  /// up and +z is in front of it).
  final String cameraOrbit;
  final String cameraTarget;

  /// True when the exercise is done sitting (the model sits on a bench).
  final bool seated;

  const CableExercise({
    required this.name,
    required this.animation,
    required this.primary,
    required this.secondary,
    required this.setup,
    required this.cueTitles,
    required this.cueDetails,
    required this.cameraOrbit,
    required this.cameraTarget,
    this.seated = false,
  });

  /// 0..1 highlight strength of a muscle group at rep time [t].
  double activation(String group, double t) {
    final c = RepTimeline.contractionAt(t);
    if (primary.contains(group)) return 0.55 + 0.45 * c;
    if (secondary.contains(group)) return 0.30 + 0.30 * c;
    return 0;
  }
}

const List<CableExercise> cableExercises = [
  CableExercise(
    name: 'Lat Pulldown',
    animation: 'LatPulldown',
    seated: true,
    primary: ['lats'],
    secondary: ['biceps', 'rhomboids', 'rear_delts', 'traps', 'forearms'],
    setup: 'Clip the tracker on the weight stack. Sit tall, thighs under the '
        'pad, hands a little wider than your shoulders.',
    cueTitles: ['Reach long', 'Elbows to your ribs', 'Squeeze', 'Let it rise'],
    cueDetails: [
      'Arms straight, shoulders relaxed up, chest lifted.',
      'Pull the shoulder blades down first, then drive the elbows down and '
          'slightly back. Do not lean far back.',
      'Bar near the upper chest, shoulder blades pinned down and together.',
      'Return slowly until the arms are straight. Keep tension, no dropping.',
    ],
    cameraOrbit: '135deg 78deg 5.4m',
    cameraTarget: '0m 1.10m 0.40m',
  ),
  CableExercise(
    name: 'Seated Cable Row',
    animation: 'SeatedCableRow',
    seated: true,
    primary: ['lats', 'rhomboids', 'traps'],
    secondary: ['rear_delts', 'biceps', 'erectors', 'forearms'],
    setup: 'Clip the tracker on the weight stack. Sit with knees slightly '
        'bent, back straight, arms reaching to the handle.',
    cueTitles: ['Reach, back flat', 'Elbows back', 'Pinch the blades', 'Reach again'],
    cueDetails: [
      'Lean slightly forward from the hips with a straight back.',
      'Pull the handle to your lower ribs, elbows brushing your sides.',
      'Squeeze the shoulder blades together, chest up, no shrugging.',
      'Let the arms go long under control. Do not round the lower back.',
    ],
    cameraOrbit: '115deg 78deg 5.6m',
    cameraTarget: '0m 0.90m 0.80m',
  ),
  CableExercise(
    name: 'Tricep Pushdown',
    animation: 'TricepPushdown',
    primary: ['triceps'],
    secondary: ['forearms', 'abs'],
    setup: 'Clip the tracker on the weight stack. Stand close to a high '
        'pulley, lean in slightly, elbows pinned to your sides.',
    cueTitles: ['Elbows pinned', 'Press down', 'Lock out', 'Rise slowly'],
    cueDetails: [
      'Forearms up, elbows tight against the ribs.',
      'Only the forearms move. Push until the arms are straight.',
      'Squeeze the back of the arms hard at the bottom.',
      'Let the handle rise to chest height without the elbows drifting.',
    ],
    cameraOrbit: '120deg 80deg 5.2m',
    cameraTarget: '0m 1.05m 0.50m',
  ),
  CableExercise(
    name: 'Cable Bicep Curl',
    animation: 'CableBicepCurl',
    primary: ['biceps'],
    secondary: ['forearms', 'front_delts'],
    setup: 'Clip the tracker on the weight stack. Stand facing a low pulley, '
        'palms up, elbows by your sides.',
    cueTitles: ['Arms long', 'Curl up', 'Squeeze', 'Lower slowly'],
    cueDetails: [
      'Stand tall, arms straight, shoulders back.',
      'Bend only at the elbows. Do not swing the body.',
      'Hands near the shoulders, biceps fully tight.',
      'Take about two seconds on the way down.',
    ],
    cameraOrbit: '55deg 80deg 5.2m',
    cameraTarget: '0m 1.00m 0.50m',
  ),
  CableExercise(
    name: 'Cable Chest Fly',
    animation: 'CableChestFly',
    primary: ['pecs'],
    secondary: ['front_delts', 'serratus', 'biceps', 'abs'],
    setup: 'Clip the tracker on one weight stack. Stand in the middle of the '
        'crossover, one foot forward, a slight lean from the hips.',
    cueTitles: ['Open wide', 'Hug a tree', 'Hands meet', 'Open under control'],
    cueDetails: [
      'Arms out with a soft bend in the elbows, chest stretched.',
      'Sweep the hands forward in a wide arc. Keep the elbow angle fixed.',
      'Hands together in front of the chest, squeeze the pecs.',
      'Let the arms open slowly until you feel the stretch again.',
    ],
    cameraOrbit: '25deg 78deg 5.4m',
    cameraTarget: '0m 1.05m 0.0m',
  ),
  CableExercise(
    name: 'Face Pull',
    animation: 'FacePull',
    primary: ['rear_delts', 'traps', 'rhomboids'],
    secondary: ['rotator_cuff', 'biceps'],
    setup: 'Clip the tracker on the weight stack. Set the rope at face height '
        'and step back until the arms are straight.',
    cueTitles: ['Arms straight', 'Elbows high', 'Hands by your ears', 'Reach forward'],
    cueDetails: [
      'Stand tall, ribs down, arms reaching to the rope.',
      'Pull towards your face with the elbows high and wide.',
      'Hands beside the ears, shoulder blades squeezed together.',
      'Return slowly. Do not let the shoulders roll forward.',
    ],
    cameraOrbit: '125deg 76deg 5.4m',
    cameraTarget: '0m 1.10m 0.75m',
  ),
];

/// Guide for a workout name, or null if there is none.
CableExercise? cableExerciseByName(String name) {
  for (final e in cableExercises) {
    if (e.name == name) return e;
  }
  return null;
}
