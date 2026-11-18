import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

class ChartPoint {
  final DateTime day;
  final double value;
  const ChartPoint(this.day, this.value);
}

/// Line chart over calendar time (gaps between training days stay visible),
/// with the first, best and last values labelled.
class ProgressChart extends StatelessWidget {
  final List<ChartPoint> points;
  final String unit;
  final int decimals;
  final double height;

  const ProgressChart({
    super.key,
    required this.points,
    required this.unit,
    this.decimals = 0,
    this.height = 170,
  });

  @override
  Widget build(BuildContext context) {
    if (points.isEmpty) {
      return SizedBox(
        height: height,
        child: const Center(
          child: Text('No data yet',
              style: TextStyle(color: AppTheme.textMuted, fontSize: 12)),
        ),
      );
    }
    return SizedBox(
      height: height,
      width: double.infinity,
      child: CustomPaint(
        painter: _ChartPainter(points, unit, decimals),
      ),
    );
  }
}

class _ChartPainter extends CustomPainter {
  final List<ChartPoint> points;
  final String unit;
  final int decimals;
  _ChartPainter(this.points, this.unit, this.decimals);

  static const double _left = 8, _right = 8, _top = 22, _bottom = 22;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width - _left - _right;
    final h = size.height - _top - _bottom;
    final t0 = points.first.day.millisecondsSinceEpoch.toDouble();
    final t1 = points.last.day.millisecondsSinceEpoch.toDouble();
    final values = points.map((p) => p.value);
    var lo = values.reduce(math.min), hi = values.reduce(math.max);
    if (hi - lo < 1e-9) {
      lo -= 1;
      hi += 1;
    }
    final pad = (hi - lo) * 0.12;
    lo -= pad;
    hi += pad;

    Offset at(ChartPoint p) {
      final x = points.length == 1 || t1 == t0
          ? _left + w / 2
          : _left + (p.day.millisecondsSinceEpoch - t0) / (t1 - t0) * w;
      final y = _top + (1 - (p.value - lo) / (hi - lo)) * h;
      return Offset(x, y);
    }

    final grid = Paint()
      ..color = AppTheme.cardBgLight
      ..strokeWidth = 1;
    for (var i = 0; i <= 3; i++) {
      final y = _top + h * i / 3;
      canvas.drawLine(Offset(_left, y), Offset(_left + w, y), grid);
    }

    final pts = points.map(at).toList();
    if (pts.length > 1) {
      final line = Path()..moveTo(pts.first.dx, pts.first.dy);
      for (final p in pts.skip(1)) {
        line.lineTo(p.dx, p.dy);
      }
      final fill = Path.from(line)
        ..lineTo(pts.last.dx, _top + h)
        ..lineTo(pts.first.dx, _top + h)
        ..close();
      canvas.drawPath(
        fill,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              AppTheme.neonGreen.withValues(alpha: .28),
              AppTheme.neonGreen.withValues(alpha: 0),
            ],
          ).createShader(Rect.fromLTWH(_left, _top, w, h)),
      );
      canvas.drawPath(
        line,
        Paint()
          ..color = AppTheme.neonGreen
          ..strokeWidth = 2.2
          ..style = PaintingStyle.stroke
          ..strokeJoin = StrokeJoin.round,
      );
    }
    final dot = Paint()..color = AppTheme.neonGreen;
    for (final p in pts) {
      canvas.drawCircle(p, 3, dot);
    }

    var best = 0;
    for (var i = 1; i < points.length; i++) {
      if (points[i].value > points[best].value) best = i;
    }
    final labelled = <int>{0, best, points.length - 1};
    for (final i in labelled) {
      _label(canvas, size, pts[i], _fmt(points[i].value),
          bold: i == points.length - 1);
    }
    _axis(canvas, size, _date(points.first.day), Alignment.bottomLeft);
    if (points.length > 1) {
      _axis(canvas, size, _date(points.last.day), Alignment.bottomRight);
    }
  }

  String _fmt(double v) => '${v.toStringAsFixed(decimals)} $unit';

  static String _date(DateTime d) => '${d.month}/${d.day}';

  void _label(Canvas canvas, Size size, Offset at, String text,
      {bool bold = false}) {
    final tp = TextPainter(
      text: TextSpan(
          text: text,
          style: TextStyle(
              color: bold ? AppTheme.neonGreen : AppTheme.textSecondary,
              fontSize: 10,
              fontWeight: bold ? FontWeight.w800 : FontWeight.w600)),
      textDirection: TextDirection.ltr,
    )..layout();
    final x = (at.dx - tp.width / 2).clamp(0.0, size.width - tp.width);
    tp.paint(canvas, Offset(x, math.max(0, at.dy - tp.height - 5)));
  }

  void _axis(Canvas canvas, Size size, String text, Alignment where) {
    final tp = TextPainter(
      text: TextSpan(
          text: text,
          style: const TextStyle(color: AppTheme.textMuted, fontSize: 10)),
      textDirection: TextDirection.ltr,
    )..layout();
    final x = where == Alignment.bottomLeft ? _left : size.width - _right - tp.width;
    tp.paint(canvas, Offset(x, size.height - tp.height));
  }

  @override
  bool shouldRepaint(covariant _ChartPainter old) =>
      old.points != points || old.unit != unit;
}
