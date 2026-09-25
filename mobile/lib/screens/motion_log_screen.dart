import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../utils/responsive.dart';
import '../services/ble_service.dart';
import '../models/motion_data.dart';

class MotionLogScreen extends StatefulWidget {
  const MotionLogScreen({super.key});

  @override
  State<MotionLogScreen> createState() => _MotionLogScreenState();
}

class _MotionLogScreenState extends State<MotionLogScreen> {
  final BleService _ble = BleService.instance;
  StreamSubscription<MotionData>? _sub;
  final List<MotionData> _buffer = [];
  static const int _maxPoints = 200;

  @override
  void initState() {
    super.initState();
    _sub = _ble.motionStream.listen((data) {
      setState(() {
        _buffer.add(data);
        if (_buffer.length > _maxPoints) {
          _buffer.removeRange(0, _buffer.length - _maxPoints);
        }
      });
    });
    // Defer connect() — it flips BleService.connectionState synchronously,
    // which would rebuild the home BleStatusChip mid-build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_ble.isConnected) _ble.connect();
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final latest = _buffer.isNotEmpty ? _buffer.last : null;
    return Scaffold(
      backgroundColor: AppTheme.darkBg,
      appBar: AppBar(
        title: const Text('Motion Log'),
      ),
      body: SafeArea(
        child: Padding(
          padding: EdgeInsets.all(Responsive.w(context, 20)),
          child: Column(
            children: [
              Container(
                height: Responsive.h(context, 220),
                decoration: BoxDecoration(
                  color: AppTheme.cardBg,
                  borderRadius: BorderRadius.circular(Responsive.r(context, 16)),
                  border: Border.all(color: AppTheme.cardBgLight),
                ),
                child: CustomPaint(
                  painter: _MotionChartPainter(_buffer),
                  child: const SizedBox.expand(),
                ),
              ),
              SizedBox(height: Responsive.h(context, 16)),
              Row(
                children: [
                  _LegendDot(color: AppTheme.neonGreen, label: 'posZ'),
                  SizedBox(width: Responsive.w(context, 12)),
                  _LegendDot(color: const Color(0xFF6EA8FF), label: 'accEnv'),
                  if (latest != null && latest.isV2) ...[
                    SizedBox(width: Responsive.w(context, 12)),
                    _LegendDot(color: const Color(0xFFFFB36E), label: 'dispMag'),
                    SizedBox(width: Responsive.w(context, 12)),
                    _LegendDot(color: const Color(0xFFC78BFF), label: 'roll'),
                  ],
                ],
              ),
              SizedBox(height: Responsive.h(context, 16)),
              if (latest != null)
                Container(
                  padding: EdgeInsets.all(Responsive.w(context, 16)),
                  decoration: BoxDecoration(
                    color: AppTheme.cardBg,
                    borderRadius: BorderRadius.circular(Responsive.r(context, 12)),
                    border: Border.all(color: AppTheme.cardBgLight),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Latest', style: TextStyle(color: AppTheme.textPrimary, fontSize: Responsive.sp(context, 14), fontWeight: FontWeight.w600)),
                      SizedBox(height: Responsive.h(context, 8)),
                      _line('posZ', latest.posZ.toStringAsFixed(3)),
                      _line('velZ', latest.velZ.toStringAsFixed(3)),
                      _line('accEnv', latest.accEnv.toStringAsFixed(3)),
                      _line('reps', latest.motionCount.toString()),
                      if (latest.isV2) ...[
                        _line('dispMag', '${latest.dispMag.toStringAsFixed(3)} m'),
                        _line('roll / pitch / yaw',
                            '${latest.roll.toStringAsFixed(0)}° / ${latest.pitch.toStringAsFixed(0)}° / ${latest.yaw.toStringAsFixed(0)}°'),
                        _line('phase', latest.repPhase == 1 ? 'ACTIVE' : 'REST'),
                        _line('ZUPT', latest.zuptActive ? 'on' : 'off'),
                      ],
                    ],
                  ),
                ),
              SizedBox(height: Responsive.h(context, 16)),
              Expanded(
                child: ListView.builder(
                  itemCount: min(20, _buffer.length),
                  itemBuilder: (context, index) {
                    final d = _buffer[_buffer.length - 1 - index];
                    return Container(
                      margin: EdgeInsets.only(bottom: Responsive.h(context, 8)),
                      padding: EdgeInsets.all(Responsive.w(context, 12)),
                      decoration: BoxDecoration(
                        color: AppTheme.cardBg,
                        borderRadius: BorderRadius.circular(Responsive.r(context, 10)),
                        border: Border.all(color: AppTheme.cardBgLight),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text('t=${d.timestampMs}ms', style: TextStyle(color: AppTheme.textMuted, fontSize: Responsive.sp(context, 10))),
                          Text('z=${d.posZ.toStringAsFixed(2)}', style: TextStyle(color: AppTheme.textPrimary)),
                          Text('env=${d.accEnv.toStringAsFixed(2)}', style: TextStyle(color: AppTheme.textSecondary)),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _line(String label, String value) {
    return Padding(
      padding: EdgeInsets.only(bottom: Responsive.h(context, 4)),
      child: Text('$label: $value', style: TextStyle(color: AppTheme.textSecondary, fontSize: Responsive.sp(context, 12))),
    );
  }
}

class _LegendDot extends StatelessWidget {
  final Color color;
  final String label;

  const _LegendDot({required this.color, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: Responsive.r(context, 10),
          height: Responsive.r(context, 10),
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        SizedBox(width: Responsive.w(context, 6)),
        Text(label, style: TextStyle(color: AppTheme.textSecondary, fontSize: Responsive.sp(context, 12))),
      ],
    );
  }
}

class _MotionChartPainter extends CustomPainter {
  final List<MotionData> data;

  _MotionChartPainter(this.data);

  @override
  void paint(Canvas canvas, Size size) {
    final paintAxis = Paint()
      ..color = AppTheme.cardBgLight
      ..strokeWidth = 1;

    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.transparent);
    canvas.drawLine(Offset(0, size.height / 2), Offset(size.width, size.height / 2), paintAxis);

    if (data.length < 2) return;

    final posZ = data.map((e) => e.posZ).toList();
    final accEnv = data.map((e) => e.accEnv).toList();

    final minZ = posZ.reduce(min);
    final maxZ = posZ.reduce(max);
    final minEnv = accEnv.reduce(min);
    final maxEnv = accEnv.reduce(max);

    double mapZ(double v) {
      if ((maxZ - minZ).abs() < 1e-3) return size.height / 2;
      final t = (v - minZ) / (maxZ - minZ);
      return size.height - t * size.height;
    }

    double mapEnv(double v) {
      if ((maxEnv - minEnv).abs() < 1e-3) return size.height / 2;
      final t = (v - minEnv) / (maxEnv - minEnv);
      return size.height - t * size.height;
    }

    final hasV2 = data.last.isV2;
    final disp = data.map((e) => e.dispMag).toList();
    final roll = data.map((e) => e.roll).toList();
    final minDisp = disp.reduce(min);
    final maxDisp = disp.reduce(max);
    final minRoll = roll.reduce(min);
    final maxRoll = roll.reduce(max);

    double mapDisp(double v) {
      if ((maxDisp - minDisp).abs() < 1e-3) return size.height / 2;
      final t = (v - minDisp) / (maxDisp - minDisp);
      return size.height - t * size.height;
    }

    double mapRoll(double v) {
      if ((maxRoll - minRoll).abs() < 1e-3) return size.height / 2;
      final t = (v - minRoll) / (maxRoll - minRoll);
      return size.height - t * size.height;
    }

    final pathZ = Path();
    final pathE = Path();
    final pathD = Path();
    final pathR = Path();

    for (int i = 0; i < data.length; i++) {
      final x = (i / (data.length - 1)) * size.width;
      final yZ = mapZ(posZ[i]);
      final yE = mapEnv(accEnv[i]);
      final yD = mapDisp(disp[i]);
      final yR = mapRoll(roll[i]);
      if (i == 0) {
        pathZ.moveTo(x, yZ);
        pathE.moveTo(x, yE);
        pathD.moveTo(x, yD);
        pathR.moveTo(x, yR);
      } else {
        pathZ.lineTo(x, yZ);
        pathE.lineTo(x, yE);
        pathD.lineTo(x, yD);
        pathR.lineTo(x, yR);
      }
    }

    final paintZ = Paint()
      ..color = AppTheme.neonGreen
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    final paintE = Paint()
      ..color = const Color(0xFF6EA8FF)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;

    canvas.drawPath(pathZ, paintZ);
    canvas.drawPath(pathE, paintE);

    if (hasV2) {
      final paintD = Paint()
        ..color = const Color(0xFFFFB36E)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2;
      final paintR = Paint()
        ..color = const Color(0xFFC78BFF)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2;
      canvas.drawPath(pathD, paintD);
      canvas.drawPath(pathR, paintR);
    }
  }

  @override
  bool shouldRepaint(covariant _MotionChartPainter oldDelegate) {
    return oldDelegate.data != data;
  }
}
