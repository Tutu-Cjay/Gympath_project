import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../utils/responsive.dart';
import '../widgets/bottom_nav_bar.dart';
import '../widgets/ble_status_chip.dart';
import '../services/routine_store.dart';
import '../services/workout_store.dart';
import 'leaderboard_screen.dart';
import 'plan_screen.dart';
import 'tracker_screen.dart';
import 'choose_workout_screen.dart';
import 'anatomy_studio_screen.dart';
import 'avatar_screen.dart';
import 'progress_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _currentIndex = 0;

  // Kept alive between tab switches.
  final List<Widget> _screens = const [
    _HomeTab(),
    _WorkoutsTab(),
    ProgressScreen(),
  ];

  static const int _guideTab = 3;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.darkBg,
      // The 3D guide is built only while its tab is open, so the model does
      // not load at start-up or keep animating in the background.
      body: _currentIndex == _guideTab
          ? const AnatomyStudioScreen(embedded: true)
          : IndexedStack(
              index: _currentIndex,
              children: _screens,
            ),
      bottomNavigationBar: GympathBottomNav(
        currentIndex: _currentIndex,
        onTap: (index) => setState(() => _currentIndex = index),
      ),
    );
  }
}

class _HomeTab extends StatelessWidget {
  const _HomeTab();

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ValueListenableBuilder<WorkoutStats>(
        valueListenable: WorkoutStore.instance.stats,
        builder: (context, stats, _) {
          final todayDone = stats.todaySets > 0;
          final goal = WorkoutStore.dailyRepGoal;
          final goalPct =
              (stats.todayReps / goal).clamp(0.0, 1.0).toDouble();
          return CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.all(Responsive.w(context, 20)),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            'Day ${stats.dayNumber}',
                            style: const TextStyle(
                              color: AppTheme.textPrimary,
                              fontSize: 24,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                tooltip: 'Your avatar',
                                icon: const Icon(Icons.face_retouching_natural_rounded),
                                color: AppTheme.neonGreen,
                                onPressed: () => Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => const AvatarScreen(),
                                  ),
                                ),
                              ),
                              IconButton(
                                tooltip: 'Tracker: screen, battery, updates',
                                icon: const Icon(Icons.watch_rounded),
                                color: AppTheme.textSecondary,
                                onPressed: () => Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => const TrackerScreen(),
                                  ),
                                ),
                              ),
                              const BleStatusChip(),
                            ],
                          ),
                        ],
                      ),
                      SizedBox(height: Responsive.h(context, 20)),
                      // Daily progress indicators — light up as today's
                      // numbers cross thresholds
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceAround,
                        children: [
                          _DailyIndicator(
                              icon: Icons.fitness_center_rounded,
                              checked: todayDone),
                          _DailyIndicator(
                              icon: Icons.local_fire_department_rounded,
                              checked: stats.streakDays > 0),
                          _DailyIndicator(
                              icon: Icons.layers_rounded,
                              checked: stats.todaySets >= 3),
                          _DailyIndicator(
                              icon: Icons.check_circle_rounded,
                              checked: goalPct >= 1.0),
                        ],
                      ),
                      SizedBox(height: Responsive.h(context, 24)),
                      // Week streak card (opens the leaderboard)
                      _WeekStreakCard(stats: stats),
                      SizedBox(height: Responsive.h(context, 20)),
                      // Today's workout progress
                      Container(
                        padding: EdgeInsets.all(Responsive.w(context, 20)),
                        decoration: BoxDecoration(
                          color: AppTheme.cardBg,
                          borderRadius:
                              BorderRadius.circular(Responsive.r(context, 16)),
                          border: Border.all(color: AppTheme.cardBgLight),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment:
                                  MainAxisAlignment.spaceBetween,
                              children: [
                                Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: [
                                    const Text(
                                      'Today\'s Reps',
                                      style: TextStyle(
                                        color: AppTheme.textSecondary,
                                        fontSize: 12,
                                      ),
                                    ),
                                    Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.baseline,
                                      textBaseline: TextBaseline.alphabetic,
                                      children: [
                                        Text(
                                          '${stats.todayReps}',
                                          style: const TextStyle(
                                            color: AppTheme.neonGreen,
                                            fontSize: 28,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                        SizedBox(
                                            width: Responsive.w(context, 8)),
                                        Text(
                                          '/ $goal',
                                          style: TextStyle(
                                            color: AppTheme.textSecondary
                                                .withValues(alpha: 0.7),
                                            fontSize: 18,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                                Icon(
                                  Icons.fitness_center_rounded,
                                  size: Responsive.r(context, 48),
                                  color: AppTheme.neonGreen
                                      .withValues(alpha: 0.5),
                                ),
                              ],
                            ),
                            SizedBox(height: Responsive.h(context, 12)),
                            ClipRRect(
                              borderRadius: BorderRadius.circular(999),
                              child: LinearProgressIndicator(
                                value: goalPct,
                                minHeight: Responsive.h(context, 8),
                                backgroundColor: AppTheme.cardBgLight,
                                valueColor: const AlwaysStoppedAnimation(
                                    AppTheme.neonGreen),
                              ),
                            ),
                          ],
                        ),
                      ),
                      SizedBox(height: Responsive.h(context, 20)),
                      const _PlanCard(),
                      SizedBox(height: Responsive.h(context, 12)),
                      // Add Workout button
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (context) =>
                                    const ChooseWorkoutScreen(showBack: true),
                              ),
                            );
                          },
                          icon: Icon(Icons.add_rounded,
                              size: Responsive.r(context, 20)),
                          label: const Text('Add Workout'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: AppTheme.neonGreen,
                            side: const BorderSide(color: AppTheme.neonGreen),
                            padding: EdgeInsets.symmetric(
                                vertical: Responsive.h(context, 16)),
                            shape: RoundedRectangleBorder(
                              borderRadius:
                                  BorderRadius.circular(Responsive.r(context, 14)),
                            ),
                          ),
                        ),
                      ),
                      SizedBox(height: Responsive.h(context, 24)),
                      // All-time stats
                      const Text(
                        'Your Stats',
                        style: TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      SizedBox(height: Responsive.h(context, 12)),
                      Row(
                        children: [
                          Expanded(
                            child: _StatCard(
                              value: '${stats.totalSets}',
                              label: 'Sets',
                            ),
                          ),
                          SizedBox(width: Responsive.w(context, 12)),
                          Expanded(
                            child: _StatCard(
                              value: '${stats.totalReps}',
                              label: 'Total Reps',
                            ),
                          ),
                          SizedBox(width: Responsive.w(context, 12)),
                          Expanded(
                            child: _StatCard(
                              value: formatVolume(stats.totalVolumeKg),
                              label: 'Volume lifted',
                            ),
                          ),
                        ],
                      ),
                      if (stats.totalSets == 0) ...[
                        SizedBox(height: Responsive.h(context, 20)),
                        _EmptyHint(),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Weeks in a row with enough training days, this week's days, and the way
/// to the leaderboard.
class _WeekStreakCard extends StatelessWidget {
  final WorkoutStats stats;
  const _WeekStreakCard({required this.stats});

  @override
  Widget build(BuildContext context) {
    final w = stats.weekStreak;
    const goal = WorkoutStore.weekGoalDays;
    const fire = Color(0xFFFF8A3D);
    final left = goal - w.daysThisWeek;
    return InkWell(
      borderRadius: BorderRadius.circular(Responsive.r(context, 16)),
      onTap: () => Navigator.push(context,
          MaterialPageRoute(builder: (_) => const LeaderboardScreen())),
      child: Container(
        padding: EdgeInsets.all(Responsive.w(context, 18)),
        decoration: BoxDecoration(
          color: AppTheme.cardBg,
          borderRadius: BorderRadius.circular(Responsive.r(context, 16)),
          border: Border.all(
              color: w.current > 0 ? fire.withValues(alpha: .6) : AppTheme.cardBgLight),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.local_fire_department_rounded,
                color: fire, size: Responsive.r(context, 40)),
            SizedBox(width: Responsive.w(context, 14)),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${w.current}-week streak',
                    style: const TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 22,
                        fontWeight: FontWeight.bold)),
                Text(
                    left > 0
                        ? '${w.daysThisWeek}/$goal days this week · $left to go'
                        : 'This week counts · ${w.daysThisWeek} days',
                    style: TextStyle(
                        color: left > 0 ? AppTheme.textSecondary : AppTheme.neonGreen,
                        fontSize: 13)),
              ]),
            ),
            const Column(children: [
              Icon(Icons.emoji_events_rounded, color: AppTheme.neonGreen, size: 20),
              Text('Ranks',
                  style: TextStyle(color: AppTheme.neonGreen, fontSize: 10)),
            ]),
          ]),
          SizedBox(height: Responsive.h(context, 12)),
          WeekDots(days: w.thisWeek),
        ]),
      ),
    );
  }
}

