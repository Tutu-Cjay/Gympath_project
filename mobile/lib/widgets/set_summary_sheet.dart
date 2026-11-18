import 'package:flutter/material.dart';

import '../models/workout_session.dart';
import '../theme/app_theme.dart';
import 'rep_bars.dart';

/// What the user picked at the end of a set.
enum SetSummaryAction { nextSet, finish, export }

/// Bottom sheet shown after Stop: the set's numbers, rep speeds, record
/// badge, and what to do next.
class SetSummarySheet extends StatelessWidget {
  final WorkoutSession set;
  final bool saved;
  final bool simulated;
  final bool isRecord;
  final bool canExport;

  const SetSummarySheet({
    super.key,
    required this.set,
    required this.saved,
    required this.simulated,
    required this.isRecord,
    required this.canExport,
  });

  static Future<SetSummaryAction?> show(
    BuildContext context, {
    required WorkoutSession set,
    required bool saved,
    required bool simulated,
    required bool isRecord,
    required bool canExport,
  }) {
    return showModalBottomSheet<SetSummaryAction>(
      context: context,
      backgroundColor: AppTheme.cardBg,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      builder: (_) => SetSummarySheet(
        set: set,
        saved: saved,
        simulated: simulated,
        isRecord: isRecord,
        canExport: canExport,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final loss = set.velocityLoss;
    String mmss(int s) => '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
    Widget cell(String label, String value) => Expanded(
          child: Column(
            children: [
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(value,
                    style: const TextStyle(
                        color: AppTheme.neonGreen,
                        fontSize: 20,
                        fontWeight: FontWeight.w800)),
              ),
              const SizedBox(height: 2),
              Text(label,
                  style: const TextStyle(
                      color: AppTheme.textSecondary, fontSize: 11)),
            ],
          ),
        );

    final String note;
    if (set.reps == 0) {
      note = 'No reps counted, nothing saved.';
    } else if (simulated && saved) {
      note = 'Simulation: saved to your history, marked SIM.';
    } else if (simulated) {
      note = 'Simulation: not saved. Turn on saving above the figure to keep '
          'simulated sets.';
    } else {
      note = 'Saved to your history.';
    }

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 38,
                height: 4,
                decoration: BoxDecoration(
                    color: AppTheme.cardBgLight,
                    borderRadius: BorderRadius.circular(2)),
              ),
            ),
            const SizedBox(height: 14),
            Row(children: [
              Expanded(
                child: Text('Set ${set.setIndex} · ${set.workoutName}',
                    style: const TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 18,
                        fontWeight: FontWeight.bold)),
              ),
              if (isRecord)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                  decoration: BoxDecoration(
                    color: AppTheme.neonGreen.withValues(alpha: .15),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AppTheme.neonGreen),
                  ),
                  child: const Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.emoji_events_rounded,
                        color: AppTheme.neonGreen, size: 14),
                    SizedBox(width: 4),
                    Text('NEW RECORD',
                        style: TextStyle(
                            color: AppTheme.neonGreen,
                            fontSize: 10,
                            fontWeight: FontWeight.w800,
                            letterSpacing: .8)),
                  ]),
                ),
            ]),
            const SizedBox(height: 4),
            Text(note,
                style: const TextStyle(
                    color: AppTheme.textSecondary, fontSize: 12)),
            const SizedBox(height: 18),
            Row(children: [
              cell('Reps', '${set.reps}'),
              cell('Weight', set.weightKg > 0 ? '${_kg(set.weightKg)} kg' : '—'),
              cell('Volume', set.volumeKg > 0 ? '${set.volumeKg.round()} kg' : '—'),
              cell('Time', mmss(set.durationSec)),
            ]),
            const SizedBox(height: 14),
            Row(children: [
              cell('Avg speed',
                  set.meanVelocity > 0 ? '${set.meanVelocity.toStringAsFixed(2)} m/s' : '—'),
              cell('Avg range',
                  set.meanRangeCm > 0 ? '${set.meanRangeCm.round()} cm' : '—'),
              cell('Speed loss', loss == null ? '—' : '${(loss * 100).round()}%'),
            ]),
            const SizedBox(height: 18),
            const Text('LIFTING SPEED PER REP (m/s)',
                style: TextStyle(
                    color: AppTheme.textSecondary,
                    fontSize: 10,
                    letterSpacing: 1.1,
                    fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            RepBars(reps: set.repDetails, height: 70),
            if (loss != null && loss > 0.3) ...[
              const SizedBox(height: 10),
              const Text(
                'Speed dropped more than 30% in this set. That is close to '
                'failure; rest longer or take some weight off for the next set.',
                style: TextStyle(color: RepBars.warn, fontSize: 12),
              ),
            ],
            const SizedBox(height: 20),
            Row(children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () =>
                      Navigator.pop(context, SetSummaryAction.finish),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppTheme.textPrimary,
                    side: const BorderSide(color: AppTheme.cardBgLight),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  child: const Text('Finish exercise'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: ElevatedButton(
                  onPressed: () =>
                      Navigator.pop(context, SetSummaryAction.nextSet),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.neonGreen,
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  child: const Text('Rest, then next set'),
                ),
              ),
            ]),
            if (canExport)
              TextButton.icon(
                onPressed: () =>
                    Navigator.pop(context, SetSummaryAction.export),
                icon: const Icon(Icons.ios_share_rounded, size: 16),
                label: const Text('Export raw tracker data (CSV)'),
                style: TextButton.styleFrom(
                    foregroundColor: AppTheme.textSecondary),
              ),
          ],
        ),
      ),
    );
  }
}

String _kg(double v) =>
    v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
