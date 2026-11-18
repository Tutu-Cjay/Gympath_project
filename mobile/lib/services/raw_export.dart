import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/track_sample.dart';

/// Raw tracker samples of one set as CSV, for checking the tracker against
/// reality (counting reps by hand, measuring the stack travel with a tape).
///
/// Columns match the firmware's serial debug stream
/// (t,a,v,p,reps,state,zupt), so the same scripts read both.
class RawExport {
  RawExport._();

  static String toCsv(
    List<TrackSample> samples, {
    required String exercise,
    required double weightKg,
    required bool simulated,
    DateTime? recordedAt,
  }) {
    final b = StringBuffer()
      ..writeln('# gympath raw set export')
      ..writeln('# exercise,$exercise')
      ..writeln('# weight_kg,$weightKg')
      ..writeln('# source,${simulated ? 'simulation' : 'tracker'}')
      ..writeln('# recorded_at,${(recordedAt ?? DateTime.now()).toIso8601String()}')
      ..writeln('t_ms,accel_mps2,velocity_mps,position_m,reps,state,zupt');
    for (final s in samples) {
      b.writeln('${s.timestampMs},${s.accel.toStringAsFixed(4)},'
          '${s.velocity.toStringAsFixed(4)},${s.position.toStringAsFixed(4)},'
          '${s.reps},${s.state.index},${s.still ? 1 : 0}');
    }
    return b.toString();
  }

  /// File name like `gympath_lat-pulldown_20261118-1843.csv`.
  static String fileName(String exercise, DateTime at) {
    String two(int v) => v.toString().padLeft(2, '0');
    final slug = exercise.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-');
    return 'gympath_${slug}_${at.year}${two(at.month)}${two(at.day)}-'
        '${two(at.hour)}${two(at.minute)}${two(at.second)}.csv';
  }

  /// Write the CSV to a temporary file and open the system share sheet.
  static Future<void> share(String csv, String name) async {
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/$name');
    await file.writeAsString(csv);
    await Share.shareXFiles(
      [XFile(file.path, mimeType: 'text/csv')],
      subject: name,
    );
  }
}
