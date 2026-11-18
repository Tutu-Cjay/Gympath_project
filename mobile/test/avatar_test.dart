import 'package:flutter_test/flutter_test.dart';
import 'package:gympath/models/avatar.dart';

void main() {
  test('JSON round trip; bad and old values fall back', () {
    const a = Avatar(skinTone: 4, hair: 1, hairColor: 3);
    expect(Avatar.fromJson(a.toJson()), a);
    final bad = Avatar.fromJson({'skinTone': 99, 'hair': -1, 'hairColor': 'x'});
    expect(bad, Avatar.standard);
    // Saved by the earlier body-shape version of the avatar.
    final old = Avatar.fromJson({'muscle': 0.8, 'fat': 0.2, 'skinTone': 2, 'shorts': 1});
    expect(old.skinTone, 2);
    expect(old.hair, Avatar.standard.hair);
  });

  test('what the 3D page gets', () {
    final js = const Avatar(skinTone: 1, hair: 0, hairColor: 2).toJs();
    expect(js['hair'], 'none');
    final skin = js['skin']! as List<double>;
    // The light tone 0xF1 (241) is about 0.88 in linear light.
    expect(skin[0], closeTo(0.88, 0.01));
    expect(const Avatar(hair: 2).toJs()['hair'], 'hair_short');
    for (final s in Avatar.hairStyles.skip(1)) {
      expect(s.id, startsWith('hair_'));
    }
  });
}
