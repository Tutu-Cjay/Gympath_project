import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../utils/responsive.dart';
import '../widgets/bottom_nav_bar.dart';
import '../widgets/ble_status_chip.dart';
import '../services/workout_store.dart';
import 'choose_workout_screen.dart';
import 'firmware_update_screen.dart';
import 'gym_monitoring_screen.dart';
import 'leaderboard_screen.dart';
import 'meal_plan_screen.dart';
import 'anatomy_studio_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _currentIndex = 0;

  final List<Widget> _screens = const [
    _HomeTab(),
    _WorkoutsTab(),
    _NutritionTab(),
    _CoachTab(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.darkBg,
      body: IndexedStack(
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
          final todayDone = stats.todaySessions > 0;
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
                                tooltip: '3D muscle guide',
                                icon: const Icon(Icons.accessibility_new_rounded),
                                color: AppTheme.neonGreen,
                                onPressed: () => Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => const AnatomyStudioScreen(),
                                  ),
                                ),
                              ),
                              IconButton(
                                tooltip: 'Firmware update',
                                icon: const Icon(Icons.system_update_rounded),
                                color: AppTheme.textSecondary,
                                onPressed: () => Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) =>
                                        const FirmwareUpdateScreen(),
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
                              icon: Icons.speed_rounded,
                              checked: stats.avgAccuracy >= 90),
                          _DailyIndicator(
                              icon: Icons.check_circle_rounded,
                              checked: goalPct >= 1.0),
                        ],
                      ),
                      SizedBox(height: Responsive.h(context, 24)),
                      // Streak card
                      Container(
                        padding: EdgeInsets.all(Responsive.w(context, 20)),
                        decoration: BoxDecoration(
                          color: AppTheme.cardBg,
                          borderRadius:
                              BorderRadius.circular(Responsive.r(context, 16)),
                          border: Border.all(color: AppTheme.cardBgLight),
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.local_fire_department_rounded,
                                color: AppTheme.neonGreen,
                                size: Responsive.r(context, 40)),
                            SizedBox(width: Responsive.w(context, 16)),
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '${stats.streakDays} day streak',
                                  style: const TextStyle(
                                    color: AppTheme.textPrimary,
                                    fontSize: 22,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                Text(
                                  stats.streakDays > 0
                                      ? 'Keep it up!'
                                      : 'Start your first workout',
                                  style: const TextStyle(
                                    color: AppTheme.textSecondary,
                                    fontSize: 14,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
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
                      // Add Workout button
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (context) =>
                                    const ChooseWorkoutScreen(),
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
                              value: '${stats.totalSessions}',
                              label: 'Workouts',
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
                              value: '${stats.totalVolumePoints}',
                              label: 'Points',
                            ),
                          ),
                        ],
                      ),
                      if (stats.totalSessions == 0) ...[
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
              'No workouts yet — tap "Add Workout" and your stats will fill in.',
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
    return const ChooseWorkoutScreen();
  }
}

class _NutritionTab extends StatelessWidget {
  const _NutritionTab();

  @override
  Widget build(BuildContext context) {
    return const MealPlanScreen();
  }
}

class _CoachTab extends StatefulWidget {
  const _CoachTab();

  @override
  State<_CoachTab> createState() => _CoachTabState();
}

class _CoachTabState extends State<_CoachTab> with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: true,
      bottom: false,
      child: Column(
        children: [
          Material(
            color: AppTheme.darkBg,
            child: TabBar(
              controller: _tabController,
              indicatorColor: AppTheme.neonGreen,
              labelColor: AppTheme.neonGreen,
              unselectedLabelColor: AppTheme.textMuted,
              tabs: const [
                Tab(text: 'Monitoring'),
                Tab(text: 'Leaderboard'),
              ],
            ),
          ),
          const Divider(height: 1, color: AppTheme.cardBgLight),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: const [
                GymMonitoringScreen(),
                LeaderboardScreen(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
