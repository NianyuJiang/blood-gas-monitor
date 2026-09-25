import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import 'ble_manager.dart';
import 'calibration.dart';
import 'connect_flow.dart';
import 'device_session.dart';
import 'theme_manager.dart';

// ══════════════════════════════════════════════════════════════════════════
//  Scan QR page
//
//  Three modes:
//    • Device mode  (default) — scans device QRs that contain a "mac"
//      field, starts a BLE connect attempt, retries every 3s while open.
//    • Material mode — opened from the history detail page; scans a
//      material QR (kind == "capno_material_v1"), pops back with the
//      formatted text. Does NOT touch BLE.
//    • Material-calibration mode — opened from the LIVE device page to
//      attach a calibration parameter set to the active recording (see
//      device_detail_page.dart's _CalibrationBar / CsvRecorder.
//      attachCalibration). Same material QR kind, but requires a valid
//      `calib` field and pops a [MaterialScanResult] instead of a bare
//      String. Does NOT touch BLE or the live raw charts.
//
//  Use one of the static helpers below to launch it:
//      ScanQRPage.openForDevices(context)
//      ScanQRPage.pickMaterial(context)             // returns String?
//      ScanQRPage.pickMaterialForCalibration(context) // returns MaterialScanResult?
// ══════════════════════════════════════════════════════════════════════════

const String kMaterialQrKind = 'capno_material_v1';

enum _ScanMode { device, material, materialCalib }

/// Result of a successful material-calibration scan: the same formatted
/// text a plain material scan would give (for display), plus the parsed
/// calibration parameters and the raw material fields (for a `material_meta`
/// traceability line in the calibrated CSV).
class MaterialScanResult {
  final String formattedText;
  final CalibrationParams calib;
  final Map<String, dynamic> materialMeta;
  const MaterialScanResult({
    required this.formattedText,
    required this.calib,
    required this.materialMeta,
  });
}

class ScanQRPage extends StatefulWidget {
  final _ScanMode mode;
  const ScanQRPage._({super.key, required this.mode});

  /// Legacy entry point — keeps existing call sites working.
  /// Behaves identically to [openForDevices].
  const ScanQRPage({super.key}) : mode = _ScanMode.device;

  /// Open the scanner in device mode (the existing flow).
  static Future<void> openForDevices(BuildContext context) {
    return Navigator.push(
      context,
      MaterialPageRoute(
          builder: (_) => const ScanQRPage._(mode: _ScanMode.device)),
    );
  }

  /// Open the scanner in material mode. Returns the formatted text
  /// to insert into the session's material field, or null if cancelled.
  static Future<String?> pickMaterial(BuildContext context) {
    return Navigator.push<String>(
      context,
      MaterialPageRoute(
          builder: (_) => const ScanQRPage._(mode: _ScanMode.material)),
    );
  }

  /// Open the scanner to attach a calibration parameter set to the LIVE
  /// recording (called from the device detail page). Only accepts a
  /// material QR that carries a valid `calib` field — anything else shows
  /// an in-scanner error and keeps the camera open. Returns null if the
  /// user backs out.
  static Future<MaterialScanResult?> pickMaterialForCalibration(
      BuildContext context) {
    return Navigator.push<MaterialScanResult>(
      context,
      MaterialPageRoute(
          builder: (_) => const ScanQRPage._(mode: _ScanMode.materialCalib)),
    );
  }

  @override
  State<ScanQRPage> createState() => _ScanQRPageState();
}

class _ScanQRPageState extends State<ScanQRPage> {
  final MobileScannerController _ctrl = MobileScannerController(
    detectionSpeed: DetectionSpeed.normal,
    facing: CameraFacing.back,
    torchEnabled: false,
  );

  // ── Device-mode state ──
  final Map<String, _Attempt> _attempts = {};
  final ValueNotifier<List<_Attempt>> _attemptsList = ValueNotifier(const []);
  final Map<String, DateTime> _recentDecodes = {};
  Timer? _retryTimer;

