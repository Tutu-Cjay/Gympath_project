import 'dart:math' as math;

import '../models/track_sample.dart';

/// Stand-in for the tracker: produces the same [TrackSample]s the firmware
/// sends (calibrate, then the weight stack going up and down), so the whole
/// app can be used and demoed without the hardware.
///
/// Pure and clock-free: call [step] with the elapsed milliseconds.
class TrackSimulator {
  /// Seconds for one repetition and the stack travel around which reps vary.
  final double repSeconds;
  final double travelM;
  final math.Random _random;

  TrackSimulator({this.repSeconds = 3.6, this.travelM = 0.34, int seed = 7})
      : _random = math.Random(seed);

  static const int calibrationMs = 900;

  TrackState _state = TrackState.idle;
  int _clockMs = 0;
  int _stateMs = 0;
  double _repClock = 0; // seconds into the current rep
  double _repTravel = 0.34;
  double _offset = 0; // ZERO moves the origin here
  double _lastPosition = 0;
  int _reps = 0;

  TrackState get state => _state;

  /// START: hold still to calibrate, then track.
  void start() {
    _state = TrackState.calibrating;
    _stateMs = 0;
    _repClock = 0;
    _reps = 0;
    _offset = 0;
    _lastPosition = 0;
    _repTravel = travelM;
  }

  void stop() => _state = TrackState.idle;

  /// ZERO: the current height becomes the new origin.
  void zero() => _offset += _lastPosition;

  static double _smooth(double x) {
    final c = x.clamp(0.0, 1.0);
    return c * c * (3 - 2 * c);
  }

  /// Stack height (0..1 of the travel) at rep phase [u] in 0..1:
  /// rest, lift, hold, lower, rest.
  static double shape(double u) {
    if (u < 0.10) return 0;
    if (u < 0.45) return _smooth((u - 0.10) / 0.35);
    if (u < 0.55) return 1;
    if (u < 0.92) return 1 - _smooth((u - 0.55) / 0.37);
    return 0;
  }

  /// Advance by [dtMs] and return the sample the tracker would send.
  TrackSample step(int dtMs) {
    _clockMs += dtMs;
    _stateMs += dtMs;
    final dt = dtMs / 1000.0;
    if (_state == TrackState.calibrating && _stateMs >= calibrationMs) {
      _state = TrackState.tracking;
      _stateMs = 0;
    }

    double raw = 0;
    if (_state == TrackState.tracking) {
      _repClock += dt;
      if (_repClock >= repSeconds) {
        _repClock -= repSeconds;
        _reps++;
        // No two reps are the same height.
        _repTravel = travelM * (0.92 + 0.16 * _random.nextDouble());
      }
      raw = shape(_repClock / repSeconds) * _repTravel +
          (_random.nextDouble() - 0.5) * 0.003;
    }
    final position = raw - _offset;
    final velocity = dt > 0 ? (position - _lastPosition) / dt : 0.0;
    final still = _state != TrackState.tracking || velocity.abs() < 0.02;
    _lastPosition = position;
    return TrackSample(
      timestampMs: _clockMs,
      accel: 0,
      velocity: _state == TrackState.tracking ? velocity : 0,
      position: _state == TrackState.tracking ? position : 0,
      reps: _reps,
      state: _state,
      still: still,
    );
  }
}
