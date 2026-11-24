import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gympath/services/device_day_sync.dart';

void main() {
  test('day summary packet matches the firmware DayPacket (23 B, LE)', () {
    final now = DateTime(2026, 11, 24, 10, 30);
    final p = DaySummary(
      now: now,
      reps: 128,
      sets: 12,
      volumeKg: 1834.6,
      activeMinutes: 24,
      repGoal: 60,
      weekStreak: 3,
      daysThisWeek: 2,
      weekGoal: 3,
      week: const [true, true, false, false, false, false, false],
      musclesActive: 8,
      musclesTotal: 13,
    ).encode();
    expect(p.length, 23);
    final b = ByteData.sublistView(p);
    expect(b.getUint8(0), 1);
    final local = b.getUint32(1, Endian.little);
    // the tracker shows the phone's wall clock: 10:30 on that day
    expect(local ~/ 3600 % 24, 10);
    expect(local ~/ 60 % 60, 30);
    expect((local ~/ 86400 + 3) % 7, 1); // 0 = Monday → a Tuesday
    expect(b.getUint16(5, Endian.little), 128);
    expect(b.getUint16(7, Endian.little), 12);
    expect(b.getUint32(9, Endian.little), 1835);
    expect(b.getUint16(13, Endian.little), 24);
    expect(b.getUint16(15, Endian.little), 60);
    expect(p[17], 3);
    expect(p[18], 2);
    expect(p[19], 3);
    expect(p[20], 0x03); // Monday and Tuesday
    expect(p[21], 8);
    expect(p[22], 13);
  });

  test('values beyond a field are clamped', () {
    final p = DaySummary(
      now: DateTime(2026, 1, 1),
      reps: 70000, sets: -1, volumeKg: 0, activeMinutes: 0, repGoal: 60,
      weekStreak: 300, daysThisWeek: 0, weekGoal: 3, week: const [],
      musclesActive: 0, musclesTotal: 13,
    ).encode();
    final b = ByteData.sublistView(p);
    expect(b.getUint16(5, Endian.little), 65535);
    expect(b.getUint16(7, Endian.little), 0);
    expect(p[17], 255);
  });
}
