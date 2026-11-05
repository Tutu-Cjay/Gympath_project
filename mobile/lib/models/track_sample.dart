import 'dart:typed_data';

/// Device tracking state (mirrors `TrackState` in firmware/Gympath_Track).
enum TrackState { idle, calibrating, tracking, calibFailed }

/// One 1D gravity-axis sample from the …cdef9 characteristic (20 bytes).
///
/// `position` is relative to where the device was when START was pressed;
/// positive = against gravity (up), negative = with gravity (down).
class TrackSample {
  final int timestampMs;
  final double accel; // m/s² along the up axis
  final double velocity; // m/s
  final double position; // m
  final int reps;
  final TrackState state;
  final bool still; // ZUPT active

  const TrackSample({
    required this.timestampMs,
    required this.accel,
    required this.velocity,
    required this.position,
    required this.reps,
    required this.state,
    required this.still,
  });

  static const int byteLength = 20;

  static TrackSample? fromBytes(Uint8List bytes) {
    if (bytes.lengthInBytes < byteLength) return null;
    final d = ByteData.sublistView(bytes);
    final st = d.getUint8(18);
    return TrackSample(
      timestampMs: d.getUint32(0, Endian.little),
      accel: d.getFloat32(4, Endian.little),
      velocity: d.getFloat32(8, Endian.little),
      position: d.getFloat32(12, Endian.little),
      reps: d.getInt16(16, Endian.little),
      state: st < TrackState.values.length
          ? TrackState.values[st]
          : TrackState.idle,
      still: (d.getUint8(19) & 1) != 0,
    );
  }
}