/// The plan's next day, or an invitation to pick a plan.
class _PlanCard extends StatelessWidget {
  const _PlanCard();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ActivePlan?>(
      valueListenable: RoutineStore.instance.plan,
      builder: (context, plan, _) {
        final String title, line;
        final IconData icon;
        if (plan == null) {
          title = 'Follow a plan';
          line = 'Ready-made cable plans with sets, rep targets and the next '
              'weight to use.';
          icon = Icons.event_note_rounded;
        } else {
          final multi = plan.routine.days.length > 1;
          final day = plan.day;
          final name = multi ? '${plan.routine.name} · ${day.name}' : plan.routine.name;
          if (plan.doneOn(DateTime.now())) {
            title = 'Done for today';
            line = 'Rest and recover. Next session: $name, '
                '${day.exercises.length} exercises.';
            icon = Icons.bedtime_rounded;
          } else {
            title = 'Next: $name';
            line = '${day.exercises.length} exercises · ${day.totalSets} sets · '
                '${day.exercises.map((e) => e.exercise).take(3).join(', ')}'
                '${day.exercises.length > 3 ? '…' : ''}';
            icon = Icons.play_circle_fill_rounded;
          }
        }
        return InkWell(
          borderRadius: BorderRadius.circular(Responsive.r(context, 16)),
          onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                  builder: (_) =>
                      plan == null ? const PlanScreen() : const PlanDayScreen())),
          child: Container(
            padding: EdgeInsets.all(Responsive.w(context, 16)),
            decoration: BoxDecoration(
              color: AppTheme.cardBg,
              borderRadius: BorderRadius.circular(Responsive.r(context, 16)),
              border: Border.all(
                  color: plan == null
                      ? AppTheme.cardBgLight
                      : AppTheme.neonGreen.withValues(alpha: .6)),
            ),
            child: Row(children: [
              Icon(icon, color: AppTheme.neonGreen, size: Responsive.r(context, 34)),
              SizedBox(width: Responsive.w(context, 14)),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  if (plan != null)
                    const Text('YOUR PLAN',
                        style: TextStyle(
                            color: AppTheme.textMuted,
                            fontSize: 10,
                            letterSpacing: 1.1,
                            fontWeight: FontWeight.w800)),
                  Text(title,
                      style: const TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: 16,
                          fontWeight: FontWeight.bold)),
                  const SizedBox(height: 2),
                  Text(line,
                      style: const TextStyle(
                          color: AppTheme.textSecondary, fontSize: 12)),
                ]),
              ),
              const Icon(Icons.chevron_right_rounded, color: AppTheme.textMuted),
            ]),
          ),
        );
      },
    );
  }
}

