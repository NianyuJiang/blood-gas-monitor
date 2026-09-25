import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ble_manager.dart';
import 'connect_flow.dart';
import 'device_session.dart';
import 'glass.dart';
import 'scan_qr_page.dart';
import 'theme_manager.dart';

// ══════════════════════════════════════════════════════════════════════════
//  KnownDevices — like a phone's Bluetooth pairing list (persisted)
//
//  Keyed by the device's advertised NAME, not its BLE MAC/remoteId. With
//  BLE privacy enabled on the firmware, the MAC now rotates on every power
//  cycle, so a MAC-keyed list would "forget" every device (treat it as
//  brand new) the moment it's rebooted. The device's name is what actually
//  stays stable across power cycles — it's what gets deliberately renamed
//  per physical unit — so that's the right identity for this list. The
//  stored value is the last MAC seen for that name, kept only as a display
//  hint / Android fallback; it's never assumed to still be valid.
// ══════════════════════════════════════════════════════════════════════════
class KnownDevices {
  KnownDevices._();
  static final KnownDevices instance = KnownDevices._();

  // v2: keyed by name instead of MAC (see class doc comment above). A new
  // pref key so an old v1 (MAC-keyed) list doesn't get misread as
  // name-keyed — it's just re-learned the first time each device
  // reconnects, no migration needed.
  static const _key = 'capno_known_devices_v2';
  Map<String, String> _map = {}; // name -> last-known mac (display only)
  bool _loaded = false;

  Future<void> load() async {
    if (_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList(_key) ?? const [];
    _map = {
      for (final entry in list)
        if (entry.contains('|'))
          entry.split('|').first: entry.split('|').sublist(1).join('|'),
    };
    _loaded = true;
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _key,
      _map.entries.map((e) => '${e.key}|${e.value}').toList(),
    );
  }

  Future<void> remember(String name, String mac) async {
    if (name.trim().isEmpty) return; // nothing stable to key on — skip
    await load();
    _map[name] = mac;
    await _save();
  }

  Future<void> forget(String name) async {
    await load();
    _map.remove(name);
    await _save();
  }

  bool isKnown(String name) => name.trim().isNotEmpty && _map.containsKey(name);
  String? macOf(String name) => _map[name];
  List<MapEntry<String, String>> get all => _map.entries.toList();
}

// ══════════════════════════════════════════════════════════════════════════
class BlePage extends StatefulWidget {
  const BlePage({super.key});
  @override
  State<BlePage> createState() => _BlePageState();
}

class _BlePageState extends State<BlePage> with WidgetsBindingObserver {
  final _ble = BleManager.instance;
  bool _permsReady = false;

