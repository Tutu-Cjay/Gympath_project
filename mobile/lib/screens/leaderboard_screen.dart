import 'package:flutter/material.dart';

import '../models/training_stats.dart';
import '../services/api_service.dart';
import '../services/workout_store.dart';
import '../theme/app_theme.dart';

const _fire = Color(0xFFFF8A3D);

/// Week streaks: your own, and how you rank against the others on the
/// Gympath server (week streak, days this week, or total reps).
class LeaderboardScreen extends StatefulWidget {
  const LeaderboardScreen({super.key});

  @override
  State<LeaderboardScreen> createState() => _LeaderboardScreenState();
}

class _LeaderboardScreenState extends State<LeaderboardScreen> {
  final _api = ApiService.instance;
  LeaderboardSort _sort = LeaderboardSort.weekStreak;
  Future<List<LeaderboardEntry>>? _rows;

  @override
  void initState() {
    super.initState();
    if (_api.account.value != null) _load();
  }

  /// Send the latest sets, then fetch the ranking.
  void _load() {
    setState(() {
      _rows = () async {
        await _api.sync(WorkoutStore.instance.sessions);
        return _api.leaderboard(_sort);
      }();
    });
  }

  Future<void> _signIn() async {
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppTheme.cardBg,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      builder: (_) => const _AccountSheet(),
    );
    if (ok == true && mounted) _load();
  }

  Future<void> _signOut() async {
    await _api.signOut();
    if (mounted) setState(() => _rows = null);
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ApiAccount?>(
      valueListenable: _api.account,
      builder: (context, account, _) => Scaffold(
        backgroundColor: AppTheme.darkBg,
        appBar: AppBar(
          title: const Text('Leaderboard'),
          actions: [
            if (account != null)
              PopupMenuButton<String>(
                color: AppTheme.cardBg,
                onSelected: (_) => _signOut(),
                itemBuilder: (_) => [
                  PopupMenuItem(
                      value: 'out',
                      child: Text('Sign out (${account.name})')),
                ],
              ),
          ],
        ),
        body: RefreshIndicator(
          color: AppTheme.neonGreen,
          onRefresh: () async {
            if (account == null) return;
            _load();
            await _rows?.catchError((_) => <LeaderboardEntry>[]);
          },
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
            children: [
              ValueListenableBuilder<WorkoutStats>(
                valueListenable: WorkoutStore.instance.stats,
                builder: (context, s, _) => _MyStreak(streak: s.weekStreak),
              ),
              const SizedBox(height: 18),
              if (account == null)
                _JoinCard(onJoin: _signIn)
              else ...[
                Wrap(spacing: 8, children: [
                  for (final (sort, label) in [
                    (LeaderboardSort.weekStreak, 'Week streak'),
                    (LeaderboardSort.week, 'This week'),
                    (LeaderboardSort.reps, 'Total reps'),
                  ])
                    ChoiceChip(
                      label: Text(label),
                      selected: _sort == sort,
                      onSelected: (_) {
                        _sort = sort;
                        _load();
                      },
                    ),
                ]),
                const SizedBox(height: 12),
                FutureBuilder<List<LeaderboardEntry>>(
                  future: _rows,
                  builder: (context, snap) {
                    if (snap.connectionState != ConnectionState.done) {
                      return const Padding(
                        padding: EdgeInsets.all(40),
                        child: Center(
                            child: CircularProgressIndicator(
                                color: AppTheme.neonGreen)),
                      );
                    }
                    if (snap.hasError) {
                      return _ErrorCard(
                          message: '${snap.error}', onRetry: _load);
                    }
                    final rows = snap.data ?? const [];
                    return Column(children: [
                      for (final r in rows) _Row(entry: r, sort: _sort),
                      const SizedBox(height: 8),
                      Text(
                          'A week counts when you train on at least '
                          '${WorkoutStore.weekGoalDays} days (Monday to Sunday). '
                          'Simulated sets are not sent.',
                          style: const TextStyle(
                              color: AppTheme.textMuted, fontSize: 11)),
                    ]);
                  },
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Your week streak and this week's days, from the sets on the phone.
class _MyStreak extends StatelessWidget {
  final WeekStreak streak;
  const _MyStreak({required this.streak});

  @override
  Widget build(BuildContext context) {
    const goal = WorkoutStore.weekGoalDays;
    final left = goal - streak.daysThisWeek;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppTheme.cardBg,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _fire.withValues(alpha: .5)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.local_fire_department_rounded, color: _fire, size: 44),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(
                  '${streak.current} week${streak.current == 1 ? '' : 's'} streak',
                  style: const TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: 24,
                      fontWeight: FontWeight.w800)),
              Text('Best: ${streak.best} week${streak.best == 1 ? '' : 's'}',
                  style: const TextStyle(
                      color: AppTheme.textSecondary, fontSize: 12)),
            ]),
          ),
        ]),
        const SizedBox(height: 14),
        WeekDots(days: streak.thisWeek),
        const SizedBox(height: 10),
        Text(
            left > 0
                ? '${streak.daysThisWeek}/$goal days this week · $left more to '
                    '${streak.current > 0 ? 'keep' : 'start'} the streak'
                : '${streak.daysThisWeek}/$goal days this week · this week counts',
            style: TextStyle(
                color: left > 0 ? AppTheme.textSecondary : AppTheme.neonGreen,
                fontSize: 12,
                fontWeight: FontWeight.w600)),
      ]),
    );
  }
}

