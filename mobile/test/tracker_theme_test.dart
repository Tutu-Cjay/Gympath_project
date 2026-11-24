import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gympath/screens/tracker_preview_data.dart';
import 'package:gympath/screens/tracker_screen.dart';
import 'package:gympath/services/ble_service.dart';

void main() {
  test('themes and number styles match the firmware (0..3)', () {
    expect(trackerThemes.map((t) => t.id), [0, 1, 2, 3]);
    expect(trackerDigitStyles.map((d) => d.id), [0, 1, 2, 3]);
  });

  test('every theme × number style has its preview picture', () {
    for (final t in trackerThemes) {
      for (final d in trackerDigitStyles) {
        for (final path in [
          trackerPage(t.id, d.id),
          'assets/tracker/count_${t.id}_${d.id}.png',
          'assets/tracker/bg_${t.id}.png',
        ]) {
          expect(File(path).existsSync(), isTrue, reason: path);
        }
      }
    }
  });

  test('count windows: one per theme, inside the 240 px screen', () {
    expect(trackerCountWindows.length, trackerThemes.length);
    for (final w in trackerCountWindows) {
      expect(w[0] >= 0 && w[1] >= 0 && w[2] > 0 && w[3] > 0, isTrue);
      expect(w[0] + w[2] <= 240 && w[1] + w[3] <= 240, isTrue);
    }
  });

  test('settings packet: theme, plus the number style when known', () {
    expect(BleService.settingsPacket(2, null), [1, 2]);
    expect(BleService.settingsPacket(2, 3), [1, 2, 3]);
  });

  test('live preview packet: axis and page × 256, little endian', () {
    expect(BleService.previewPacket(0, 0), [2, 0, 0, 0]);
    expect(BleService.previewPacket(1, 2.5), [2, 1, 128, 2]);
    expect(BleService.previewPacket(0, 3), [2, 0, 0, 3]);
    expect(BleService.previewPacket(0, -0.2), [2, 0, 0, 0]); // overscroll
  });
}
