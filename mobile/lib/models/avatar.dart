import 'dart:math' as math;
import 'dart:ui' show Color;

/// A preset colour shown as a swatch.
class AvatarSwatch {
  final String name;
  final Color color;
  const AvatarSwatch(this.name, this.color);
}

/// The user's figure in the 3D views: build, skin tone, shorts and how much
/// of the muscles shows through the skin.
class Avatar {
  /// Muscle mass, 0 = slim .. 1 = bodybuilder (the model's Muscular key).
  final double muscle;

  /// Body fat, 0 = lean .. 1 = soft (the model's BodyFat key).
  final double fat;

  /// How see-through the skin is: 0 = solid .. 1 = muscles fully visible.
  final double seeThrough;

  final int skinTone; // index into [skinTones]
  final int shorts; // index into [shortsColors]

  const Avatar({
    this.muscle = 0.45,
    this.fat = 0.15,
    this.seeThrough = 0.55,
    this.skinTone = 0,
    this.shorts = 0,
  });

  static const Avatar standard = Avatar();

  /// The first tone is the app's stylised graphite figure.
  static const List<AvatarSwatch> skinTones = [
    AvatarSwatch('Graphite', Color(0xFF959AA2)),
    AvatarSwatch('Light', Color(0xFFF1C7A8)),
    AvatarSwatch('Fair', Color(0xFFD9A07A)),
    AvatarSwatch('Tan', Color(0xFFB97E57)),
    AvatarSwatch('Brown', Color(0xFF8D5A3B)),
    AvatarSwatch('Deep', Color(0xFF5C3A26)),
  ];

  static const List<AvatarSwatch> shortsColors = [
    AvatarSwatch('Black', Color(0xFF3E4148)),
    AvatarSwatch('Navy', Color(0xFF2B3A67)),
    AvatarSwatch('Grey', Color(0xFF7D828B)),
    AvatarSwatch('Neon', Color(0xFF00E676)),
    AvatarSwatch('Red', Color(0xFFD7263D)),
  ];

  Avatar copyWith({
    double? muscle,
    double? fat,
    double? seeThrough,
    int? skinTone,
    int? shorts,
  }) =>
      Avatar(
        muscle: muscle ?? this.muscle,
        fat: fat ?? this.fat,
        seeThrough: seeThrough ?? this.seeThrough,
        skinTone: skinTone ?? this.skinTone,
        shorts: shorts ?? this.shorts,
      );

  /// sRGB swatch colour to the linear factor glTF materials use.
  static List<double> linear(Color c) {
    double ch(double v) => v <= 0.04045
        ? v / 12.92
        : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
    double r(double v) => (ch(v) * 1000).round() / 1000;
    return [r(c.r), r(c.g), r(c.b)];
  }

  /// Skin opacity in the 3D view. Even "fully see-through" keeps a hint of
  /// skin so the outline stays; body fat covers the muscles, as it does.
  double get skinAlpha {
    final base = 0.9 - 0.75 * seeThrough.clamp(0.0, 1.0);
    return base + (1 - base) * 0.6 * fat.clamp(0.0, 1.0);
  }

  /// What the 3D page needs (see AnatomyViewer).
  Map<String, Object> toJs() => {
        'muscle': muscle.clamp(0.0, 1.0),
        'fat': fat.clamp(0.0, 1.0),
        'skinAlpha': skinAlpha,
        'skin': linear(skinTones[skinTone.clamp(0, skinTones.length - 1)].color),
        'shorts': linear(shortsColors[shorts.clamp(0, shortsColors.length - 1)].color),
      };

  @override
  bool operator ==(Object other) =>
      other is Avatar &&
      other.muscle == muscle &&
      other.fat == fat &&
      other.seeThrough == seeThrough &&
      other.skinTone == skinTone &&
      other.shorts == shorts;

  @override
  int get hashCode => Object.hash(muscle, fat, seeThrough, skinTone, shorts);

  Map<String, dynamic> toJson() => {
        'muscle': muscle,
        'fat': fat,
        'seeThrough': seeThrough,
        'skinTone': skinTone,
        'shorts': shorts,
      };

  factory Avatar.fromJson(Map<String, dynamic> j) {
    double d(String k, double fallback) =>
        j[k] is num ? (j[k] as num).toDouble().clamp(0.0, 1.0) : fallback;
    int i(String k, int max) =>
        j[k] is int ? (j[k] as int).clamp(0, max - 1) : 0;
    return Avatar(
      muscle: d('muscle', standard.muscle),
      fat: d('fat', standard.fat),
      seeThrough: d('seeThrough', standard.seeThrough),
      skinTone: i('skinTone', skinTones.length),
      shorts: i('shorts', shortsColors.length),
    );
  }
}
