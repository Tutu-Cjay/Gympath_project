import 'package:flutter_test/flutter_test.dart';
import 'package:gympath/models/rep_analyzer.dart';
import 'package:gympath/models/track_sample.dart';
import 'package:gympath/services/track_simulator.dart';

TrackSample sample(int t, double p, double v, int reps,
        [TrackState state = TrackState.tracking]) =>
    TrackSample(
        timestampMs: t,
        accel: 0,
        velocity: v,
        position: p,
        reps: reps,
        state: state,
        still: false);

void main() {
  test('measures every rep of a simulated set', () {
    final sim = TrackSimulator(repSeconds: 3.0, travelM: 0.30);
    final a = RepAnalyzer();
    sim.start();
    var counted = 0;
    for (var i = 0; i < 14000 ~/ 20; i++) {
      final s = sim.step(20);
      if (a.add(s) != null) counted++;
    }
    expect(counted, 4);
    expect(a.reps, hasLength(4));
    for (final r in a.reps) {
      // Each rep travels 0.92..1.08 × 30 cm in the simulator.
      expect(r.rangeCm, inInclusiveRange(26, 34));
      // 30 cm lifted in about 1 s (35 % of a 3 s rep), smoothstep profile.
      expect(r.meanVelocity, inInclusiveRange(0.15, 0.40));
      expect(r.peakVelocity, greaterThan(r.meanVelocity));
      expect(r.durationSec, closeTo(3.0, 0.15));
    }
  });

  test('ignores samples outside tracking and a counter reset', () {
    final a = RepAnalyzer();
    expect(a.add(sample(0, 0, 0, 0, TrackState.calibrating)), isNull);
    // One clean rep: up 40 cm at 0.5 m/s, back down, counted at the end.
    var t = 0;
    for (var i = 0; i <= 40; i++) {
      a.add(sample(t += 20, i / 100, 0.5, 0));
    }
    for (var i = 40; i >= 10; i--) {
      a.add(sample(t += 20, i / 100, -0.5, 0));
    }
    final rep = a.add(sample(t += 20, 0.08, -0.5, 1));
    expect(rep, isNotNull);
    expect(rep!.rangeCm, closeTo(40, 0.01));
    expect(rep.meanVelocity, closeTo(0.5, 1e-9));
    // Firmware restarted the count: no phantom rep.
    expect(a.add(sample(t += 20, 0.0, 0, 0)), isNull);
    expect(a.reps, hasLength(1));
  });

  test('reset starts a new set', () {
    final a = RepAnalyzer();
    for (var i = 0; i < 10; i++) {
      a.add(sample(i * 20, i / 50, 0.4, i < 9 ? 3 : 4));
    }
    expect(a.reps, hasLength(1));
    a.reset();
    expect(a.reps, isEmpty);
    // After reset the current counter value is the starting point.
    expect(a.add(sample(0, 0, 0, 4)), isNull);
  });
}
