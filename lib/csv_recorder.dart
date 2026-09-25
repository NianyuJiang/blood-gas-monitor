import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';

import 'backup_store.dart';
import 'ble_history_sync.dart';
import 'ble_manager.dart';
import 'boot_anchor_store.dart';
import 'calibration.dart';
import 'device_session.dart';
import 'gas_params.dart';
import 'session_metadata.dart';

// ══════════════════════════════════════════════════════════════════════════
//  Multi-session CSV recorder.
//
//  Each connected DeviceSession gets its own _RecordingState — independent
//  IOSink, row counter, start time, filename. Sessions don't interfere.
//
//  Records ALL 9 parameters (see gas_params.dart) per row.
//
//  File naming:  GASMON_<patient_or_devN>_<startYMD_HMS>__<endYMD_HMS>.csv
//
//  When a recording starts, we auto-populate session_metadata.json from
//  the QR-supplied dict:
//     title  ← device name (only when no title is set yet)
//     notes  ← formatted block: Device / Age / Note / Connected
// ══════════════════════════════════════════════════════════════════════════

class CsvRecorder {
  CsvRecorder._();
  static final CsvRecorder instance = CsvRecorder._();

  final Map<String, _RecState> _states = {}; // keyed by MAC
  StreamSubscription? _sampleSub;
  StreamSubscription? _sessionsSub;

  bool _initialized = false;

  // ── Backfill-in-flight guard ─────────────────────────────────────────
  //
  // Keyed by CSV filename (the recording's stable identity — see
  // mostRecentRecordingForName's doc comment), NOT by mac: a device can
  // reconnect under a rotated BLE MAC (privacy is on) while still being
  // "the same recording" on disk. Without this guard, a flaky/rapid
  // reconnect sequence could fire a SECOND _syncAndBackfill() for the
  // same file while an earlier one is still awaiting its BLE round-trip.
  // Both would then read SessionMetadata's lastSeq BEFORE either had
  // written it back (that watermark is only persisted once, at the very
  // end of a successful sync — see _syncAndBackfill), so both would
  // request/receive an overlapping (often near-identical) range and
  // both would append it — independently re-anchoring each record's
  // timestamp to their own call's DateTime.now(). That's exactly the
  // "duplicate blocks with slightly different timestamps" bug: this set
  // makes a second concurrent attempt for the same file a no-op instead.
  final Set<String> _syncInFlight = {};

  // ── Resume ("continue from last recording?") ────────────────────────────
  //
  // Populated by the UI (see connect_flow.dart) BEFORE BleManager.connect()
  // is called, if the nurse answered "continue from last" in the two
  // connect-time dialogs. _start() checks and consumes this the instant a
  // session appears; when nothing was primed here, _start() runs its
  // ORIGINAL body completely unchanged — a device that was never asked
  // about (no prior recording), or where the answer was "new patient" /
  // "no" to resuming, behaves exactly as it did before this feature existed.
  final Map<String, RecordingInfo> _pendingResume = {};

  /// Most recent RAW (non-calibrated) recording on disk for this DEVICE
  /// NAME, or null if this device has never recorded before.
  ///
  /// Matched by name rather than BLE MAC/remoteId on purpose: with
  /// CONFIG_BT_PRIVACY=y on the firmware, the device's BLE address now
  /// rotates on every power cycle, so a MAC-based match would treat the
  /// SAME physical sensor as a brand-new device every time it's rebooted.
  /// The device's advertised name is what actually stays stable across
  /// power cycles (it's what a nurse renames per-unit), so that's the
  /// right identity to track continuity by. Matched the same way filenames
  /// already tie a recording to a device elsewhere in this file (the
  /// _deviceTag suffix) — cheap (no file contents read) and consistent
  /// with the rest of the naming scheme.
  static Future<RecordingInfo?> mostRecentRecordingForName(String name) async {
    if (name.trim().isEmpty) return null; // no name to match — nothing to resume
    final tag = '_${_deviceTag(name)}_';
    final all = await listRecordings(); // newest-first already
    for (final r in all) {
      if (r.name.contains('_CALIBRATED_')) continue; // resume targets a raw file
      if (r.name.contains(tag)) return r;
    }
    return null;
  }

  /// Called by the UI when the nurse chooses "continue from last recording"
  /// for [mac], before connecting. The next _start() for this mac will
  /// resume [previous] instead of creating a fresh file.
  void markPendingResume(String mac, RecordingInfo previous) {
    _pendingResume[mac] = previous;
  }

  // ── Lifecycle ─────────────────────────────────────────────────────────
  void init() {
    if (_initialized) return;
    _initialized = true;

    // Data-safety on startup: finalize any recording orphaned by a previous
    // crash/kill, and purge trash items past their 30-day retention.
    _recoverAndPurge();

    // Per-sample → write the right session's row
    _sampleSub = BleManager.instance.sampleStream.listen(_onSample);

    // Watch session add/remove to start & stop recordings automatically
    _sessionsSub =
        _seToStream().listen((sessions) => _reconcile(sessions));
  }

  // Adapt the ValueNotifier into a stream for the listener
  Stream<List<DeviceSession>> _seToStream() {
    final controller = StreamController<List<DeviceSession>>();
    final notifier = BleManager.instance.sessionsNotifier;
    void emit() => controller.add(notifier.value);
    notifier.addListener(emit);
    controller.onCancel = () => notifier.removeListener(emit);
    return controller.stream;
  }

  Future<void> _reconcile(List<DeviceSession> active) async {
    final activeMacs = active.map((s) => s.mac).toSet();

    // Start a recording for any new session
    for (final s in active) {
      if (!_states.containsKey(s.mac)) {
        await _start(s);
      }
    }
    // Stop recordings for sessions that are no longer active
    for (final mac in _states.keys.toList()) {
      if (!activeMacs.contains(mac)) {
        await _stop(mac);
      }
    }
  }

  // ── Start ─────────────────────────────────────────────────────────────
  Future<void> _start(DeviceSession session) async {
    final resumeTarget = _pendingResume.remove(session.mac);
    if (resumeTarget != null) {
      await _resumeStart(session, resumeTarget);
      return;
    }
    try {
      final dir = await _recordingsDir();
      final now = DateTime.now();
      final patientSlug = _slug(session.patient ?? 'dev${session.slot}');

      // The device tag keeps concurrent sessions apart: two probes on the
      // SAME patient started in the same second would otherwise generate an
      // identical filename and the second would truncate the first.
      final prefix = 'GASMON_${patientSlug}_${_deviceTag(session.displayName)}';
      final pending =
          await _uniqueName(dir, prefix, '_${_stamp(now)}__pending.csv');
      final file = File('${dir.path}/$pending');
      await file.create(recursive: true); // exists before the next _start runs
      final sink = file.openWrite(mode: FileMode.write);

      sink.writeln('# BloodGas Session');
      sink.writeln('mac,${session.mac}');
      sink.writeln('slot,${session.slot}');
      sink.writeln('start_iso,${now.toIso8601String()}');
      sink.writeln('end_iso,');
      // Embed QR meta as comments so the CSV is self-describing. Quoted so
      // a value containing a comma (a free-text note, most often) stays one
      // CSV field instead of spilling into extra columns.
      for (final key in const ['name', 'patient', 'age', 'note']) {
        final v = session.meta[key];
        if (v != null && v.toString().isNotEmpty) {
          sink.writeln('${key}_meta,${_csvQuote(v.toString())}');
        }
      }
      sink.writeln('---');
      sink.writeln('time,${kAllParams.map((p) => p.csvKey).join(',')}');

      _states[session.mac] = _RecState(
        session: session,
        file: file,
        sink: sink,
        startTime: now,
      );

      // Populate sidecar metadata (title + notes) from QR info
      await _populateSidecar(session, file, now);

      debugPrint('[CSV] start ${session.mac} → ${file.path}');
    } catch (e) {
      debugPrint('[CSV] start failed for ${session.mac}: $e');
    }
  }

