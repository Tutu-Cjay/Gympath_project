import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/workout_session.dart';

/// Aggregated, display-ready figures derived from the stored sessions.
class WorkoutStats {
  final int dayNumber; // days since first ever session (1-based)
  final int streakDays; // consecutive days up to today with ≥1 session
  final int todayReps;
  final int todaySessions;
  final int totalSessions;
  final int totalReps;
  final int totalVolumePoints; // sum of points (reps + bonus)
  final int weekSessions; // sessions in the last 7 days
  final double avgAccuracy;

  const WorkoutStats({
    required this.dayNumber,
    required this.streakDays,
    required this.todayReps,
    required this.todaySessions,
    required this.totalSessions,
    required this.totalReps,
    required this.totalVolumePoints,
    required this.weekSessions,
    required this.avgAccuracy,
  });

  static const empty = WorkoutStats(
    dayNumber: 1,
    streakDays: 0,
    todayReps: 0,
    todaySessions: 0,
    totalSessions: 0,
    totalReps: 0,
    totalVolumePoints: 0,
    weekSessions: 0,
    avgAccuracy: 0,
  );
}

/// Local-first persistence for completed workouts. The dashboard listens to
/// [stats]; calling [addSession] recomputes and notifies. The backend (Step 3)
/// will sync this same session list, so nothing here is throwaway.
class WorkoutStore {
  WorkoutStore._();
  static final WorkoutStore instance = WorkoutStore._();

  static const String _key = 'gympath_sessions_v1';

  final List<WorkoutSession> _sessions = [];
  SharedPreferences? _prefs;

  /// Daily rep goal used by the dashboard's "today's workout" ring.
  static const int dailyRepGoal = 60;

  final ValueNotifier<WorkoutStats> stats =
      ValueNotifier<WorkoutStats>(WorkoutStats.empty);

  List<WorkoutSession> get sessions => List.unmodifiable(_sessions);

  Future<void> load() async {
    _prefs = await SharedPreferences.getInstance();
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

    final todaySessions = _sessions.where((s) => _dayOf(s.timestamp) == today);
    final weekAgo = today.subtract(const Duration(days: 6));
    final weekSessions =
        _sessions.where((s) => !_dayOf(s.timestamp).isBefore(weekAgo)).length;

    final totalReps = _sessions.fold<int>(0, (a, s) => a + s.reps);
    final totalPoints = _sessions.fold<int>(0, (a, s) => a + s.points);
    final avgAcc = _sessions.fold<double>(0, (a, s) => a + s.accuracy) /
        _sessions.length;

    stats.value = WorkoutStats(
      dayNumber: dayNumber,
      streakDays: streak,
      todayReps: todaySessions.fold<int>(0, (a, s) => a + s.reps),
      todaySessions: todaySessions.length,
      totalSessions: _sessions.length,
      totalReps: totalReps,
      totalVolumePoints: totalPoints,
      weekSessions: weekSessions,
      avgAccuracy: avgAcc,
    );
  }

  /// Most recent sessions first, capped at [limit].
  List<WorkoutSession> recent([int limit = 10]) {
    final copy = [..._sessions]
      ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return copy.take(limit).toList();
  }
}
