import 'dart:math' as math;

/// Procedural 3D squat rig for the Movement Studio.
///
/// Pure Dart (no Flutter imports) so the kinematics can be unit-tested and
/// later driven by real animation data (pose pipeline / coach reference)
/// instead of the built-in squat curve.
///
/// World frame, metres: X = the figure's right, Y = up, Z = forward (the
/// direction the figure faces). The floor is the plane y = 0.
class Vec3 {
  final double x, y, z;
  const Vec3(this.x, this.y, this.z);

  static const Vec3 zero = Vec3(0, 0, 0);

  Vec3 operator +(Vec3 o) => Vec3(x + o.x, y + o.y, z + o.z);
  Vec3 operator -(Vec3 o) => Vec3(x - o.x, y - o.y, z - o.z);
  Vec3 operator *(double s) => Vec3(x * s, y * s, z * s);

  double dot(Vec3 o) => x * o.x + y * o.y + z * o.z;
  double get length => math.sqrt(dot(this));
  double distanceTo(Vec3 o) => (this - o).length;

  Vec3 get normalized {
    final l = length;
    return l < 1e-9 ? this : this * (1 / l);
  }

  /// Angle between two vectors in degrees.
  static double angleDeg(Vec3 a, Vec3 b) {
    final c = a.normalized.dot(b.normalized).clamp(-1.0, 1.0);
    return math.acos(c) * 180 / math.pi;
  }

  @override
  String toString() =>
      'Vec3(${x.toStringAsFixed(3)}, ${y.toStringAsFixed(3)}, ${z.toStringAsFixed(3)})';
}

enum Joint {
  pelvis,
  chest,
  neck,
  head,
  hipL,
  hipR,
  kneeL,
  kneeR,
  ankleL,
  ankleR,
  toeL,
  toeR,
  heelL,
  heelR,
  shoulderL,
  shoulderR,
  elbowL,
  elbowR,
  handL,
  handR,
}

enum MuscleGroup { quadriceps, glutes, hamstrings, core }

extension MuscleGroupLabel on MuscleGroup {
  String get label {
    switch (this) {
      case MuscleGroup.quadriceps:
        return 'Quadriceps';
      case MuscleGroup.glutes:
        return 'Gluteus maximus';
      case MuscleGroup.hamstrings:
        return 'Hamstrings';
      case MuscleGroup.core:
        return 'Core stabilizers';
    }
  }
}

/// The five squat phases from the product concept (section 6).
enum SquatPhase { standing, descent, bottom, ascent, finish }

extension SquatPhaseInfo on SquatPhase {
  String get label {
    switch (this) {
      case SquatPhase.standing:
        return 'START / STANDING';
      case SquatPhase.descent:
        return 'DESCENT (ECCENTRIC)';
      case SquatPhase.bottom:
        return 'BOTTOM POSITION';
      case SquatPhase.ascent:
        return 'ASCENT (CONCENTRIC)';
      case SquatPhase.finish:
        return 'FINISH / STANDING';
    }
  }

  String get cueTitle {
    switch (this) {
      case SquatPhase.standing:
        return 'Set your stance';
      case SquatPhase.descent:
        return 'Sit back and down';
      case SquatPhase.bottom:
        return 'Control the bottom';
      case SquatPhase.ascent:
        return 'Drive through the floor';
      case SquatPhase.finish:
        return 'Stand tall';
    }
  }

  String get cueDetail {
    switch (this) {
      case SquatPhase.standing:
        return 'Feet about shoulder-width, toes slightly out. '
            'Brace your core before you move.';
      case SquatPhase.descent:
        return 'Send the hips back, keep knees tracking over your toes '
            'and heels on the floor.';
      case SquatPhase.bottom:
        return 'Go as deep as your own range allows with the back position '
            'held. Reverse smoothly, no bounce.';
      case SquatPhase.ascent:
        return 'Push evenly through both feet. Hips and chest rise together.';
      case SquatPhase.finish:
        return 'Finish with hips fully extended, then reset your brace '
            'for the next rep.';
    }
  }
}

/// One volume of the body surface: a tapered capsule from [a] (radius [ra])
/// to [b] (radius [rb]), in metres. A sphere when a == b.
class BodySegment {
  final Vec3 a, b;
  final double ra, rb;

  /// Raised muscle definition (pecs, deltoids, knee caps): drawn a shade
  /// lighter than the rest of the body.
  final bool definition;
  const BodySegment(this.a, this.ra, this.b, this.rb,
      {this.definition = false});
}

