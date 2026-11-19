import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/workout_session.dart';

/// The signed-in account on the Gympath server.
class ApiAccount {
  final String server; // e.g. http://192.168.1.20:8000
  final String token;
  final String name;
  final String email;
  const ApiAccount(
      {required this.server,
      required this.token,
      required this.name,
      required this.email});

  Map<String, dynamic> toJson() =>
      {'server': server, 'token': token, 'name': name, 'email': email};

  static ApiAccount? fromJson(Map<String, dynamic> j) {
    final s = j['server'], t = j['token'];
    if (s is! String || t is! String || s.isEmpty || t.isEmpty) return null;
    return ApiAccount(
        server: s,
        token: t,
        name: (j['name'] ?? '') as String,
        email: (j['email'] ?? '') as String);
  }
}

/// One row of the leaderboard.
class LeaderboardEntry {
  final int rank;
  final String name;
  final bool isMe;
  final int weekStreak;
  final int bestWeekStreak;
  final int daysThisWeek;
  final int weekGoalDays;
  final int totalReps;
  final int weekReps;
  final double totalVolumeKg;
  final double weekVolumeKg;

  /// Muscle groups worked this week, of those the exercises can train.
  final int musclesActive;
  final int musclesTotal;
  final int musclesPct;

  const LeaderboardEntry({
    required this.rank,
    required this.name,
    required this.isMe,
    required this.weekStreak,
    required this.bestWeekStreak,
    required this.daysThisWeek,
    required this.weekGoalDays,
    required this.totalReps,
    this.weekReps = 0,
    this.totalVolumeKg = 0,
    this.weekVolumeKg = 0,
    this.musclesActive = 0,
    this.musclesTotal = 0,
    this.musclesPct = 0,
  });

  factory LeaderboardEntry.fromJson(Map<String, dynamic> j) {
    int n(String k) => (j[k] as num?)?.toInt() ?? 0;
    double d(String k) => (j[k] as num?)?.toDouble() ?? 0;
    return LeaderboardEntry(
      rank: n('rank'),
      name: (j['display_name'] ?? '') as String,
      isMe: j['is_me'] == true,
      weekStreak: n('week_streak'),
      bestWeekStreak: n('best_week_streak'),
      daysThisWeek: n('days_this_week'),
      weekGoalDays: j['week_goal_days'] is num ? n('week_goal_days') : 3,
      totalReps: n('total_reps'),
      weekReps: n('week_reps'),
      totalVolumeKg: d('total_volume_kg'),
      weekVolumeKg: d('week_volume_kg'),
      musclesActive: n('muscles_active'),
      musclesTotal: n('muscles_total'),
      musclesPct: n('muscles_pct'),
    );
  }
}

/// How the leaderboard is ranked (the server's `by`).
enum LeaderboardSort { weekStreak, week, muscles, volume, reps }

extension LeaderboardSortApi on LeaderboardSort {
  String get param => switch (this) {
        LeaderboardSort.weekStreak => 'week_streak',
        LeaderboardSort.week => 'week',
        LeaderboardSort.muscles => 'muscles',
        LeaderboardSort.volume => 'volume',
        LeaderboardSort.reps => 'reps',
      };

  /// Volume and reps can be ranked over this week or all time.
  bool get hasPeriod =>
      this == LeaderboardSort.volume || this == LeaderboardSort.reps;
}

class ApiException implements Exception {
  final String message;
  const ApiException(this.message);
  @override
  String toString() => message;
}

/// Talks to the Gympath server (backend/): account, set sync, leaderboard.
/// The phone stays the source of the sets; the server gets copies.
class ApiService {
  ApiService._();
  static final ApiService instance = ApiService._();

  static const String _key = 'gympath_account_v1';
  static const Duration _timeout = Duration(seconds: 12);