/// Monday to Sunday: filled for the days with training.
class WeekDots extends StatelessWidget {
  final List<bool> days;
  const WeekDots({super.key, required this.days});

  @override
  Widget build(BuildContext context) {
    final today = DateTime.now().weekday - 1;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        for (var i = 0; i < 7; i++)
          Column(children: [
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: days[i] ? _fire : AppTheme.cardBgLight,
                border: i == today
                    ? Border.all(color: AppTheme.textPrimary, width: 1.5)
                    : null,
              ),
              child: days[i]
                  ? const Icon(Icons.check_rounded, size: 18, color: Colors.black)
                  : null,
            ),
            const SizedBox(height: 4),
            Text(const ['M', 'T', 'W', 'T', 'F', 'S', 'S'][i],
                style: TextStyle(
                    color: i == today ? AppTheme.textPrimary : AppTheme.textMuted,
                    fontSize: 10,
                    fontWeight: FontWeight.w700)),
          ]),
      ],
    );
  }
}

class _Row extends StatelessWidget {
  final LeaderboardEntry entry;
  final LeaderboardSort sort;
  const _Row({required this.entry, required this.sort});

  @override
  Widget build(BuildContext context) {
    final e = entry;
    final (value, unit) = switch (sort) {
      LeaderboardSort.weekStreak => ('${e.weekStreak}', e.weekStreak == 1 ? 'week' : 'weeks'),
      LeaderboardSort.week => ('${e.daysThisWeek}', e.daysThisWeek == 1 ? 'day' : 'days'),
      LeaderboardSort.reps => ('${e.totalReps}', 'reps'),
    };
    const medals = [Color(0xFFFFD54F), Color(0xFFCFD8DC), Color(0xFFD7A26B)];
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 10, 14, 10),
      decoration: BoxDecoration(
        color: e.isMe ? AppTheme.neonGreen.withValues(alpha: .10) : AppTheme.cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
            color: e.isMe ? AppTheme.neonGreen : AppTheme.cardBgLight),
      ),
      child: Row(children: [
        SizedBox(
          width: 34,
          child: e.rank <= 3
              ? Icon(Icons.emoji_events_rounded, color: medals[e.rank - 1], size: 22)
              : Text('#${e.rank}',
                  style: const TextStyle(
                      color: AppTheme.textSecondary,
                      fontSize: 13,
                      fontWeight: FontWeight.w700)),
        ),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(e.isMe ? '${e.name} (you)' : e.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w600)),
            Text(
                'This week ${e.daysThisWeek}/${e.weekGoalDays} · best ${e.bestWeekStreak} wk',
                style: const TextStyle(color: AppTheme.textSecondary, fontSize: 11)),
          ]),
        ),
        if (sort == LeaderboardSort.weekStreak)
          const Icon(Icons.local_fire_department_rounded, color: _fire, size: 18),
        const SizedBox(width: 4),
        Text(value,
            style: const TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.w800)),
        const SizedBox(width: 4),
        Text(unit,
            style: const TextStyle(color: AppTheme.textSecondary, fontSize: 11)),
      ]),
    );
  }
}

