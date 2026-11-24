import 'package:flutter_test/flutter_test.dart';
import 'package:gympath/services/firmware_auto_check.dart';

void main() {
  test('offers only a newer version, once per run', () {
    expect(FirmwareAutoCheck.shouldOffer('1.2.2', '1.2.3', {}), isTrue);
    expect(FirmwareAutoCheck.shouldOffer('1.2.3', '1.2.3', {}), isFalse);
    expect(FirmwareAutoCheck.shouldOffer('1.3.0', '1.2.3', {}), isFalse);
    expect(FirmwareAutoCheck.shouldOffer('1.2.2', '1.2.3', {'1.2.3'}), isFalse);
    // version unknown (could not be read): ask nothing
    expect(FirmwareAutoCheck.shouldOffer(null, '1.2.3', {}), isFalse);
    expect(FirmwareAutoCheck.shouldOffer('', '1.2.3', {}), isFalse);
  });
}
