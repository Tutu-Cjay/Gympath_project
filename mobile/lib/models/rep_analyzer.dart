import 'dart:math' as math;

import 'track_sample.dart';
import 'workout_session.dart';

/// Measures each repetition from the tracker's samples.
///
/// The firmware counts the reps (a rep ends once the stack has come back at
/// least 60 % of the way). Everything between two counts is one rep's
/// window: its range is the window's highest minus lowest stack position, and
/// its lifting velocity comes from the samples on the way up to that highest
/// point (velocity > [liftThreshold]).
class RepAnalyzer {
  /// Slower than this does not count as lifting (m/s): removes sensor noise
  /// while the stack rests or the user pauses at the top.
  final double liftThreshold;

  RepAnalyzer({this.liftThreshold = 0.03});

  final List<RepMetrics> _reps = [];
  final List<TrackSample> _window = [];
  int _lastCount = 0;
  bool _started = false;

  /// Reps measured so far in this set.
  List<RepMetrics> get reps => List.unmodifiable(_reps);

  void reset() {
    _reps.clear();
    _window.clear();
    _lastCount = 0;
    _started = false;
  }

  /// Feed every sample while tracking. Returns the new rep when the tracker
  /// just counted one, otherwise null.
  RepMetrics? add(TrackSample s) {
    if (s.state != TrackState.tracking) return null;
    if (!_started) {
      _started = true;
      _lastCount = s.reps;
    }
    _window.add(s);
    if (s.reps <= _lastCount) {
      if (s.reps < _lastCount) _lastCount = s.reps; // counter was reset
      return null;
    }
    _lastCount = s.reps;
    final rep = _measure(_window);
    // Keep the last sample: it is where the next rep starts.
    _window
      ..clear()
      ..add(s);
    // Several reps counted at once (lost packets): the window is measured as
    // one rep; the ones before it go unmeasured.
    if (rep != null) _reps.add(rep);
    return rep;
  }

  RepMetrics? _measure(List<TrackSample> w) {
    if (w.length < 3) return null;
    var top = 0;
    var low = w.first.position;
    for (var i = 0; i < w.length; i++) {
      if (w[i].position > w[top].position) top = i;
      low = math.min(low, w[i].position);
    }
    var sum = 0.0, peak = 0.0;
    var n = 0;
    for (var i = 0; i <= top; i++) {
      final v = w[i].velocity;
      if (v > liftThreshold) {
        sum += v;
        n++;
        peak = math.max(peak, v);
      }
    }
    final duration = _elapsedMs(w.first.timestampMs, w.last.timestampMs) / 1000;
    return RepMetrics(
      rangeCm: (w[top].position - low) * 100,
      meanVelocity: n == 0 ? 0 : sum / n,
      peakVelocity: peak,
      durationSec: duration,
    );
  }

  // The firmware clock is a uint32 of milliseconds; it can wrap.
  static int _elapsedMs(int from, int to) =>
      to >= from ? to - from : to + 0x100000000 - from;
}
