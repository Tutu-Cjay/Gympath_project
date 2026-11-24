import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gympath/screens/tracker_screen.dart';
import 'package:gympath/services/ble_service.dart';

void main() {
  test('tracker themes match the firmware (0..3) and have pictures', () {
    expect(trackerThemes.map((t) => t.id), [0, 1, 2, 3]);
    for (final t in trackerThemes) {
      expect(File(t.image).existsSync(), isTrue, reason: t.image);
    }
  });

  test('number styles match the firmware (0..3) and have pictures', () {
    expect(trackerDigitStyles.map((d) => d.id), [0, 1, 2, 3]);
    for (final d in trackerDigitStyles) {
      expect(File(d.image).existsSync(), isTrue, reason: d.image);
    }
  });

  test('settings packet: theme, plus the number style when known', () {
    expect(BleService.settingsPacket(2, null), [1, 2]);
    expect(BleService.settingsPacket(2, 3), [1, 2, 3]);
  });
}
