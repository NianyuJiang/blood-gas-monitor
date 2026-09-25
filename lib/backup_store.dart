import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

// ══════════════════════════════════════════════════════════════════════════
//  BackupStore — "hard" data protection.
//
//  Recordings normally live in the app's PRIVATE documents directory, which
//  Android wipes when the app is uninstalled. BackupStore mirrors every
//  finished CSV into PUBLIC storage:
//
//      /storage/emulated/0/Documents/BloodGas Monitor/
//
//  Files there survive an uninstall, are visible to the Files app / MTP,
//  and can be pulled off the device without the app.
//
//  Design rules:
//   • No UI in here — pure helper. The History page drives permission.
//   • NOTHING throws. Every entry point is wrapped in try/catch and returns
//     a falsy value on failure, so a backup problem can never kill a live
//     recording.
//   • If the user never granted all-files access, the mirror silently
//     no-ops; the "Save to device" button in History is where they grant it.
// ══════════════════════════════════════════════════════════════════════════

class BackupStore {
  BackupStore._();

  /// Public folder name (also shown to the user in SnackBars).
  static const String folderName = 'BloodGas Monitor';

  /// Human-readable destination, e.g. for SnackBar copy.
  static const String displayPath = 'Documents/$folderName';

  /// Android's primary shared-storage Documents root.
  static const String _androidDocuments = '/storage/emulated/0/Documents';

  // ── Permission ────────────────────────────────────────────────────────

  /// True when we may already write to public storage (no prompt shown).
  ///
  /// Android 11+ (API 30+) needs MANAGE_EXTERNAL_STORAGE ("All files
  /// access"); Android 10 and below only need the legacy storage
  /// permission. We probe both instead of querying the SDK level so no
  /// extra plugin (device_info_plus) is required — on a version where a
  /// permission doesn't apply it simply reports not-granted.
  static Future<bool> hasPermission() async {
    try {
      if (!Platform.isAndroid) return true; // iOS: app sandbox, always OK
      if (await Permission.manageExternalStorage.isGranted) return true;
      if (await Permission.storage.isGranted) return true;
      return false;
    } catch (e) {
      debugPrint('[BACKUP] hasPermission error: $e');
      return false;
    }
  }

  /// Ask for write access if we don't have it yet. Returns whether we ended
  /// up with usable access. Never throws.
  ///
  /// On denial the caller should surface a hint and offer [openSettings]
  /// (All-files access can only be re-enabled from system settings once
  /// permanently denied).
  static Future<bool> ensurePermission() async {
    try {
      if (!Platform.isAndroid) return true;
      if (await hasPermission()) return true;

      // Android 11+ — All files access (opens a system settings screen).
      final manage = await Permission.manageExternalStorage.request();
      if (manage.isGranted) return true;

      // Android 10 and below — legacy WRITE_EXTERNAL_STORAGE.
      final legacy = await Permission.storage.request();
      if (legacy.isGranted) return true;

      debugPrint('[BACKUP] permission denied (manage=$manage legacy=$legacy)');
      return false;
    } catch (e) {
      debugPrint('[BACKUP] ensurePermission error: $e');
      return false;
    }
  }

  /// Open the OS app-settings page so the user can grant All-files access.
  static Future<bool> openSettings() async {
    try {
      return await openAppSettings();
    } catch (e) {
      debugPrint('[BACKUP] openSettings error: $e');
      return false;
    }
  }

  // ── Destination folder ────────────────────────────────────────────────

  /// `/storage/emulated/0/Documents/<folderName>/`, created if missing.
  /// Returns null (never throws) when it can't be created — e.g. no
  /// permission yet.
  static Future<Directory?> publicDir() async {
    try {
      final Directory dir;
      if (Platform.isAndroid) {
        dir = Directory('$_androidDocuments/$folderName');
      } else {
        // Non-Android: there is no shared Documents volume. Fall back to
        // the app's own documents dir so callers still work in dev/iOS.
        final root = await getApplicationDocumentsDirectory();
        dir = Directory('${root.path}/$folderName');
      }
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      return dir;
    } catch (e) {
      debugPrint('[BACKUP] publicDir error: $e');
      return null;
    }
  }

  // ── Copying ───────────────────────────────────────────────────────────

  /// Copy [csv] into the public folder. Existing files are NEVER
  /// overwritten: a name clash becomes `name (2).csv`, `name (3).csv`, …
  ///
  /// If a copy with the same name AND the same byte size already exists,
  /// this recording was already mirrored — the existing file is returned
  /// as-is so auto-mirror + a manual "Save" don't create duplicates.
  ///
  /// Returns the written (or already-present) file, or null on failure.
  static Future<File?> saveCopy(File csv, {String? asName}) async {
    try {
      if (!await csv.exists()) return null;
      final dir = await publicDir();
      if (dir == null) return null;

      final name = asName ?? csv.uri.pathSegments.last;
      final srcLen = await csv.length();

      final target = File('${dir.path}/$name');
      if (await target.exists()) {
        if (await target.length() == srcLen) {
          debugPrint('[BACKUP] already mirrored: $name');
          return target;
        }
        final unique = await _uniqueName(dir, name);
        final copied = await csv.copy('${dir.path}/$unique');
        debugPrint('[BACKUP] saved: ${copied.path}');
        return copied;
      }

      final copied = await csv.copy(target.path);
      debugPrint('[BACKUP] saved: ${copied.path}');
      return copied;
    } catch (e) {
      debugPrint('[BACKUP] saveCopy failed for ${csv.path}: $e');
      return null;
    }
  }

  /// Copy many files. Returns how many landed in public storage.
  static Future<int> saveAll(Iterable<File> files) async {
    var ok = 0;
    for (final f in files) {
      final res = await saveCopy(f);
      if (res != null) ok++;
    }
    return ok;
  }

  /// `report.csv` → `report (2).csv` → `report (3).csv` …
  static Future<String> _uniqueName(Directory dir, String name) async {
    final dot = name.lastIndexOf('.');
    final base = dot > 0 ? name.substring(0, dot) : name;
    final ext = dot > 0 ? name.substring(dot) : '';
    for (var i = 2; i < 1000; i++) {
      final candidate = '$base ($i)$ext';
      if (!await File('${dir.path}/$candidate').exists()) return candidate;
    }
    // Absurdly unlikely fallback — timestamped so it can't clash.
    return '$base (${DateTime.now().millisecondsSinceEpoch})$ext';
  }
}