  // ── Resume ("continue from last recording?") ────────────────────────────
  //
  // How long a gap between two samples has to be before it gets called out
  // as "missing data" in the file's header rather than treated as normal
  // sampling jitter or a brief BLE hiccup. BG_MINI samples/notifies about
  // every ~30 s (two 15 s phases in pO2_measure_thread), so 5 minutes is
  // ~10x the nominal interval. (The NICU app uses 20 min because its
  // device was changed to a ~300 s interval.) If the BG firmware's
  // sampling interval is ever lengthened, raise this to ~4-10x it.
  static const Duration kMissingGapThreshold = Duration(minutes: 5);

  /// Reopens [previous] (the device's last recording) in append mode and
  /// registers it exactly like a freshly-started one, then kicks off a
  /// background history-sync to backfill whatever the device buffered while
  /// this app wasn't connected. Never touches the normal fresh-start code
  /// path in _start() above.
  Future<void> _resumeStart(DeviceSession session, RecordingInfo previous) async {
    try {
      // Capture the file's REAL last-pause time before the next line
      // overwrites it. `previous.endTime` (parsed from the FILENAME) is NOT
      // this — a resumed file's filename is only ever set once, at its
      // very first finalize, and deliberately never renamed again on later
      // resumes (see the isResumed branch in _stop() below), so on a
      // SECOND or later resume `previous.endTime` silently points at the
      // file's first-ever pause instead of its most recent one. The
      // header's own end_iso line, in contrast, DOES get correctly patched
      // on every pause (see _stop()'s isResumed branch), so reading it here
      // — right now, before anything touches it again — is the actual most
      // recent live-recording boundary. Falls back to previous.endTime if
      // the header can't be read/parsed for any reason, so this can never
      // make things worse than before.
      final realBoundary = await _readEndIso(previous.file) ?? previous.endTime;

      // Mark the file "in progress" again — it was last written with a
      // real end_iso when the previous connection stopped. This is a
      // plain read-rewrite of the whole (small) file, so it must happen
      // BEFORE the append-mode sink below is opened — two file handles
      // open on the same file at once (one appending, one truncating and
      // rewriting) would race and corrupt it, exactly why appendNote()
      // elsewhere in this file always closes its sink before doing this
      // same kind of header edit and only reopens it afterward.
      await _patchEndIso(previous.file, DateTime.now());
      final sink = previous.file.openWrite(mode: FileMode.append);

      _states[session.mac] = _RecState(
        session: session,
        file: previous.file,
        sink: sink,
        startTime: previous.startTime ?? previous.modified,
        isResumed: true,
        // Non-zero so _stop()'s "drop empty files" check never deletes a
        // resumed file just because THIS connection happened to add zero
        // new live rows before disconnecting again — it already holds all
        // of its earlier data regardless.
        rowCount: 1,
      );

      debugPrint('[CSV] resumed ${session.mac} → ${previous.file.path}');

      // Deliberately not awaited: pulling and writing potentially ~1920
      // buffered records shouldn't hold up _reconcile()/_start() or block
      // the live 30 s sample stream from flowing into the same file in the
      // meantime (_onSample keeps appending live rows to st.sink exactly
      // as normal throughout).
      unawaited(_syncAndBackfill(session, previous, realBoundary));
    } catch (e) {
      debugPrint('[CSV] resume failed for ${session.mac}: $e');
    }
  }

  /// Reads the CURRENT value of a file's `end_iso,` header line, or null if
  /// the file can't be read or that line is missing/unparseable/blank (a
  /// brand-new, never-paused recording has an empty end_iso — see _start()).
  static Future<DateTime?> _readEndIso(File f) async {
    try {
      final lines = await f.readAsLines();
      for (var i = 0; i < lines.length && i < 12; i++) {
        if (lines[i].startsWith('end_iso,')) {
          return DateTime.tryParse(lines[i].substring(8).trim());
        }
      }
    } catch (_) {}
    return null;
  }

