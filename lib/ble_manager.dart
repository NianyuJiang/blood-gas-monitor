import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
// pointycastle exports a few class names (State, Padding, ...) that
// collide with Flutter's framework. We only need AES here, so hide the
// conflicting names to keep the rest of the codebase safe.
import 'package:pointycastle/export.dart' hide State, Padding;

import 'device_session.dart';
import 'gas_params.dart';

// ══════════════════════════════════════════════════════════════════════════
//  Wire format  (see gas_params.dart + ESP32_BG/src/main.c)
//
//  BG_MINI sends, per notify, 40 bytes PLAINTEXT:
//    • 9 × float32 little-endian:
//      [phase_diff_avg, mag_ratio, pCO2_ratio, pH_ratio, temperature,
//       PCO2_405, PCO2_470, PH_405, PH_450]
//    • + 1 × uint32 little-endian: the device's uptime in ms at the moment
//      of this sample, as a RAW bit-copy — not a numeric float conversion
//      (a float can't exactly hold an integer past ~16.7M, and device
//      uptime over many hours exceeds that).
//
//  Parsed opportunistically: a 36-byte (9-float) packet from BG firmware
//  without the history buffer still works, just without deviceTimeMs.
//  The legacy 32-byte AES branch below is inherited from the NICU app and
//  never triggers for BG_MINI (it doesn't encrypt); kept only so the two
//  code bases stay easy to compare.
// ══════════════════════════════════════════════════════════════════════════
/// Maximum simultaneous sensor connections.
///
/// 8 is a deliberate, tested ceiling rather than a hardware one: this tablet's
/// BLE stack advertises 16 concurrent LE links and each sensor only notifies
/// once per ~30 s, so CPU/memory are nowhere near saturated. Android BLE link
/// scheduling is what gets unreliable first, typically past ~8 connections.
const int kMaxDevices = 8;

// ── Legacy AES-128 key (only used if a 32-byte packet ever arrives) ──
// aes_key16[i] = aes_key32[i] ^ aes_key32[i+16] = 0x10 repeated 16 times.
final Uint8List _kRealDeviceAesKey =
    Uint8List.fromList(List.filled(16, 0x10));
const int kEncryptedPacketBytes = 32;

enum BleStatus { idle, scanning, connecting, disconnected }

class ConnectResult {
  final bool ok;
  final String? error;
  final DeviceSession? session;
  const ConnectResult.success(this.session)
      : ok = true,
        error = null;
  const ConnectResult.failure(this.error)
      : ok = false,
        session = null;
}

// ══════════════════════════════════════════════════════════════════════════
//  BleManager — singleton, owns all DeviceSessions
// ══════════════════════════════════════════════════════════════════════════
class BleManager {
  BleManager._();
  static final BleManager instance = BleManager._();

  // Known custom service UUIDs that the firmware exposes
  static const List<String> _knownServiceUuids = [
    '12345678-1234-1234-1234-123456789abc', // virtual ESP32
    'abcdef01-1234-5678-1234-56789abcdef0', // real BG_MINI / NICU_MINI_BLE (service)
    'abcdef02-1234-5678-1234-56789abcdef0', // legacy entry, kept for safety
  ];

  // ── Global state ──
  final ValueNotifier<BleStatus> statusNotifier = ValueNotifier(BleStatus.idle);
  final ValueNotifier<List<ScanResult>> scanResultsNotifier =
      ValueNotifier(const []);

  /// Live registry of connected devices, keyed by MAC.
  final Map<String, DeviceSession> _sessions = {};
  final ValueNotifier<List<DeviceSession>> sessionsNotifier =
      ValueNotifier(const []);

  /// Per-sample stream — every device's data flows through here.
  /// CsvRecorder listens to this stream and routes samples to the right file.
  final StreamController<SampleEvent> _sampleCtrl =
      StreamController.broadcast();
  Stream<SampleEvent> get sampleStream => _sampleCtrl.stream;

  StreamSubscription? _scanSub;

  // ─── Accessors ────────────────────────────────────────────────────────
  List<DeviceSession> get sessions => List.unmodifiable(_sessions.values);
  int get sessionCount => _sessions.length;
  bool get isFull => _sessions.length >= kMaxDevices;
  bool isConnected(String mac) => _sessions.containsKey(mac);
  DeviceSession? sessionFor(String mac) => _sessions[mac];

