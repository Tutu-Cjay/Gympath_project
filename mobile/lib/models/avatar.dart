import 'dart:math' as math;
import 'dart:ui' show Color;

/// A preset colour shown as a swatch.
class AvatarSwatch {
  final String name;
  final Color color;
  const AvatarSwatch(this.name, this.color);
}

/// A named option whose [id] is a material (or morph target) in the model.
class AvatarOption {
  final String name;
  final String id;
  const AvatarOption(this.name, this.id);
}

enum AvatarSex { male, female }

/// The user's avatar: a realistic head (MakeHuman) on the body of their sex.
///
/// Kept on the phone for now (AvatarStore). [toJson] is the format to sync
/// to a server later; ids are the material / morph names in the 3D models,
/// so they stay stable when options are added.
class Avatar {
  final AvatarSex sex;
  final int skinTone; // index into [skinTones]
  final String face; // id from [faceShapes]
  final int eyeColor; // index into [eyeColors]
  final String brows; // id from [browStyles]
  final String hair; // id from [hairStylesFor(sex)]
  final int hairColor; // index into [hairColors]
  final String beard; // id from [beardStyles]; male only
  final String glasses; // id from [glassesStyles]

  const Avatar({
    this.sex = AvatarSex.male,
    this.skinTone = 1,
    this.face = 'Oval',
    this.eyeColor = 0,
    this.brows = 'brows_thick',
    this.hair = 'hair_short',
    this.hairColor = 0,
    this.beard = 'none',
    this.glasses = 'none',
  });

  static const Avatar standard = Avatar();
  static const Avatar standardFemale = Avatar(
      sex: AvatarSex.female, hair: 'hair_bob', brows: 'brows_thin');

  static const List<AvatarSwatch> skinTones = [
    AvatarSwatch('Graphite', Color(0xFF959AA2)),
    AvatarSwatch('Light', Color(0xFFF1C7A8)),
    AvatarSwatch('Fair', Color(0xFFD9A07A)),
    AvatarSwatch('Tan', Color(0xFFB97E57)),
    AvatarSwatch('Brown', Color(0xFF8D5A3B)),
    AvatarSwatch('Deep', Color(0xFF5C3A26)),
  ];

  static const List<AvatarOption> faceShapes = [
    AvatarOption('Oval', 'Oval'),
    AvatarOption('Round', 'FaceRound'),
    AvatarOption('Square', 'FaceSquare'),
    AvatarOption('Long', 'FaceLong'),
    AvatarOption('Heart', 'FaceHeart'),
  ];

  static const List<AvatarSwatch> eyeColors = [
    AvatarSwatch('Brown', Color(0xFF6B4A30)),
    AvatarSwatch('Dark', Color(0xFF2E2018)),
    AvatarSwatch('Hazel', Color(0xFF8E7A3A)),
    AvatarSwatch('Green', Color(0xFF3A7D44)),
    AvatarSwatch('Blue', Color(0xFF2E6DA4)),
    AvatarSwatch('Grey', Color(0xFF7C8A96)),
  ];

  static const List<AvatarOption> browStyles = [
    AvatarOption('Thin', 'brows_thin'),
    AvatarOption('Thick', 'brows_thick'),
  ];

  static const List<AvatarOption> maleHair = [
    AvatarOption('None', 'none'),
    AvatarOption('Buzz', 'hair_buzz'),
    AvatarOption('Short', 'hair_short'),
    AvatarOption('Side part', 'hair_side'),
    AvatarOption('Curly', 'hair_curly'),
  ];

  static const List<AvatarOption> femaleHair = [
    AvatarOption('Pixie', 'hair_pixie'),
    AvatarOption('Bob', 'hair_bob'),
    AvatarOption('Long', 'hair_long'),
    AvatarOption('Ponytail', 'hair_ponytail'),
    AvatarOption('Bun', 'hair_bun'),
    AvatarOption('None', 'none'),
  ];

  static List<AvatarOption> hairStylesFor(AvatarSex sex) =>
      sex == AvatarSex.male ? maleHair : femaleHair;

