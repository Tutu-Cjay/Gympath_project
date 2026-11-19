import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import '../models/motion_data.dart';
import '../models/track_sample.dart';
import 'track_simulator.dart';

enum BleConnectionState { disconnected, scanning, connecting, connected, error }

/// Commands written to the control characteristic (firmware/Gympath_Track).
enum TrackCommand { stop, start, zero }

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
  // 1D gravity-axis tracking (firmware/Gympath_Track); absent on older builds
  static const String controlUuid = '12345678-1234-5678-1234-56789abcdef8';
  static const String trackUuid = '12345678-1234-5678-1234-56789abcdef9';

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

  final StreamController<TrackSample> _trackController =
      StreamController<TrackSample>.broadcast();
  Stream<TrackSample> get trackStream => _trackController.stream;

  /// True when the connected firmware supports 1D tracking (has …cdef8/9).
  final ValueNotifier<bool> trackSupported = ValueNotifier<bool>(false);

  /// True when the firmware accepts over-the-air updates (has …cdefa/b).
  final ValueNotifier<bool> otaSupported = ValueNotifier<bool>(false);
  static const String otaUuid = '12345678-1234-5678-1234-56789abcdefa';
  static const String versionUuid = '12345678-1234-5678-1234-56789abcdefb';
  BluetoothCharacteristic? _otaChar;
  BluetoothCharacteristic? _versionChar;
  StreamSubscription<List<int>>? _otaSub;
  final StreamController<List<int>> _otaStatusController =
      StreamController<List<int>>.broadcast();

  /// Raw OTA status notifications: [state, err, written u32 LE].
  Stream<List<int>> get otaStatus => _otaStatusController.stream;

  BluetoothDevice? _device;
  BluetoothCharacteristic? _motionChar;
  BluetoothCharacteristic? _controlChar;
  StreamSubscription<List<int>>? _motionSub;
  StreamSubscription<List<int>>? _trackSub;
  int _cmdSeq = 0;
  StreamSubscription<BluetoothConnectionState>? _connSub;

  bool _userDisconnected = false; // distinguishes intentional disconnects
  bool _reconnecting = false;

  // USB test link (debug): tools/serial_bridge.py relays the tracker's UART
  // over TCP, so the app can run on an emulator that has no Bluetooth.
  Socket? _testSocket;
  StreamSubscription<String>? _testSub;
  String? _testVersion;

  /// True while data comes over the USB test link instead of BLE.
  final ValueNotifier<bool> testLink = ValueNotifier<bool>(false);

  // Simulation: a built-in stand-in for the tracker (see TrackSimulator), so
  // the app can be tried and demoed without the hardware.
  TrackSimulator? _simulator;
  Timer? _simTimer;
  static const int _simPeriodMs = 20; // 50 Hz, like the firmware

  /// True while samples come from the built-in simulator.
  final ValueNotifier<bool> simulation = ValueNotifier<bool>(false);

  bool get isConnected =>
      connectionState.value == BleConnectionState.connected;

  /// Replace the tracker with the simulator. It answers START / STOP / ZERO
  /// and streams the same samples, so every screen works unchanged.
  Future<bool> startSimulation() async {
    if (simulation.value) return true;
    await disconnect();
    _userDisconnected = true; // no Bluetooth reconnect attempts meanwhile
    lastError.value = null;
    final sim = TrackSimulator();
    _simulator = sim;
    _simTimer = Timer.periodic(const Duration(milliseconds: _simPeriodMs), (_) {
      _trackController.add(sim.step(_simPeriodMs));
    });
    simulation.value = true;
    trackSupported.value = true;
    connectionState.value = BleConnectionState.connected;
    return true;
  }

  void _stopSimulation() {
    if (_simulator == null) return;
    _simTimer?.cancel();
    _simTimer = null;
    _simulator = null;
    simulation.value = false;
    trackSupported.value = false;
    connectionState.value = BleConnectionState.disconnected;
  }

  /// Connect to serial_bridge.py. From an Android emulator the PC is 10.0.2.2.
  Future<bool> connectTestLink({String host = '10.0.2.2', int port = 7700}) async {
    if (testLink.value) return true;
    await disconnect();
    _userDisconnected = false;
    lastError.value = null;
    connectionState.value = BleConnectionState.connecting;
    final Socket socket;
    try {
      socket = await Socket.connect(host, port,
          timeout: const Duration(seconds: 4));
    } catch (_) {
      return _fail('USB bridge not reachable at $host:$port');
    }
    socket.setOption(SocketOption.tcpNoDelay, true);
    _testSocket = socket;
    testLink.value = true;
    connectionState.value = BleConnectionState.connected;
    trackSupported.value = true;
    _testSub = utf8.decoder
        .bind(socket)
        .transform(const LineSplitter())
        .listen(_onTestLine, onDone: _closeTestLink, onError: (_) => _closeTestLink());
    return true;
  }

  void _onTestLine(String line) {
    if (line.length < 2 || line[1] != ',') return;
    final body = line.substring(2);
    switch (line[0]) {
      case 'T':
        final s = TrackSample.fromBytes(_hexDecode(body));
        if (s != null) _trackController.add(s);
      case 'M':
        final d = MotionData.fromBytes(_hexDecode(body));
        if (d != null) {
          packetCount.value++;
          _motionController.add(d);
        }
      case 'V':
        _testVersion = body.trim();
    }
  }

  static Uint8List _hexDecode(String hex) {
    final out = Uint8List(hex.length ~/ 2);
    for (int i = 0; i < out.length; i++) {
      out[i] = int.tryParse(hex.substring(2 * i, 2 * i + 2), radix: 16) ?? 0;
    }
    return out;
  }

  void _closeTestLink() {
    if (_testSocket == null) return;
    _testSub?.cancel();
    _testSub = null;
    _testSocket?.destroy();
    _testSocket = null;
    _testVersion = null;
    testLink.value = false;
    trackSupported.value = false;
    connectionState.value = BleConnectionState.disconnected;
  }

  Future<bool> connect() async {
    _stopSimulation(); // a real connection replaces the simulator
    if (isConnected) return true;
    _userDisconnected = false;
    lastError.value = null;
    connectionState.value = BleConnectionState.scanning;

    final supported = await FlutterBluePlus.isSupported;
    if (!supported) {
      return _fail('Bluetooth is not supported on this device');
    }
    await _ensurePermissions();
    if ((!kIsWeb && Platform.isAndroid)) {
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
    if ((!kIsWeb && Platform.isAndroid)) {
      try {
        await device.requestMtu(517); // large MTU → bigger OTA chunks
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
    _stopSimulation();
    _closeTestLink();
    await _motionSub?.cancel();
    _motionSub = null;
    await _trackSub?.cancel();
    _trackSub = null;
    _controlChar = null;
    trackSupported.value = false;
    await _otaSub?.cancel();
    _otaSub = null;
    _otaChar = _versionChar = null;
    otaSupported.value = false;
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
        _trackSub?.cancel();
        _trackSub = null;
        _controlChar = null;
        trackSupported.value = false;
        _otaSub?.cancel();
        _otaSub = null;
        _otaChar = _versionChar = null;
        otaSupported.value = false;
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
    if (!(!kIsWeb && Platform.isAndroid)) return;
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

    // Optional 1D tracking characteristics (only on firmware/Gympath_Track).
    await _subscribeTrack(service);
    await _subscribeOta(service);
    return true;
  }

  Future<void> _subscribeTrack(BluetoothService service) async {
    BluetoothCharacteristic? find(String uuid) => service.characteristics
        .cast<BluetoothCharacteristic?>()
        .firstWhere((c) => c?.uuid == Guid(uuid), orElse: () => null);
    final control = find(controlUuid);
    final track = find(trackUuid);
    if (control == null || track == null) {
      trackSupported.value = false;
      return;
    }
    try {
      await track.setNotifyValue(true);
    } catch (_) {
      trackSupported.value = false;
      return;
    }
    _controlChar = control;
    _trackSub?.cancel();
    _trackSub = track.onValueReceived.listen((value) {
      final s = TrackSample.fromBytes(Uint8List.fromList(value));
      if (s != null) _trackController.add(s);
    });
    trackSupported.value = true;
  }

  Future<void> _subscribeOta(BluetoothService service) async {
    BluetoothCharacteristic? find(String uuid) => service.characteristics
        .cast<BluetoothCharacteristic?>()
        .firstWhere((c) => c?.uuid == Guid(uuid), orElse: () => null);
    final ota = find(otaUuid);
    final ver = find(versionUuid);
    if (ota == null || ver == null) {
      otaSupported.value = false;
      return;
    }
    try {
      await ota.setNotifyValue(true);
    } catch (_) {
      otaSupported.value = false;
      return;
    }
    _otaChar = ota;
    _versionChar = ver;
    _otaSub?.cancel();
    _otaSub = ota.onValueReceived.listen(_otaStatusController.add);
    otaSupported.value = true;
  }

  /// Firmware version string reported by the device, e.g. "1.0.0".
  Future<String?> readFirmwareVersion() async {
    if (testLink.value) return _testVersion;
    final c = _versionChar;
    if (c == null) return null;
    try {
      return String.fromCharCodes(await c.read()).trim();
    } catch (_) {
      return null;
    }
  }

  /// Bytes that fit in one OTA write after the ATT header and our op byte.
  int get otaChunkSize {
    final mtu = _device?.mtuNow ?? 23;
    return (mtu - 3 - 1).clamp(20, 512);
  }

  /// Ask Android for the fastest connection interval (OTA throughput).
  Future<void> requestHighThroughput() async {
    if (_device == null || !(!kIsWeb && Platform.isAndroid)) return;
    try {
      await _device!.requestConnectionPriority(
          connectionPriorityRequest: ConnectionPriority.high);
    } catch (_) {}
  }

  /// One OTA write, with response — the device acks only after flashing it.
  Future<void> writeOta(List<int> bytes) async {
    final c = _otaChar;
    if (c == null) throw StateError('OTA not supported by this firmware');
    await c.write(bytes, withoutResponse: false);
  }

  /// Send START / STOP / ZERO to the device. Each write carries a fresh
  /// sequence byte so the firmware acts on repeated commands exactly once.
  Future<bool> sendCommand(TrackCommand cmd) async {
    final sim = _simulator;
    if (sim != null) {
      switch (cmd) {
        case TrackCommand.start:
          sim.start();
        case TrackCommand.stop:
          sim.stop();
        case TrackCommand.zero:
          sim.zero();
      }
      return true;
    }
    final socket = _testSocket;
    if (socket != null) {
      _cmdSeq = (_cmdSeq % 255) + 1;
      socket.write('C,${cmd.index},$_cmdSeq\n');
      return true;
    }
    final c = _controlChar;
    if (c == null) return false;
    _cmdSeq = (_cmdSeq % 255) + 1;
    try {
      await c.write([cmd.index, _cmdSeq], withoutResponse: false);
      return true;
    } catch (_) {
      return false;
    }
  }
}