/// A highlighted muscle volume lying on the body surface.
class MuscleSegment {
  final MuscleGroup group;
  final Vec3 a, b;
  final double radius;
  const MuscleSegment(this.group, this.a, this.b, this.radius);
}

class SquatPose {
  /// 0 = standing, 1 = bottom of the squat.
  final double depth;
  final Map<Joint, Vec3> joints;

  /// Athletic body surface, built around the joints.
  final List<BodySegment> body;
  final List<MuscleSegment> muscles;

  /// Knee flexion: 0° = straight leg.
  final double kneeFlexionDeg;

  /// Hip flexion: 0° = thigh in line with the torso.
  final double hipFlexionDeg;

  /// Forward lean of the torso from vertical.
  final double torsoLeanDeg;

  const SquatPose({
    required this.depth,
    required this.joints,
    required this.body,
    required this.muscles,
    required this.kneeFlexionDeg,
    required this.hipFlexionDeg,
    required this.torsoLeanDeg,
  });

  Vec3 operator [](Joint j) => joints[j]!;
}

class SquatRig {
  SquatRig._();

  // Segment lengths (m) for a ~1.75 m figure.
  static const double shankLength = 0.43;
  static const double thighLength = 0.44;
  static const double torsoLength = 0.50;
  static const double upperArmLength = 0.29;
  static const double forearmLength = 0.25;

  static const double ankleHeight = 0.08;
  static const double footHeight = 0.02;
  static const double stanceHalfWidth = 0.165;
  static const double hipHalfWidth = 0.095;
  static const double shoulderHalfWidth = 0.205;
  static const double toeOutDeg = 22;

  static const double _bottomPelvisHeight = 0.45;
  static const double _bottomPelvisShift = -0.24;

  // Timeline boundaries of one repetition, t in [0, 1).
  static const double descentStart = 0.08;
  static const double bottomStart = 0.45;
  static const double ascentStart = 0.55;
  static const double finishStart = 0.92;


  static double _lerp(double a, double b, double t) => a + (b - a) * t;

  static double _smooth(double t) {
    final c = t.clamp(0.0, 1.0);
    return c * c * (3 - 2 * c);
  }

  static double _rad(double deg) => deg * math.pi / 180;

  /// Squat depth (0..1) at normalized repetition time [t] (0..1).
  static double depthAt(double t) {
    final u = t.clamp(0.0, 1.0);
    if (u < descentStart) return 0;
    if (u < bottomStart) {
      return _smooth((u - descentStart) / (bottomStart - descentStart));
    }
    if (u < ascentStart) return 1;
    if (u < finishStart) {
      return 1 - _smooth((u - ascentStart) / (finishStart - ascentStart));
    }
    return 0;
  }

  static SquatPhase phaseAt(double t) {
    final u = t.clamp(0.0, 1.0);
    if (u < descentStart) return SquatPhase.standing;
    if (u < bottomStart) return SquatPhase.descent;
    if (u < ascentStart) return SquatPhase.bottom;
    if (u < finishStart) return SquatPhase.ascent;
    return SquatPhase.finish;
  }

  /// Illustrative activation (0..1) of a muscle group.
  ///
  /// This is a teaching annotation tied to depth and phase. It is not EMG and
  /// does not measure real muscle force.
  static double activation(MuscleGroup g, double depth, SquatPhase phase) {
    final d = depth.clamp(0.0, 1.0);
    // The concentric (way up) is shown a little hotter than the eccentric.
    final drive = phase == SquatPhase.ascent ? 1.0 : 0.85;
    switch (g) {
      case MuscleGroup.quadriceps:
        return (0.20 + 0.80 * d * drive).clamp(0.0, 1.0);
      case MuscleGroup.glutes:
        final curve = math.pow(d, 1.3).toDouble();
        return (0.12 + 0.88 * curve * drive).clamp(0.0, 1.0);
      case MuscleGroup.hamstrings:
        return (0.12 + 0.48 * d * drive).clamp(0.0, 1.0);
      case MuscleGroup.core:
        return (0.40 + 0.40 * d).clamp(0.0, 1.0);
    }
  }

