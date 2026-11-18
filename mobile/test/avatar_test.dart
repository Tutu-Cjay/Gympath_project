import 'package:flutter_test/flutter_test.dart';
import 'package:gympath/models/avatar.dart';

void main() {
  test('JSON round trip and bad values', () {
    const a = Avatar(muscle: 0.8, fat: 0.1, seeThrough: 0.3, skinTone: 4, shorts: 2);
    expect(Avatar.fromJson(a.toJson()), a);
    final bad = Avatar.fromJson({'muscle': 7, 'fat': 'x', 'skinTone': 99, 'shorts': -3});
    expect(bad.muscle, 1.0);
    expect(bad.fat, Avatar.standard.fat);
    expect(bad.skinTone, Avatar.skinTones.length - 1);
    expect(bad.shorts, 0);
  });

  test('skin opacity: see-through lowers it, body fat raises it', () {
    expect(const Avatar(seeThrough: 0, fat: 0).skinAlpha, closeTo(0.9, 1e-9));
    expect(const Avatar(seeThrough: 1, fat: 0).skinAlpha, closeTo(0.15, 1e-9));
    expect(const Avatar(seeThrough: 1, fat: 1).skinAlpha,
        greaterThan(const Avatar(seeThrough: 1, fat: 0).skinAlpha));
    expect(const Avatar(seeThrough: 0, fat: 1).skinAlpha, lessThanOrEqualTo(1));
  });

  test('swatches become linear colour factors for the 3D page', () {
    final js = const Avatar(skinTone: 0, shorts: 3).toJs();
    final skin = js['skin']! as List<double>;
    expect(skin, hasLength(3));
    for (final c in skin) {
      expect(c, inInclusiveRange(0, 1));
    }
    // sRGB 0x95 (149) is about 0.30 in linear light.
    expect(skin[0], closeTo(0.30, 0.01));
    // The light tone 0xF1 (241) is about 0.88.
    expect(Avatar.linear(Avatar.skinTones[1].color)[0], closeTo(0.88, 0.01));
  });
}
