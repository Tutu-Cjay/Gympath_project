import 'dart:math' as math;

/// Rebuilds where the user is in a repetition from the tracker's one number:
/// the height of the weight stack.
///
/// On a cable machine the stack rises while the muscle shortens and sinks on
/// the way back, whichever way the handle moves. So the stack height, scaled
/// between its resting height and the top of the user's own reps, is the
/// progress through the working phase: 0 = start position, 1 = peak
/// contraction. That progress poses the 3D figure (see AnatomyViewer).
///
/// The range is learned as the set goes on. Each rep is measured from its own
/// bottom to its own top: the first one sets the range, later ones pull it
/// halfway towards themselves, and the resting height follows the bottom of
/// each rep. Because only that rise matters, not the absolute height, the
/// figure reaches full contraction for short and tall users alike and slow
/// drift of the tracker's zero point does not shrink the movement.
class MotionReconstructor {
  /// Travel assumed until the first rep has shown the real one (m).
  final double defaultRangeM;

  /// Smallest travel that counts as a rep (m).
  final double minRangeM;

  MotionReconstructor({this.defaultRangeM = 0.30, this.minRangeM = 0.06});

  double _floor = 0;
  double _range = 0; // learned rise of one rep; 0 until the first peak
  double _extreme = 0;
  bool _rising = true;
  int _peaks = 0;
  double _progress = 0;
  bool _started = false;

  /// 0 = start position, 1 = peak contraction.
  double get progress => _progress;

  /// Travel of the weight stack the progress is scaled to (m).
  double get rangeM =>
      math.max(_peaks == 0 ? defaultRangeM : _range, minRangeM);

  /// Height of the stack above its resting position (m).
  double get heightM => _started ? math.max(0.0, _last - _floor) : 0.0;
  double _last = 0;

  /// Number of turning points at the top seen so far.
  int get peaks => _peaks;

  /// True while the stack is on its way up.
  bool get rising => _rising;

  void reset() {
    _floor = _range = _extreme = _last = 0;
    _rising = true;
    _peaks = 0;
    _progress = 0;
    _started = false;
  }

  /// Feed one position sample (m, + = up). Returns the new [progress].
  double update(double positionM) {
    final p = positionM;
    if (!_started) {
      _started = true;
      _floor = _extreme = p;
    }
    _last = p;
    if (p < _floor) _floor = p;
    // Higher than any rep so far: the range grows with it straight away.
    if (_peaks > 0 && p - _floor > _range) _range = p - _floor;

    // A turn only counts once the stack has come back by a clear margin.
    final margin = math.max(0.015, 0.15 * rangeM);
    if (_rising) {
      if (p > _extreme) {
        _extreme = p;
      } else if (_extreme - p > margin) {
        final rise = _extreme - _floor;
        if (rise >= minRangeM) {
          _range = _peaks == 0 ? rise : _range + (rise - _range) * 0.5;
          _peaks++;
        }
        _rising = false;
        _extreme = p;
      }
    } else {
      if (p < _extreme) {
        _extreme = p;
      } else if (p - _extreme > margin) {
        // Bottom of a rep: let the resting height follow it (drift).
        _floor += (_extreme - _floor) * 0.5;
        _rising = true;
        _extreme = p;
      }
    }

    _progress = ((p - _floor) / rangeM).clamp(0.0, 1.0);
    return _progress;
  }
}