  static const List<AvatarSwatch> hairColors = [
    AvatarSwatch('Black', Color(0xFF1C1A18)),
    AvatarSwatch('Dark brown', Color(0xFF3B2A20)),
    AvatarSwatch('Brown', Color(0xFF6B4A30)),
    AvatarSwatch('Auburn', Color(0xFF7A3B22)),
    AvatarSwatch('Blonde', Color(0xFFC8A46A)),
    AvatarSwatch('Grey', Color(0xFF9A9A9A)),
  ];

  static const List<AvatarOption> beardStyles = [
    AvatarOption('None', 'none'),
    AvatarOption('Stubble', 'beard_stubble'),
    AvatarOption('Full', 'beard_full'),
  ];

  static const List<AvatarOption> glassesStyles = [
    AvatarOption('None', 'none'),
    AvatarOption('Round', 'glasses_round'),
    AvatarOption('Square', 'glasses_square'),
  ];

  Avatar copyWith({
    AvatarSex? sex,
    int? skinTone,
    String? face,
    int? eyeColor,
    String? brows,
    String? hair,
    int? hairColor,
    String? beard,
    String? glasses,
  }) =>
      Avatar(
        sex: sex ?? this.sex,
        skinTone: skinTone ?? this.skinTone,
        face: face ?? this.face,
        eyeColor: eyeColor ?? this.eyeColor,
        brows: brows ?? this.brows,
        hair: hair ?? this.hair,
        hairColor: hairColor ?? this.hairColor,
        beard: beard ?? this.beard,
        glasses: glasses ?? this.glasses,
      );

  /// Switch sex, keeping what carries over (skin, eyes, face, glasses,
  /// colours) and picking that sex's default hair if the current one is not
  /// in its set.
  Avatar withSex(AvatarSex s) {
    if (s == sex) return this;
    final fallback = s == AvatarSex.male ? standard : standardFemale;
    final hairOk = hairStylesFor(s).any((o) => o.id == hair);
    return copyWith(
      sex: s,
      hair: hairOk ? hair : fallback.hair,
      brows: fallback.brows,
      beard: 'none',
    );
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
        'face': face,
        'eyeColor': linear(eyeColors[eyeColor].color),
        'brows': brows,
        'hair': hair,
        'hairColor': linear(hairColors[hairColor].color),
        'beard': sex == AvatarSex.male ? beard : 'none',
        'glasses': glasses,
      };

  @override
  bool operator ==(Object other) =>
      other is Avatar &&
      other.sex == sex &&
      other.skinTone == skinTone &&
      other.face == face &&
      other.eyeColor == eyeColor &&
      other.brows == brows &&
      other.hair == hair &&
      other.hairColor == hairColor &&
      other.beard == beard &&
      other.glasses == glasses;

  @override
  int get hashCode => Object.hash(
      sex, skinTone, face, eyeColor, brows, hair, hairColor, beard, glasses);

  Map<String, dynamic> toJson() => {
        'version': 2,
        'sex': sex.name,
        'skinTone': skinTone,
        'face': face,
        'eyeColor': eyeColor,
        'brows': brows,
        'hair': hair,
        'hairColor': hairColor,
        'beard': beard,
        'glasses': glasses,
      };

  /// Unknown or out-of-range values (and settings saved by older versions)
  /// fall back to the defaults.
  factory Avatar.fromJson(Map<String, dynamic> j) {
    final sex = j['sex'] == 'female' ? AvatarSex.female : AvatarSex.male;
    final base = sex == AvatarSex.male ? standard : standardFemale;
    int index(String k, int count, int fallback) {
      final v = j[k];
      return v is int && v >= 0 && v < count ? v : fallback;
    }

    String pick(String k, List<AvatarOption> options, String fallback) {
      final v = j[k];
      return v is String && options.any((o) => o.id == v) ? v : fallback;
    }

    return Avatar(
      sex: sex,
      skinTone: index('skinTone', skinTones.length, base.skinTone),
      face: pick('face', faceShapes, base.face),
      eyeColor: index('eyeColor', eyeColors.length, base.eyeColor),
      brows: pick('brows', browStyles, base.brows),
      hair: pick('hair', hairStylesFor(sex), base.hair),
      hairColor: index('hairColor', hairColors.length, base.hairColor),
      beard: sex == AvatarSex.male ? pick('beard', beardStyles, 'none') : 'none',
      glasses: pick('glasses', glassesStyles, 'none'),
    );
  }
}
