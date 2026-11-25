import 'package:flutter_test/flutter_test.dart';
import 'package:gympath/models/avatar.dart';

void main() {
  test('JSON round trip for both sexes', () {
    const m = Avatar(skinTone: 4, eyeColor: 4, hair: 'hair_buzz', hairColor: 3);
    expect(Avatar.fromJson(m.toJson()), m);
    const f = Avatar(sex: AvatarSex.female, hair: 'hair_bun', eyeColor: 3);
    expect(Avatar.fromJson(f.toJson()), f);
    expect(f.toJson()['sex'], 'female');
  });

  test('bad values fall back to the defaults', () {
    final bad = Avatar.fromJson({
      'sex': 'female', 'skinTone': 99, 'hair': 'hair_buzz', 'eyeColor': -1,
    });
    expect(bad.sex, AvatarSex.female);
    expect(bad.skinTone, Avatar.standardFemale.skinTone);
    expect(bad.eyeColor, Avatar.standardFemale.eyeColor);
    expect(bad.hair, Avatar.standardFemale.hair); // a male style
  });

  test('avatars saved by the previous version still load', () {
    final old = Avatar.fromJson({'skinTone': 2, 'hair': 1, 'hairColor': 3});
    expect(old.sex, AvatarSex.male);
    expect(old.skinTone, 2);
    expect(old.hair, 'hair_buzz');
    expect(old.hairColor, 3);
    expect(old.eyeColor, 0);
  });

  test('switching body keeps colours, and hair when it exists for both', () {
    const m = Avatar(skinTone: 3, eyeColor: 3, hair: 'hair_short', hairColor: 2);
    final f = m.withSex(AvatarSex.female);
    expect(f.skinTone, 3);
    expect(f.eyeColor, 3);
    expect(f.hairColor, 2);
    expect(Avatar.femaleHair.map((o) => o.id), contains(f.hair));
    expect(m.copyWith(hair: 'none').withSex(AvatarSex.female).hair, 'hair_bun');
    expect(f.withSex(AvatarSex.male).hair, Avatar.standard.hair);
  });

  test('what the 3D page gets', () {
    final js = const Avatar(skinTone: 1, eyeColor: 4).toJs();
    expect((js['skin']! as List<double>)[0], closeTo(0.88, 0.01));
    expect((js['eyeColor']! as List<double>)[2], greaterThan(0.3)); // blue
    expect(js['hair'], 'hair_short');
    for (final o in [...Avatar.maleHair, ...Avatar.femaleHair]) {
      expect(o.id == 'none' || o.id.startsWith('hair_'), isTrue);
    }
  });

  test('body shape sliders', () {
    final a = const Avatar().withBody('Muscle', 0.7).withBody('Waist', -2);
    expect(a.bodyValue('Muscle'), 0.7);
    expect(a.bodyValue('Waist'), -1); // clamped to the slider
    expect(a.bodyValue('Chest'), 0);
    final back = Avatar.fromJson(a.toJson());
    expect(back, a);
    expect((a.toJs()['body']! as Map)['Muscle'], 0.7);
    expect(a.withBody('Muscle', 0).withBody('Waist', 0), const Avatar());
    // Junk and out-of-range values from storage.
    final j = Avatar.fromJson({'body': {'Muscle': 9, 'Chest': 'big', 'Height': 1}});
    expect(j.bodyValue('Muscle'), 1);
    expect(j.body.containsKey('Chest'), isFalse);
    expect(j.body.containsKey('Height'), isFalse);
  });

  test('body shape picks the clip fitted to it, rounding up', () {
    const a = Avatar();
    expect(a.shapeLevel, 0);
    expect(a.clip('LatPulldown'), 'LatPulldown');
    expect(a.withBody('Muscle', -0.5).shapeLevel, 0); // slimmer: the base fits
    expect(a.withBody('BodyFat', 0.2).shapeLevel, 1);
    expect(a.withBody('BodyFat', 0.5).shapeLevel, 1);
    expect(a.withBody('Chest', 0.51).shapeLevel, 2);
    final big = a.withBody('Muscle', 1).withBody('Waist', 0.3);
    expect(big.shapeLevel, 2);
    expect(big.clip('LatPulldown'), 'LatPulldown@2');
    expect(big.toJs()['level'], 2);
  });
}
