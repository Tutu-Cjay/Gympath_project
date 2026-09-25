/// A single completed workout, persisted locally and (later) synced to the
/// backend. Kept deliberately small so it maps 1:1 to a backend row.
class WorkoutSession {
  final String workoutName;
  final int reps;
  final double accuracy; // 0..100
  final String performance; // S / A / B / C
  final int bonus;
  final int durationSec;
  final DateTime timestamp;

  const WorkoutSession({
    required this.workoutName,
    required this.reps,
    required this.accuracy,
    required this.performance,
    required this.bonus,
    required this.durationSec,
    required this.timestamp,
  });

  /// Score awarded for this session — reps plus the accuracy bonus.
  int get points => reps + bonus;

  Map<String, dynamic> toJson() => {
        'workoutName': workoutName,
        'reps': reps,
        'accuracy': accuracy,
        'performance': performance,
        'bonus': bonus,
        'durationSec': durationSec,
        'timestamp': timestamp.toIso8601String(),
      };

  factory WorkoutSession.fromJson(Map<String, dynamic> j) => WorkoutSession(
        workoutName: (j['workoutName'] ?? 'Workout') as String,
        reps: (j['reps'] ?? 0) as int,
        accuracy: ((j['accuracy'] ?? 0) as num).toDouble(),
        performance: (j['performance'] ?? '-') as String,
        bonus: (j['bonus'] ?? 0) as int,
        durationSec: (j['durationSec'] ?? 0) as int,
        timestamp:
            DateTime.tryParse((j['timestamp'] ?? '') as String) ?? DateTime.now(),
      );
}
