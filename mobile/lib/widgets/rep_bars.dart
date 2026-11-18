import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/workout_session.dart';
import '../theme/app_theme.dart';

/// One bar per rep, height = mean lifting velocity. Bars that dropped more
/// than [warnLoss] below the fastest of the first two reps turn amber: a
/// quick read of fatigue inside the set.
class RepBars extends StatelessWidget {
  final List<RepMetrics> reps;
  final double height;
  final double warnLoss;
  final bool showValues;

  const RepBars({
    super.key,
    required this.reps,
    this.height = 64,
    this.warnLoss = 0.2,
    this.showValues = true,
  });

  static const Color warn = Color(0xFFFFB833);

  @override
  Widget build(BuildContext context) {
    if (reps.isEmpty) {
      return SizedBox(
        height: height,
        child: const Center(
          child: Text('Rep speeds appear here',
              style: TextStyle(color: AppTheme.textMuted, fontSize: 11)),
        ),
      );
    }
    final top = reps.map((r) => r.meanVelocity).reduce(math.max);
    final reference = reps.length >= 2
        ? math.max(reps[0].meanVelocity, reps[1].meanVelocity)
        : reps[0].meanVelocity;
    return SizedBox(
      height: height,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (var i = 0; i < reps.length; i++)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: _bar(i, top, reference),
              ),
            ),
        ],
      ),
    );
  }

  Widget _bar(int i, double top, double reference) {
    final v = reps[i].meanVelocity;
    final slow = reference > 0 && (reference - v) / reference > warnLoss;
    final color = slow ? warn : AppTheme.neonGreen;
    final frac = top > 0 ? (v / top).clamp(0.05, 1.0) : 0.05;
    return Column(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        if (showValues)
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(v.toStringAsFixed(2),
                style: TextStyle(
                    color: color, fontSize: 9, fontWeight: FontWeight.w700)),
          ),
        const SizedBox(height: 2),
        Flexible(
          child: FractionallySizedBox(
            heightFactor: frac,
            child: Container(
              decoration: BoxDecoration(
                color: color.withValues(alpha: .85),
                borderRadius: BorderRadius.circular(3),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
