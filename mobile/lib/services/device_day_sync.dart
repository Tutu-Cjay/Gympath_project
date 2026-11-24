import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../models/training_stats.dart';
import 'ble_service.dart';
import 'workout_store.dart';

/// Today's numbers for the tracker's idle screen (firmware 1.2+).
class DaySummary {
  final DateTime now; // phone local time
  final int reps;
  final int sets;
  final double volumeKg;
  final int activeMinutes;
  final int repGoal;
  final int weekStreak;
  final int daysThisWeek;
  final int weekGoal;
  final List<bool> week; // Monday … Sunday trained
  final int musclesActive;
  final int musclesTotal;

  const DaySummary({
    required this.now,
    required this.reps,
    required this.sets,
    required this.volumeKg,
    required this.activeMinutes,
    required this.repGoal,
    required this.weekStreak,
    required this.daysThisWeek,
    required this.weekGoal,
    required this.week,
    required this.musclesActive,
    required this.musclesTotal,
  });

  factory DaySummary.of(TrainingStats t, WorkoutStats s, DateTime now) {
    final today = dayOf(now);
    final tomorrow = DateTime(today.year, today.month, today.day + 1);
    final sets = t.sets
        .where((x) => !x.timestamp.isBefore(today) && x.timestamp.isBefore(tomorrow));
    final seconds = sets.fold<int>(0, (a, x) => a + x.durationSec);
    final (active, total) = t.muscleCoverage(today, tomorrow);
    return DaySummary(
      now: now,
      reps: s.todayReps,
      sets: s.todaySets,
      volumeKg: s.todayVolumeKg,
      activeMinutes: (seconds / 60).round(),
      repGoal: WorkoutStore.dailyRepGoal,
      weekStreak: s.weekStreak.current,
      daysThisWeek: s.weekStreak.daysThisWeek,
      weekGoal: WorkoutStore.weekGoalDays,
      week: s.weekStreak.thisWeek,
      musclesActive: active,
      musclesTotal: total,
    );
  }

  /// The phone's local time as seconds since 1970 (UTC + its offset): the
  /// tracker has no time zone, it shows this clock as it is.
  static int localEpoch(DateTime now) =>
      (now.millisecondsSinceEpoch ~/ 1000) + now.timeZoneOffset.inSeconds;

  /// The 23-byte packet …cdefc takes (firmware DayPacket, little endian).
  Uint8List encode() {
    int u8(int v) => v.clamp(0, 255);
    int u16(int v) => v.clamp(0, 65535);
    final b = ByteData(23);
    b.setUint8(0, 1); // version
    b.setUint32(1, localEpoch(now), Endian.little);
    b.setUint16(5, u16(reps), Endian.little);
    b.setUint16(7, u16(sets), Endian.little);
    b.setUint32(9, volumeKg.round().clamp(0, 0xFFFFFFFF), Endian.little);
    b.setUint16(13, u16(activeMinutes), Endian.little);
    b.setUint16(15, u16(repGoal), Endian.little);
    b.setUint8(17, u8(weekStreak));
    b.setUint8(18, u8(daysThisWeek));
    b.setUint8(19, u8(weekGoal));
    var mask = 0;
    for (var i = 0; i < 7 && i < week.length; i++) {
      if (week[i]) mask |= 1 << i;
    }
    b.setUint8(20, mask);
    b.setUint8(21, u8(musclesActive));
    b.setUint8(22, u8(musclesTotal));
    return b.buffer.asUint8List();
  }
}

/// Keeps the tracker's idle screen current: sends today's numbers when it
/// connects and whenever a set is saved.
class DeviceDaySync {
  DeviceDaySync._();
  static final DeviceDaySync instance = DeviceDaySync._();

  final _ble = BleService.instance;
  Timer? _debounce;
  bool _started = false;

  void start() {
    if (_started) return;
    _started = true;
    _ble.daySummarySupported.addListener(_schedule);
    WorkoutStore.instance.stats.addListener(_schedule);
  }

  void _schedule() {
    if (!_ble.daySummarySupported.value) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 600), sendNow);
  }

  Future<bool> sendNow() async {
    if (!_ble.daySummarySupported.value) return false;
    final store = WorkoutStore.instance;
    final summary =
        DaySummary.of(store.training, store.stats.value, DateTime.now());
    final ok = await _ble.writeDaySummary(summary.encode());
    if (!ok) debugPrint('[BLE] day summary not sent');
    return ok;
  }
}
