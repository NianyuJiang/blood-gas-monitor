import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

// ══════════════════════════════════════════════════════════════════════════
//  Sidecar metadata (custom name + notes + material) per CSV recording.
//
//  Stored as a single JSON file in the app documents directory:
//    {
//      "CAPNO_xxx.csv": {
//        "name":     "...",
//        "notes":    "...",
//        "material": "...",   // formatted text block, scanned from QR
//      },
//      ...
//    }
//
//  Keyed by CSV filename. When a CSV is deleted or renamed, the sidecar
//  entry is removed or renamed in sync.
// ══════════════════════════════════════════════════════════════════════════
class SessionMetadata {
  SessionMetadata._();
  static final SessionMetadata instance = SessionMetadata._();

  static const _fileName = 'session_metadata.json';
  Map<String, Map<String, String>> _store = {};
  bool _loaded = false;

  // Serializes every _save() call through a single Future chain so two
  // concurrent writers (e.g. a history-buffer backfill's setLastSeq
  // racing _populateSidecar's setName/setNotes on a fresh connect, or two
  // devices' CsvRecorder states both touching this one shared JSON file)
  // can never interleave their writeAsString() calls. Without this, two
  // overlapping saves could each read/modify/write _store independently
  // and the loser's write would silently clobber the other's — or, if
  // truly interleaved at the OS level, corrupt the file outright, which
  // _ensureLoaded() below would then treat as "no metadata yet" and wipe
  // every recording's saved title/notes/lastSeq watermark.
  Future<void> _writeQueue = Future.value();

  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    try {
      final f = await _file();
      if (await f.exists()) {
        final raw = await f.readAsString();
        final json = jsonDecode(raw) as Map<String, dynamic>;
        _store = json.map(
          (k, v) => MapEntry(k, Map<String, String>.from(v as Map)),
        );
      }
    } catch (e) {
      debugPrint('[Meta] load error: $e');
    }
    _loaded = true;
  }

  Future<File> _file() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$_fileName');
  }

  /// Queues this save behind any save already in flight (see
  /// [_writeQueue]'s doc comment) and returns a future that completes once
  /// THIS save has actually landed on disk.
  Future<void> _save() {
    final next = _writeQueue.then((_) => _doSave());
    _writeQueue = next;
    return next;
  }

  Future<void> _doSave() async {
    try {
      final f = await _file();
      // Write-to-temp-then-rename instead of writing the real file
      // directly: a crash/kill mid-write can only ever leave behind a
      // stray .tmp file, never a half-written session_metadata.json. A
      // rename onto an existing file is atomic on both iOS/Android
      // filesystems, so readers never observe a partial file either.
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(jsonEncode(_store));
      await tmp.rename(f.path);
    } catch (e) {
      debugPrint('[Meta] save error: $e');
    }
  }

  // ── Public API ────────────────────────────────────────────────────────
  Future<String> getName(String csvFilename) async {
    await _ensureLoaded();
    return _store[csvFilename]?['name'] ?? '';
  }

  Future<String> getNotes(String csvFilename) async {
    await _ensureLoaded();
    return _store[csvFilename]?['notes'] ?? '';
  }

  Future<String> getMaterial(String csvFilename) async {
    await _ensureLoaded();
    return _store[csvFilename]?['material'] ?? '';
  }

  /// Highest firmware history-buffer sequence number already pulled into
  /// this CSV, so a later resume only requests records after it (delta
  /// sync). 0 if this recording has never been synced (including every
  /// recording made before this feature existed — they simply request
  /// "everything," which is the correct/safe default).
  Future<int> getLastSeq(String csvFilename) async {
    await _ensureLoaded();
    return int.tryParse(_store[csvFilename]?['lastSeq'] ?? '') ?? 0;
  }

  Future<void> setLastSeq(String csvFilename, int seq) async {
    await _ensureLoaded();
    final entry = _store[csvFilename] ?? <String, String>{};
    entry['lastSeq'] = seq.toString();
    _store[csvFilename] = entry;
    await _save();
  }

  Future<void> setName(String csvFilename, String name) async {
    await _ensureLoaded();
    final entry = _store[csvFilename] ?? <String, String>{};
    entry['name'] = name;
    _store[csvFilename] = entry;
    await _save();
  }

  Future<void> setNotes(String csvFilename, String notes) async {
    await _ensureLoaded();
    final entry = _store[csvFilename] ?? <String, String>{};
    entry['notes'] = notes;
    _store[csvFilename] = entry;
    await _save();
  }

  Future<void> setMaterial(String csvFilename, String material) async {
    await _ensureLoaded();
    final entry = _store[csvFilename] ?? <String, String>{};
    entry['material'] = material;
    _store[csvFilename] = entry;
    await _save();
  }

  Future<void> rename(String oldName, String newName) async {
    await _ensureLoaded();
    final entry = _store.remove(oldName);
    if (entry != null) {
      _store[newName] = entry;
      await _save();
    }
  }

  Future<void> remove(String csvFilename) async {
    await _ensureLoaded();
    if (_store.remove(csvFilename) != null) await _save();
  }
}
