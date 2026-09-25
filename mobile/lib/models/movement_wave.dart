import 'dart:math';

/// A recorded reference movement: the normalized posZ trajectory of one rep
/// over time. Recorded once (by the user or a coach), then followed during a
/// workout. `samples` are resampled to a fixed length and normalized to 0..1
/// so different recordings line up and can later be shared between users.
class MovementWave {
  final String name;
  final String exerciseKey; // lowercased workout name
  final List<double> samples; // normalized 0..1, fixed length
  final DateTime createdAt;

  static const int length = 120; // fixed sample count

  const MovementWave({
    required this.name,
    required this.exerciseKey,
    required this.samples,
    required this.createdAt,
  });

  /// Value of the wave at phase t∈[0,1] with linear interpolation.
  double sampleAt(double t) {
    if (samples.isEmpty) return 0.5;
    final x = (t.clamp(0.0, 1.0)) * (samples.length - 1);
    final i = x.floor();
    final f = x - i;
    if (i >= samples.length - 1) return samples.last;
    return samples[i] * (1 - f) + samples[i + 1] * f;
  }

  /// Build a wave from a raw posZ capture: trims flat ends, normalizes to
  /// 0..1, and resamples to [length] points.
  static MovementWave? fromCapture({
    required String name,
    required String exerciseKey,
    required List<double> raw,
  }) {
    if (raw.length < 8) return null;
    final lo = raw.reduce(min);
    final hi = raw.reduce(max);
    final range = hi - lo;
    if (range < 1e-4) return null; // no real movement captured

    // resample raw → fixed length with linear interpolation, normalize
    final out = List<double>.filled(length, 0.0);
    for (int k = 0; k < length; k++) {
      final x = k / (length - 1) * (raw.length - 1);
      final i = x.floor();
      final f = x - i;
      final v = i >= raw.length - 1
          ? raw.last
          : raw[i] * (1 - f) + raw[i + 1] * f;
      out[k] = ((v - lo) / range).clamp(0.0, 1.0);
    }
    return MovementWave(
      name: name,
      exerciseKey: exerciseKey,
      samples: out,
      createdAt: DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'exerciseKey': exerciseKey,
        'samples': samples,
        'createdAt': createdAt.toIso8601String(),
      };

  factory MovementWave.fromJson(Map<String, dynamic> j) => MovementWave(
        name: (j['name'] ?? 'Reference') as String,
        exerciseKey: (j['exerciseKey'] ?? '') as String,
        samples: ((j['samples'] ?? []) as List<dynamic>)
            .map((e) => (e as num).toDouble())
            .toList(),
        createdAt: DateTime.tryParse((j['createdAt'] ?? '') as String) ??
            DateTime.now(),
      );
}
