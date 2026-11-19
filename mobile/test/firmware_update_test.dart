import 'package:flutter_test/flutter_test.dart';
import 'package:gympath/services/ble_service.dart';
import 'package:gympath/services/firmware_update_service.dart';

void main() {
  group('FirmwareUpdateService.isNewer', () {
    test('detects newer patch/minor/major', () {
      expect(FirmwareUpdateService.isNewer('1.0.1', '1.0.0'), isTrue);
      expect(FirmwareUpdateService.isNewer('1.1.0', '1.0.9'), isTrue);
      expect(FirmwareUpdateService.isNewer('2.0.0', '1.9.9'), isTrue);
    });
    test('same or older is not newer', () {
      expect(FirmwareUpdateService.isNewer('1.0.0', '1.0.0'), isFalse);
      expect(FirmwareUpdateService.isNewer('1.0.0', '1.0.1'), isFalse);
      expect(FirmwareUpdateService.isNewer('1.9.9', '2.0.0'), isFalse);
    });
    test('numeric, not lexical (1.10 > 1.9)', () {
      expect(FirmwareUpdateService.isNewer('1.10.0', '1.9.0'), isTrue);
    });
    test('tolerates missing parts and suffixes', () {
      expect(FirmwareUpdateService.isNewer('1.1', '1.0.5'), isTrue);
      expect(FirmwareUpdateService.isNewer('1.0.0', '1.0'), isFalse);
      expect(FirmwareUpdateService.isNewer('1.0.1-beta', '1.0.0'), isTrue);
    });
  });

  test('manifest parses the published JSON shape', () {
    final m = FirmwareManifest.fromJson({
      'version': '1.0.0',
      'url': 'https://tutu-cjay.github.io/firmware/gympath_track-1.0.0.bin',
      'size': 535120,
      'md5': 'B710B23AE09C4F21451839AAFF39E02C',
      'notes': 'n',
    });
    expect(m.version, '1.0.0');
    expect(m.size, 535120);
    expect(m.md5, 'b710b23ae09c4f21451839aaff39e02c'); // normalised to lower
    expect(m.url.host, 'tutu-cjay.github.io');
  });

  test('OTA chunks fit a 512-byte characteristic value with the op byte', () {
    expect(BleService.otaChunkFor(517), 511);
    expect(BleService.otaChunkFor(512), 508);
    expect(BleService.otaChunkFor(185), 181);
    expect(BleService.otaChunkFor(23), 20);
  });

  test('the CI release is checked first for new firmware', () {
    expect(FirmwareUpdateService.manifestUrls.first.path,
        endsWith('/releases/download/firmware-latest/manifest.json'));
  });
}