  // Raw per-permission result from the last check — shown on the banner
  // (temporary diagnostic) so we can see exactly WHICH permission Android
  // is reporting as not granted, instead of guessing from the combined
  // scanOk && connectOk boolean. Safe to remove once the root cause is
  // confirmed; doesn't change any actual permission-request behavior.
  Map<Permission, PermissionStatus> _lastStatuses = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _init();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Android doesn't tell the app when the user grants a permission from
  // Settings — it only tells us the app came back to the foreground. So
  // whenever that happens, and we're still showing "permission needed",
  // silently re-check: if the user just granted it, this clears the
  // banner and starts scanning without them having to back out and
  // reopen the page. If permission still isn't granted, this is a no-op
  // (same banner, same behavior as before this fix).
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_permsReady) {
      _recheckPermissions();
    }
  }

  Future<void> _recheckPermissions() async {
    final ok = await _requestPermissions();
    if (!mounted) return;
    // Always setState (even if `ok` is unchanged) so the diagnostic status
    // line below the banner refreshes on every manual RETRY tap too, not
    // just on a genuine granted/denied flip.
    setState(() => _permsReady = ok);
    if (ok) _ble.startScan();
  }

  Future<void> _init() async {
    await KnownDevices.instance.load();
    final ok = await _requestPermissions();
    if (!mounted) return;
    setState(() => _permsReady = ok);
    if (ok) _ble.startScan();
  }

  Future<bool> _requestPermissions() async {
    // iOS doesn't have Android's split "Nearby devices" permission model
    // (Permission.bluetoothScan / bluetoothConnect are Android 12+-only
    // concepts — Core Bluetooth exposes one unified Bluetooth
    // authorization instead), and Core Bluetooth central-role scanning
    // needs NO Location permission at all — that's purely an Android
    // legacy requirement. Requesting Permission.locationWhenInUse here
    // without a matching NSLocationWhenInUseUsageDescription key in
    // Info.plist (there isn't one — it was never actually needed on iOS)
    // is what was producing the bogus "permanentlyDenied" statuses on
    // iPhone: iOS refuses to ever grant a permission whose usage
    // description is missing. Android's path below is completely
    // unchanged from before.
    if (Platform.isIOS) {
      final status = await Permission.bluetooth.request();
      _lastStatuses = {Permission.bluetooth: status};
      debugPrint('[BLE perms/iOS] bluetooth=$status');
      return status.isGranted;
    }

    final statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();
    _lastStatuses = statuses;
    debugPrint('[BLE perms] scan=${statuses[Permission.bluetoothScan]} '
        'connect=${statuses[Permission.bluetoothConnect]} '
        'location=${statuses[Permission.locationWhenInUse]}');
    final scanOk = statuses[Permission.bluetoothScan]?.isGranted ?? false;
    final connectOk =
        statuses[Permission.bluetoothConnect]?.isGranted ?? false;
    return scanOk && connectOk;
  }

  Future<void> _connectToDevice(BluetoothDevice device) async {
    if (_ble.isFull) {
      _snack(
        'Maximum $kMaxDevices devices already connected. Disconnect one first.',
        ThemeManager.orange,
      );
      return;
    }
    await _ble.stopScan();

    // Build a minimal meta dict from the BLE advertisement so the rest of
    // the app (CSV recorder → session_metadata) gets the same `name` field
    // it would get from a QR-code connect. This makes the auto-fill of the
    // session title work whether the user scans a QR or taps the device
    // in the Bluetooth list.
    final resolvedName = device.platformName.trim();
    final meta = <String, dynamic>{
      if (resolvedName.isNotEmpty) 'name': resolvedName,
    };

    // If this device has a prior recording, ask whether to resume it —
    // a no-op (no dialog) for any device that's never recorded before.
    // Must happen BEFORE connect(): CsvRecorder starts recording the
    // instant the session appears, so this is the only point where a
    // "continue from last recording?" choice can still take effect.
    await maybeShowConnectDialogs(context,
        mac: device.remoteId.str, deviceName: resolvedName);
    if (!mounted) return;

    final res = await _ble.connect(device, meta: meta);
    if (!mounted) return;
    if (!res.ok) {
      _snack('Connection failed: ${res.error}', ThemeManager.red);
      return;
    }
    final name = resolvedName.isEmpty ? 'Unknown' : resolvedName;
    await KnownDevices.instance.remember(name, device.remoteId.str);
    if (!mounted) return;
    _snack('Connected: $name', ThemeManager.green);
    setState(() {}); // refresh known list
  }

  // Reconnects by NAME, not the last-known MAC — with BLE privacy enabled
  // on the firmware, that MAC may well belong to a different (or no)
  // device by now if this sensor has been power-cycled since we last saw
  // it. connectByName() does its own scan-and-match by advertised name
  // (see ble_manager.dart), so this works whether or not the device is
  // already in the current scan results, and regardless of what its MAC
  // is today.
  Future<void> _connectToKnown(String name, String lastKnownMac) async {
    if (_ble.isFull) {
      _snack(
        'Maximum $kMaxDevices devices already connected. Disconnect one first.',
        ThemeManager.orange,
      );
      return;
    }
    await _ble.stopScan();
    final meta = <String, dynamic>{'name': name};

    final res = await _ble.connectByName(
      name,
      meta: meta,
      // Fires once connectByName has found the device (and knows its
      // CURRENT remoteId) but before the GATT connect — the same hook
      // scan_qr_page.dart uses, and the only point a resume dialog can
      // still take effect before CsvRecorder starts a session for it.
      beforeConnect: (remoteId) async {
        if (!mounted) return;
        await maybeShowConnectDialogs(context, mac: remoteId, deviceName: name);
      },
    );
    if (!mounted) return;
    if (!res.ok) {
      _snack('Connection failed: ${res.error}', ThemeManager.red);
      return;
    }
    await KnownDevices.instance.remember(name, res.session?.mac ?? lastKnownMac);
    if (!mounted) return;
    _snack('Connected: $name', ThemeManager.green);
    setState(() {});
  }

  Future<void> _forgetDevice(String mac, String name) async {
    final tm = ThemeManager.instance;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        child: GlassCard(
          borderRadius: 26,
          accent: ThemeManager.red,
          child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'FORGET DEVICE',
                style: TextStyle(
                  color: ThemeManager.red,
                  fontSize: 11,
                  letterSpacing: 3,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 14),
              Text(name,
                  style: TextStyle(
                      color: tm.textPrimary,
                      fontSize: 14,
                      fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              Text(mac, style: TextStyle(color: tm.textSub, fontSize: 11)),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: GlassPill(
                      onTap: () => Navigator.pop(ctx, false),
                      child: Center(
                        child: Text('CANCEL',
                            style: TextStyle(
                                color: tm.textSub,
                                fontSize: 11,
                                letterSpacing: 2,
                                fontWeight: FontWeight.w700)),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: GlassPill(
                      onTap: () => Navigator.pop(ctx, true),
                      accent: ThemeManager.red,
                      child: const Center(
                        child: Text('FORGET',
                            style: TextStyle(
                                color: ThemeManager.red,
                                fontSize: 11,
                                letterSpacing: 2,
                                fontWeight: FontWeight.w700)),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
          ),
        ),
      ),
    );
    if (confirm == true) {
      await KnownDevices.instance.forget(name);
      if (mounted) setState(() {});
    }
  }

  void _snack(String msg, Color color) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: color,
      duration: const Duration(seconds: 2),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final tm = ThemeManager.instance;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: LiquidBackground(
        child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildHeader(context, tm),
              const SizedBox(height: 18),
              _buildStatusRow(tm),
              const SizedBox(height: 18),
              if (!_permsReady)
                Expanded(child: _buildPermsRequired(tm))
              else
                Expanded(child: _buildDeviceLists(tm)),
            ],
          ),
        ),
      ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context, ThemeManager tm) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      // Buttons flush to the top; the QR button carries a caption underneath.
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GestureDetector(
          onTap: () => Navigator.pop(context),
          child: SizedBox(
            width: 38,
            height: 38,
            child: GlassCard(
              borderRadius: 14,
              elevated: false,
              child: Icon(Icons.arrow_back_ios_new,
                  color: tm.textPrimary, size: 14),
            ),
          ),
        ),
        const SizedBox(
          height: 38,
          child: Center(
            child: Text(
              'BLUETOOTH',
              style: TextStyle(
                color: ThemeManager.purple,
                fontSize: 10,
                fontWeight: FontWeight.w700,
                letterSpacing: 3.5,
              ),
            ),
          ),
        ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 📷 QR scan
            GestureDetector(
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const ScanQRPage()),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 38,
                    height: 38,
                    child: GlassCard(
                      borderRadius: 14,
                      elevated: false,
                      accent: ThemeManager.cyan,
                      child: Icon(Icons.qr_code_scanner,
                          color: ThemeManager.cyan, size: 16),
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    'Scan device',
                    style: TextStyle(
                      color: tm.textSub,
                      fontSize: 8,
                      letterSpacing: 0.2,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            // Scan / Stop
            ValueListenableBuilder<BleStatus>(
              valueListenable: _ble.statusNotifier,
              builder: (_, status, __) {
                final scanning = status == BleStatus.scanning;
                return GestureDetector(
                  onTap: scanning ? _ble.stopScan : _ble.startScan,
                  child: SizedBox(
                    width: 38,
                    height: 38,
                    child: GlassCard(
                      borderRadius: 14,
                      elevated: false,
                      accent: scanning ? ThemeManager.purple : null,
                      child: scanning
                          ? const Center(
                              child: SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 1.6,
                                  color: ThemeManager.purple,
                                ),
                              ),
                            )
                          : Icon(Icons.radar,
                              color: tm.textPrimary, size: 16),
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildStatusRow(ThemeManager tm) {
    return ValueListenableBuilder<BleStatus>(
      valueListenable: _ble.statusNotifier,
      builder: (_, status, __) {
        return ValueListenableBuilder<List<DeviceSession>>(
          valueListenable: _ble.sessionsNotifier,
          builder: (_, sessions, __) {
            final (msg, color) = switch (status) {
              BleStatus.scanning => ('SCANNING…', ThemeManager.cyan),
              BleStatus.connecting => ('CONNECTING…', ThemeManager.purple),
              _ => sessions.isNotEmpty
                  ? ('${sessions.length} CONNECTED', ThemeManager.green)
                  : ('READY', tm.textSub),
            };
            return Row(
              children: [
                Container(
                  width: 6,
                  height: 6,
                  decoration:
                      BoxDecoration(shape: BoxShape.circle, color: color),
                ),
                const SizedBox(width: 8),
                Text(
                  msg,
                  style: TextStyle(
                    color: color,
                    fontSize: 10,
                    letterSpacing: 2.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                ValueListenableBuilder<List<ScanResult>>(
                  valueListenable: _ble.scanResultsNotifier,
                  builder: (_, list, __) => Text(
                    '${list.length} nearby',
                    style: TextStyle(
                      color: tm.textSub,
                      fontSize: 10,
                      letterSpacing: 1.5,
                    ),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildPermsRequired(ThemeManager tm) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.bluetooth_disabled,
              size: 48, color: ThemeManager.red.withValues(alpha: 0.6)),
          const SizedBox(height: 16),
          Text(
            'PERMISSION NEEDED',
            style: TextStyle(
              color: tm.textPrimary,
              fontSize: 13,
              fontWeight: FontWeight.w700,
              letterSpacing: 2,
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              'This app needs Bluetooth and Location permission to scan for sensors.',
              textAlign: TextAlign.center,
              style: TextStyle(color: tm.textSub, fontSize: 12, height: 1.4),
            ),
          ),
          const SizedBox(height: 20),
          GlassPill(
            onTap: () => openAppSettings(),
            accent: ThemeManager.purple,
            child: const Text(
              'OPEN SETTINGS',
              style: TextStyle(
                color: ThemeManager.purple,
                fontSize: 11,
                letterSpacing: 2,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(height: 10),
          GlassPill(
            onTap: _recheckPermissions,
            child: Text(
              'RETRY',
              style: TextStyle(
                color: tm.textSub,
                fontSize: 11,
                letterSpacing: 2,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          // Temporary diagnostic: shows exactly which permission the OS
          // is reporting as not granted, so a mismatch between "scanning
          // clearly works" and "banner still up" can be pinned down to a
          // specific permission instead of guessed at. Safe to delete once
          // the cause is confirmed.
          if (_lastStatuses.isNotEmpty) ...[
            const SizedBox(height: 14),
            Text(
              Platform.isIOS
                  ? 'bluetooth=${_lastStatuses[Permission.bluetooth]?.name}'
                  : 'scan=${_lastStatuses[Permission.bluetoothScan]?.name} · '
                      'connect=${_lastStatuses[Permission.bluetoothConnect]?.name} · '
                      'location=${_lastStatuses[Permission.locationWhenInUse]?.name}',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: tm.textSub.withValues(alpha: 0.6),
                fontSize: 9,
                letterSpacing: 0.5,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildDeviceLists(ThemeManager tm) {
    return ValueListenableBuilder<List<ScanResult>>(
      valueListenable: _ble.scanResultsNotifier,
      builder: (_, scanResults, __) {
        // Matched by advertised NAME now, not MAC — see KnownDevices' class
        // doc comment for why (BLE privacy rotates the MAC every power
        // cycle, so a MAC match would never recognize a rebooted device
        // as one already in "MY DEVICES").
        final known = KnownDevices.instance.all; // (name, last-known mac)
        final unknownResults = scanResults
            .where((r) =>
                !KnownDevices.instance.isKnown(r.device.platformName.trim()))
            .toList();
        final knownLive = <_KnownEntry>[];
        for (final entry in known) {
          final name = entry.key;
          final lastMac = entry.value;
          final scan = scanResults
              .where((r) => r.device.platformName.trim() == name);
          knownLive.add(_KnownEntry(
            // Show the MAC currently seen live when in range (accurate);
            // otherwise fall back to the last one we remembered, which
            // may well be stale — it's display text only, never used to
            // connect (see _connectToKnown).
            mac: scan.isNotEmpty ? scan.first.device.remoteId.str : lastMac,
            name: name,
            rssi: scan.isEmpty ? null : scan.first.rssi,
            live: scan.isNotEmpty,
            connected: _ble.isConnectedByName(name),
          ));
        }

        return ListView(
          padding: EdgeInsets.zero,
          children: [
            if (knownLive.isNotEmpty) ...[
              _SectionLabel(text: 'MY DEVICES', tm: tm),
              const SizedBox(height: 10),
              ...knownLive.map((k) => Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _KnownDeviceCard(
                      entry: k,
                      tm: tm,
                      onTap: () => _connectToKnown(k.name, k.mac),
                      onForget: () => _forgetDevice(k.mac, k.name),
                    ),
                  )),
              const SizedBox(height: 22),
            ],
            _SectionLabel(text: 'OTHER DEVICES', tm: tm),
            const SizedBox(height: 10),
            if (unknownResults.isEmpty)
              _EmptyOtherDevices(tm: tm)
            else
              ...unknownResults.map((r) => Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _ScanResultCard(
                      result: r,
                      tm: tm,
                      onTap: () => _connectToDevice(r.device),
                    ),
                  )),
          ],
        );
      },
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════
class _SectionLabel extends StatelessWidget {
  final String text;
  final ThemeManager tm;
  const _SectionLabel({required this.text, required this.tm});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Text(
        text,
        style: TextStyle(
          color: tm.textSub,
          fontSize: 10,
          letterSpacing: 3,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _KnownEntry {
  final String mac;
  final String name;
  final int? rssi;
  final bool live;
  final bool connected;
  _KnownEntry({
    required this.mac,
    required this.name,
    required this.rssi,
    required this.live,
    required this.connected,
  });
}

class _KnownDeviceCard extends StatelessWidget {
  final _KnownEntry entry;
  final ThemeManager tm;
  final VoidCallback onTap;
  final VoidCallback onForget;
  const _KnownDeviceCard(
      {required this.entry,
      required this.tm,
      required this.onTap,
      required this.onForget});

  @override
  Widget build(BuildContext context) {
    final live = entry.live;
    final connected = entry.connected;
    final color = connected
        ? ThemeManager.green
        : live
            ? ThemeManager.cyan
            : tm.textSub;
    return GestureDetector(
      onTap: connected ? null : onTap,
      onLongPress: connected ? null : onForget,
      child: GlassCard(
        borderRadius: 16,
        accent: color,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: color.withValues(alpha: 0.15),
                border: Border.all(color: color.withValues(alpha: 0.4)),
              ),
              child: Icon(
                connected
                    ? Icons.check_circle_outline
                    : live
                        ? Icons.bluetooth_connected
                        : Icons.bluetooth,
                color: color,
                size: 16,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.name,
                    style: TextStyle(
                      color: tm.textPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Text(
                        entry.mac,
                        style: TextStyle(
                          color: tm.textSub,
                          fontSize: 10,
                          letterSpacing: 0.6,
                        ),
                      ),
                      if (entry.rssi != null) ...[
                        const SizedBox(width: 10),
                        Text(
                          '${entry.rssi} dBm',
                          style: TextStyle(
                            color: color.withValues(alpha: 0.85),
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: color.withValues(alpha: 0.3)),
              ),
              child: Text(
                connected
                    ? 'LIVE'
                    : live
                        ? 'CONNECT'
                        : 'OUT OF RANGE',
                style: TextStyle(
                  color: color,
                  fontSize: 9,
                  letterSpacing: 1.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ScanResultCard extends StatelessWidget {
  final ScanResult result;
  final ThemeManager tm;
  final VoidCallback onTap;
  const _ScanResultCard(
      {required this.result, required this.tm, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final name = result.device.platformName.isEmpty
        ? 'Unknown Device'
        : result.device.platformName;
    final bars = _rssiBars(result.rssi);

    return GestureDetector(
      onTap: onTap,
      child: GlassCard(
        borderRadius: 16,
        accent: ThemeManager.purple,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            SizedBox(
              width: 26,
              height: 20,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: List.generate(4, (i) {
                  final active = i < bars;
                  return Container(
                    width: 3.5,
                    height: 5.0 + i * 4,
                    decoration: BoxDecoration(
                      color: active
                          ? ThemeManager.purple
                          : tm.textSub.withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(1),
                    ),
                  );
                }),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    style: TextStyle(
                      color: tm.textPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Text(
                        result.device.remoteId.str,
                        style: TextStyle(
                          color: tm.textSub,
                          fontSize: 10,
                          letterSpacing: 0.6,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        '${result.rssi} dBm',
                        style: TextStyle(
                          color: ThemeManager.purple.withValues(alpha: 0.85),
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right,
                color: tm.textSub.withValues(alpha: 0.6), size: 18),
          ],
        ),
      ),
    );
  }

  int _rssiBars(int rssi) {
    if (rssi >= -60) return 4;
    if (rssi >= -75) return 3;
    if (rssi >= -85) return 2;
    if (rssi >= -95) return 1;
    return 0;
  }
}

class _EmptyOtherDevices extends StatelessWidget {
  final ThemeManager tm;
  const _EmptyOtherDevices({required this.tm});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 24),
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.bluetooth_searching,
              size: 32, color: ThemeManager.purple.withValues(alpha: 0.4)),
          const SizedBox(height: 10),
          Text(
            'Tap the radar to scan',
            style: TextStyle(
              color: tm.textSub,
              fontSize: 11,
              letterSpacing: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}
