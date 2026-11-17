import 'package:flutter_test/flutter_test.dart';
import 'package:gympath/models/motion_reconstructor.dart';
import 'package:gympath/models/track_sample.dart';
import 'package:gympath/services/track_simulator.dart';

void main() {
  test('idle until started, then calibrates, then tracks', () {
    final sim = TrackSimulator();
    expect(sim.step(20).state, TrackState.idle);
    sim.start();
    expect(sim.step(20).state, TrackState.calibrating);
    TrackSample s = sim.step(20);
    for (var ms = 40; ms < TrackSimulator.calibrationMs + 40; ms += 20) {
      s = sim.step(20);
    }
    expect(s.state, TrackState.tracking);
    sim.stop();
    expect(sim.step(20).state, TrackState.idle);
  });

  test('one rep every repSeconds, stack rises to about the travel', () {
    final sim = TrackSimulator(repSeconds: 3.0, travelM: 0.30);
    sim.start();
    var top = 0.0;
    TrackSample s = sim.step(20);
    for (var i = 0; i < (TrackSimulator.calibrationMs + 9500) ~/ 20; i++) {
      s = sim.step(20);
      if (s.position > top) top = s.position;
    }
    expect(s.reps, 3);
    expect(top, inInclusiveRange(0.27, 0.34));
    expect(s.timestampMs, greaterThan(9000));
  });

  test('zero moves the origin to the current height', () {
    final sim = TrackSimulator(repSeconds: 4.0);
    sim.start();
    TrackSample s = sim.step(20);
    // Run to the top of the first rep (half way through it).
    for (var i = 0; i < (TrackSimulator.calibrationMs + 2000) ~/ 20; i++) {
      s = sim.step(20);
    }
    expect(s.position, greaterThan(0.25));
    sim.zero();
    expect(sim.step(20).position.abs(), lessThan(0.02));
  });

  test('simulated set drives the figure through full reps', () {
    final sim = TrackSimulator();
    final motion = MotionReconstructor();
    sim.start();
    var low = 1.0, high = 0.0;
    for (var i = 0; i < 20000 ~/ 20; i++) {
      final s = sim.step(20);
      if (s.state != TrackState.tracking) continue;
      final p = motion.update(s.position);
      if (s.reps >= 2) {
        if (p < low) low = p;
        if (p > high) high = p;
      }
    }
    expect(motion.peaks, greaterThanOrEqualTo(4));
    expect(high, greaterThan(0.9));
    expect(low, lessThan(0.1));
  });
}