  /// Solves the full-body pose for a squat [depth] in 0..1.
  ///
  /// The feet are pinned to the floor; each leg is solved with two-bone IK
  /// with the knee pointed along the toes, so thigh and shank keep their
  /// length at every depth.
  static SquatPose solve(double depth) {
    final d = depth.clamp(0.0, 1.0);
    final joints = <Joint, Vec3>{};
    final body = <BodySegment>[];
    final muscles = <MuscleSegment>[];
    void seg(Vec3 a, double ra, Vec3 b, double rb, {bool def = false}) =>
        body.add(BodySegment(a, ra, b, rb, definition: def));

    final legReach = shankLength + thighLength;
    final spread = stanceHalfWidth - hipHalfWidth;
    final standHeight = ankleHeight +
        0.997 * math.sqrt(legReach * legReach - spread * spread);

    final pelvis = Vec3(
      0,
      _lerp(standHeight, _bottomPelvisHeight, d),
      _lerp(0, _bottomPelvisShift, d),
    );
    final lean = _rad(_lerp(4, 40, d));
    // Torso axis (pelvis -> neck) and the direction the chest faces.
    final up = Vec3(0, math.cos(lean), math.sin(lean));
    final front = Vec3(0, -math.sin(lean), math.cos(lean));

    final neck = pelvis + up * torsoLength;
    final headLean = lean * 0.45;
    joints[Joint.pelvis] = pelvis;
    joints[Joint.chest] = pelvis + up * 0.30;
    joints[Joint.neck] = neck;
    joints[Joint.head] =
        neck + Vec3(0, math.cos(headLean), math.sin(headLean)) * 0.15;

    final head = joints[Joint.head]!;
    seg(neck - up * 0.03, 0.060, head - up * 0.06, 0.054);
    seg(head, 0.100, head + up * 0.035 + front * 0.012, 0.092);

    final toe = _rad(toeOutDeg);
    double kneeFlexion = 0;
    double hipFlexion = 0;

    for (final right in [false, true]) {
      final s = right ? 1.0 : -1.0;
      final hip = pelvis + Vec3(s * hipHalfWidth, 0, 0);
      final ankle = Vec3(s * stanceHalfWidth, ankleHeight, 0);
      final pole = Vec3(s * math.sin(toe), 0, math.cos(toe));

      // Two-bone IK: hip -> knee -> ankle, knee bent toward the pole.
      final toAnkle = ankle - hip;
      final reach = math.min(toAnkle.length, legReach * 0.9995);
      final axis = toAnkle.normalized;
      final bend = (pole - axis * pole.dot(axis)).normalized;
      final cosHip = ((thighLength * thighLength +
                  reach * reach -
                  shankLength * shankLength) /
              (2 * thighLength * reach))
          .clamp(-1.0, 1.0);
      final sinHip = math.sqrt(math.max(0.0, 1 - cosHip * cosHip));
      final thighDir = axis * cosHip + bend * sinHip;
      final knee = hip + thighDir * thighLength;

      final sole = Vec3(ankle.x, footHeight, 0);
      joints[right ? Joint.hipR : Joint.hipL] = hip;
      joints[right ? Joint.kneeR : Joint.kneeL] = knee;
      joints[right ? Joint.ankleR : Joint.ankleL] = ankle;
      joints[right ? Joint.toeR : Joint.toeL] = sole + pole * 0.17;
      joints[right ? Joint.heelR : Joint.heelL] = sole - pole * 0.06;

      // Arms swing forward as a counterbalance while the hips travel back.
      final shoulder = neck - up * 0.04 + Vec3(s * shoulderHalfWidth, 0, 0);
      final raise = _rad(_lerp(6, 78, d));
      final upperDir =
          Vec3(-s * 0.10 * d, -math.cos(raise), math.sin(raise)).normalized;
      final elbow = shoulder + upperDir * upperArmLength;
      final reachUp = _rad(_lerp(14, 96, d));
      final foreDir =
          Vec3(-s * 0.30 * d, -math.cos(reachUp), math.sin(reachUp))
              .normalized;
      joints[right ? Joint.shoulderR : Joint.shoulderL] = shoulder;
      joints[right ? Joint.elbowR : Joint.elbowL] = elbow;
      joints[right ? Joint.handR : Joint.handL] =
          elbow + foreDir * forearmLength;

      // Front of the thigh: perpendicular to the thigh inside the leg plane.
      final thighFront =
          (bend - thighDir * bend.dot(thighDir)).normalized;
      final shankDir = (ankle - knee).normalized;
      final side = Vec3(s, 0, 0);

      // --- Body surface -------------------------------------------------
      // Torso: narrow waist flaring into the lats and chest (V-taper).
      seg(pelvis + up * 0.05 + side * 0.050, 0.092,
          pelvis + up * 0.20 + side * 0.050, 0.082);
      seg(pelvis + up * 0.20 + side * 0.050, 0.082,
          pelvis + up * 0.39 + side * 0.105, 0.112);
      seg(pelvis + up * 0.39 + side * 0.105, 0.112,
          shoulder - side * 0.045, 0.078);
      // Trapezius.
      seg(neck + up * 0.025, 0.056,
          shoulder - side * 0.03 + up * 0.02, 0.056);
      // Pectoral.
      seg(pelvis + up * 0.375 + side * 0.070 + front * 0.070, 0.072,
          pelvis + up * 0.395 + side * 0.135 + front * 0.050, 0.058,
          def: true);
      // Thigh, knee cap, calf, foot.
      seg(hip + thighDir * 0.02, 0.106, knee - thighDir * 0.06, 0.068);
      seg(knee, 0.060, knee, 0.060, def: true);
      final calfBack =
          (thighFront - shankDir * thighFront.dot(shankDir)).normalized *
              -1.0;
      final calfBelly = knee + shankDir * 0.15 + calfBack * 0.022;
      seg(knee + shankDir * 0.03, 0.056, calfBelly, 0.068);
      seg(calfBelly, 0.068, ankle - shankDir * 0.02, 0.038);
      seg(ankle, 0.040, ankle, 0.040);
      seg(sole - pole * 0.06, 0.040, sole + pole * 0.17, 0.032);
      // Deltoid, upper arm with biceps bulge, forearm, hand.
      final hand = elbow + foreDir * forearmLength;
      seg(shoulder, 0.080, shoulder + upperDir * 0.03, 0.070, def: true);
      seg(shoulder + upperDir * 0.04, 0.060,
          shoulder + upperDir * 0.14, 0.066);
      seg(shoulder + upperDir * 0.14, 0.066, elbow, 0.046);
      seg(elbow, 0.047, elbow + foreDir * 0.08, 0.053);
      seg(elbow + foreDir * 0.08, 0.053, hand - foreDir * 0.03, 0.034);
      seg(hand, 0.042, hand, 0.038);

      // --- Highlighted muscle groups -------------------------------------
      muscles.add(MuscleSegment(
        MuscleGroup.quadriceps,
        hip + thighDir * 0.09 + thighFront * 0.050,
        knee - thighDir * 0.07 + thighFront * 0.036,
        0.062,
      ));
      muscles.add(MuscleSegment(
        MuscleGroup.hamstrings,
        hip + thighDir * 0.10 - thighFront * 0.050,
        knee - thighDir * 0.08 - thighFront * 0.034,
        0.054,
      ));
      muscles.add(MuscleSegment(
        MuscleGroup.glutes,
        hip - front * 0.070 + up * 0.03,
        hip - front * 0.062 + thighDir * 0.07 - thighFront * 0.02,
        0.100,
      ));
      // Spinal erectors, one strip each side of the spine.
      muscles.add(MuscleSegment(
        MuscleGroup.core,
        pelvis + up * 0.10 - front * 0.066 + side * 0.035,
        pelvis + up * 0.34 - front * 0.078 + side * 0.035,
        0.030,
      ));
      // Rectus abdominis ("six-pack") and obliques.
      for (final h in [0.105, 0.175, 0.245]) {
        final c = pelvis + up * h + side * 0.037 + front * 0.070;
        muscles.add(MuscleSegment(MuscleGroup.core, c, c, 0.033));
      }
      muscles.add(MuscleSegment(
        MuscleGroup.core,
        pelvis + up * 0.10 + side * 0.105 + front * 0.020,
        pelvis + up * 0.24 + side * 0.110 + front * 0.030,
        0.025,
      ));

      if (right) {
        kneeFlexion = 180 - Vec3.angleDeg(hip - knee, ankle - knee);
        hipFlexion = 180 - Vec3.angleDeg(neck - pelvis, knee - hip);
      }
    }

    // Pelvis block joining the two hips.
    seg(pelvis + Vec3(-hipHalfWidth, 0, 0) + up * 0.01, 0.105,
        pelvis + Vec3(hipHalfWidth, 0, 0) + up * 0.01, 0.105);

    return SquatPose(
      depth: d,
      joints: joints,
      body: body,
      muscles: muscles,
      kneeFlexionDeg: kneeFlexion,
      hipFlexionDeg: hipFlexion,
      torsoLeanDeg: lean * 180 / math.pi,
    );
  }
}
