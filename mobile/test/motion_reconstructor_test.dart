import 'package:flutter_test/flutter_test.dart';
import 'package:gympath/models/motion_reconstructor.dart';
import 'package:gympath/services/track_simulator.dart';

/// Stack height for a set of clean reps: [travel] metres, [steps] per rep.
Iterable<double> reps(int count, double travel, {int steps = 180}) sync* {
  for (var r = 0; r < count; r++) {
    for (var i = 0; i < steps; i++) {
      yield TrackSimulator.shape(i / steps) * travel;
    }
  }
}

void main() {
  test('learns the range from the first rep, then reaches 0 and 1', () {
    final m = MotionReconstructor();
    var peak = 0.0;
    for (final p in reps(1, 0.42)) {
      peak = peak < m.update(p) ? m.progress : peak;
    }
    expect(m.peaks, 1);
    expect(m.rangeM, closeTo(0.42, 0.01));

    final seen = [for (final p in reps(2, 0.42)) m.update(p)];
    expect(seen.reduce((a, b) => a > b ? a : b), closeTo(1.0, 0.02));
    expect(seen.reduce((a, b) => a < b ? a : b), closeTo(0.0, 0.02));
    expect(m.peaks, 3);
  });

  test('a short range of motion still reaches full contraction', () {
    final m = MotionReconstructor();
    for (final p in reps(1, 0.15)) {
      m.update(p);
    }
    // Before the first peak the default range applies; afterwards the user's.
    expect(m.rangeM, closeTo(0.15, 0.01));
    final seen = [for (final p in reps(1, 0.15)) m.update(p)];
    expect(seen.reduce((a, b) => a > b ? a : b), closeTo(1.0, 0.03));
  });

  test('progress follows the stack in both directions', () {
    final m = MotionReconstructor();
    for (final p in reps(2, 0.30)) {
      m.update(p);
    }
    double last = m.update(0);
    for (var h = 0.02; h <= 0.30; h += 0.02) {
      final now = m.update(h);
      expect(now, greaterThanOrEqualTo(last));
      last = now;
    }
    expect(m.rising, isTrue);
    for (var h = 0.28; h >= 0; h -= 0.02) {
      final now = m.update(h);
      expect(now, lessThanOrEqualTo(last));
      last = now;
    }
  });

  test('tremor at rest does not count as reps', () {
    final m = MotionReconstructor();
    for (var i = 0; i < 500; i++) {
      m.update(0.004 * (i.isEven ? 1 : -1));
    }
    expect(m.peaks, 0);
    expect(m.progress, lessThan(0.05));
  });

  test('slow drift of the zero point is absorbed', () {
    final m = MotionReconstructor();
    var drift = 0.0;
    final tops = <double>[];
    for (var r = 0; r < 6; r++) {
      var top = 0.0;
      for (final p in reps(1, 0.30)) {
        drift -= 0.0004; // the position sinks 7 cm per rep
        final now = m.update(p + drift);
        if (now > top) top = now;
      }
      tops.add(top);
    }
    // Still close to full contraction on the later reps despite ~40 cm drift.
    expect(tops.last, greaterThan(0.85));
    expect(m.progress, lessThan(0.2));
  });

  test('reset forgets the learned range', () {
    final m = MotionReconstructor();
    for (final p in reps(2, 0.5)) {
      m.update(p);
    }
    m.reset();
    expect(m.peaks, 0);
    expect(m.progress, 0);
    expect(m.rangeM, m.defaultRangeM);
  });
}