class _EmptyHint extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(Responsive.w(context, 16)),
      decoration: BoxDecoration(
        color: AppTheme.neonGreen.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(Responsive.r(context, 12)),
        border: Border.all(color: AppTheme.neonGreen.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(Icons.tips_and_updates_rounded,
              color: AppTheme.neonGreen, size: Responsive.r(context, 22)),
          SizedBox(width: Responsive.w(context, 12)),
          const Expanded(
            child: Text(
              'No sets yet. Tap "Add Workout", or try it without the tracker with Simulate.',
              style: TextStyle(color: AppTheme.textSecondary, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}

class _DailyIndicator extends StatelessWidget {
  final IconData icon;
  final bool checked;

  const _DailyIndicator({required this.icon, required this.checked});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: Responsive.r(context, 48),
      height: Responsive.r(context, 48),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: checked
            ? AppTheme.neonGreen.withValues(alpha:0.2)
            : AppTheme.cardBg,
        border: Border.all(
          color: checked ? AppTheme.neonGreen : AppTheme.cardBgLight,
        ),
      ),
      child: Icon(
        icon,
        color: checked ? AppTheme.neonGreen : AppTheme.textMuted,
        size: Responsive.r(context, 24),
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  final String value;
  final String label;

  const _StatCard({required this.value, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(Responsive.w(context, 16)),
      decoration: BoxDecoration(
        color: AppTheme.cardBg,
        borderRadius: BorderRadius.circular(Responsive.r(context, 12)),
        border: Border.all(color: AppTheme.cardBgLight),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            style: const TextStyle(
              color: AppTheme.textPrimary,
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
          Text(
            label,
            style: const TextStyle(
              color: AppTheme.textSecondary,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}

class _WorkoutsTab extends StatelessWidget {
  const _WorkoutsTab();

  @override
  Widget build(BuildContext context) {
    return const ChooseWorkoutScreen(showBack: false);
  }
}
