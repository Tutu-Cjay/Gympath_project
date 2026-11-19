import 'package:flutter_test/flutter_test.dart';
import 'package:gympath/models/training_stats.dart';
import 'package:gympath/models/workout_session.dart';
import 'package:gympath/services/api_service.dart';

void main() {
  final mon = DateTime(2026, 11, 16); // a Monday
  List<DateTime> days(List<int> offsets) =>
      [for (final o in offsets) DateTime(mon.year, mon.month, mon.day + o, 18)];

  group('week streak (3 days a week)', () {
    test('the week in progress does not break the streak', () {
      final w = WeekStreak.of(days([-14, -12, -10, -7, -5, -3, 1]),
          DateTime(2026, 11, 19, 9), 3);
      expect(w.current, 2);
      expect(w.best, 2);
      expect(w.daysThisWeek, 1);
      expect(w.thisWeek, [false, true, false, false, false, false, false]);
    });

    test('this week counts once it reaches the goal', () {
      final w = WeekStreak.of(
          days([-7, -5, -3, 0, 1, 2, 2]), DateTime(2026, 11, 19), 3);
      expect(w.current, 2);
      expect(w.daysThisWeek, 3); // two sets on one day are one day
    });

    test('a short week breaks it; the best run stays', () {
      final w = WeekStreak.of(
          days([-28, -27, -26, -21, -20, -19, -7, -6, -5]), mon, 3);
      expect(w.current, 1);
      expect(w.best, 2);
      final none = WeekStreak.of(const [], mon, 3);
      expect(none.current, 0);
      expect(none.best, 0);
    });

    test('matches the server rule (backend services.week_streak)', () {
      // Same cases as backend/test_api.py.
      expect(WeekStreak.of(days([-14, -12, -10, -7, -5, -3, 1]), DateTime(2026, 11, 19), 3).current, 2);
      expect(WeekStreak.of(days([-7, -5, -3, 0, 1, 2]), DateTime(2026, 11, 19), 3).current, 2);
    });
  });

  group('server', () {
    final set = WorkoutSession(
      workoutName: 'Lat Pulldown',
      reps: 10,
      weightKg: 42.5,
      workoutId: '1763280000000',
      setIndex: 2,
      durationSec: 40,
      timestamp: DateTime(2026, 11, 16, 18, 30),
    );

    test('a set as the server takes it', () {
      final j = ApiService.setJson(set);
      expect(j['workout_name'], 'Lat Pulldown');
      expect(j['weight_kg'], 42.5);
      expect(j['client_timestamp'], '2026-11-16T18:30:00.000'); // local, no offset
      expect(j['client_id'], ApiService.clientId(set));
      expect(ApiService.clientId(set), isNot(ApiService.clientId(
          WorkoutSession(workoutName: 'Lat Pulldown', reps: 10, workoutId: '1763280000000',
              setIndex: 3, durationSec: 40, timestamp: set.timestamp))));
      expect((j['client_id'] as String).length, lessThanOrEqualTo(80));
    });

    test('server address', () {
      expect(ApiService.normalizeServer(' 192.168.1.20:8000/ '), 'http://192.168.1.20:8000');
      expect(ApiService.normalizeServer('https://gym.example.com'), 'https://gym.example.com');
    });

    test('account and leaderboard rows', () {
      const a = ApiAccount(server: 'http://x:8000', token: 't', name: 'Tuvshin', email: 'a@b.c');
      final back = ApiAccount.fromJson(a.toJson())!;
      expect(back.name, 'Tuvshin');
      expect(ApiAccount.fromJson({'server': '', 'token': 't'}), isNull);
      final e = LeaderboardEntry.fromJson({
        'rank': 1, 'display_name': 'Bat', 'points': 30, 'total_reps': 30,
        'is_me': false, 'week_streak': 2, 'best_week_streak': 4,
        'days_this_week': 1, 'week_goal_days': 3,
      });
      expect(e.weekStreak, 2);
      expect(e.bestWeekStreak, 4);
      expect(e.isMe, isFalse);
      // An older server without the streak fields.
      final old = LeaderboardEntry.fromJson(
          {'rank': 2, 'display_name': 'Sasha', 'points': 60, 'total_reps': 60, 'is_me': true});
      expect(old.weekStreak, 0);
      expect(old.weekGoalDays, 3);
      expect(LeaderboardSort.weekStreak.param, 'week_streak');
    });
  });
}