  final ValueNotifier<ApiAccount?> account = ValueNotifier<ApiAccount?>(null);

  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_key);
    if (raw == null) return;
    try {
      account.value = ApiAccount.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      account.value = null;
    }
  }

  /// "192.168.1.20:8000" -> "http://192.168.1.20:8000" (no trailing slash).
  static String normalizeServer(String s) {
    var v = s.trim();
    if (v.isEmpty) return v;
    if (!v.startsWith('http://') && !v.startsWith('https://')) v = 'http://$v';
    while (v.endsWith('/')) {
      v = v.substring(0, v.length - 1);
    }
    return v;
  }

  /// The app's id for a set, so the server stores each set once however
  /// often it is synced.
  static String clientId(WorkoutSession s) =>
      '${s.workoutId}-${s.setIndex}-${s.timestamp.millisecondsSinceEpoch}';

  /// What the server's /sessions/bulk takes for one set. Times are sent as
  /// the phone's local time (no offset), so days and weeks match the phone.
  static Map<String, dynamic> setJson(WorkoutSession s) => {
        'workout_name': s.workoutName,
        'reps': s.reps,
        'duration_sec': s.durationSec,
        'weight_kg': s.weightKg,
        'client_id': clientId(s),
        'client_timestamp': s.timestamp.toIso8601String(),
      };

  Future<ApiAccount> signIn({
    required String server,
    required String email,
    required String password,
    String? name, // given = create an account
  }) async {
    final base = normalizeServer(server);
    final register = name != null;
    final body = await _send('POST', base, register ? '/auth/register' : '/auth/login',
        body: {
          'email': email.trim(),
          'password': password,
          if (name != null) 'display_name': name.trim(),
        });
    final user = (body as Map<String, dynamic>)['user'] as Map<String, dynamic>;
    final a = ApiAccount(
        server: base,
        token: body['access_token'] as String,
        name: (user['display_name'] ?? '') as String,
        email: (user['email'] ?? '') as String);
    await _save(a);
    return a;
  }

  Future<void> signOut() => _save(null);

  /// Upload the real (not simulated) sets. Already synced ones are skipped
  /// by the server.
  Future<void> sync(Iterable<WorkoutSession> sets) async {
    final a = _need();
    final list = sets.where((s) => !s.simulated && s.reps > 0).toList();
    for (var i = 0; i < list.length; i += 200) {
      final chunk = list.skip(i).take(200).map(setJson).toList();
      await _send('POST', a.server, '/sessions/bulk',
          token: a.token, body: {'sessions': chunk});
    }
  }

  Future<List<LeaderboardEntry>> leaderboard(LeaderboardSort by,
      {bool thisWeek = false}) async {
    final a = _need();
    final body = await _send('GET', a.server,
        '/leaderboard?by=${by.param}&period=${thisWeek ? 'week' : 'all'}',
        token: a.token);
    return (body as List)
        .whereType<Map<String, dynamic>>()
        .map(LeaderboardEntry.fromJson)
        .toList();
  }

  ApiAccount _need() {
    final a = account.value;
    if (a == null) throw const ApiException('Not signed in');
    return a;
  }

  Future<Object?> _send(String method, String base, String path,
      {String? token, Object? body}) async {
    final uri = Uri.tryParse('$base$path');
    if (uri == null || uri.host.isEmpty) {
      throw const ApiException('Check the server address');
    }
    final headers = {
      'Content-Type': 'application/json',
      if (token != null) 'Authorization': 'Bearer $token',
    };
    http.Response r;
    try {
      r = method == 'GET'
          ? await http.get(uri, headers: headers).timeout(_timeout)
          : await http
              .post(uri, headers: headers, body: jsonEncode(body))
              .timeout(_timeout);
    } on TimeoutException {
      throw const ApiException(
          'The server did not answer. Is it running, and on the same Wi-Fi?');
    } catch (_) {
      throw const ApiException(
          'Could not reach the server. Check the address and the Wi-Fi.');
    }
    Object? data;
    try {
      data = r.body.isEmpty ? null : jsonDecode(utf8.decode(r.bodyBytes));
    } catch (_) {
      data = null;
    }
    if (r.statusCode == 401 && token != null) {
      await _save(null);
      throw const ApiException('Signed out by the server. Please sign in again.');
    }
    if (r.statusCode >= 400) {
      throw ApiException(errorMessage(r.statusCode, data));
    }
    return data;
  }

  /// A readable message from an error response (FastAPI: "detail" is a
  /// string, or a list of field errors for 422).
  static String errorMessage(int status, Object? data) {
    final detail = data is Map ? data['detail'] : null;
    if (detail is String) return detail;
    if (detail is List && detail.isNotEmpty && detail.first is Map) {
      final e = detail.first as Map;
      final loc = e['loc'];
      final field = loc is List && loc.isNotEmpty ? '${loc.last}' : '';
      var msg = '${e['msg'] ?? ''}';
      if (field == 'password' && msg.contains('at least')) {
        msg = 'needs 6 or more characters';
      }
      final name = switch (field) {
        'email' => 'Email',
        'password' => 'Password',
        'display_name' => 'Name',
        _ => field,
      };
      return name.isEmpty ? msg : '$name: $msg';
    }
    return 'Server error $status';
  }

  Future<void> _save(ApiAccount? a) async {
    account.value = a;
    final p = await SharedPreferences.getInstance();
    if (a == null) {
      await p.remove(_key);
    } else {
      await p.setString(_key, jsonEncode(a.toJson()));
    }
  }
}
