import 'dart:math' as math;
import 'dart:ui' show Color;

/// A preset colour shown as a swatch.
class AvatarSwatch {
  final String name;
  final Color color;
  const AvatarSwatch(this.name, this.color);
}

/// Hair styles; [id] is the material of that hair cap in the 3D model.
class HairStyle {
  final String name;
  final String id;
  const HairStyle(this.name, this.id);
}

/// The user's avatar. The body is the same for everyone (a normal build with
/// see-through skin, so the working muscles show); only the head is the
/// user's own: skin tone and hair.
class Avatar {
  final int skinTone; // index into [skinTones]
  final int hair; // index into [hairStyles]
  final int hairColor; // index into [hairColors]

  const Avatar({this.skinTone = 0, this.hair = 2, this.hairColor = 0});

  static const Avatar standard = Avatar();

  /// The first tone matches the app's graphite body.
  static const List<AvatarSwatch> skinTones = [
    AvatarSwatch('Graphite', Color(0xFF959AA2)),
    AvatarSwatch('Light', Color(0xFFF1C7A8)),
    AvatarSwatch('Fair', Color(0xFFD9A07A)),
    AvatarSwatch('Tan', Color(0xFFB97E57)),
    AvatarSwatch('Brown', Color(0xFF8D5A3B)),
    AvatarSwatch('Deep', Color(0xFF5C3A26)),
  ];

  static const List<HairStyle> hairStyles = [
    HairStyle('None', 'none'),
    HairStyle('Buzz', 'hair_buzz'),
    HairStyle('Short', 'hair_short'),
  ];

  static const List<AvatarSwatch> hairColors = [
    AvatarSwatch('Black', Color(0xFF1C1A18)),
    AvatarSwatch('Dark brown', Color(0xFF3B2A20)),
    AvatarSwatch('Brown', Color(0xFF6B4A30)),
    AvatarSwatch('Blonde', Color(0xFFC8A46A)),
    AvatarSwatch('Grey', Color(0xFF9A9A9A)),
  ];

  Avatar copyWith({int? skinTone, int? hair, int? hairColor}) => Avatar(
        skinTone: skinTone ?? this.skinTone,
        hair: hair ?? this.hair,
        hairColor: hairColor ?? this.hairColor,
      );

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
        'hair': hairStyles[hair].id,
        'hairColor': linear(hairColors[hairColor].color),
      };

  @override
  bool operator ==(Object other) =>
      other is Avatar &&
      other.skinTone == skinTone &&
      other.hair == hair &&
      other.hairColor == hairColor;

  @override
  int get hashCode => Object.hash(skinTone, hair, hairColor);

  Map<String, dynamic> toJson() =>
      {'skinTone': skinTone, 'hair': hair, 'hairColor': hairColor};

  /// Unknown or out-of-range values (or settings from older versions) fall
  /// back to the standard avatar.
  factory Avatar.fromJson(Map<String, dynamic> j) {
    int i(String k, int count, int fallback) {
      final v = j[k];
      return v is int && v >= 0 && v < count ? v : fallback;
    }

    return Avatar(
      skinTone: i('skinTone', skinTones.length, standard.skinTone),
      hair: i('hair', hairStyles.length, standard.hair),
      hairColor: i('hairColor', hairColors.length, standard.hairColor),
    );
  }
}
