import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../utils/responsive.dart';

class GymMonitoringScreen extends StatelessWidget {
  const GymMonitoringScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final chartData = [30.0, 45.0, 35.0, 55.0, 50.0, 60.0, 55.0];

    return Scaffold(
      backgroundColor: AppTheme.darkBg,
      body: SafeArea(
        child: CustomScrollView(
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
                        Row(
                          children: [
                            IconButton(
                              onPressed: () {},
                              icon: const Icon(Icons.add_rounded),
                              color: AppTheme.neonGreen,
                            ),
                            const Text(
                              'Gym Monitoring',
                              style: TextStyle(
                                color: AppTheme.textPrimary,
                                fontSize: 22,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                        CircleAvatar(
                          radius: Responsive.r(context, 20),
                          backgroundColor: AppTheme.cardBgLight,
                          child: Icon(
                            Icons.person_rounded,
                            size: Responsive.r(context, 20),
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: Responsive.h(context, 20)),
                    // User profile card
                    Container(
                      padding: EdgeInsets.all(Responsive.w(context, 20)),
                      decoration: BoxDecoration(
                        color: AppTheme.cardBg,
                        borderRadius: BorderRadius.circular(Responsive.r(context, 16)),
                        border: Border.all(color: AppTheme.cardBgLight),
                      ),
                      child: Row(
                        children: [
                          CircleAvatar(
                            radius: Responsive.r(context, 30),
                            backgroundColor: AppTheme.neonGreen.withValues(alpha:0.2),
                            child: Icon(
                              Icons.person_rounded,
                              size: Responsive.r(context, 32),
                              color: AppTheme.neonGreen,
                            ),
                          ),
                          SizedBox(width: Responsive.w(context, 16)),
                          const Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Sasha Watson',
                                  style: TextStyle(
                                    color: AppTheme.textPrimary,
                                    fontSize: 18,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                Text(
                                  'Ready for workout',
                                  style: TextStyle(
                                    color: AppTheme.textSecondary,
                                    fontSize: 14,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    SizedBox(height: Responsive.h(context, 24)),
                    // Performance chart
                    const Text(
                      'Performance',
                      style: TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    SizedBox(height: Responsive.h(context, 12)),
                    Container(
                      height: Responsive.h(context, 180),
                      padding: EdgeInsets.all(Responsive.w(context, 16)),
                      decoration: BoxDecoration(
                        color: AppTheme.cardBg,
                        borderRadius: BorderRadius.circular(Responsive.r(context, 16)),
                        border: Border.all(color: AppTheme.cardBgLight),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: chartData.asMap().entries.map((e) {
                          return Expanded(
                            child: Padding(
                              padding: EdgeInsets.symmetric(horizontal: Responsive.w(context, 4)),
                              child: Column(
                                children: [
                                  Text(
                                    e.value.toInt().toString(),
                                    style: const TextStyle(
                                      color: AppTheme.textSecondary,
                                      fontSize: 10,
                                    ),
                                  ),
                                  SizedBox(height: Responsive.h(context, 4)),
                                  // bar fills the leftover space; the fraction
                                  // keeps relative heights without any fixed math
                                  Expanded(
                                    child: FractionallySizedBox(
                                      alignment: Alignment.bottomCenter,
                                      heightFactor: (e.value / 60).clamp(0.0, 1.0),
                                      child: Container(
                                        decoration: BoxDecoration(
                                          color: AppTheme.neonGreen.withValues(alpha: 0.6),
                                          borderRadius: BorderRadius.circular(Responsive.r(context, 4)),
                                        ),
                                      ),
                                    ),
                                  ),
                                  SizedBox(height: Responsive.h(context, 6)),
                                  Text(
                                    ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul'][e.key],
                                    style: const TextStyle(
                                      color: AppTheme.textSecondary,
                                      fontSize: 10,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                    ),
                    SizedBox(height: Responsive.h(context, 24)),
                    // Weekly challenge
                    Container(
                      padding: EdgeInsets.all(Responsive.w(context, 20)),
                      decoration: BoxDecoration(
                        color: AppTheme.cardBg,
                        borderRadius: BorderRadius.circular(Responsive.r(context, 16)),
                        border: Border.all(color: AppTheme.cardBgLight),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Row(
                                children: [
                                  Icon(
                                    Icons.emoji_events_rounded,
                                    color: AppTheme.neonGreen,
                                    size: Responsive.r(context, 24),
                                  ),
                                  SizedBox(width: Responsive.w(context, 8)),
                                  const Text(
                                    'Weekly Challenge',
                                    style: TextStyle(
                                      color: AppTheme.textPrimary,
                                      fontSize: 16,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ),
                              const Text(
                                '5/7',
                                style: TextStyle(
                                  color: AppTheme.neonGreen,
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                          SizedBox(height: Responsive.h(context, 12)),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(Responsive.r(context, 8)),
                            child: LinearProgressIndicator(
                              value: 5 / 7,
                              minHeight: Responsive.h(context, 8),
                              backgroundColor: AppTheme.cardBgLight,
                              valueColor: const AlwaysStoppedAnimation(AppTheme.neonGreen),
                            ),
                          ),
                          SizedBox(height: Responsive.h(context, 8)),
                          const Text(
                            '85,260 Steps',
                            style: TextStyle(
                              color: AppTheme.textSecondary,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    SizedBox(height: Responsive.h(context, 24)),
                    // Alerts
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'Alerts',
                          style: TextStyle(
                            color: AppTheme.textPrimary,
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        TextButton(
                          onPressed: () {},
                          child: const Text(
                            '4.0 >',
                            style: TextStyle(color: AppTheme.neonGreen),
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: Responsive.h(context, 12)),
                    _AlertItem(title: 'Bench Press', subtitle: '10 reps'),
                    _AlertItem(title: 'Running', subtitle: '6 km'),
                    _AlertItem(title: 'Squats', subtitle: '6 sets'),
                    Container(
                      margin: EdgeInsets.only(top: Responsive.h(context, 8)),
                      padding: EdgeInsets.all(Responsive.w(context, 16)),
                      decoration: BoxDecoration(
                        color: AppTheme.neonGreen.withValues(alpha:0.1),
                        borderRadius: BorderRadius.circular(Responsive.r(context, 12)),
                        border: Border.all(color: AppTheme.neonGreen.withValues(alpha:0.3)),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.warning_amber_rounded, color: AppTheme.neonGreen, size: Responsive.r(context, 24)),
                          SizedBox(width: Responsive.w(context, 12)),
                          const Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Underperformed Bench Press!',
                                  style: TextStyle(
                                    color: AppTheme.textPrimary,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                Text(
                                  'With weight suggestions',
                                  style: TextStyle(
                                    color: AppTheme.textSecondary,
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Icon(Icons.arrow_forward_ios_rounded, size: Responsive.r(context, 12), color: AppTheme.textMuted),
                        ],
                      ),
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

class _AlertItem extends StatelessWidget {
  final String title;
  final String subtitle;

  const _AlertItem({required this.title, required this.subtitle});

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
          Icon(Icons.fitness_center_rounded, color: AppTheme.neonGreen.withValues(alpha:0.8)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                Text(
                  subtitle,
                  style: const TextStyle(
                    color: AppTheme.textSecondary,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          const Icon(Icons.arrow_forward_ios_rounded, size: 12, color: AppTheme.textMuted),
        ],
      ),
    );
  }
}