  /// Pulls every device-buffered record newer than this recording's
  /// last-synced sequence number, appends them to the file with their real
  /// (back-calculated) timestamps, and inserts a "missing data" header note
  /// for any gap over [kMissingGapThreshold]. Silently does nothing if the
  /// device has no history-sync characteristic (older firmware) or the
  /// sync otherwise fails — the resumed recording still works fine with
  /// live-only data from this point forward.
  Future<void> _syncAndBackfill(
      DeviceSession session, RecordingInfo previous, DateTime? boundary) async {
    final csvName = previous.name;

    // See _syncInFlight's doc comment: a second backfill for the SAME
    // file (possibly from a different mac after a BLE-privacy address
    // rotation) while one is already running would both read the same
    // stale lastSeq watermark and both append an overlapping range.
    // Refuse instead of racing.
    if (_syncInFlight.contains(csvName)) {
      debugPrint('[CSV] backfill already in progress for $csvName — '
          'skipping duplicate request');
      return;
    }
    _syncInFlight.add(csvName);

    final st = _states[session.mac];
    // Mark "syncing" for this whole operation — from right before the
    // (slow, up-to-90s) BLE round-trip starts until this function's own
    // rows are safely written — so _onSample() queues any live sample
    // that arrives in the meantime instead of racing ahead of the
    // backfilled (older) data it's about to write. See _RecState.syncing.
    if (st != null) st.syncing = true;
    try {
      final sinceSeq = await SessionMetadata.instance.getLastSeq(csvName);
      final records = await BleHistorySync.sync(
        session.device,
        sinceSeq: sinceSeq,
      );
      if (records == null || records.isEmpty) {
        return; // no sync characteristic, or genuinely nothing new
      }

      // ── Boot-epoch boundary detection ──────────────────────────────
      //
      // device_time_ms (main.c's k_uptime_get_32()) is uptime SINCE THE
      // CURRENT BOOT ONLY — it resets to near-zero on every power cycle —
      // while seq is monotonic and PERSISTED ACROSS power cycles. So one
      // synced batch can span multiple boot epochs: e.g. seq 100 was
      // written late in boot A (device_time_ms ≈ 900000), the device was
      // then power-cycled, and seq 101 was written early in boot B
      // (device_time_ms ≈ 5000). Anchoring every record's timestamp off
      // ONE (anchorWallClock, anchorDeviceMs) pair — which is correct
      // WITHIN a single boot, and is exactly what device_time_ms exists
      // for — would produce a bogus timestamp for any record from an
      // earlier boot, because the same device_time_ms delta means a
      // completely different real-world gap depending which epoch it's
      // measured against. `records.last.seq` still advances lastSeq past
      // every record below regardless of which epoch it ends up in (see
      // setLastSeq call further down), so nothing here is ever
      // re-requested on a future sync either way.
      var epochStart = 0;
      for (var i = 1; i < records.length; i++) {
        if (records[i].deviceTimeMs < records[i - 1].deviceTimeMs) {
          epochStart = i;
        }
      }
      final currentEpochRecords = records.sublist(epochStart);
      final preEpochRecords = records.sublist(0, epochStart); // usually empty

      // Current epoch always anchors off "now": walk every record backward
      // from the NEWEST (highest-seq) record's device_time_ms by the
      // uptime difference. This is exactly what device_time_ms exists for
      // — see its declaration comment in main.c and ble_manager.dart.
      final anchorWallClock = DateTime.now();
      final anchorDeviceMs = records.last.deviceTimeMs;
      DateTime timestampOfCurrent(HistorySample s) => anchorWallClock
          .subtract(Duration(milliseconds: anchorDeviceMs - s.deviceTimeMs));

      // Try to recover the pre-reboot segment (if any) instead of always
      // discarding it. See boot_anchor_store.dart: every LIVE sample this
      // app has ever received is a trustworthy (device_time_ms,
      // real-wall-clock) pair for whatever boot it arrived during — no
      // reconstruction needed, it's just "what time was it right then."
      // `previous` is the last such pair observed for the boot immediately
      // before the current one. If it's on file AND it plausibly belongs
      // to THIS pre-epoch segment (its device_time_ms can't exceed the
      // segment's own highest device_time_ms — device_time_ms only
      // increases within one boot, so a larger value could not have come
      // from this same, earlier boot), the exact same trustworthy linear
      // math above applies just as well here — it just needs the anchor
      // that actually belongs to that older boot instead of "now". Only
      // reaches back ONE reboot (see boot_anchor_store.dart's doc comment
      // for why) — a segment two or more reboots back still has no anchor
      // available and is dropped, exactly as before this fix.
      var recoveredPreEpoch = const <HistorySample>[];
      DateTime Function(HistorySample)? timestampOfPreEpoch;
      var unrecoverableCount = 0;
      if (preEpochRecords.isNotEmpty) {
        final prevAnchor =
            await BootAnchorStore.instance.getPrevious(session.displayName);
        if (prevAnchor != null &&
            prevAnchor.deviceTimeMs <= preEpochRecords.last.deviceTimeMs) {
          recoveredPreEpoch = preEpochRecords;
          final anchor = prevAnchor;
          timestampOfPreEpoch = (s) => anchor.wallClock.add(
              Duration(milliseconds: s.deviceTimeMs - anchor.deviceTimeMs));
          debugPrint('[CSV] recovered ${preEpochRecords.length} pre-reboot '
              'record(s) for $csvName using a remembered boot anchor');
        } else {
          unrecoverableCount = preEpochRecords.length;
          debugPrint('[CSV] dropping $unrecoverableCount pre-reboot '
              'record(s) from this sync for $csvName (no usable boot '
              'anchor on file — no RTC to date them)');
        }
      }

      // One chronologically-ordered (record, real timestamp) list — the
      // recovered pre-epoch segment (if any) first, since it's older, then
      // the current epoch. Both segments are already seq/time-ordered
      // internally, so concatenating keeps the whole thing ordered.
      final timedRecords = <MapEntry<HistorySample, DateTime>>[
        for (final r in recoveredPreEpoch)
          MapEntry(r, timestampOfPreEpoch!(r)),
        for (final r in currentEpochRecords)
          MapEntry(r, timestampOfCurrent(r)),
      ];

      // Gap detection: the boundary between "when this recording was last
      // active" and the first backfilled sample, plus any gaps between
      // consecutive backfilled samples themselves (e.g. the device itself
      // missed a window, or was power-cycled mid-buffer). A note only ever
      // gets inserted for a gap that's REAL — i.e. still shows up as a
      // large jump between two records this code trusts the timestamp of.
      // A disconnect that got fully recovered — whether within one boot,
      // or across a reboot via the anchor above — produces normally-spaced
      // records with no such jump, so it gets no note at all: silence here
      // means "reconnected and fully synced," not "nothing happened."
      DateTime? prevTs = boundary;
      final gapNotes = <String>[];
      final dataLines = <String>[];
      final fmt = DateFormat('HH:mm:ss');

      for (final entry in timedRecords) {
        final rec = entry.key;
        final ts = entry.value;

        // Skip any backfilled record that lands at or before `boundary`
        // (when this file was last actively recording live). The
        // firmware's own seq filter (sinceSeq) only protects against
        // re-fetching what a PRIOR SYNC already pulled — it has no idea
        // what the app already captured through the plain live-notify
        // path, which never touches lastSeq at all. So the very first
        // sync for a file (sinceSeq starts at 0, correctly, since
        // nothing has been SYNCED yet) legitimately receives the
        // device's whole buffer — including whatever span this
        // recording already has as live rows from before this sync ever
        // ran. Anything computed to fall at/before `boundary` is
        // guaranteed to already be on disk, so writing it again here
        // would just duplicate it under a re-anchored timestamp. This
        // also acts as a safety net against the device (or a stray BLE
        // retry) redelivering an already-synced range a second time
        // within one sync — that range is always <= boundary too, once
        // it's been through here once.
        if (boundary != null && !ts.isAfter(boundary)) {
          continue;
        }

        if (prevTs != null && ts.difference(prevTs) > kMissingGapThreshold) {
          gapNotes.add('note_log,${fmt.format(ts)},'
              '${_csvQuote('Missing data from ${fmt.format(prevTs)} - ${fmt.format(ts)}')}');
        }
        prevTs = ts;

        final vals =
            kAllParams.map((p) => (rec.values[p] ?? double.nan).toStringAsFixed(4)).join(',');
        dataLines.add('${_timestamp(ts)},$vals');
      }

      // A separate, distinctly-worded note for any records dropped as
      // genuinely unrecoverable — this is NOT the same thing as a real
      // device-off gap (a "Missing data" note above): this data actually
      // existed on the device with real values, it just couldn't be dated
      // with any confidence, so rather than guess it was left out.
      if (unrecoverableCount > 0) {
        final noteTs = timedRecords.isNotEmpty
            ? fmt.format(timedRecords.first.value)
            : fmt.format(DateTime.now());
        gapNotes.add('note_log,$noteTs,'
            '${_csvQuote('$unrecoverableCount buffered record(s) '
                '(seq ${preEpochRecords.first.seq}-${preEpochRecords.last.seq}) '
                'from before a device reboot could not be dated (no time '
                'reference available) and were discarded')}');
      }

      // Insert any gap notes into the header block first (same
      // insert-before-`---` pattern as appendNote), then append the
      // backfilled data rows.
      if (gapNotes.isNotEmpty) {
        try {
          if (st != null) {
            await st.sink.flush();
            await st.sink.close();
          }
          final lines = await previous.file.readAsLines();
          final dividerIdx = lines.indexOf('---');
          if (dividerIdx != -1) {
            lines.insertAll(dividerIdx, gapNotes);
            await previous.file.writeAsString('${lines.join('\n')}\n');
          }
        } catch (e) {
          debugPrint('[CSV] backfill gap-note insert error: $e');
        } finally {
          if (st != null) {
            st.sink = previous.file.openWrite(mode: FileMode.append);
          }
        }
      }

      final appendSink = st?.sink ?? previous.file.openWrite(mode: FileMode.append);
      for (final line in dataLines) {
        appendSink.writeln(line);
      }
      await appendSink.flush();
      if (st == null) {
        await appendSink.close(); // session already gone (fast disconnect)
      }

      await SessionMetadata.instance.setLastSeq(csvName, records.last.seq);
      debugPrint('[CSV] backfilled ${records.length} record(s) into $csvName '
          '(${gapNotes.length} gap note(s))');
    } catch (e) {
      debugPrint('[CSV] backfill failed for ${session.mac}: $e');
    } finally {
      _syncInFlight.remove(csvName);
      if (st != null) {
        st.syncing = false;
        if (st.pendingLiveLines.isNotEmpty) {
          try {
            for (final line in st.pendingLiveLines) {
              st.sink.writeln(line);
            }
            await st.sink.flush();
          } catch (e) {
            debugPrint('[CSV] pending-line flush error for ${session.mac}: $e');
          } finally {
            st.pendingLiveLines.clear();
          }
        }
      }
    }
  }

  Future<void> _populateSidecar(
      DeviceSession s, File csvFile, DateTime startedAt) async {
    final csvName = csvFile.uri.pathSegments.last;
    final devName = (s.meta['name'] as String?)?.trim();

    // Title = "<device name> - <date>", e.g. "BG_MINI_01 - 09/17/2026" —
    // never just the bare device name, so reusing the same device across
    // multiple sessions doesn't leave them all showing an identical title
    // in History. Only fill it in when no title exists yet — never
    // overwrite a name the user has manually edited.
    final existingTitle = await SessionMetadata.instance.getName(csvName);
    if (existingTitle.isEmpty) {
      await SessionMetadata.instance
          .setName(csvName, _sessionTitle(s, startedAt));
    }

    // Notes — format A: labelled multi-line.
    // Notes are session-specific and shouldn't be merged with previous
    // content (this is a brand-new CSV), so it's safe to overwrite.
    final lines = <String>[];
    final noteDev = devName ?? '';
    if (noteDev.isNotEmpty) {
      lines.add('Device: $noteDev');
    } else if (s.device.platformName.isNotEmpty) {
      lines.add('Device: ${s.device.platformName}');
    }
    final patient = (s.meta['patient'] as String?)?.trim();
    if (patient != null && patient.isNotEmpty) {
      lines.add('Patient: $patient');
    }
    final age = s.meta['age'];
    if (age != null && age.toString().isNotEmpty) {
      lines.add('Age: $age');
    }
    final note = (s.meta['note'] as String?)?.trim();
    if (note != null && note.isNotEmpty) {
      lines.add('Note: $note');
    }
    lines.add(
        'Connected: ${DateFormat('yyyy-MM-dd HH:mm:ss').format(startedAt)}');

    if (lines.isNotEmpty) {
      await SessionMetadata.instance.setNotes(csvName, lines.join('\n'));
    }
  }

  // ── Per-sample write ──────────────────────────────────────────────────
  void _onSample(SampleEvent ev) {
    final st = _states[ev.session.mac];
    if (st == null) return;
    final now = DateTime.now();

    // Every LIVE sample (as opposed to a backfilled one) is a perfectly
    // trustworthy (device_time_ms, real wall-clock) pair — no reconstruction
    // involved, it's just "what time is it right now." Remember it as a
    // boot anchor so a LATER backfill spanning a reboot can correctly date
    // records from the boot that just ended, instead of discarding them.
    // See boot_anchor_store.dart for the full reasoning. Fire-and-forget:
    // this must never block or fail the live sample write below it.
    if (ev.deviceTimeMs != null) {
      unawaited(BootAnchorStore.instance
          .recordLiveSample(ev.session.displayName, ev.deviceTimeMs!, now));
    }

    final vals =
        kAllParams.map((p) => ev.value(p).toStringAsFixed(4)).join(',');
    final line = '${_timestamp(now)},$vals';
    if (st.syncing) {
      // A history-buffer backfill is in progress for this device and
      // hasn't written its (older) rows yet — queue this live row instead
      // of writing it now, so it can't land ahead of the backfilled data.
      // See _RecState.syncing and _syncAndBackfill.
      st.pendingLiveLines.add(line);
      st.rowCount++;
    } else {
      try {
        st.sink.writeln(line);
        st.rowCount++;
        // Flush EVERY row: samples arrive ~30 s apart, so the cost is
        // trivial and it guarantees data is on disk even if the app is
        // killed/crashes.
        st.sink.flush();
      } catch (e) {
        debugPrint('[CSV] write error for ${ev.session.mac}: $e');
      }
    }

    // Calibrated companion file — only written once a material QR carrying
    // calibration parameters has been scanned for this recording (see
    // attachCalibration). Entirely additive: nothing above this block, the
    // live charts, or DeviceSession are touched by this.
    final calib = st.calib;
    final calSink = st.calSink;
    if (calib != null && calSink != null) {
      try {
        calSink.writeln('${_timestamp(now)},${_calibratedRow(calib, ev)}');
        st.calRowCount++;
        calSink.flush();
      } catch (e) {
        debugPrint('[CSV] calibrated write error for ${ev.session.mac}: $e');
      }
    }
  }

  /// One calibrated data row, in the SAME column order as the raw file
  /// (`kAllParams`): po2_lifetime, po2_intensity, pco2_ratio, temperature,
  /// pd_405, pd_470. Only the four physiological channels are converted —
  /// pd_405/pd_470 are recorded unchanged since they're raw inputs to the
  /// pCO2 ratio, not a physiological quantity of their own. NOTE:
  /// temperature is NOT left raw either — it's replaced with the
  /// device→reference CORRECTED temperature (calib.correctedTemperature),
  /// same as what feeds the pCO2 formula, since that's the best available
  /// estimate of the true temperature. See calibration.dart for the
  /// mapping functions and their unit caveat.
  ///
  /// [value] is a lookup rather than a concrete SampleEvent so this same
  /// logic serves both a live sample (_calibratedRow) and a historical row
  /// read back off disk (_backfillCalibratedRows).
  static String _calibratedRowFromValues(
      CalibrationParams calib, double Function(GasParam) value) {
    // Shared with the live Gas Monitor view — see calibration.dart's
    // applyTo() doc comment. One implementation, used by both the
    // calibrated CSV writer here and DeviceSession's live RAW/CALIB
    // switch, so they can never drift apart.
    final row = calib.applyTo(value);
    return kAllParams
        .map((p) => (row[p] ?? double.nan).toStringAsFixed(4))
        .join(',');
  }

  static String _calibratedRow(CalibrationParams calib, SampleEvent ev) =>
      _calibratedRowFromValues(calib, (p) => ev.value(p));

  /// Reads back every data row already written to [rawFile] and converts
  /// each one with [calib], preserving the ORIGINAL timestamp from that
  /// row (not "now") so backfilled rows line up with when the sample
  /// actually arrived. Uses the same header-driven column mapping as
  /// parseFile(), so it still works even if the raw file's column order
  /// ever changes. Returns the fully-formed data lines (timestamp +
  /// calibrated values), ready to write straight into the calibrated
  /// file. Never throws — a malformed row is just skipped.
  static Future<List<String>> _backfillCalibratedRows(
      File rawFile, CalibrationParams calib) async {
    try {
      final lines = await rawFile.readAsLines();
      var inData = false;
      List<GasParam?>? colMap;
      final out = <String>[];
      for (final line in lines) {
        if (line.trim() == '---') {
          inData = false;
          continue;
        }
        if (line.startsWith('time,') || line.startsWith('elapsed,')) {
          inData = true;
          colMap = line.split(',').map<GasParam?>((h) {
            final key = h.trim();
            for (final p in kAllParams) {
              if (p.csvKey == key) return p;
            }
            return null;
          }).toList();
          continue;
        }
        if (!inData) continue;

        final parts = line.split(',');
        if (parts.length < 2) continue;
        final map = <GasParam, double>{};
        if (colMap != null && colMap.length == parts.length) {
          for (var i = 1; i < parts.length; i++) {
            final p = colMap[i];
            if (p == null) continue;
            final v = double.tryParse(parts[i].trim());
            if (v != null) map[p] = v;
          }
        } else {
          for (var i = 0; i < kAllParams.length; i++) {
            final idx = i + 1;
            if (idx >= parts.length) break;
            final v = double.tryParse(parts[idx].trim());
            if (v != null) map[kAllParams[i]] = v;
          }
        }
        if (map.isEmpty) continue;

        final timeText = parts[0];
        final row =
            _calibratedRowFromValues(calib, (p) => map[p] ?? double.nan);
        out.add('$timeText,$row');
      }
      return out;
    } catch (e) {
      debugPrint('[CSV] backfill error: $e');
      return const [];
    }
  }

  // ── Nurse quick notes (live, during an active recording) ────────────────
  //
  //  Called from the device detail page's note field. Timestamped and
  //  written to TWO places so it's durable and immediately visible:
  //    1. A `note_log,<time>,<text>` row inserted into the CSV's HEADER
  //       block — grouped with the QR's `name_meta,`/`note_meta,` lines,
  //       right before the `---` divider, rather than scattered among the
  //       data rows. Because that means editing content that's already on
  //       disk, this briefly closes the sink, rewrites the whole (small)
  //       file with the note inserted, and reopens the sink for further
  //       data rows to keep streaming into. Values are CSV-quoted so a note
  //       containing commas stays one field instead of spilling into extra
  //       columns.
  //    2. The recording's sidecar Notes (session_metadata.json), appended
  //       rather than overwritten, so it shows up right away on the History
  //       page without waiting for the recording to finish.
  //  No-op if this device doesn't have an active recording yet (e.g. called
  //  in the brief moment between BLE connect and the first sample).
  //
  //  Note: the rewrite is not mutex-locked against _onSample's writes. A
  //  BLE sample landing in the same few milliseconds as a note rewrite could
  //  fail to write that one row (caught and logged, never a crash) — an
  //  acceptable trade-off given samples arrive only ~30s apart and notes are
  //  a rare, human-triggered event.
  Future<void> appendNote(String mac, String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    final st = _states[mac];
    if (st == null) return;

    final stamp = DateFormat('HH:mm:ss').format(DateTime.now());
    final noteLine = 'note_log,$stamp,${_csvQuote(trimmed)}';

    try {
      await st.sink.flush();
      await st.sink.close();

      final lines = await st.file.readAsLines();
      final dividerIdx = lines.indexOf('---');
      if (dividerIdx == -1) {
        // Unexpected shape — don't guess where to insert; just reopen so
        // recording keeps going, and skip the header insert this time.
        debugPrint('[CSV] note insert skipped for $mac: no --- divider found');
      } else {
        lines.insert(dividerIdx, noteLine);
        await st.file.writeAsString('${lines.join('\n')}\n');
      }
      // Reopen for further appending — subsequent data rows keep streaming
      // in after whatever is now on disk.
      st.sink = st.file.openWrite(mode: FileMode.append);
    } catch (e) {
      debugPrint('[CSV] note write error for $mac: $e');
      try {
        st.sink = st.file.openWrite(mode: FileMode.append);
      } catch (_) {}
    }

    // Mirror the same note into the calibrated companion file's header, if
    // one is currently active — same insert-before-`---` treatment as the
    // raw file above, so the note shows up whichever file gets opened
    // later.
    final calFile = st.calFile;
    final calSink = st.calSink;
    if (calFile != null && calSink != null) {
      try {
        await calSink.flush();
        await calSink.close();

        final calLines = await calFile.readAsLines();
        final calDividerIdx = calLines.indexOf('---');
        if (calDividerIdx == -1) {
          debugPrint(
              '[CSV] note insert skipped for calibrated $mac: no --- divider found');
        } else {
          calLines.insert(calDividerIdx, noteLine);
          await calFile.writeAsString('${calLines.join('\n')}\n');
        }
        st.calSink = calFile.openWrite(mode: FileMode.append);
      } catch (e) {
        debugPrint('[CSV] calibrated note write error for $mac: $e');
        try {
          st.calSink = calFile.openWrite(mode: FileMode.append);
        } catch (_) {}
      }
    }

    try {
      final csvName = st.file.uri.pathSegments.last;
      final existing = await SessionMetadata.instance.getNotes(csvName);
      final line = '[$stamp] $trimmed';
      final updated = existing.isEmpty ? line : '$existing\n$line';
      await SessionMetadata.instance.setNotes(csvName, updated);
    } catch (e) {
      debugPrint('[Meta] note append error for $mac: $e');
    }
  }

  // ── Calibration (live, during an active recording) ──────────────────────
  //
  //  Called from the device detail page after a material QR carrying a
  //  `calib` field (see calibration.dart) is scanned while this device is
  //  connected and recording. Starts a SECOND CSV file, in exactly the same
  //  header/column format as the raw one, and BACKFILLS it with every raw
  //  sample recorded since the start of this session — not just samples
  //  from this point forward — so the calibrated file always covers the
  //  whole recording, however late the QR gets scanned. New samples then
  //  keep streaming into it live via _onSample/_calibratedRow above.
  //
  //  The raw file and the live charts are completely untouched — this is
  //  purely additive. Re-scanning a (possibly different) calibration QR
  //  replaces the calibrated file: the previous attempt is closed out (and
  //  discarded if it never got a data row) and a fresh one is backfilled
  //  from scratch with the newly-scanned parameters.
  //
  //  Returns false (no-op) if there's no active recording for this device
  //  yet — e.g. called in the brief moment between BLE connect and the
  //  first sample.
  Future<bool> attachCalibration(
    String mac,
    CalibrationParams calib,
    Map<String, dynamic> materialMeta,
  ) async {
    final st = _states[mac];
    if (st == null) return false;
    try {
      await _closeCalSink(st, discardIfEmpty: true);

      final dir = await _recordingsDir();
      final patientSlug = _slug(st.session.patient ?? 'dev${st.session.slot}');
      final calPrefix =
          'GASMON_${patientSlug}_${_deviceTag(st.session.displayName)}_CALIBRATED';
      final pending = await _uniqueName(
          dir, calPrefix, '_${_stamp(st.startTime)}__pending.csv');
      final calFile = File('${dir.path}/$pending');
      await calFile.create(recursive: true);
      final calSink = calFile.openWrite(mode: FileMode.write);

      calSink.writeln('# BloodGas Session');
      calSink.writeln('mac,$mac');
      calSink.writeln('slot,${st.session.slot}');
      calSink.writeln('start_iso,${st.startTime.toIso8601String()}');
      calSink.writeln('end_iso,');
      for (final key in const ['name', 'patient', 'age', 'note']) {
        final v = st.session.meta[key];
        if (v != null && v.toString().isNotEmpty) {
          calSink.writeln('${key}_meta,${_csvQuote(v.toString())}');
        }
      }
      // Traceability: which raw file this was derived from, the material
      // it was calibrated against, and the exact parameters applied — so
      // anyone reviewing this file later can see precisely what produced
      // it, without having to cross-reference anything else.
      calSink.writeln(
          'source_meta,${_csvQuote(st.file.uri.pathSegments.last)}');
      final materialLabel = materialMeta['material'];
      if (materialLabel != null && materialLabel.toString().isNotEmpty) {
        calSink.writeln('material_meta,${_csvQuote(materialLabel.toString())}');
      }
      calSink.writeln(
          'calib_meta,${_csvQuote(jsonEncode(calib.toJson()))}');
      calSink.writeln('---');
      calSink.writeln('time,${kAllParams.map((p) => p.csvKey).join(',')}');

      // Backfill every raw sample recorded so far. Flush the raw file
      // first so a sample written moments ago isn't missed.
      await st.sink.flush();
      final backfilled = await _backfillCalibratedRows(st.file, calib);
      for (final line in backfilled) {
        calSink.writeln(line);
      }

      st.calib = calib;
      st.calFile = calFile;
      st.calSink = calSink;
      st.calRowCount = backfilled.length;
      // Mirror onto the live session too — this is what lets the Gas
      // Monitor page's RAW/CALIB switch (device_detail_page.dart) appear
      // and DeviceSession.addSample start computing calibrated values
      // going forward. See device_session.dart's calib field doc comment.
      st.session.calib = calib;

      // Title mirrors the raw file's "<device> - <date>" scheme with a
      // " - Calibrated" suffix, so History shows the pair as clearly
      // related instead of the calibrated one sitting there "Untitled".
      await SessionMetadata.instance.setName(
        pending,
        _sessionTitle(st.session, st.startTime, calibrated: true),
      );

      debugPrint('[CSV] calibration attached for $mac → ${calFile.path} '
          '(${backfilled.length} backfilled rows)');
      return true;
    } catch (e) {
      debugPrint('[CSV] attachCalibration failed for $mac: $e');
      return false;
    }
  }

  /// Closes (and, if it never got a data row, deletes) the current
  /// calibrated-file sink for [st], if any. Shared by attachCalibration
  /// (replacing a previous calibration) and _finalizeCalFile (recording
  /// stopped).
  static Future<void> _closeCalSink(_RecState st,
      {required bool discardIfEmpty}) async {
    final sink = st.calSink;
    if (sink == null) return;
    try {
      await sink.flush();
      await sink.close();
    } catch (_) {}
    if (discardIfEmpty && st.calRowCount == 0) {
      final name = st.calFile?.uri.pathSegments.last;
      try {
        await st.calFile?.delete();
      } catch (_) {}
      if (name != null) {
        await SessionMetadata.instance.remove(name);
      }
    }
    st.calSink = null;
    st.calFile = null;
    st.calib = null;
    st.calRowCount = 0;
  }

  /// Finalizes the calibrated companion file the same way _stop finalizes
  /// the raw one: rename with the end timestamp, patch end_iso, keep the
  /// sidecar title/notes attached to the new name, mirror to public
  /// storage. No-op if no calibration was ever attached, or if it never
  /// received a data row (deleted instead, like an empty raw file).
  Future<void> _finalizeCalFile(_RecState st, DateTime endTime) async {
    final calSink = st.calSink;
    final calFile = st.calFile;
    if (calSink == null || calFile == null) return;
    try {
      await calSink.flush();
      await calSink.close();
    } catch (_) {}

    final oldCalName = calFile.uri.pathSegments.last;

    if (st.calRowCount == 0) {
      try {
        await calFile.delete();
      } catch (_) {}
      await SessionMetadata.instance.remove(oldCalName);
      return;
    }

    try {
      final patientSlug = _slug(st.session.patient ?? 'dev${st.session.slot}');
      final prefix =
          'GASMON_${patientSlug}_${_deviceTag(st.session.displayName)}_CALIBRATED';
      final newName = await _uniqueName(calFile.parent, prefix,
          '_${_stamp(st.startTime)}__${_stamp(endTime)}.csv');
      final renamed = await calFile.rename('${calFile.parent.path}/$newName');
      await _patchEndIso(renamed, endTime);
      await SessionMetadata.instance.rename(oldCalName, newName);
      debugPrint('[CSV] calibrated saved: $newName');
      await _mirrorToPublic(renamed);
    } catch (e) {
      debugPrint('[CSV] calibrated rename error: $e');
    }
  }

  // ── Stop ──────────────────────────────────────────────────────────────
  Future<void> _stop(String mac) async {
    final st = _states.remove(mac);
    if (st == null) return;
    final endTime = DateTime.now();

    try {
      await st.sink.flush();
      await st.sink.close();
    } catch (_) {}

    // Finalize the calibrated companion file (if one was started) using
    // the same rename/end-stamp/mirror steps as the raw file below.
    await _finalizeCalFile(st, endTime);

    // A resumed recording (_resumeStart) is the SAME already-named CSV
    // from an earlier connection, just reopened — it never gets renamed
    // again here, and it's never dropped as "empty" even if this
    // particular connection happened to add zero new rows, since it
    // already holds everything from before. Only its end_iso is refreshed.
    if (st.isResumed) {
      try {
        await _patchEndIso(st.file, endTime);
        debugPrint('[CSV] resumed session re-paused: '
            '${st.file.uri.pathSegments.last}');
        await _mirrorToPublic(st.file);
      } catch (e) {
        debugPrint('[CSV] resumed session patch error: $e');
      }
      return;
    }

    // Drop empty files
    if (st.rowCount == 0) {
      try {
        await st.file.delete();
      } catch (_) {}
      debugPrint('[CSV] empty session discarded: $mac');
      return;
    }

    // Rename to include the end timestamp; keep sidecar metadata in sync.
    // Same device tag + uniqueness check as _start, so finishing two
    // concurrent sessions can never overwrite one another.
    final oldName = st.file.uri.pathSegments.last;
    final patientSlug =
        _slug(st.session.patient ?? 'dev${st.session.slot}');
    final prefix = 'GASMON_${patientSlug}_${_deviceTag(st.session.displayName)}';
    final newName = await _uniqueName(
        st.file.parent, prefix, '_${_stamp(st.startTime)}__${_stamp(endTime)}.csv');
    try {
      final renamed = await st.file.rename('${st.file.parent.path}/$newName');
      await _patchEndIso(renamed, endTime);
      await SessionMetadata.instance.rename(oldName, newName);
      debugPrint('[CSV] saved: $newName');
      await _mirrorToPublic(renamed);
    } catch (e) {
      debugPrint('[CSV] rename error: $e');
    }
  }

  /// Best-effort mirror of a FINISHED recording into public device storage
  /// (Documents/<app folder>/) so the data survives an app uninstall.
  ///
  /// Deliberately fire-and-forget in spirit: it never throws, and a failure
  /// (no permission yet, no shared storage, full disk) is logged and
  /// ignored — the private copy in app storage is still authoritative.
  static Future<void> _mirrorToPublic(File csv) async {
    try {
      final saved = await BackupStore.saveCopy(csv);
      debugPrint(saved == null
          ? '[CSV] public mirror skipped: ${csv.uri.pathSegments.last}'
          : '[CSV] public mirror ok: ${saved.path}');
    } catch (e) {
      debugPrint('[CSV] public mirror error: $e');
    }
  }

  static Future<void> _patchEndIso(File f, DateTime end) async {
    try {
      final lines = await f.readAsLines();
      for (var i = 0; i < lines.length && i < 12; i++) {
        if (lines[i].startsWith('end_iso,')) {
          lines[i] = 'end_iso,${end.toIso8601String()}';
          break;
        }
      }
      await f.writeAsString('${lines.join('\n')}\n');
    } catch (_) {}
  }

  // ── Helpers ───────────────────────────────────────────────────────────

  /// A short, filename-safe token derived from the device's advertised
  /// name — makes a filename unique even when several sensors share a
  /// patient name and start/stop in the same second, and (unlike the old
  /// MAC-based tag) stays the SAME across a power cycle, since renaming a
  /// device is rare and deliberate but its BLE address now rotates every
  /// reboot (CONFIG_BT_PRIVACY=y on the firmware). This is also what
  /// [mostRecentRecordingForName] matches against to find a device's prior
  /// recording, so continuity ("continue from last recording?") now
  /// survives a reboot instead of breaking every time the MAC changes.
  static String _deviceTag(String name) {
    final cleaned =
        name.trim().toUpperCase().replaceAll(RegExp(r'[^0-9A-Z]'), '');
    if (cleaned.isEmpty) return 'DEV';
    return cleaned.length > 16 ? cleaned.substring(0, 16) : cleaned;
  }

  /// `<prefix><suffix>`, disambiguated with `-2`, `-3`… if it already exists.
  ///
  /// The counter is appended to the PREFIX (never to the timestamps), so the
  /// start stamp stays the final 15 characters before `__` and
  /// [RecordingInfo._parseTimes] keeps working.
  static Future<String> _uniqueName(
      Directory dir, String prefix, String suffix) async {
    var name = '$prefix$suffix';
    var n = 2;
    while (await File('${dir.path}/$name').exists()) {
      name = '$prefix-$n$suffix';
      n++;
    }
    return name;
  }

  static String _slug(String s) {
    final cleaned =
        s.replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '_').replaceAll(RegExp(r'_+'), '_');
    final trimmed = cleaned.replaceAll(RegExp(r'^_+|_+$'), '');
    return trimmed.isEmpty ? 'session' : trimmed;
  }

  /// "<device name> - <MM/dd/yyyy>", e.g. "BG_MINI_01 - 09/17/2026" — the
  /// History-page title for a recording. [calibrated] appends " -
  /// Calibrated" for the companion file, so the pair reads as obviously
  /// related but still tells apart at a glance.
  static String _sessionTitle(DeviceSession s, DateTime startTime,
      {bool calibrated = false}) {
    final devName = (s.meta['name'] as String?)?.trim();
    final base = (devName != null && devName.isNotEmpty)
        ? devName
        : (s.device.platformName.isNotEmpty
            ? s.device.platformName
            : 'Device #${s.slot}');
    final title = '$base - ${DateFormat('MM/dd/yyyy').format(startTime)}';
    return calibrated ? '$title - Calibrated' : title;
  }

  static String _stamp(DateTime dt) =>
      '${dt.year.toString().padLeft(4, '0')}'
      '${dt.month.toString().padLeft(2, '0')}'
      '${dt.day.toString().padLeft(2, '0')}_'
      '${dt.hour.toString().padLeft(2, '0')}'
      '${dt.minute.toString().padLeft(2, '0')}'
      '${dt.second.toString().padLeft(2, '0')}';

  /// Absolute timestamp for a data row: "yyyy-MM-dd HH:mm:ss.ffff" — the
  /// iPhone's/tablet's own real clock, with 4-digit (ten-thousandths of a
  /// second) fractional precision, e.g. "2026-09-17 09:16:03.9897".
  static String _timestamp(DateTime dt) {
    final base = DateFormat('yyyy-MM-dd HH:mm:ss').format(dt);
    // millisecond*1000 + microsecond = the full sub-second remainder in
    // microseconds (0..999999); /100 rounds that down to 4 digits (0..9999).
    final frac =
        ((dt.millisecond * 1000 + dt.microsecond) ~/ 100).toString().padLeft(4, '0');
    return '$base.$frac';
  }

  /// Wraps [s] as one safe CSV field (RFC 4180 style): doubles any internal
  /// quotes and always quotes the whole value, so a note containing commas
  /// (very common in free text) stays a single column instead of spilling
  /// into extras when the file is opened in Excel/Sheets.
  static String _csvQuote(String s) => '"${s.replaceAll('"', '""')}"';

  static Future<Directory> _recordingsDir() async {
    final root = await getApplicationDocumentsDirectory();
    final dir = Directory('${root.path}/gas_monitor_records');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  // ── Public API for History page ───────────────────────────────────────
  static Future<List<RecordingInfo>> listRecordings() async {
    try {
      final dir = await _recordingsDir();
      final files = dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.csv'))
          .where((f) => !f.path.endsWith('__pending.csv'))
          .toList()
        ..sort((a, b) => b.path.compareTo(a.path));
      return files.map((f) => RecordingInfo.fromFile(f)).toList();
    } catch (e) {
      debugPrint('[CSV] listRecordings error: $e');
      return [];
    }
  }

  static Future<void> deleteFile(File f) async {
    try {
      final name = f.uri.pathSegments.last;
      await f.delete();
      await SessionMetadata.instance.remove(name);
    } catch (e) {
      debugPrint('[CSV] delete error: $e');
    }
  }

  static Future<RecordingData> parseFile(File f) async {
    try {
      final lines = await f.readAsLines();
      DateTime? start, end;
      final samples = <CsvSample>[];
      var inData = false;
      // Column → GasParam mapping derived from the data header. colMap[i]
      // is the param stored at row-index i (null for elapsed / unknown cols).
      List<GasParam?>? colMap;
      for (final line in lines) {
        if (line.startsWith('start_iso,')) {
          start = DateTime.tryParse(line.substring(10).trim());
        } else if (line.startsWith('end_iso,')) {
          end = DateTime.tryParse(line.substring(8).trim());
        } else if (line.trim() == '---') {
          inData = false;
        } else if (line.startsWith('time,') || line.startsWith('elapsed,')) {
          // 'time,' is the current data-row header (absolute timestamps);
          // 'elapsed,' is the older relative-duration format used before —
          // both still parse fine, since only the columns AFTER the first
          // are keyed off csvKey.
          inData = true;
          // Map each header cell to a GasParam by matching csvKey.
          colMap = line.split(',').map<GasParam?>((h) {
            final key = h.trim();
            for (final p in kAllParams) {
              if (p.csvKey == key) return p;
            }
            return null;
          }).toList();
        } else if (inData) {
          final parts = line.split(',');
          if (parts.length < 2) continue;
          final map = <GasParam, double>{};
          if (colMap != null && colMap.length == parts.length) {
            // Header-driven: honour whatever column order the file used.
            for (var i = 1; i < parts.length; i++) {
              final p = colMap[i];
              if (p == null) continue;
              final v = double.tryParse(parts[i].trim());
              if (v != null) map[p] = v;
            }
          } else {
            // Fallback: assume fixed kAllParams order after the elapsed col.
            for (var i = 0; i < kAllParams.length; i++) {
              final idx = i + 1;
              if (idx >= parts.length) break;
              final v = double.tryParse(parts[idx].trim());
              if (v != null) map[kAllParams[i]] = v;
            }
          }
          if (map.isEmpty) continue; // malformed / no numeric values
          samples.add(CsvSample(elapsedText: parts[0], values: map));
        }
      }
      return RecordingData(start: start, end: end, samples: samples);
    } catch (e) {
      debugPrint('[CSV] parse error: $e');
      return const RecordingData(start: null, end: null, samples: []);
    }
  }

  // ══════════════════════════════════════════════════════════════════════
  //  DATA-SAFETY: crash recovery
  // ══════════════════════════════════════════════════════════════════════
  Future<void> _recoverAndPurge() async {
    await recoverPending();
    await purgeExpiredTrash();
  }

  /// Finalize any `*__pending.csv` left behind by a crash/kill so its data
  /// shows up in history instead of staying hidden. End time = file mtime.
  static Future<void> recoverPending() async {
    try {
      final dir = await _recordingsDir();
      final pendings = dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('__pending.csv'))
          .toList();
      for (final f in pendings) {
        try {
          final oldName = f.uri.pathSegments.last;
          final lines = await f.readAsLines();
          final dataStart = lines.indexWhere(
              (l) => l.startsWith('time,') || l.startsWith('elapsed,'));
          final hasData = dataStart >= 0 && lines.length > dataStart + 1;
          if (!hasData) {
            await f.delete();
            await SessionMetadata.instance.remove(oldName);
            continue;
          }
          final end = f.statSync().modified;
          final base = oldName.replaceAll('.csv', '');
          final left = base.split('__').first; // <prefix>_<slug>_<startStamp>
          final newName = '${left}__${_stamp(end)}.csv';
          await _patchEndIso(f, end);
          final recovered = await f.rename('${f.parent.path}/$newName');
          await SessionMetadata.instance.rename(oldName, newName);
          debugPrint('[CSV] recovered orphaned recording → $newName');
          await _mirrorToPublic(recovered);
        } catch (e) {
          debugPrint('[CSV] recover failed for ${f.path}: $e');
        }
      }
    } catch (e) {
      debugPrint('[CSV] recoverPending error: $e');
    }
  }

  // ══════════════════════════════════════════════════════════════════════
  //  TRASH (soft-delete, 30-day retention — like Apple Photos)
  // ══════════════════════════════════════════════════════════════════════
  static const int kTrashRetentionDays = 30;

  static Future<Directory> _trashDir() async {
    final root = await _recordingsDir();
    final dir = Directory('${root.path}/trash');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// Soft-delete: move [f] into trash/ (kept [kTrashRetentionDays] days).
  /// The sidecar metadata (name/notes/material) follows the file.
  static Future<void> moveToTrash(File f) async {
    try {
      final trash = await _trashDir();
      final orig = f.uri.pathSegments.last;
      final trashName = 'DEL_${_stamp(DateTime.now())}__$orig';
      await f.rename('${trash.path}/$trashName');
      await SessionMetadata.instance.rename(orig, trashName);
      debugPrint('[CSV] moved to trash: $orig');
    } catch (e) {
      debugPrint('[CSV] moveToTrash error: $e');
    }
  }

  /// List trashed recordings (newest deletion first). Purges expired first.
  static Future<List<TrashedRecording>> listTrash() async {
    await purgeExpiredTrash();
    try {
      final trash = await _trashDir();
      final out = <TrashedRecording>[];
      for (final f in trash.listSync().whereType<File>()) {
        if (!f.path.endsWith('.csv')) continue;
        final t = TrashedRecording.fromFile(f);
        if (t != null) out.add(t);
      }
      out.sort((a, b) => b.deletedAt.compareTo(a.deletedAt));
      return out;
    } catch (e) {
      debugPrint('[CSV] listTrash error: $e');
      return [];
    }
  }

  /// Restore a trashed file back into the library.
  static Future<void> restoreFromTrash(File trashedFile) async {
    try {
      final records = await _recordingsDir();
      final trashName = trashedFile.uri.pathSegments.last;
      final original = TrashedRecording._stripPrefix(trashName) ?? trashName;
      var targetName = original;
      if (await File('${records.path}/$targetName').exists()) {
        targetName = '${original.replaceAll('.csv', '')}_restored.csv';
      }
      await trashedFile.rename('${records.path}/$targetName');
      await SessionMetadata.instance.rename(trashName, targetName);
      debugPrint('[CSV] restored: $targetName');
    } catch (e) {
      debugPrint('[CSV] restore error: $e');
    }
  }

  /// Permanently (hard) delete one trashed file.
  static Future<void> permanentlyDelete(File trashedFile) async {
    try {
      final name = trashedFile.uri.pathSegments.last;
      await trashedFile.delete();
      await SessionMetadata.instance.remove(name);
    } catch (e) {
      debugPrint('[CSV] permanentlyDelete error: $e');
    }
  }

  /// Hard-delete everything currently in the trash.
  static Future<void> emptyTrash() async {
    try {
      final trash = await _trashDir();
      for (final f in trash.listSync().whereType<File>()) {
        try {
          await SessionMetadata.instance.remove(f.uri.pathSegments.last);
          await f.delete();
        } catch (_) {}
      }
    } catch (e) {
      debugPrint('[CSV] emptyTrash error: $e');
    }
  }

  /// Purge trashed items older than [kTrashRetentionDays].
  static Future<void> purgeExpiredTrash() async {
    try {
      final trash = await _trashDir();
      final now = DateTime.now();
      for (final f in trash.listSync().whereType<File>()) {
        final t = TrashedRecording.fromFile(f);
        if (t == null) continue;
        if (now.difference(t.deletedAt).inDays >= kTrashRetentionDays) {
          try {
            await SessionMetadata.instance.remove(f.uri.pathSegments.last);
            await f.delete();
            debugPrint('[CSV] purged expired trash: ${f.path}');
          } catch (_) {}
        }
      }
    } catch (e) {
      debugPrint('[CSV] purgeExpiredTrash error: $e');
    }
  }
}

