import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../services/workout_store.dart';

class LeaderboardScreen extends StatelessWidget {
  const LeaderboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.darkBg,
      body: SafeArea(
        child: CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          children: [
                            Icon(Icons.check_circle_rounded, color: AppTheme.neonGreen, size: 28),
                            const SizedBox(width: 8),
                            const Text(
                              'Welcome back!',
                              style: TextStyle(
                                color: AppTheme.textPrimary,
                                fontSize: 22,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                        CircleAvatar(
                          radius: 20,
                          backgroundColor: AppTheme.cardBgLight,
                          child: const Icon(Icons.person_rounded),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    // Activity feed
                    const Text(
                      'Recent Activity',
                      style: TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 12),
                    _ActivityItem(
                      name: 'Sasha',
                      text: 'Clicked into the gym',
                      icon: Icons.fitness_center_rounded,
                    ),
                    _ActivityItem(
                      name: 'Sarah',
                      text: 'Reached 10,000 steps',
                      icon: Icons.directions_walk_rounded,
                      hasBadge: true,
                    ),
                    _ActivityItem(
                      name: 'Alex',
                      text: 'Unlocked the 50 Days Streak',
                      icon: Icons.local_fire_department_rounded,
                      hasBadge: true,
                    ),
                    const SizedBox(height: 24),
                    // Leaderboard
                    const Text(
                      'Leaderboard',
                      style: TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 12),
                    ValueListenableBuilder<WorkoutStats>(
                      valueListenable: WorkoutStore.instance.stats,
                      builder: (context, stats, _) {
                        // Rank "You" against demo peers by real points
                        final board = <(String, int, bool)>[
                          ('Sasha', 60, false),
                          ('Sarah', 45, false),
                          ('You', stats.totalVolumePoints, true),
                        ]..sort((a, b) => b.$2.compareTo(a.$2));
                        return Column(
                          children: [
                            for (int i = 0; i < board.length; i++)
                              _LeaderboardItem(
                                rank: i + 1,
                                name: board[i].$1,
                                score: board[i].$2,
                                isYou: board[i].$3,
                              ),
                            const SizedBox(height: 24),
                            Row(
                              children: [
                                _SummaryStat(
                                    value: '${stats.weekSessions}/7',
                                    label: 'Days'),
                                _SummaryStat(
                                    value: '${stats.totalReps}', label: 'Reps'),
                                _SummaryStat(
                                    value: '${stats.totalSessions}',
                                    label: 'Workouts'),
                                _SummaryStat(
                                    value: '${stats.totalVolumePoints}',
                                    label: 'Points'),
                              ],
                            ),
                          ],
                        );
                      },
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ActivityItem extends StatelessWidget {
  final String name;
  final String text;
  final IconData icon;
  final bool hasBadge;

  const _ActivityItem({
    required this.name,
    required this.text,
    required this.icon,
    this.hasBadge = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.cardBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.cardBgLight),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 20,
            backgroundColor: AppTheme.neonGreen.withValues(alpha:0.2),
            child: Icon(icon, color: AppTheme.neonGreen, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: RichText(
              text: TextSpan(
                style: const TextStyle(color: AppTheme.textPrimary, fontSize: 14),
                children: [
                  TextSpan(text: '$name ', style: const TextStyle(fontWeight: FontWeight.w600)),
                  TextSpan(text: text, style: const TextStyle(color: AppTheme.textSecondary)),
                ],
              ),
            ),
          ),
          if (hasBadge) Icon(Icons.emoji_events_rounded, color: AppTheme.neonGreen, size: 20),
        ],
      ),
    );
  }
}

class _LeaderboardItem extends StatelessWidget {
  final int rank;
  final String name;
  final int score;
  final bool isYou;

  const _LeaderboardItem({
    required this.rank,
    required this.name,
    required this.score,
    this.isYou = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isYou ? AppTheme.neonGreen.withValues(alpha:0.1) : AppTheme.cardBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isYou ? AppTheme.neonGreen.withValues(alpha:0.5) : AppTheme.cardBgLight,
        ),
      ),
      child: Row(
        children: [
          Text(
            '$rank',
            style: TextStyle(
              color: AppTheme.neonGreen,
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(width: 16),
          CircleAvatar(
            radius: 20,
            backgroundColor: AppTheme.cardBgLight,
            child: Icon(Icons.person_rounded, color: AppTheme.textSecondary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              name,
              style: TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 16,
                fontWeight: isYou ? FontWeight.w600 : FontWeight.w500,
              ),
            ),
          ),
          Icon(Icons.emoji_events_rounded, color: AppTheme.neonGreen, size: 20),
          const SizedBox(width: 4),
          Text(
            '$score',
            style: const TextStyle(
              color: AppTheme.neonGreen,
              fontWeight: FontWeight.bold,
            ),
          ),
          const Icon(Icons.arrow_forward_ios_rounded, size: 12),
        ],
      ),
    );
  }
}

class _SummaryStat extends StatelessWidget {
  final String value;
  final String label;

  const _SummaryStat({required this.value, required this.label});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        margin: const EdgeInsets.only(right: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppTheme.cardBg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.cardBgLight),
        ),
        child: Column(
          children: [
            Text(
              value,
              style: const TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 14,
                fontWeight: FontWeight.bold,
              ),
            ),
            Text(
              label,
              style: const TextStyle(
                color: AppTheme.textSecondary,
                fontSize: 10,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
