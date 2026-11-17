import 'package:flutter_test/flutter_test.dart';
import 'package:gympath/models/squat_rig.dart';

void main() {
  final depths = [for (var i = 0; i <= 20; i++) i / 20];

  test('thigh and shank keep their length at every depth', () {
    for (final d in depths) {
      final p = SquatRig.solve(d);
      for (final leg in [
        [Joint.hipL, Joint.kneeL, Joint.ankleL],
        [Joint.hipR, Joint.kneeR, Joint.ankleR],
      ]) {
        expect(p[leg[0]].distanceTo(p[leg[1]]),
            closeTo(SquatRig.thighLength, 1e-6));
        expect(p[leg[1]].distanceTo(p[leg[2]]),
            closeTo(SquatRig.shankLength, 1e-6));
      }
    }
  });

  test('feet stay planted and the pose is left/right symmetric', () {
    for (final d in depths) {
      final p = SquatRig.solve(d);
      expect(p[Joint.ankleR].y, closeTo(SquatRig.ankleHeight, 1e-9));
      expect(p[Joint.ankleR].x, closeTo(SquatRig.stanceHalfWidth, 1e-9));
      expect(p[Joint.toeR].y, closeTo(SquatRig.footHeight, 1e-9));
      expect(p[Joint.kneeL].x, closeTo(-p[Joint.kneeR].x, 1e-9));
      expect(p[Joint.kneeL].y, closeTo(p[Joint.kneeR].y, 1e-9));
      expect(p[Joint.handL].z, closeTo(p[Joint.handR].z, 1e-9));
    }
  });

  test('hips drop and travel back as depth increases', () {
    var last = SquatRig.solve(0)[Joint.pelvis];
    for (final d in depths.skip(1)) {
      final pelvis = SquatRig.solve(d)[Joint.pelvis];
      expect(pelvis.y, lessThan(last.y));
      expect(pelvis.z, lessThan(last.z));
      last = pelvis;
    }
  });

  test('joint angles: near-straight standing, deep flexion at the bottom', () {
    final stand = SquatRig.solve(0);
    final bottom = SquatRig.solve(1);
    expect(stand.kneeFlexionDeg, lessThan(15));
    expect(bottom.kneeFlexionDeg, inInclusiveRange(105, 130));
    expect(bottom.hipFlexionDeg, greaterThan(100));
    expect(bottom.torsoLeanDeg, closeTo(40, 1e-6));
  });

  test('knees track over the toes at the bottom', () {
    final p = SquatRig.solve(1);
    expect((p[Joint.kneeR].x - p[Joint.toeR].x).abs(), lessThan(0.06));
    expect(p[Joint.kneeR].z, greaterThan(0.10));
  });

  test('timeline maps to depth and phase', () {
    expect(SquatRig.depthAt(0), 0);
    expect(SquatRig.depthAt(0.5), 1);
    expect(SquatRig.depthAt(0.99), 0);
    expect(SquatRig.depthAt(0.3), inExclusiveRange(0, 1));
    expect(SquatRig.phaseAt(0.02), SquatPhase.standing);
    expect(SquatRig.phaseAt(0.2), SquatPhase.descent);
    expect(SquatRig.phaseAt(0.5), SquatPhase.bottom);
    expect(SquatRig.phaseAt(0.7), SquatPhase.ascent);
    expect(SquatRig.phaseAt(0.95), SquatPhase.finish);
  });

  test('activation stays in 0..1 and rises with depth', () {
    for (final g in MuscleGroup.values) {
      for (final ph in SquatPhase.values) {
        for (final d in depths) {
          expect(SquatRig.activation(g, d, ph), inInclusiveRange(0, 1));
        }
      }
      expect(SquatRig.activation(g, 1, SquatPhase.ascent),
          greaterThan(SquatRig.activation(g, 0, SquatPhase.standing)));
    }
  });
}
