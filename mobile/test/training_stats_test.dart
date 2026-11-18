import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gympath/models/training_stats.dart';
import 'package:gympath/models/workout_session.dart';
import 'package:gympath/services/raw_export.dart';
import 'package:gympath/models/track_sample.dart';

WorkoutSession set(String name, double kg, int reps, DateTime at,
        {List<double> speeds = const []}) =>
    WorkoutSession(
      workoutName: name,
      reps: reps,
      weightKg: kg,
      repDetails: [
        for (final v in speeds)
          RepMetrics(rangeCm: 40, meanVelocity: v, peakVelocity: v * 1.5, durationSec: 2.5)
      ],
      workoutId: at.toIso8601String(),
      durationSec: 30,
      timestamp: at,
    );

void main() {
  final mon = DateTime(2026, 11, 16, 18); // a Monday
  final sets = [
    set('Lat Pulldown', 40, 10, mon.subtract(const Duration(days: 7))),
    set('Lat Pulldown', 45, 8, mon.subtract(const Duration(days: 7, hours: -1))),
    set('Lat Pulldown', 45, 10, mon, speeds: [0.6, 0.62, 0.55, 0.45]),
    set('Lat Pulldown', 50, 5, mon.add(const Duration(minutes: 5))),
    set('Cable Bicep Curl', 15, 12, mon.add(const Duration(days: 1))),
  ];
  final t = TrainingStats(sets);

  test('one-rep max, volume and speed loss of a set', () {
    final s = sets[2];
    expect(s.volumeKg, 450);
    expect(s.estimatedOneRepMax, closeTo(45 * (1 + 10 / 30), 1e-9));
    expect(set('X', 100, 1, mon).estimatedOneRepMax, 100);
    expect(set('X', 0, 10, mon).estimatedOneRepMax, 0);
    // Fastest of the first two reps 0.62, last 0.45.
    expect(s.velocityLoss, closeTo((0.62 - 0.45) / 0.62, 1e-9));
    expect(sets[0].velocityLoss, isNull);
  });

  test('history has one point per day with the best values', () {
    final h = t.history('Lat Pulldown');
    expect(h, hasLength(2));
    expect(h[0].topWeightKg, 45);
    expect(h[0].volumeKg, 40 * 10 + 45 * 8);
    expect(h[1].sets, 2);
    expect(h[1].estimatedOneRepMax, closeTo(60, 1e-9)); // 45 × 10 beats 50 × 5
  });

  test('records and new-record detection', () {
    final r = t.records('Lat Pulldown');
    expect(r.heaviest!.weightKg, 50);
    expect(r.bestOneRepMax!.weightKg, 45);
    expect(r.mostVolume!.volumeKg, 450);
    expect(r.fastest!.meanVelocity, closeTo(0.555, 0.001));
    expect(t.isRecord(sets[2]), isTrue); // 1RM 60 > 57
    expect(t.isRecord(sets[3]), isTrue); // heavier than ever
    expect(t.isRecord(sets[0]), isFalse); // first ever set: nothing to beat
    expect(t.isRecord(set('Lat Pulldown', 30, 5, mon.add(const Duration(hours: 1)))), isFalse);
  });

  test('week summary and muscle sets', () {
    final w = t.thisWeek(mon.add(const Duration(days: 2)));
    expect(w.sets, 3);
    expect(w.workoutDays, 2);
    expect(w.volumeKg, 450 + 250 + 180);
    final m = t.muscleSets(weekStart(mon), weekStart(mon).add(const Duration(days: 7)));
    expect(m['lats'], 2); // two pulldown sets, prime mover
    expect(m['biceps'], 2 * 0.5 + 1); // assisting twice + curl
    expect(m.containsKey('pecs'), isFalse);
    expect(weekStart(DateTime(2026, 11, 22, 23)), DateTime(2026, 11, 16));
  });

  test('exercises ordered by most recent, last weight', () {
    expect(t.exercises(), ['Cable Bicep Curl', 'Lat Pulldown']);
    expect(t.lastWeight('Lat Pulldown'), 50);
    expect(t.lastWeight('Face Pull'), 0);
  });

  test('sets round-trip through JSON; old records still load', () {
    final s = sets[2];
    final back = WorkoutSession.fromJson(
        jsonDecode(jsonEncode(s.toJson())) as Map<String, dynamic>);
    expect(back.weightKg, 45);
    expect(back.repDetails, hasLength(4));
    expect(back.repDetails[1].meanVelocity, closeTo(0.62, 1e-9));
    final old = WorkoutSession.fromJson({
      'workoutName': 'Face Pull',
      'reps': 12,
      'accuracy': 0,
      'performance': '-',
      'bonus': 0,
      'durationSec': 40,
      'timestamp': '2026-11-01T10:00:00.000',
    });
    expect(old.reps, 12);
    expect(old.weightKg, 0);
    expect(old.repDetails, isEmpty);
    expect(old.workoutId, isNotEmpty);
    expect(old.simulated, isFalse);
    final sim = WorkoutSession(
        workoutName: 'Face Pull', reps: 10, weightKg: 20, durationSec: 30,
        timestamp: mon, simulated: true);
    expect(sim.toJson()['simulated'], isTrue);
    expect(s.toJson().containsKey('simulated'), isFalse);
    expect(WorkoutSession.fromJson(sim.toJson()).simulated, isTrue);
  });

  test('raw export CSV', () {
    final csv = RawExport.toCsv([
      const TrackSample(
          timestampMs: 20, accel: 0.1, velocity: 0.25, position: 0.123456,
          reps: 1, state: TrackState.tracking, still: true),
    ], exercise: 'Face Pull', weightKg: 22.5, simulated: true,
        recordedAt: DateTime(2026, 11, 18, 18, 43, 5));
    final lines = csv.trim().split('\n');
    expect(lines[1], '# exercise,Face Pull');
    expect(lines[3], '# source,simulation');
    expect(lines[5], 't_ms,accel_mps2,velocity_mps,position_m,reps,state,zupt');
    expect(lines[6], '20,0.1000,0.2500,0.1235,1,2,1');
    expect(RawExport.fileName('Lat Pulldown', DateTime(2026, 11, 18, 18, 43, 5)),
        'gympath_lat-pulldown_20261118-184305.csv');
  });
}