  bool _torch = false;
  bool _materialHandled = false; // material-mode debounce (both variants)

  bool get _isMaterialMode => widget.mode == _ScanMode.material;
  bool get _isMaterialCalibMode => widget.mode == _ScanMode.materialCalib;
  bool get _showMaterialUi => _isMaterialMode || _isMaterialCalibMode;

  @override
  void initState() {
    super.initState();
    if (!_showMaterialUi) {
      _retryTimer = Timer.periodic(
          const Duration(seconds: 3), (_) => _retryPending());
    }
  }

  void _publish() {
    _attemptsList.value = List.unmodifiable(_attempts.values);
  }

  void _onDetect(BarcodeCapture capture) {
    for (final code in capture.barcodes) {
      final raw = code.rawValue;
      if (raw == null || raw.isEmpty) continue;
      if (_isMaterialCalibMode) {
        _handleMaterialCalibRaw(raw);
      } else if (_isMaterialMode) {
        _handleMaterialRaw(raw);
      } else {
        _handleDeviceRaw(raw);
      }
    }
  }

  // ─── Material-mode handler ────────────────────────────────────────────
  void _handleMaterialRaw(String raw) {
    if (_materialHandled) return;
    Map<String, dynamic>? meta;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) meta = decoded;
    } catch (_) {}
    if (meta == null || meta['kind'] != kMaterialQrKind) {
      _showSnack('Not a material QR code', ThemeManager.red);
      return;
    }
    _materialHandled = true;
    final formatted = _formatMaterial(meta);
    Navigator.pop(context, formatted);
  }

  String _formatMaterial(Map<String, dynamic> m) {
    String s(String key) =>
        (m[key] is String ? (m[key] as String).trim() : '');
    final parts = <String>[];
    final material = s('material');
    if (material.isNotEmpty) parts.add('Material: $material');
    final type = s('type');
    if (type.isNotEmpty) parts.add('Type: $type');
    final batch = s('batch');
    if (batch.isNotEmpty) parts.add('Batch: $batch');
    final expiry = s('expiry');
    if (expiry.isNotEmpty) parts.add('Expiry: $expiry');
    final vendor = s('vendor');
    if (vendor.isNotEmpty) parts.add('Vendor: $vendor');
    final note = s('note');
    if (note.isNotEmpty) parts.add('Note: $note');
    return parts.join('\n');
  }

  // ─── Material-calibration-mode handler ─────────────────────────────────
  // Same QR kind as a plain material scan, but requires a valid `calib`
  // field (see calibration.dart CalibrationParams.tryParse). A material QR
  // without one is a normal material QR, not a calibration error — but this
  // scanner was opened specifically to get a calibration, so it's still
  // reported here rather than silently accepted.
  void _handleMaterialCalibRaw(String raw) {
    if (_materialHandled) return;
    Map<String, dynamic>? meta;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) meta = decoded;
    } catch (_) {}
    if (meta == null || meta['kind'] != kMaterialQrKind) {
      _showSnack('Not a material QR code', ThemeManager.red);
      return;
    }
    final calib = CalibrationParams.tryParse(meta['calib']);
    if (calib == null) {
      _showSnack(
          'This material QR has no valid calibration parameters',
          ThemeManager.orange);
      return;
    }
    _materialHandled = true;
    final formatted = _formatMaterial(meta);
    Navigator.pop(
      context,
      MaterialScanResult(
          formattedText: formatted, calib: calib, materialMeta: meta),
    );
  }

  // ─── Device-mode handlers ──────────────────────────────────────────────
  void _handleDeviceRaw(String raw) {
    Map<String, dynamic>? meta;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) meta = decoded;
    } catch (_) {}

    final rawMac = meta?['mac'];
    final hasMac = rawMac is String && rawMac.trim().isNotEmpty;
    final rawName = meta?['name'];
    final hasName = rawName is String && rawName.trim().isNotEmpty;

    // Android connects by MAC, so it still needs one to recognize a
    // device QR. iOS can't use MAC at all (Core Bluetooth hides it) and
    // instead connects by advertised name, so on iOS a QR with just a
    // "name" and no "mac" is still a valid, scannable device QR.
    final recognizable = Platform.isIOS ? (hasMac || hasName) : hasMac;
    if (meta == null || !recognizable) {
      _showSnack('Unrecognized QR code', ThemeManager.red);
      return;
    }
    // Internal tracking key only (never sent to the BLE stack): the real
    // MAC when we have one, otherwise a synthetic key built from the
    // name so iOS-only, MAC-less QRs still get a stable identity here.
    final mac = hasMac
        ? (rawMac as String).toUpperCase().trim()
        : 'NAME:${(rawName as String).trim().toUpperCase()}';

    // Dedupe within 5s
    final last = _recentDecodes[mac];
    if (last != null && DateTime.now().difference(last).inSeconds < 5) {
      return;
    }
    _recentDecodes[mac] = DateTime.now();

    if (BleManager.instance.isConnected(mac)) {
      _showSnack('Already connected: $mac', ThemeManager.green);
      return;
    }

    if (BleManager.instance.isFull) {
      _showSnack(
        'Maximum $kMaxDevices devices reached. Disconnect one to add more.',
        ThemeManager.orange,
      );
      return;
    }

    _attempts[mac] = _Attempt(
      mac: mac,
      meta: meta,
      status: _AttemptStatus.connecting,
      message: 'Connecting…',
    );
    _publish();
    _tryConnect(mac);
  }

  Future<void> _tryConnect(String mac) async {
    final attempt = _attempts[mac];
    if (attempt == null) return;

    attempt.status = _AttemptStatus.connecting;
    attempt.message = 'Connecting…';
    _publish();

    // iOS hides the real BLE MAC from apps, so it can't connect using the
    // QR's "mac" field the way Android does — match by advertised device
    // name instead. Android's original MAC-based connect is unchanged.
    final ConnectResult res;
    if (Platform.isIOS) {
      final name = (attempt.meta?['name'] as String?) ?? '';
      // iOS can't know this device's real identity until connectByName()
      // finds it via the name scan, so the resume dialogs run from inside
      // that call (beforeConnect) instead of before it, the way Android's
      // MAC-based path (below) can. Same "only ask once per scan attempt"
      // guard as Android, via askedResume.
      res = await BleManager.instance.connectByName(
        name,
        meta: attempt.meta,
        beforeConnect: (remoteId) async {
          if (attempt.askedResume) return;
          attempt.askedResume = true;
          if (!mounted) return;
          await maybeShowConnectDialogs(context,
              mac: remoteId, deviceName: name);
        },
      );
    } else {
      // If this device has a prior recording, ask whether to resume it —
      // a no-op (no dialog) for any device that's never recorded before.
      // Only asked once per scan attempt (askedResume), not on every 3 s
      // retry while the device is still out of range.
      if (!attempt.askedResume) {
        attempt.askedResume = true;
        final androidName = (attempt.meta?['name'] as String?) ?? '';
        await maybeShowConnectDialogs(context,
            mac: mac, deviceName: androidName);
        if (!mounted) return;
      }
      final device = BluetoothDevice.fromId(mac);
      res = await BleManager.instance.connect(device, meta: attempt.meta);
    }
    if (!mounted) return;

    if (res.ok) {
      attempt.status = _AttemptStatus.connected;
      attempt.message = 'Connected';
      _publish();
    } else {
      attempt.status = _AttemptStatus.failed;
      attempt.message =
          _humanError(res.error) ?? 'Out of range — will keep trying';
      _publish();
    }
  }

  String? _humanError(String? raw) {
    if (raw == null) return null;
    final r = raw.toLowerCase();
    if (r.contains('timeout') ||
        r.contains('not found') ||
        r.contains('range') ||
        r.contains('androidcode 133') ||
        r.contains('disconnected')) {
      return 'Out of range — keep close, will retry';
    }
    if (r.contains('already')) return 'Already connected';
    if (r.contains('maximum')) return raw;
    return raw;
  }

  void _retryPending() {
    final macs = _attempts.entries
        .where((e) => e.value.status == _AttemptStatus.failed)
        .map((e) => e.key)
        .toList();
    for (final m in macs) {
      if (BleManager.instance.isFull) continue;
      if (BleManager.instance.isConnected(m)) {
        _attempts[m]?.status = _AttemptStatus.connected;
        _attempts[m]?.message = 'Connected';
        _publish();
        continue;
      }
      _tryConnect(m);
    }
  }

  void _showSnack(String msg, Color color) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: color,
      duration: const Duration(seconds: 2),
    ));
  }

  @override
  void dispose() {
    _retryTimer?.cancel();
    _ctrl.dispose();
    _attemptsList.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // Camera feed
          MobileScanner(
            controller: _ctrl,
            onDetect: _onDetect,
            errorBuilder: (_, error) =>
                _CameraError(error: error.errorCode.name),
          ),

          // Dimming overlay + viewfinder window
          const _ScannerOverlay(),

          // Top bar
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _RoundIconButton(
                    icon: Icons.close,
                    onTap: () => Navigator.pop(context),
                  ),
                  Text(
                    _showMaterialUi ? 'SCAN MATERIAL' : 'SCAN QR',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 4,
                    ),
                  ),
                  if (_showMaterialUi)
                    // Spacer to keep title centered
                    const SizedBox(width: 38, height: 38)
                  else
                    ValueListenableBuilder<List<DeviceSession>>(
                      valueListenable: BleManager.instance.sessionsNotifier,
                      builder: (_, sessions, __) => Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.5),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          '${sessions.length}/$kMaxDevices',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            fontFeatures: [FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),

          // Bottom area: attempts list (device mode only) + torch
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 22),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_showMaterialUi)
                      _buildMaterialHint()
                    else
                      ValueListenableBuilder<List<_Attempt>>(
                        valueListenable: _attemptsList,
                        builder: (_, list, __) {
                          if (list.isEmpty) {
                            return Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 16, vertical: 10),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.55),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: const Text(
                                'Point at a device QR code',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                  letterSpacing: 1,
                                ),
                              ),
                            );
                          }
                          return Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              for (final a in list) ...[
                                _AttemptRow(attempt: a),
                                const SizedBox(height: 6),
                              ],
                            ],
                          );
                        },
                      ),
                    const SizedBox(height: 14),
                    GestureDetector(
                      onTap: () async {
                        await _ctrl.toggleTorch();
                        setState(() => _torch = !_torch);
                      },
                      child: Container(
                        width: 56,
                        height: 56,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: _torch
                              ? Colors.white
                              : Colors.black.withValues(alpha: 0.55),
                          border: Border.all(
                              color: Colors.white.withValues(alpha: 0.5)),
                        ),
                        child: Icon(
                          _torch
                              ? Icons.flashlight_on
                              : Icons.flashlight_off,
                          color: _torch ? Colors.black : Colors.white,
                          size: 22,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMaterialHint() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        _isMaterialCalibMode
            ? 'Point at a material QR with calibration data'
            : 'Point at a material QR code',
        style: const TextStyle(
          color: Colors.white,
          fontSize: 12,
          letterSpacing: 1,
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════
enum _AttemptStatus { connecting, connected, failed }

class _Attempt {
  final String mac;
  final Map<String, dynamic> meta;
  _AttemptStatus status;
  String message;

  /// True once the "new patient? / continue from last?" dialogs have been
  /// asked for this attempt (or skipped because there was nothing to ask).
  /// _tryConnect retries every 3 s while out of range — without this flag
  /// the dialogs would re-open on every retry instead of once per scan.
  bool askedResume = false;

  _Attempt({
    required this.mac,
    required this.meta,
    required this.status,
    required this.message,
  });

  String get displayName {
    final p = (meta['patient'] as String?)?.trim();
    if (p != null && p.isNotEmpty) return p;
    final n = (meta['name'] as String?)?.trim();
    if (n != null && n.isNotEmpty) return n;
    return mac;
  }
}

class _AttemptRow extends StatelessWidget {
  final _Attempt attempt;
  const _AttemptRow({required this.attempt});

  @override
  Widget build(BuildContext context) {
    final color = switch (attempt.status) {
      _AttemptStatus.connecting => ThemeManager.cyan,
      _AttemptStatus.connected => ThemeManager.green,
      _AttemptStatus.failed => ThemeManager.orange,
    };
    final icon = switch (attempt.status) {
      _AttemptStatus.connecting => Icons.bluetooth_searching,
      _AttemptStatus.connected => Icons.check_circle,
      _AttemptStatus.failed => Icons.warning_amber_rounded,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 16),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  attempt.displayName,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  attempt.message,
                  style: TextStyle(
                    color: color.withValues(alpha: 0.9),
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _RoundIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _RoundIconButton({required this.icon, required this.onTap});
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.black.withValues(alpha: 0.55),
          border: Border.all(color: Colors.white.withValues(alpha: 0.3)),
        ),
        child: Icon(icon, color: Colors.white, size: 18),
      ),
    );
  }
}

class _CameraError extends StatelessWidget {
  final String error;
  const _CameraError({required this.error});
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.no_photography,
                color: Colors.white70, size: 48),
            const SizedBox(height: 16),
            const Text(
              'CAMERA UNAVAILABLE',
              style: TextStyle(
                color: Colors.white,
                fontSize: 12,
                letterSpacing: 3,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              error,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white60, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════
//  Viewfinder overlay — dim outside, transparent square in the middle
// ══════════════════════════════════════════════════════════════════════════
class _ScannerOverlay extends StatelessWidget {
  const _ScannerOverlay();
  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (_, c) {
        final size = c.maxWidth * 0.7;
        return Stack(
          children: [
            CustomPaint(
              size: Size(c.maxWidth, c.maxHeight),
              painter: _OverlayPainter(boxSize: size),
            ),
            Center(
              child: SizedBox(
                width: size,
                height: size,
                child: Stack(
                  children: [
                    _corner(Alignment.topLeft, false, false),
                    _corner(Alignment.topRight, true, false),
                    _corner(Alignment.bottomLeft, false, true),
                    _corner(Alignment.bottomRight, true, true),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _corner(Alignment a, bool flipH, bool flipV) {
    const t = 3.0;
    const len = 26.0;
    return Align(
      alignment: a,
      child: SizedBox(
        width: len,
        height: len,
        child: Stack(
          children: [
            Positioned(
              left: flipH ? null : 0,
              right: flipH ? 0 : null,
              top: flipV ? null : 0,
              bottom: flipV ? 0 : null,
              child: Container(width: len, height: t, color: Colors.white),
            ),
            Positioned(
              left: flipH ? null : 0,
              right: flipH ? 0 : null,
              top: flipV ? null : 0,
              bottom: flipV ? 0 : null,
              child: Container(width: t, height: len, color: Colors.white),
            ),
          ],
        ),
      ),
    );
  }
}

class _OverlayPainter extends CustomPainter {
  final double boxSize;
  _OverlayPainter({required this.boxSize});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = Colors.black.withValues(alpha: 0.55);
    final box = Rect.fromCenter(
      center: Offset(size.width / 2, size.height / 2),
      width: boxSize,
      height: boxSize,
    );
    final outer = Path()..addRect(Offset.zero & size);
    final inner =
        Path()..addRRect(RRect.fromRectAndRadius(box, const Radius.circular(18)));
    final dim = Path.combine(PathOperation.difference, outer, inner);
    canvas.drawPath(dim, paint);
  }

  @override
  bool shouldRepaint(covariant _OverlayPainter o) => o.boxSize != boxSize;
}
