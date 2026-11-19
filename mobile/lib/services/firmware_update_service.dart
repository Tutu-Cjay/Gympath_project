import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'ble_service.dart';

/// Latest tracker firmware, published by the firmware CI
/// (.github/workflows/firmware.yml) as the `firmware-latest` release.
class FirmwareManifest {
  final String version;
  final Uri url;
  final int size;
  final String md5; // hex
  final String notes;

  const FirmwareManifest({
    required this.version,
    required this.url,
    required this.size,
    required this.md5,
    required this.notes,
  });

  factory FirmwareManifest.fromJson(Map<String, dynamic> j) => FirmwareManifest(
        version: j['version'] as String,
        url: Uri.parse(j['url'] as String),
        size: (j['size'] as num).toInt(),
        md5: (j['md5'] as String).toLowerCase(),
        notes: (j['notes'] ?? '') as String,
      );
}

/// Over-the-air firmware update through the phone (BLE), see the OTA section
/// of firmware/Gympath_Track: BEGIN [1, size, md5] → DATA [2, …] → END [3].
class FirmwareUpdateService {
  FirmwareUpdateService._();
  static final FirmwareUpdateService instance = FirmwareUpdateService._();

  /// Where the newest manifest is looked for, in order: the CI release,
  /// then the website the first builds were published on.
  static final List<Uri> manifestUrls = [
    Uri.parse('https://github.com/Tutu-Cjay/Gympath_project/releases/download/'
        'firmware-latest/manifest.json'),
    Uri.parse('https://tutu-cjay.github.io/firmware/manifest.json'),
  ];

  final BleService _ble = BleService.instance;

  Future<FirmwareManifest> fetchManifest() async {
    Object? lastError;
    for (final url in manifestUrls) {
      try {
        final r = await http
            .get(url, headers: {'Cache-Control': 'no-cache'})
            .timeout(const Duration(seconds: 15));
        if (r.statusCode != 200) {
          lastError = Exception('Update server returned ${r.statusCode}');
          continue;
        }
        return FirmwareManifest.fromJson(
            jsonDecode(r.body) as Map<String, dynamic>);
      } catch (e) {
        lastError = e;
      }
    }
    throw lastError ?? Exception('No update server reachable');
  }

  /// true when [latest] is newer than [current] (dotted numeric versions).
  static bool isNewer(String latest, String current) {
    List<int> parts(String v) => v
        .split('.')
        .map((p) => int.tryParse(p.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0)
        .toList();
    final a = parts(latest), b = parts(current);
    for (int i = 0; i < 3; i++) {
      final x = i < a.length ? a[i] : 0, y = i < b.length ? b[i] : 0;
      if (x != y) return x > y;
    }
    return false;
  }

  /// Download the image and verify it against the manifest before flashing.
  Future<Uint8List> download(FirmwareManifest m) async {
    final r = await http.get(m.url).timeout(const Duration(seconds: 60));
    if (r.statusCode != 200) {
      throw Exception('Download failed (${r.statusCode})');
    }
    final bytes = r.bodyBytes;
    if (bytes.length != m.size) {
      throw Exception('Downloaded size ${bytes.length} ≠ ${m.size}');
    }
    if (md5.convert(bytes).toString() != m.md5) {
      throw Exception('Downloaded file is corrupted (MD5 mismatch)');
    }
    return bytes;
  }

  /// Stream the image to the device. [onProgress] gets 0..1.
  Future<void> flash(Uint8List image,
      {required void Function(double) onProgress}) async {
    await _ble.requestHighThroughput();

    // listen for the device's status notifications; an error the device
    // reports while chunks are going out stops the transfer right away
    final statuses = StreamController<List<int>>.broadcast();
    int? deviceError;
    final sub = _ble.otaStatus.listen((s) {
      if (s.isNotEmpty && s[0] == 3) deviceError = s.length > 1 ? s[1] : 0;
      statuses.add(s);
    });
    Future<List<int>> waitState(int want, Duration timeout) =>
        statuses.stream.firstWhere((s) {
          if (s.isNotEmpty && s[0] == 3) {
            throw Exception(_errText(s.length > 1 ? s[1] : 0));
          }
          return s.isNotEmpty && s[0] == want;
        }).timeout(timeout);

    Future<List<int>>? pending; // a status wait that may outlive a failed write
    try {
      // BEGIN: [1, size u32 LE, md5 16 bytes]
      final begin = BytesBuilder()
        ..addByte(1)
        ..add((ByteData(4)..setUint32(0, image.length, Endian.little))
            .buffer
            .asUint8List())
        ..add(md5.convert(image).bytes);
      pending = waitState(1, const Duration(seconds: 10));
      await _ble.writeOta(begin.toBytes());
      await pending; // flash region erased and ready

      // DATA: [2, chunk…] — each write is acknowledged after it is flashed
      final chunk = _ble.otaChunkSize;
      for (int off = 0; off < image.length; off += chunk) {
        if (deviceError != null) throw Exception(_errText(deviceError!));
        final end = (off + chunk).clamp(0, image.length);
        await _ble.writeOta([2, ...image.sublist(off, end)]);
        onProgress(end / image.length);
      }

      // END: device checks MD5 + image, then reboots into the new firmware
      pending = waitState(2, const Duration(seconds: 20));
      await _ble.writeOta([3]);
      await pending;
    } catch (e) {
      pending?.ignore();
      try {
        await _ble.writeOta([4]); // ABORT — old firmware keeps running
      } catch (_) {}
      rethrow;
    } finally {
      await sub.cancel();
      await statuses.close();
    }
  }

  static String _errText(int code) {
    switch (code) {
      case 1:
        return 'Device rejected the update header';
      case 2:
        return 'Not enough space on the device for the update';
      case 3:
        return 'Writing to device flash failed';
      case 4:
        return 'Update verification failed (corrupted transfer)';
      case 5:
        return 'The update stalled and was cancelled. Keep the phone close and try again';
      default:
        return 'Device reported an update error';
    }
  }
}
