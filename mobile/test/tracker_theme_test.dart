import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gympath/screens/tracker_screen.dart';

void main() {
  test('tracker themes match the firmware (0..3) and have pictures', () {
    expect(trackerThemes.map((t) => t.id), [0, 1, 2, 3]);
    for (final t in trackerThemes) {
      expect(File(t.image).existsSync(), isTrue, reason: t.image);
    }
  });
}
