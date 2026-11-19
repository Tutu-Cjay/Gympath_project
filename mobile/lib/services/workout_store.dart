import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/training_stats.dart';
import '../models/workout_session.dart';

/// Aggregated, display-ready figures derived from the stored sets.
class WorkoutStats {
  final int dayNumber; // days since the first ever set (1-based)
  final int streakDays; // consecutive days up to today with at least one set
  final int todayReps;
  final int todaySets;
  final double todayVolumeKg;
  final int totalWorkouts; // distinct workouts (one exercise visit each)
  final int totalSets;
  final int totalReps;
  final double totalVolumeKg;
  final int weekDays; // days trained in the last 7 days
  final WeekStreak weekStreak;

  const WorkoutStats({
    required this.dayNumber,
    required this.streakDays,
    required this.todayReps,
    required this.todaySets,
    required this.todayVolumeKg,
    required this.totalWorkouts,
    required this.totalSets,
    required this.totalReps,
    required this.totalVolumeKg,
    required this.weekDays,
    this.weekStreak = const WeekStreak(
        current: 0, best: 0, daysThisWeek: 0, thisWeek: [false, false, false, false, false, false, false]),
  });

  static const empty = WorkoutStats(
    dayNumber: 1,
    streakDays: 0,
    todayReps: 0,
    todaySets: 0,
    todayVolumeKg: 0,
    totalWorkouts: 0,
    totalSets: 0,
    totalReps: 0,
    totalVolumeKg: 0,
    weekDays: 0,
  );
}

/// Local-first persistence for completed sets. Screens listen to [stats];
/// every change recomputes and notifies. The backend will sync this same
/// list, so nothing here is throwaway.
class WorkoutStore {
  WorkoutStore._();
  static final WorkoutStore instance = WorkoutStore._();

  static const String _key = 'gympath_sessions_v1';
  static const String _saveSimKey = 'gympath_save_simulated';

  /// Whether sets done in simulation mode go into the history (they are then
  /// marked as simulated). Off by default; remembered.
  final ValueNotifier<bool> saveSimulated = ValueNotifier<bool>(false);

  Future<void> setSaveSimulated(bool on) async {
    saveSimulated.value = on;
    _prefs ??= await SharedPreferences.getInstance();
    await _prefs!.setBool(_saveSimKey, on);
  }

  int get simulatedCount => _sessions.where((s) => s.simulated).length;

  /// Remove every set recorded in simulation mode.
  Future<void> removeSimulated() async {
    _sessions.removeWhere((s) => s.simulated);
    _recompute();
    await _persist();
  }

  final List<WorkoutSession> _sessions = [];
  SharedPreferences? _prefs;

  /// Daily rep goal used by the dashboard's "today's workout" ring.
  static const int dailyRepGoal = 60;

  /// A week counts towards the week streak with this many training days
  /// (same rule as the server's leaderboard, backend WEEK_GOAL_DAYS).
  static const int weekGoalDays = 3;

  final ValueNotifier<WorkoutStats> stats =
      ValueNotifier<WorkoutStats>(WorkoutStats.empty);

  List<WorkoutSession> get sessions => List.unmodifiable(_sessions);

  Future<void> load() async {
    _prefs = await SharedPreferences.getInstance();
    saveSimulated.value = _prefs!.getBool(_saveSimKey) ?? false;
    final raw = _prefs!.getString(_key);
    _sessions.clear();
    if (raw != null && raw.isNotEmpty) {
      try {
        final list = jsonDecode(raw) as List<dynamic>;
        _sessions.addAll(list
            .map((e) => WorkoutSession.fromJson(e as Map<String, dynamic>)));
      } catch (_) {
        // corrupt store — start fresh rather than crash
      }
    }
    _recompute();
  }

  Future<void> addSession(WorkoutSession session) async {
    _sessions.add(session);
    _recompute();
    await _persist();
  }

  /// Remove one set (e.g. one saved by mistake).
  Future<void> removeSession(WorkoutSession session) async {
    _sessions.remove(session);
    _recompute();
    await _persist();
  }

  /// Put a set back, e.g. after an undo.
  Future<void> restoreSession(WorkoutSession session) => addSession(session);

  /// Replace a saved set with an edited copy (e.g. with RIR added).
  Future<void> replaceSession(WorkoutSession old, WorkoutSession updated) async {
    final i = _sessions.indexOf(old);
    if (i < 0) return;
    _sessions[i] = updated;
    _recompute();
    await _persist();
  }

  /// Read-only analysis of everything saved.
  TrainingStats get training => TrainingStats(_sessions);

  Future<void> clear() async {
    _sessions.clear();
    _recompute();
    await _persist();
  }

  Future<void> _persist() async {
    _prefs ??= await SharedPreferences.getInstance();
    final raw = jsonEncode(_sessions.map((e) => e.toJson()).toList());
    await _prefs!.setString(_key, raw);
  }

  static DateTime _dayOf(DateTime t) => DateTime(t.year, t.month, t.day);

  void _recompute() {
    if (_sessions.isEmpty) {
      stats.value = WorkoutStats.empty;
      return;
    }
    final now = DateTime.now();
    final today = _dayOf(now);

    final daysWithSession = _sessions.map((s) => _dayOf(s.timestamp)).toSet();

    // current streak: walk back day-by-day while a session exists
    int streak = 0;
    var cursor = today;
    if (daysWithSession.contains(today)) {
      while (daysWithSession.contains(cursor)) {
        streak++;
        cursor = cursor.subtract(const Duration(days: 1));
      }
    } else {
      // grace: if they worked out yesterday the streak still stands today
      final yest = today.subtract(const Duration(days: 1));
      cursor = yest;
      while (daysWithSession.contains(cursor)) {
        streak++;
        cursor = cursor.subtract(const Duration(days: 1));
      }
    }

    final first = _sessions
        .map((s) => _dayOf(s.timestamp))
        .reduce((a, b) => a.isBefore(b) ? a : b);
    final dayNumber = today.difference(first).inDays + 1;

    final todaySets =
        _sessions.where((s) => _dayOf(s.timestamp) == today).toList();
    final weekAgo = today.subtract(const Duration(days: 6));
    final weekDays =
        daysWithSession.where((d) => !d.isBefore(weekAgo)).length;

    stats.value = WorkoutStats(
      dayNumber: dayNumber,
      streakDays: streak,
      todayReps: todaySets.fold<int>(0, (a, s) => a + s.reps),
      todaySets: todaySets.length,
      todayVolumeKg: todaySets.fold<double>(0, (a, s) => a + s.volumeKg),
      totalWorkouts: _sessions.map((s) => s.workoutId).toSet().length,
      totalSets: _sessions.length,
      totalReps: _sessions.fold<int>(0, (a, s) => a + s.reps),
      totalVolumeKg: _sessions.fold<double>(0, (a, s) => a + s.volumeKg),
      weekDays: weekDays,
      weekStreak: WeekStreak.of(daysWithSession, now, weekGoalDays),
    );
  }

  /// Most recent sessions first, capped at [limit].
  List<WorkoutSession> recent([int limit = 10]) {
    final copy = [..._sessions]
      ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return copy.take(limit).toList();
  }
}
