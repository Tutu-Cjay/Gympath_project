import 'package:flutter/material.dart';

import '../models/training_stats.dart';
import '../theme/app_theme.dart';

/// Training days as a grid: one column per week (Monday on top), brighter
/// for more sets that day.
class ActivityHeatmap extends StatelessWidget {
  /// Sets per day (keys are days at 00:00).
  final Map<DateTime, int> sets;
  final DateTime now;
  final int weeks;

  const ActivityHeatmap(
      {super.key, required this.sets, required this.now, this.weeks = 26});

  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  /// First Monday shown.
  static DateTime firstDay(DateTime now, int weeks) {
    final w = weekStart(now);
    return DateTime(w.year, w.month, w.day - 7 * (weeks - 1));
  }

  /// [n] calendar days after [d] (safe across daylight-saving changes).
  static DateTime plusDays(DateTime d, int n) => DateTime(d.year, d.month, d.day + n);

  static double level(int n) => n <= 0
      ? 0
      : n <= 3
          ? .35
          : n <= 7
              ? .6
              : n <= 12
                  ? .8
                  : 1;

  @override
  Widget build(BuildContext context) {
    final start = firstDay(now, weeks);
    final today = dayOf(now);
    return LayoutBuilder(builder: (context, c) {
      const labelW = 16.0, gap = 3.0;
      final cell = ((c.maxWidth - labelW) / weeks - gap).clamp(4.0, 16.0);
      Widget box(DateTime d) {
        if (d.isAfter(today)) return SizedBox(width: cell, height: cell);
        final n = sets[d] ?? 0;
        return Tooltip(
          message: '${d.day} ${_months[d.month - 1]}: $n set${n == 1 ? '' : 's'}',
          child: Container(
            width: cell,
            height: cell,
            decoration: BoxDecoration(
              color: n == 0
                  ? AppTheme.cardBgLight
                  : AppTheme.neonGreen.withValues(alpha: level(n)),
              borderRadius: BorderRadius.circular(2),
              border: d == today
                  ? Border.all(color: AppTheme.textPrimary, width: 1)
                  : null,
            ),
          ),
        );
      }

      const small = TextStyle(color: AppTheme.textMuted, fontSize: 9);
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const SizedBox(width: labelW),
          for (var w = 0; w < weeks; w++)
            SizedBox(
              width: cell + gap,
              height: 12,
              child: OverflowBox(
                alignment: Alignment.centerLeft,
                maxWidth: 40,
                child: Builder(builder: (_) {
                  final d = plusDays(start, 7 * w);
                  final prev = plusDays(d, -7);
                  final show = w == 0 ? d.day <= 7 : prev.month != d.month;
                  return Text(show ? _months[d.month - 1] : '', style: small);
                }),
              ),
            ),
        ]),
        const SizedBox(height: 3),
        for (var r = 0; r < 7; r++)
          Padding(
            padding: const EdgeInsets.only(bottom: gap),
            child: Row(children: [
              SizedBox(
                width: labelW,
                child: Text(const ['M', '', 'W', '', 'F', '', 'S'][r], style: small),
              ),
              for (var w = 0; w < weeks; w++)
                Padding(
                  padding: const EdgeInsets.only(right: gap),
                  child: box(plusDays(start, 7 * w + r)),
                ),
            ]),
          ),
      ]);
    });
  }
}