// ══════════════════════════════════════════════════════════════════════════
class _RecState {
  final DeviceSession session;
  final File file;
  // Mutable: appendNote() briefly closes and reopens this to rewrite the
  // note into the file's header block, then hands back a fresh sink for
  // data rows to keep streaming into.
  IOSink sink;
  final DateTime startTime;
  int rowCount;

  /// True for a recording reopened by _resumeStart (the nurse chose
  /// "continue from last recording?"), as opposed to a fresh _start().
  /// _stop() uses this to skip the normal rename-with-end-timestamp step —
  /// a resumed file already has its permanent name; only its end_iso gets
  /// refreshed.
  final bool isResumed;

  // ── Optional calibrated companion file — set by attachCalibration()
  //    once a material QR carrying calibration parameters is scanned while
  //    this recording is live. Null (all three) until then. ──
  CalibrationParams? calib;
  File? calFile;
  IOSink? calSink;
  int calRowCount = 0;

  // ── Backfill-ordering guard (see _onSample / _syncAndBackfill) ──
  // _syncAndBackfill() has to await a slow BLE round-trip (up to ~90s)
  // before it can write its (older, backfilled) rows to this file. If a
  // live sample from _onSample arrived and got written during that wait,
  // it would land in the file BEFORE the backfilled rows even though it's
  // chronologically AFTER them. While `syncing` is true, _onSample queues
  // its lines here instead of writing them, and _syncAndBackfill flushes
  // this queue (in arrival order — already chronological) immediately
  // after its own rows are safely on disk.
  bool syncing = false;
  final List<String> pendingLiveLines = [];

