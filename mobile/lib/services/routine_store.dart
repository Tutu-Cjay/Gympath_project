import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/routine.dart';

/// The plan the user follows and which of its days comes next.
class ActivePlan {
  final Routine routine;
  final int nextDay; // index into routine.days
  final int daysDone;

  /// When the last plan day was finished.
  final DateTime? lastDone;

  const ActivePlan(this.routine,
      {this.nextDay = 0, this.daysDone = 0, this.lastDone});

  RoutineDay get day => routine.days[nextDay];

  bool doneOn(DateTime now) =>
      lastDone != null &&
      lastDone!.year == now.year &&
      lastDone!.month == now.month &&
      lastDone!.day == now.day;

  Map<String, dynamic> toJson() => {
        'routine': routine.id,
        'nextDay': nextDay,
        'daysDone': daysDone,
        if (lastDone != null) 'lastDone': lastDone!.toIso8601String(),
      };

  static ActivePlan? fromJson(Map<String, dynamic> j) {
    final r = routineById((j['routine'] ?? '') as String);
    if (r == null) return null;
    final n = j['nextDay'];
    final d = j['daysDone'];
    return ActivePlan(r,
        nextDay: n is int && n >= 0 && n < r.days.length ? n : 0,
        daysDone: d is int && d >= 0 ? d : 0,
        lastDone: DateTime.tryParse((j['lastDone'] ?? '') as String));
  }
}

/// Kept on the phone, like the sets.
class RoutineStore {
  RoutineStore._();
  static final RoutineStore instance = RoutineStore._();

  static const String _key = 'gympath_plan_v1';

  /// Null when no plan is chosen.
  final ValueNotifier<ActivePlan?> plan = ValueNotifier<ActivePlan?>(null);
  SharedPreferences? _prefs;

  Future<void> load() async {
    _prefs = await SharedPreferences.getInstance();
    final raw = _prefs!.getString(_key);
    if (raw == null) return;
    try {
      plan.value = ActivePlan.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      plan.value = null;
    }
  }

  Future<void> choose(Routine r) => _set(ActivePlan(r));

  Future<void> stop() => _set(null);

  /// Do another day of the plan next (the user's call: "move a session").
  Future<void> pickDay(int index) async {
    final p = plan.value;
    if (p == null || index < 0 || index >= p.routine.days.length) return;
    await _set(ActivePlan(p.routine,
        nextDay: index, daysDone: p.daysDone, lastDone: p.lastDone));
  }

  /// The next day is done: move on to the one after it.
  Future<void> finishDay() async {
    final p = plan.value;
    if (p == null) return;
    await _set(ActivePlan(p.routine,
        nextDay: (p.nextDay + 1) % p.routine.days.length,
        daysDone: p.daysDone + 1,
        lastDone: DateTime.now()));
  }

  Future<void> _set(ActivePlan? p) async {
    plan.value = p;
    _prefs ??= await SharedPreferences.getInstance();
    if (p == null) {
      await _prefs!.remove(_key);
    } else {
      await _prefs!.setString(_key, jsonEncode(p.toJson()));
    }
  }
}
