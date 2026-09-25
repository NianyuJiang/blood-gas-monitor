import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

// ══════════════════════════════════════════════════════════════════════════
//  Per-device "boot anchor" store — the missing piece that lets a history
//  backfill correctly date records from a boot epoch BEFORE the most recent
//  reboot, instead of unconditionally discarding them (see csv_recorder.dart
//  _syncAndBackfill's epoch-boundary comment for the full background).
//
//  THE IDEA: device_time_ms is only comparable to other values from the SAME
//  boot. A live-received sample's device_time_ms IS comparable to a later
//  backfilled record's device_time_ms, as long as no reboot happened in
//  between — and the live sample's real (wall-clock) time is known exactly
//  (it's just DateTime.now() at the moment it arrived over BLE, no
//  reconstruction needed). So every live sample is a perfectly trustworthy
//  "anchor" for whichever boot it was taken during — this store just
//  remembers the most useful ones instead of letting them evaporate the
//  moment a newer sample overwrites them in memory.
//
//  Deliberately a 2-slot design, not a full history:
//    current  — the freshest live (device_time_ms, wall-clock) pair seen for
//               whatever boot is running right now.
//    previous — the LAST live sample seen during the boot before that one,
//               captured automatically the instant a live sample arrives
//               whose device_time_ms is SMALLER than `current`'s (that drop
//               is exactly what a reboot looks like — see recordLiveSample).
//
//  This is enough to correctly recover the single most common real-world
//  case: a device connected live, disconnects, keeps buffering, THEN loses
//  power and reboots, THEN gets reconnected later. `previous` is exactly the
//  anchor needed to re-date the pre-reboot buffered records that arrive in
//  that later backfill — no guessing, same trustworthy linear math already
//  used for the current epoch, just applied with the anchor that actually
//  belongs to that older epoch.
//
//  It does NOT reach further back than one reboot — if the device rebooted
//  twice while unsynced, only the epoch immediately before `current` can be
//  recovered this way; anything older still gets dropped by the epoch-drop
//  logic exactly as before this store existed. Extending that would mean
//  keeping an unbounded (or capped) list instead of 2 slots — deliberately
//  not done here, since the single-reboot case is what's actually been
//  observed, and a longer list is a straightforward extension later if a
//  double-reboot-while-unsynced case ever turns out to matter in practice.
//
//  Keyed by device NAME, not MAC — same reasoning as everywhere else this
//  app tracks device identity (BLE privacy rotates the MAC every boot; the
//  advertised name is what actually stays stable). A boot epoch belongs to
//  the physical sensor, not to any particular CSV file/patient, so keying by
//  name (rather than by CSV filename, the way SessionMetadata's lastSeq is)
//  is deliberate — see connect_flow.dart's "new patient" note for the
//  related discussion of why device-level history isn't patient-scoped.
// ══════════════════════════════════════════════════════════════════════════

class BootAnchor {
  final int deviceTimeMs;
  final DateTime wallClock;
  const BootAnchor({required this.deviceTimeMs, required this.wallClock});

  Map<String, dynamic> toJson() => {
        't': deviceTimeMs,
        'w': wallClock.toIso8601String(),
      };

  static BootAnchor? tryFromJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    final t = json['t'];
    final w = json['w'];
    if (t is! int || w is! String) return null;
    final wc = DateTime.tryParse(w);
    if (wc == null) return null;
    return BootAnchor(deviceTimeMs: t, wallClock: wc);
  }
}

class BootAnchorStore {
  BootAnchorStore._();
  static final BootAnchorStore instance = BootAnchorStore._();

  static const _fileName = 'boot_anchor_store.json';

  // deviceName -> {"current": {...}, "previous": {...}?}
  Map<String, Map<String, dynamic>> _store = {};
  bool _loaded = false;

  // Same single-Future-chain serialization as SessionMetadata._writeQueue —
  // see that file's doc comment for why this matters (concurrent devices/
  // connects touching this one shared JSON file).
  Future<void> _writeQueue = Future.value();

  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    try {
      final f = await _file();
      if (await f.exists()) {
        final raw = await f.readAsString();
        final json = jsonDecode(raw) as Map<String, dynamic>;
        _store = json.map(
          (k, v) => MapEntry(k, Map<String, dynamic>.from(v as Map)),
        );
      }
    } catch (e) {
      debugPrint('[BootAnchor] load error: $e');
    }
    _loaded = true;
  }

  Future<File> _file() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$_fileName');
  }

  Future<void> _save() {
    final next = _writeQueue.then((_) => _doSave());
    _writeQueue = next;
    return next;
  }

  Future<void> _doSave() async {
    try {
      final f = await _file();
      // Write-to-temp-then-rename — same crash-safety reasoning as
      // SessionMetadata._doSave: never leaves behind a half-written file.
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(jsonEncode(_store));
      await tmp.rename(f.path);
    } catch (e) {
      debugPrint('[BootAnchor] save error: $e');
    }
  }

  /// Called from CsvRecorder._onSample for every LIVE sample that carries a
  /// device_time_ms (older firmware without the history feature sends null
  /// here — nothing to anchor, silently a no-op). Detects a reboot exactly
  /// the same way the backfill epoch-splitter does (a drop in device_time_ms
  /// relative to the last-known value for this device) and, when one is
  /// detected, archives the about-to-be-overwritten `current` anchor into
  /// `previous` first so it isn't lost.
  Future<void> recordLiveSample(
      String deviceName, int deviceTimeMs, DateTime wallClock) async {
    if (deviceName.trim().isEmpty) return;
    await _ensureLoaded();

    final entry = _store[deviceName] ?? <String, dynamic>{};
    final current = BootAnchor.tryFromJson(
        entry['current'] as Map<String, dynamic>?);

    if (current != null && deviceTimeMs < current.deviceTimeMs) {
      // device_time_ms just went backwards relative to what we last saw for
      // this device — the only way that happens is a reboot occurred
      // between the previous live sample and this one. Preserve the boot
      // that just ended as `previous` before overwriting `current`.
      entry['previous'] = current.toJson();
    }
    entry['current'] =
        BootAnchor(deviceTimeMs: deviceTimeMs, wallClock: wallClock).toJson();
    _store[deviceName] = entry;

    await _save();
  }

  /// The freshest live-observed anchor for [deviceName]'s current boot, or
  /// null if this device has never sent a live sample carrying device_time_ms.
  Future<BootAnchor?> getCurrent(String deviceName) async {
    await _ensureLoaded();
    return BootAnchor.tryFromJson(
        _store[deviceName]?['current'] as Map<String, dynamic>?);
  }

  /// The last live-observed anchor from the boot immediately BEFORE the
  /// current one, or null if no reboot has ever been observed live for this
  /// device (or the app was reinstalled/never connected live before it).
  Future<BootAnchor?> getPrevious(String deviceName) async {
    await _ensureLoaded();
    return BootAnchor.tryFromJson(
        _store[deviceName]?['previous'] as Map<String, dynamic>?);
  }
}