  _RecState({
    required this.session,
    required this.file,
    required this.sink,
    required this.startTime,
    this.isResumed = false,
    this.rowCount = 0,
  });
}

// ══════════════════════════════════════════════════════════════════════════
//  Value types used by the History page
// ══════════════════════════════════════════════════════════════════════════
class RecordingInfo {
  final File file;
  final String name;
  final int sizeBytes;
  final DateTime modified;
  final DateTime? startTime;
  final DateTime? endTime;

  RecordingInfo({
    required this.file,
    required this.name,
    required this.sizeBytes,
    required this.modified,
    required this.startTime,
    required this.endTime,
  });

  factory RecordingInfo.fromFile(File f) {
    final stat = f.statSync();
    final name = f.uri.pathSegments.last;
    final (start, end) = _parseTimes(name);
    return RecordingInfo(
      file: f,
      name: name,
      sizeBytes: stat.size,
      modified: stat.modified,
      startTime: start,
      endTime: end,
    );
  }

  // Parses filenames GASMON_<slug>_YYYYMMDD_HHMMSS__YYYYMMDD_HHMMSS.csv
  static (DateTime?, DateTime?) _parseTimes(String filename) {
    try {
      final base = filename.replaceAll('.csv', '');
      if (!base.startsWith('GASMON_')) return (null, null);
      // Split off the time stamps from the right (they are fixed-width)
      final parts = base.split('__');
      if (parts.length != 2) return (null, null);
      final left = parts[0]; // GASMON_<slug>_<startStamp>
      final endStamp = parts[1];
      // Start stamp is the last 15 chars of `left`
      if (left.length < 16) return (null, null);
      final startStamp = left.substring(left.length - 15);
      return (_parseStamp(startStamp), _parseStamp(endStamp));
    } catch (_) {
      return (null, null);
    }
  }