  /// True if a session for this advertised device NAME is currently
  /// connected — used wherever "is this device already connected" needs
  /// to survive a MAC change (BLE privacy rotates the MAC every power
  /// cycle, but a session's displayName stays whatever it was connected
  /// with). Case/whitespace-insensitive so "BG_MINI_01" and a QR/known-
  /// devices entry typed as " bg_mini_01 " still match.
  bool isConnectedByName(String name) {
    final target = name.trim().toLowerCase();
    if (target.isEmpty) return false;
    return _sessions.values
        .any((s) => s.displayName.trim().toLowerCase() == target);
  }

  void _publishSessions() {
    sessionsNotifier.value = List.unmodifiable(_sessions.values);
  }

  int _nextFreeSlot() {
    final used = _sessions.values.map((s) => s.slot).toSet();
    for (int i = 1; i <= kMaxDevices; i++) {
      if (!used.contains(i)) return i;
    }
    return _sessions.length + 1;
  }

  // ─── Scanning ─────────────────────────────────────────────────────────
  Future<void> startScan() async {
    if (statusNotifier.value == BleStatus.scanning) return;
    scanResultsNotifier.value = const [];
    statusNotifier.value = BleStatus.scanning;
    await FlutterBluePlus.stopScan();
    _scanSub?.cancel();

    _scanSub = FlutterBluePlus.scanResults.listen((results) {
      final sorted = List<ScanResult>.from(results)
        ..sort((a, b) => b.rssi.compareTo(a.rssi));
      scanResultsNotifier.value =
          sorted.length > 50 ? sorted.sublist(0, 50) : sorted;
    });

    await FlutterBluePlus.startScan(timeout: const Duration(seconds: 15));
    if (statusNotifier.value == BleStatus.scanning) {
      statusNotifier.value = BleStatus.idle;
    }
  }

  Future<void> stopScan() async {
    await FlutterBluePlus.stopScan();
    _scanSub?.cancel();
    if (statusNotifier.value == BleStatus.scanning) {
      statusNotifier.value = BleStatus.idle;
    }
  }

