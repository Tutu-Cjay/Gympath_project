import 'dart:math' as math;
import 'dart:ui' show Color;

/// A preset colour shown as a swatch.
class AvatarSwatch {
  final String name;
  final Color color;
  const AvatarSwatch(this.name, this.color);
}

/// A named option whose [id] is a material in the 3D model.
class AvatarOption {
  final String name;
  final String id;
  const AvatarOption(this.name, this.id);
}

enum AvatarSex { male, female }

/// The user's avatar. The body is the same for everyone of a sex (a normal
/// build with see-through skin, so the working muscles show); the head is
/// the user's own: skin tone, eye colour and hair.
///
/// Kept on the phone for now (AvatarStore). [toJson] is the format to sync
/// to a server later; ids are material names in the 3D models, so they stay
/// stable when options are added.
class Avatar {
  final AvatarSex sex;
  final int skinTone; // index into [skinTones]
  final int eyeColor; // index into [eyeColors]
  final String hair; // id from [hairStylesFor(sex)]
  final int hairColor; // index into [hairColors]

  const Avatar({
    this.sex = AvatarSex.male,
    this.skinTone = 0,
    this.eyeColor = 0,
    this.hair = 'hair_short',
    this.hairColor = 0,
  });

  static const Avatar standard = Avatar();
  static const Avatar standardFemale =
      Avatar(sex: AvatarSex.female, hair: 'hair_ponytail');

  /// The first tone matches the app's graphite body.
  static const List<AvatarSwatch> skinTones = [
    AvatarSwatch('Graphite', Color(0xFF959AA2)),
    AvatarSwatch('Light', Color(0xFFF1C7A8)),
    AvatarSwatch('Fair', Color(0xFFD9A07A)),
    AvatarSwatch('Tan', Color(0xFFB97E57)),
    AvatarSwatch('Brown', Color(0xFF8D5A3B)),
    AvatarSwatch('Deep', Color(0xFF5C3A26)),
  ];

  static const List<AvatarSwatch> eyeColors = [
    AvatarSwatch('Brown', Color(0xFF6B4A30)),
    AvatarSwatch('Dark', Color(0xFF2E2018)),
    AvatarSwatch('Hazel', Color(0xFF8E7A3A)),
    AvatarSwatch('Green', Color(0xFF3A7D44)),
    AvatarSwatch('Blue', Color(0xFF2E6DA4)),
    AvatarSwatch('Grey', Color(0xFF7C8A96)),
  ];

  static const List<AvatarOption> maleHair = [
    AvatarOption('None', 'none'),
    AvatarOption('Buzz', 'hair_buzz'),
    AvatarOption('Short', 'hair_short'),
  ];

  /// The female figure has one fixed look: a ponytail (its colour is still
  /// the user's).
  static const List<AvatarOption> femaleHair = [
    AvatarOption('Ponytail', 'hair_ponytail'),
  ];

  static List<AvatarOption> hairStylesFor(AvatarSex sex) =>
      sex == AvatarSex.male ? maleHair : femaleHair;

  // New colours go at the end: saved avatars keep their index.
  static const List<AvatarSwatch> hairColors = [
    AvatarSwatch('Black', Color(0xFF1C1A18)),
    AvatarSwatch('Dark brown', Color(0xFF3B2A20)),
    AvatarSwatch('Brown', Color(0xFF6B4A30)),
    AvatarSwatch('Blonde', Color(0xFFC8A46A)),
    AvatarSwatch('Grey', Color(0xFF9A9A9A)),
    AvatarSwatch('Auburn', Color(0xFF7A3B22)),
  ];

  Avatar copyWith({
    AvatarSex? sex,
    int? skinTone,
    int? eyeColor,
    String? hair,
    int? hairColor,
  }) =>
      Avatar(
        sex: sex ?? this.sex,
        skinTone: skinTone ?? this.skinTone,
        eyeColor: eyeColor ?? this.eyeColor,
        hair: hair ?? this.hair,
        hairColor: hairColor ?? this.hairColor,
      );

  /// Switch body, keeping the colours and picking that sex's default hair if
  /// the current style is not one of its own.
  Avatar withSex(AvatarSex s) {
    if (s == sex) return this;
    final ok = hairStylesFor(s).any((o) => o.id == hair);
    final fallback = s == AvatarSex.male ? standard : standardFemale;
    return copyWith(sex: s, hair: ok ? hair : fallback.hair);
  }

  /// sRGB swatch colour to the linear factor glTF materials use.
  static List<double> linear(Color c) {
    double ch(double v) => v <= 0.04045
        ? v / 12.92
        : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
    double r(double v) => (ch(v) * 1000).round() / 1000;
    return [r(c.r), r(c.g), r(c.b)];
  }

  /// What the 3D page needs (see AnatomyViewer).
  Map<String, Object> toJs() => {
        'skin': linear(skinTones[skinTone].color),
        'eyeColor': linear(eyeColors[eyeColor].color),
        'hair': hair,
        'hairColor': linear(hairColors[hairColor].color),
      };

  @override
  bool operator ==(Object other) =>
      other is Avatar &&
      other.sex == sex &&
      other.skinTone == skinTone &&
      other.eyeColor == eyeColor &&
      other.hair == hair &&
      other.hairColor == hairColor;

  @override
  int get hashCode => Object.hash(sex, skinTone, eyeColor, hair, hairColor);

  Map<String, dynamic> toJson() => {
        'version': 2,
        'sex': sex.name,
        'skinTone': skinTone,
        'eyeColor': eyeColor,
        'hair': hair,
        'hairColor': hairColor,
      };

  /// Unknown or out-of-range values fall back to the defaults. Version 1
  /// (male only, hair as an index into None / Buzz / Short) still loads.
  factory Avatar.fromJson(Map<String, dynamic> j) {
    final sex = j['sex'] == 'female' ? AvatarSex.female : AvatarSex.male;
    final base = sex == AvatarSex.male ? standard : standardFemale;
    int index(String k, int count, int fallback) {
      final v = j[k];
      return v is int && v >= 0 && v < count ? v : fallback;
    }

    final h = j['hair'];
    var hair = base.hair;
    if (h is String && hairStylesFor(sex).any((o) => o.id == h)) {
      hair = h;
    } else if (h is int && sex == AvatarSex.male && h >= 0 && h < maleHair.length) {
      hair = maleHair[h].id;
    }
    return Avatar(
      sex: sex,
      skinTone: index('skinTone', skinTones.length, base.skinTone),
      eyeColor: index('eyeColor', eyeColors.length, base.eyeColor),
      hair: hair,
      hairColor: index('hairColor', hairColors.length, base.hairColor),
    );
  }
}