  static DateTime? _parseStamp(String s) {
    // YYYYMMDD_HHMMSS
    if (s.length != 15 || s[8] != '_') return null;
    try {
      return DateTime(
        int.parse(s.substring(0, 4)),
        int.parse(s.substring(4, 6)),
        int.parse(s.substring(6, 8)),
        int.parse(s.substring(9, 11)),
        int.parse(s.substring(11, 13)),
        int.parse(s.substring(13, 15)),
      );
    } catch (_) {
      return null;
    }
  }

  String get sizeLabel {
    if (sizeBytes < 1024) return '$sizeBytes B';
    if (sizeBytes < 1024 * 1024) {
      return '${(sizeBytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(sizeBytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
}

class CsvSample {
  final String elapsedText;
  final Map<GasParam, double> values;
  const CsvSample({required this.elapsedText, required this.values});

  /// Value for [p], or NaN if this row didn't carry that column.
  double valueOf(GasParam p) => values[p] ?? double.nan;
}

class RecordingData {
  final DateTime? start;
  final DateTime? end;
  final List<CsvSample> samples;
  const RecordingData(
      {required this.start, required this.end, required this.samples});

  /// Max value of [p] across all samples (ignoring non-finite). 0 if none.
  double peakOf(GasParam p) {
    var hi = double.negativeInfinity;
    for (final s in samples) {
      final v = s.valueOf(p);
      if (v.isFinite && v > hi) hi = v;
    }
    return hi == double.negativeInfinity ? 0 : hi;
  }

  /// Mean value of [p] across all samples (ignoring non-finite). 0 if none.
  double meanOf(GasParam p) {
    var sum = 0.0;
    var n = 0;
    for (final s in samples) {
      final v = s.valueOf(p);
      if (v.isFinite) {
        sum += v;
        n++;
      }
    }
    return n == 0 ? 0 : sum / n;
  }

  Duration get duration => (start != null && end != null)
      ? end!.difference(start!)
      : Duration.zero;
}

// ══════════════════════════════════════════════════════════════════════════
//  A recording currently sitting in the trash (soft-deleted).
//  Filename scheme inside trash/:  DEL_<YYYYMMDD_HHMMSS>__<originalName>
// ══════════════════════════════════════════════════════════════════════════
class TrashedRecording {
  final File file; // the file inside trash/
  final String originalName; // e.g. GASMON_..._....csv (as it will be restored)
  final DateTime deletedAt;
  final int sizeBytes;
  final DateTime? startTime;
  final DateTime? endTime;

  TrashedRecording({
    required this.file,
    required this.originalName,
    required this.deletedAt,
    required this.sizeBytes,
    required this.startTime,
    required this.endTime,
  });

  /// Strip the `DEL_<stamp>__` prefix → the original filename.
  static String? _stripPrefix(String trashName) {
    if (!trashName.startsWith('DEL_')) return null;
    final idx = trashName.indexOf('__');
    if (idx < 0) return null;
    return trashName.substring(idx + 2);
  }

  static DateTime? _parseDeletedStamp(String trashName) {
    if (!trashName.startsWith('DEL_')) return null;
    final idx = trashName.indexOf('__');
    if (idx < 0) return null;
    return RecordingInfo._parseStamp(trashName.substring(4, idx));
  }

  static TrashedRecording? fromFile(File f) {
    try {
      final name = f.uri.pathSegments.last;
      final original = _stripPrefix(name);
      final deletedAt = _parseDeletedStamp(name);
      if (original == null || deletedAt == null) return null;
      final stat = f.statSync();
      final (start, end) = RecordingInfo._parseTimes(original);
      return TrashedRecording(
        file: f,
        originalName: original,
        deletedAt: deletedAt,
        sizeBytes: stat.size,
        startTime: start,
        endTime: end,
      );
    } catch (_) {
      return null;
    }
  }

  /// Days remaining before auto-purge (0..30).
  int get daysLeft {
    final d = CsvRecorder.kTrashRetentionDays -
        DateTime.now().difference(deletedAt).inDays;
    return d < 0 ? 0 : d;
  }

  /// Trash filename (used as the SessionMetadata key while trashed).
  String get trashName => file.uri.pathSegments.last;

  String get sizeLabel {
    if (sizeBytes < 1024) return '$sizeBytes B';
    if (sizeBytes < 1024 * 1024) {
      return '${(sizeBytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(sizeBytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
}