  // ─── Connect ──────────────────────────────────────────────────────────
  Future<ConnectResult> connect(
    BluetoothDevice device, {
    Map<String, dynamic>? meta,
  }) async {
    final mac = device.remoteId.str;

    if (_sessions.containsKey(mac)) {
      return ConnectResult.failure('Already connected');
    }
    if (isFull) {
      return ConnectResult.failure(
          'Maximum of $kMaxDevices devices already connected');
    }

    statusNotifier.value = BleStatus.connecting;
    try {
      await device.connect(timeout: const Duration(seconds: 15));

      final services = await device.discoverServices();
      for (final svc in services) {
        debugPrint('[BLE:$mac] Service ${svc.uuid}');
        for (final ch in svc.characteristics) {
          debugPrint('[BLE:$mac]   Char ${ch.uuid} notify=${ch.properties.notify}');
        }
      }

      final char = _findNotifyChar(services, mac);
      if (char == null) {
        await device.disconnect();
        statusNotifier.value = BleStatus.idle;
        return ConnectResult.failure(
            'No notify characteristic found on this device');
      }

      try {
        await device.requestMtu(64);
      } catch (_) {}
      await char.setNotifyValue(true);

      final session = DeviceSession(
        device: device,
        slot: _nextFreeSlot(),
        meta: meta,
      );
      session.notifyChar = char;
      session.startClock();

      session.notifySub = char.lastValueStream.listen((bytes) {
        if (bytes.isNotEmpty) _onBytes(session, bytes);
      });

      session.stateSub = device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected) {
          _removeSession(mac, notifyStatus: false);
        }
      });

      _sessions[mac] = session;
      _publishSessions();
      statusNotifier.value = BleStatus.idle;
      return ConnectResult.success(session);
    } catch (e) {
      statusNotifier.value = BleStatus.idle;
      return ConnectResult.failure(e.toString());
    }
  }

  // ─── Connect by advertised name (iOS) ──────────────────────────────────
  // iOS's Core Bluetooth privacy model never exposes the real BLE MAC to
  // apps, so a MAC-based device QR (Android's connect path, above) cannot
  // be used to connect on iPhone — `BluetoothDevice.fromId(mac)` throws
  // "invalid remoteId" there. As an iOS-only fallback, scan for nearby
  // devices and match by the advertised local name instead (the QR's
  // "name" field, which must equal the sensor's real advertised BLE name).
  // Android is untouched — it keeps using connect() with the real MAC.
  Future<ConnectResult> connectByName(
    String name, {
    Map<String, dynamic>? meta,
    Duration timeout = const Duration(seconds: 8),
    // Fires once the real device (and its remoteId — the closest thing to
    // a stable identity iOS exposes) has been found via the name scan
    // below, but BEFORE the GATT connect happens. This is the only point
    // an iOS caller ever has a trustworthy identity for this device, so
    // it's the hook scan_qr_page.dart uses to run the "continue from last
    // recording?" dialogs — mirroring where the Android (MAC-based) path
    // runs them, just later, since iOS can't know the identity any sooner.
    // Optional and unused by existing callers, so this is purely additive.
    Future<void> Function(String remoteId)? beforeConnect,
  }) async {
    final target = name.trim().toLowerCase();
    if (target.isEmpty) {
      return ConnectResult.failure(
          'This QR has no device name saved — regenerate it with the '
          "device's advertised Bluetooth name filled in (MAC alone can't "
          'be used to connect on iPhone)');
    }
    for (final s in _sessions.values) {
      if (s.device.platformName.trim().toLowerCase() == target) {
        return ConnectResult.failure('Already connected');
      }
    }
    if (isFull) {
      return ConnectResult.failure(
          'Maximum of $kMaxDevices devices already connected');
    }

    statusNotifier.value = BleStatus.connecting;
    BluetoothDevice? found;
    final sub = FlutterBluePlus.scanResults.listen((results) {
      for (final r in results) {
        if (r.device.platformName.trim().toLowerCase() == target) {
          found = r.device;
        }
      }
    });

    try {
      if (!FlutterBluePlus.isScanningNow) {
        await FlutterBluePlus.startScan(timeout: timeout);
      }
      final deadline = DateTime.now().add(timeout);
      while (found == null && DateTime.now().isBefore(deadline)) {
        await Future.delayed(const Duration(milliseconds: 200));
      }
    } finally {
      await sub.cancel();
      if (FlutterBluePlus.isScanningNow) {
        await FlutterBluePlus.stopScan();
      }
    }

    if (found == null) {
      statusNotifier.value = BleStatus.idle;
      return ConnectResult.failure(
          'Device "$name" not found nearby — keep it close and try again');
    }
    if (beforeConnect != null) {
      await beforeConnect(found!.remoteId.str);
    }
    return connect(found!, meta: meta);
  }

  BluetoothCharacteristic? _findNotifyChar(
      List<BluetoothService> services, String mac) {
    for (final svc in services) {
      final uuid = svc.uuid.toString().toLowerCase();
      if (_knownServiceUuids.contains(uuid)) {
        for (final ch in svc.characteristics) {
          if (ch.properties.notify || ch.properties.indicate) {
            debugPrint('[BLE:$mac] Matched known service $uuid');
            return ch;
          }
        }
      }
    }
    for (final svc in services) {
      final uuid = svc.uuid.toString().toLowerCase();
      if (uuid.contains('00805f9b34fb')) continue;
      if (uuid.length <= 8) continue;
      for (final ch in svc.characteristics) {
        if (ch.properties.notify || ch.properties.indicate) {
          debugPrint('[BLE:$mac] Using custom service $uuid');
          return ch;
        }
      }
    }
    return null;
  }

  // ─── Disconnect ───────────────────────────────────────────────────────
  Future<void> disconnect(String mac) async {
    final session = _sessions[mac];
    if (session == null) return;
    try {
      await session.device.disconnect();
    } catch (_) {}
    await _removeSession(mac);
  }

  Future<void> disconnectAll() async {
    for (final mac in _sessions.keys.toList()) {
      await disconnect(mac);
    }
  }

  Future<void> _removeSession(String mac, {bool notifyStatus = true}) async {
    final session = _sessions.remove(mac);
    if (session == null) return;
    await session.dispose();
    _publishSessions();
    if (notifyStatus && _sessions.isEmpty) {
      statusNotifier.value = BleStatus.idle;
    }
  }

  // ─── Sample parsing ───────────────────────────────────────────────────
  void _onBytes(DeviceSession session, List<int> bytes) {
    // Step 1: 32-byte packets are AES-encrypted (legacy NICU rig only).
    Uint8List payload;
    if (bytes.length == kEncryptedPacketBytes) {
      try {
        payload = _aesDecrypt(Uint8List.fromList(bytes));
      } catch (e) {
        debugPrint('[BLE:${session.mac}] AES decrypt failed: $e');
        return;
      }
    } else {
      payload = Uint8List.fromList(bytes);
    }

    // Step 2: need at least the 9 floats.
    if (payload.length < kPayloadBytes) {
      debugPrint('[BLE:${session.mac}] packet too short (${payload.length}B)');
      return;
    }

    // Step 3: parse all 9 float32 little-endian values.
    try {
      final view = ByteData.sublistView(payload);
      final values = List<double>.generate(
        kPayloadFloats,
        (i) => view.getFloat32(i * 4, Endian.little),
      );

      // Step 4 (optional): a 10th value — device uptime in ms — present
      // on history-buffer firmware. It's a RAW uint32 bit-pattern, not a
      // real float, so it must be read back as an unsigned int, never via
      // getFloat32. Firmware without it sends 36 bytes and deviceTimeMs
      // stays null — everything else about the packet parses the same.
      int? deviceTimeMs;
      if (payload.length >= kWirePacketBytes) {
        deviceTimeMs = view.getUint32(kPayloadBytes, Endian.little);
      }

      // Log every decoded packet so a channel that reads blank in the UI can
      // be traced to what the firmware actually sent (0 / NaN / a real value).
      debugPrint('[BLE:${session.mac}] ${payload.length}B → '
          'pO2L=${values[0]} pO2I=${values[1]} pCO2=${values[2]} '
          'pH=${values[3]} T=${values[4]} '
          'CO2_405=${values[5]} CO2_470=${values[6]} '
          'pH_405=${values[7]} pH_450=${values[8]}'
          '${deviceTimeMs != null ? ' t_ms=$deviceTimeMs' : ''}');
      session.addSample(values, deviceTimeMs: deviceTimeMs);
      _sampleCtrl.add(SampleEvent(
        session: session,
        values: values,
        deviceTimeMs: deviceTimeMs,
      ));
    } catch (e) {
      debugPrint('[BLE:${session.mac}] parse error: $e');
    }
  }

  // ─── AES-128 ECB decryption (legacy 32-byte packets) ──────────────────
  Uint8List _aesDecrypt(Uint8List ciphertext) {
    if (ciphertext.isEmpty || ciphertext.length % 16 != 0) {
      throw FormatException(
          'Invalid AES ciphertext length: ${ciphertext.length}');
    }
    final cipher = ECBBlockCipher(AESEngine())
      ..init(false, KeyParameter(_kRealDeviceAesKey));
    final plaintext = Uint8List(ciphertext.length);
    for (int offset = 0; offset < ciphertext.length; offset += 16) {
      cipher.processBlock(ciphertext, offset, plaintext, offset);
    }
    final padLen = plaintext.last;
    if (padLen >= 1 && padLen <= 16) {
      return plaintext.sublist(0, plaintext.length - padLen);
    }
    return plaintext;
  }

  void dispose() {
    _sampleCtrl.close();
    _scanSub?.cancel();
  }
}

// ══════════════════════════════════════════════════════════════════════════
//  One decoded packet: all 9 floats in GasParam order, plus the optional
//  device-uptime timestamp (history-buffer-capable firmware only).
// ══════════════════════════════════════════════════════════════════════════
class SampleEvent {
  final DeviceSession session;
  final List<double> values; // length 9, GasParam order

  /// Device uptime (ms since its last power-on) at the moment this sample
  /// was taken, or null if the connected firmware doesn't send it (older
  /// 36-byte-packet firmware). Used to back-calculate real timestamps for
  /// samples pulled from the device's history buffer on resume/sync.
  final int? deviceTimeMs;

  const SampleEvent(
      {required this.session, required this.values, this.deviceTimeMs});

  /// Value for a given parameter, or 0 if out of range.
  double value(GasParam p) =>
      p.floatIndex < values.length ? values[p.floatIndex] : 0.0;
}
