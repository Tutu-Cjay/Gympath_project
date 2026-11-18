import 'package:flutter_test/flutter_test.dart';
import 'package:gympath/models/avatar.dart';

void main() {
  test('JSON round trip for both sexes', () {
    const m = Avatar(skinTone: 4, face: 'FaceSquare', eyeColor: 4, hair: 'hair_side',
        hairColor: 3, beard: 'beard_full', glasses: 'glasses_round');
    expect(Avatar.fromJson(m.toJson()), m);
    const f = Avatar(sex: AvatarSex.female, hair: 'hair_ponytail', brows: 'brows_thin');
    expect(Avatar.fromJson(f.toJson()), f);
    expect(f.toJson()['sex'], 'female');
  });

  test('bad and old values fall back to the defaults', () {
    final bad = Avatar.fromJson({
      'sex': 'female', 'skinTone': 99, 'face': 'Triangle', 'hair': 'hair_side',
      'beard': 'beard_full', 'eyeColor': -1,
    });
    expect(bad.sex, AvatarSex.female);
    expect(bad.skinTone, Avatar.standardFemale.skinTone);
    expect(bad.face, 'Oval');
    expect(bad.hair, Avatar.standardFemale.hair); // a male style
    expect(bad.beard, 'none');
    // Saved by the head-only avatar of the previous version.
    final old = Avatar.fromJson({'skinTone': 2, 'hair': 2, 'hairColor': 1});
    expect(old.sex, AvatarSex.male);
    expect(old.skinTone, 2);
    expect(old.hair, Avatar.standard.hair);
  });

  test('switching sex keeps what carries over', () {
    const m = Avatar(skinTone: 3, eyeColor: 3, glasses: 'glasses_square',
        hair: 'hair_curly', beard: 'beard_full');
    final f = m.withSex(AvatarSex.female);
    expect(f.skinTone, 3);
    expect(f.eyeColor, 3);
    expect(f.glasses, 'glasses_square');
    expect(Avatar.femaleHair.map((o) => o.id), contains(f.hair));
    expect(f.beard, 'none');
    expect(f.toJs()['beard'], 'none');
    // "none" exists for both, so it is kept.
    expect(m.copyWith(hair: 'none').withSex(AvatarSex.female).hair, 'none');
  });

  test('what the 3D page gets', () {
    final js = const Avatar(skinTone: 1, eyeColor: 4).toJs();
    expect((js['skin']! as List<double>)[0], closeTo(0.88, 0.01));
    expect((js['eyeColor']! as List<double>)[2], greaterThan(0.3)); // blue
    expect(js['hair'], 'hair_short');
    expect(js['face'], 'Oval');
    for (final o in [...Avatar.maleHair, ...Avatar.femaleHair]) {
      expect(o.id == 'none' || o.id.startsWith('hair_'), isTrue);
    }
  });
}