class _JoinCard extends StatelessWidget {
  final VoidCallback onJoin;
  const _JoinCard({required this.onJoin});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.cardBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.cardBgLight),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Row(children: [
          Icon(Icons.emoji_events_rounded, color: AppTheme.neonGreen),
          SizedBox(width: 10),
          Text('Compete on week streaks',
              style: TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.bold)),
        ]),
        const SizedBox(height: 8),
        const Text(
            'Sign in to the Gympath server to see how your week streak ranks '
            'against the others. Your sets are sent there; simulated ones are '
            'not.',
            style: TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: onJoin,
            style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.neonGreen,
                foregroundColor: Colors.black),
            child: const Text('Sign in or create an account'),
          ),
        ),
      ]),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorCard({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppTheme.cardBg,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFFFF6B6B)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(message,
              style: const TextStyle(color: AppTheme.textPrimary, fontSize: 13)),
          TextButton(onPressed: onRetry, child: const Text('Try again')),
        ]),
      );
}

/// Server address, then sign in or create an account.
class _AccountSheet extends StatefulWidget {
  const _AccountSheet();

  @override
  State<_AccountSheet> createState() => _AccountSheetState();
}

class _AccountSheetState extends State<_AccountSheet> {
  final _server = TextEditingController(text: 'http://192.168.');
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _create = true;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    for (final c in [_server, _name, _email, _password]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ApiService.instance.signIn(
        server: _server.text,
        email: _email.text,
        password: _password.text,
        name: _create ? _name.text : null,
      );
      if (mounted) Navigator.pop(context, true);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    InputDecoration deco(String label, {String? hint}) => InputDecoration(
          labelText: label,
          hintText: hint,
          filled: true,
          fillColor: AppTheme.darkBg,
          border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide.none),
        );
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_create ? 'Create an account' : 'Sign in',
                  style: const TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: 18,
                      fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              const Text(
                  'Server: the address the Gympath server shows (lan_hint), '
                  'e.g. http://192.168.1.20:8000',
                  style: TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
              const SizedBox(height: 14),
              TextField(
                  controller: _server,
                  keyboardType: TextInputType.url,
                  decoration: deco('Server address')),
              const SizedBox(height: 10),
              if (_create) ...[
                TextField(
                    controller: _name,
                    textCapitalization: TextCapitalization.words,
                    decoration: deco('Name on the leaderboard')),
                const SizedBox(height: 10),
              ],
              TextField(
                  controller: _email,
                  keyboardType: TextInputType.emailAddress,
                  decoration: deco('Email')),
              const SizedBox(height: 10),
              TextField(
                  controller: _password,
                  obscureText: true,
                  decoration: deco('Password', hint: _create ? '6 or more characters' : null)),
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(_error!,
                    style: const TextStyle(color: Color(0xFFFF6B6B), fontSize: 12)),
              ],
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: _busy ? null : _submit,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.neonGreen,
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                child: Text(_busy
                    ? 'Connecting…'
                    : _create
                        ? 'Create account'
                        : 'Sign in'),
              ),
              TextButton(
                onPressed: _busy ? null : () => setState(() => _create = !_create),
                child: Text(_create
                    ? 'I already have an account'
                    : 'Create a new account'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
