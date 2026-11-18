import 'dart:math' as math;

/// What the tracker measured for one repetition.
class RepMetrics {
  /// How far the weight stack travelled (cm).
  final double rangeCm;

  /// Mean velocity while the stack was rising (m/s): the lifting (concentric)
  /// part of the rep, the number velocity-based training is built on.
  final double meanVelocity;

  /// Highest velocity during the lift (m/s).
  final double peakVelocity;

  /// Time for the whole rep, up and down (s).
  final double durationSec;

  const RepMetrics({
    required this.rangeCm,
    required this.meanVelocity,
    required this.peakVelocity,
    required this.durationSec,
  });

  Map<String, dynamic> toJson() => {
        'rangeCm': _round(rangeCm, 1),
        'meanVelocity': _round(meanVelocity, 3),
        'peakVelocity': _round(peakVelocity, 3),
        'durationSec': _round(durationSec, 2),
      };

  factory RepMetrics.fromJson(Map<String, dynamic> j) => RepMetrics(
        rangeCm: _num(j['rangeCm']),
        meanVelocity: _num(j['meanVelocity']),
        peakVelocity: _num(j['peakVelocity']),
        durationSec: _num(j['durationSec']),
      );
}

/// One set on one machine, persisted locally and (later) synced to the
/// backend. Sets done in one visit to an exercise share a [workoutId].
class WorkoutSession {
  /// Exercise name, as in the workout list (e.g. "Lat Pulldown").
  final String workoutName;
  final int reps;

  /// Weight selected on the stack (kg). 0 = not entered.
  final double weightKg;

  /// Per-rep measurements; may be shorter than [reps] (older records, or reps
  /// the tracker counted without a clean measurement).
  final List<RepMetrics> repDetails;

  /// Groups the sets of one workout; also the set's position in it.
  final String workoutId;
  final int setIndex;

  final int durationSec;
  final DateTime timestamp;

  const WorkoutSession({
    required this.workoutName,
    required this.reps,
    this.weightKg = 0,
    this.repDetails = const [],
    this.workoutId = '',
    this.setIndex = 1,
    required this.durationSec,
    required this.timestamp,
  });

  /// Score shown on the dashboard: one point per rep.
  int get points => reps;

  /// Weight moved in the set: weight × reps (kg).
  double get volumeKg => weightKg * reps;

  /// Estimated one-rep max (Epley), or 0 without a weight. Beyond 12 reps the
  /// formula gets unreliable, so higher counts are treated as 12.
  double get estimatedOneRepMax {
    if (weightKg <= 0 || reps <= 0) return 0;
    if (reps == 1) return weightKg;
    return weightKg * (1 + math.min(reps, 12) / 30);
  }

  /// Mean lifting velocity over the measured reps (m/s), or 0.
  double get meanVelocity {
    if (repDetails.isEmpty) return 0;
    return repDetails.fold<double>(0, (a, r) => a + r.meanVelocity) /
        repDetails.length;
  }

  /// Mean range of motion over the measured reps (cm), or 0.
  double get meanRangeCm {
    if (repDetails.isEmpty) return 0;
    return repDetails.fold<double>(0, (a, r) => a + r.rangeCm) /
        repDetails.length;
  }

  /// How much slower the last measured rep was than the fastest of the first
  /// two (0..1). A rising loss means fatigue; null with fewer than 3 reps.
  double? get velocityLoss {
    if (repDetails.length < 3) return null;
    final best = math.max(repDetails[0].meanVelocity, repDetails[1].meanVelocity);
    if (best <= 0) return null;
    return ((best - repDetails.last.meanVelocity) / best).clamp(0.0, 1.0);
  }

  Map<String, dynamic> toJson() => {
        'workoutName': workoutName,
        'reps': reps,
        'weightKg': weightKg,
        'repDetails': repDetails.map((r) => r.toJson()).toList(),
        'workoutId': workoutId,
        'setIndex': setIndex,
        'durationSec': durationSec,
        'timestamp': timestamp.toIso8601String(),
      };

  /// Also reads records saved by older app versions (no weight / reps detail).
  factory WorkoutSession.fromJson(Map<String, dynamic> j) {
    final timestamp =
        DateTime.tryParse((j['timestamp'] ?? '') as String) ?? DateTime.now();
    final details = j['repDetails'];
    return WorkoutSession(
      workoutName: (j['workoutName'] ?? 'Workout') as String,
      reps: (j['reps'] ?? 0) as int,
      weightKg: _num(j['weightKg']),
      repDetails: details is List
          ? details
              .whereType<Map<String, dynamic>>()
              .map(RepMetrics.fromJson)
              .toList()
          : const [],
      workoutId: (j['workoutId'] ?? timestamp.toIso8601String()) as String,
      setIndex: (j['setIndex'] ?? 1) as int,
      durationSec: (j['durationSec'] ?? 0) as int,
      timestamp: timestamp,
    );
  }
}

double _num(Object? v) => v is num ? v.toDouble() : 0.0;

double _round(double v, int digits) {
  final f = math.pow(10, digits);
  return (v * f).round() / f;
}
