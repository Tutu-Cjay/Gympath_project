import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import '../models/motion_data.dart';

enum BleConnectionState { disconnected, scanning, connecting, connected, error }

/// BLE central for the Smart Tracker.
///
/// Matches the on-device firmware (not the older ble_protocol.md draft):
///   service `…cdef0`, motion notify `…cdef1` (60-byte MotionPacket; the v2
///   build extends it to 104), rep `…cdef2`, mean-velocity `…cdef3`.
/// Implements US1 (scan/connect/error+retry) and C4 (auto-reconnect).
class BleService {
  BleService._();
  static final BleService instance = BleService._();

  static const String serviceUuid = '12345678-1234-5678-1234-56789abcdef0';
  static const String motionUuid = '12345678-1234-5678-1234-56789abcdef1';
  static const String repUuid = '12345678-1234-5678-1234-56789abcdef2';
  static const String velocityUuid = '12345678-1234-5678-1234-56789abcdef3';

  static const int _maxReconnectAttempts = 5;

  final ValueNotifier<BleConnectionState> connectionState =
      ValueNotifier(BleConnectionState.disconnected);

  /// Human-readable reason for the last failure, for the UI to surface (US1).
  final ValueNotifier<String?> lastError = ValueNotifier<String?>(null);

  /// Count of motion notifications received — diagnostic for "no data" issues.
  final ValueNotifier<int> packetCount = ValueNotifier<int>(0);

  final StreamController<MotionData> _motionController =
      StreamController<MotionData>.broadcast();
  Stream<MotionData> get motionStream => _motionController.stream;

  BluetoothDevice? _device;
  BluetoothCharacteristic? _motionChar;
  StreamSubscription<List<int>>? _motionSub;
  StreamSubscription<BluetoothConnectionState>? _connSub;

  bool _userDisconnected = false; // distinguishes intentional disconnects
  bool _reconnecting = false;

  bool get isConnected =>
      connectionState.value == BleConnectionState.connected;

  Future<bool> connect() async {
    if (isConnected) return true;
    _userDisconnected = false;
    lastError.value = null;
    connectionState.value = BleConnectionState.scanning;

    final supported = await FlutterBluePlus.isSupported;
    if (!supported) {
      return _fail('Bluetooth is not supported on this device');
    }
    await _ensurePermissions();
    if (Platform.isAndroid) {
      try {
        await FlutterBluePlus.turnOn();
      } catch (_) {
        return _fail('Please turn on Bluetooth and try again');
      }
    }

    final device = await _scanForDevice();
    if (device == null) {
      return _fail('No Smart Tracker found nearby. Make sure it is on.');
    }

    connectionState.value = BleConnectionState.connecting;
    try {
      await device.connect(timeout: const Duration(seconds: 12));
    } catch (_) {
      // a timeout here often still ends up connected; fall through and verify
    }

    _device = device;
    _attachConnectionListener(device);

    // Larger MTU so the 60/104-byte motion packet fits one notification.
    if (Platform.isAndroid) {
      try {
        await device.requestMtu(247);
      } catch (_) {}
    }

    final ok = await _discoverAndSubscribe(device);
    if (ok) {
      connectionState.value = BleConnectionState.connected;
      lastError.value = null;
      return true;
    }
    return _fail('Connected but no motion service found');
  }

  bool _fail(String message) {
    lastError.value = message;
    connectionState.value = BleConnectionState.error;
    return false;
  }

  Future<void> disconnect() async {
    _userDisconnected = true; // suppress auto-reconnect
    await _motionSub?.cancel();
    _motionSub = null;
    await _connSub?.cancel();
    _connSub = null;
    if (_device != null) {
      try {
        await _device!.disconnect();
      } catch (_) {}
    }
    connectionState.value = BleConnectionState.disconnected;
  }

  void _attachConnectionListener(BluetoothDevice device) {
    _connSub?.cancel();
    _connSub = device.connectionState.listen((state) {
      if (state == BluetoothConnectionState.disconnected) {
        _motionSub?.cancel();
        _motionSub = null;
        connectionState.value = BleConnectionState.disconnected;
        // C4: automatic reconnection on an unexpected drop
        if (!_userDisconnected) {
          _attemptReconnect();
        }
      }
    });
  }

  Future<void> _attemptReconnect() async {
    if (_reconnecting || _userDisconnected) return;
    _reconnecting = true;
    for (int attempt = 1; attempt <= _maxReconnectAttempts; attempt++) {
      if (_userDisconnected) break;
      lastError.value = 'Reconnecting… ($attempt/$_maxReconnectAttempts)';
      final ok = await connect();
      if (ok) {
        _reconnecting = false;
        return;
      }
      // backoff: 2s, 4s, 6s, …
      await Future.delayed(Duration(seconds: 2 * attempt));
    }
    _reconnecting = false;
    if (!isConnected && !_userDisconnected) {
      _fail('Lost connection to Smart Tracker');
    }
  }

  Future<void> _ensurePermissions() async {
    if (!Platform.isAndroid) return;
    final permissions = <Permission>[
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.bluetoothAdvertise,
      Permission.locationWhenInUse,
    ];
    await permissions.request();
  }

  Future<BluetoothDevice?> _scanForDevice() async {
    BluetoothDevice? found;
    final completer = Completer<BluetoothDevice?>();
    final sub = FlutterBluePlus.scanResults.listen((results) {
      for (final result in results) {
        // H1: device.name is deprecated → platformName + advName fallback
        final name = (result.device.platformName.isNotEmpty
                ? result.device.platformName
                : result.advertisementData.advName)
            .toLowerCase();
        // H2: normalize both sides to lowercase for a case-insensitive match
        final uuids = result.advertisementData.serviceUuids
            .map((e) => e.toString().toLowerCase())
            .toList();
        final hasService = uuids.contains(serviceUuid.toLowerCase());
        final isNameMatch =
            name.contains('smart tracker') || name.contains('vn-e900');
        if (hasService || isNameMatch) {
          found = result.device;
          if (!completer.isCompleted) {
            completer.complete(found);
          }
        }
      }
    });

    try {
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 6));
    } catch (_) {}
    final device = await completer.future
        .timeout(const Duration(seconds: 7), onTimeout: () => null);
    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {}
    await sub.cancel();
    return device;
  }

  Future<bool> _discoverAndSubscribe(BluetoothDevice device) async {
    final List<BluetoothService> services;
    try {
      services = await device.discoverServices();
    } catch (_) {
      return false;
    }
    final service = services
        .cast<BluetoothService?>()
        .firstWhere((s) => s?.uuid == Guid(serviceUuid), orElse: () => null);
    if (service == null) return false;

    _motionChar = service.characteristics
        .cast<BluetoothCharacteristic?>()
        .firstWhere((c) => c?.uuid == Guid(motionUuid), orElse: () => null);
    if (_motionChar == null) return false;

    try {
      await _motionChar!.setNotifyValue(true);
    } catch (_) {
      return false;
    }
    _motionSub?.cancel();
    _motionSub = _motionChar!.onValueReceived.listen((value) {
      if (value.isEmpty) return; // ignore empty reads/notifies
      packetCount.value++;
      if (packetCount.value <= 3 || packetCount.value % 50 == 0) {
        debugPrint('[BLE] motion packet #${packetCount.value} len=${value.length}');
      }
      final data = MotionData.fromBytes(Uint8List.fromList(value));
      if (data != null) {
        _motionController.add(data);
      } else {
        debugPrint('[BLE] packet parse FAILED len=${value.length}');
      }
    });
    return true;
  }
}
