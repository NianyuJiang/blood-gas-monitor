import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'gas_params.dart';

// ══════════════════════════════════════════════════════════════════════════
//  BleHistorySync — talks to the firmware's rolling flash buffer.
//
//  Same GATT service as the live 30 s notify (abcdef01-...), one extra
//  characteristic (abcdef03-...): the app WRITEs a 4-byte little-endian
//  uint32 ("give me everything after this sequence number, 0 = all of
//  it"); the device streams back matching buffered records — same order
//  as the live packet's 9 floats, plus the sequence number and
//  device-uptime timestamp — oldest first, ending with a sentinel record
//  (seq == 0xFFFFFFFF). Same protocol as the NICU app; only the record
//  size differs (44 bytes here vs 32 on NICU).
//
//  Only ever used from CsvRecorder's resume path (see csv_recorder.dart),
//  never from the normal live-data flow — a device running OLDER firmware
//  simply won't have this characteristic, and every call here degrades
//  gracefully (returns null) rather than throwing, so a mismatched
//  firmware/app pairing just means "no history to backfill," not a crash.
// ══════════════════════════════════════════════════════════════════════════

const String kHistoryServiceUuid = 'abcdef01-1234-5678-1234-56789abcdef0';
const String kHistorySyncCharUuid = 'abcdef03-1234-5678-1234-56789abcdef0';

/// One record pulled from the device's history buffer — mirrors
/// `struct history_record` in ESP32_BG/src/main.c exactly (44 bytes, same
/// field order).
class HistorySample {
  final int seq;
  final int deviceTimeMs;
  final Map<GasParam, double> values; // kAllParams order

  const HistorySample({
    required this.seq,
    required this.deviceTimeMs,
    required this.values,
  });

  static const int wireBytes = 8 + kPayloadBytes; // 44
  static const int sentinelSeq = 0xFFFFFFFF;

  /// Parses one 44-byte record: seq(u32) + device_time_ms(u32) + 9×float32,
  /// all little-endian — exactly `struct history_record`'s on-flash layout.
  static HistorySample? tryParse(Uint8List bytes) {
    if (bytes.length != wireBytes) return null;
    final view = ByteData.sublistView(bytes);
    final seq = view.getUint32(0, Endian.little);
    final deviceTimeMs = view.getUint32(4, Endian.little);
    final values = <GasParam, double>{};
    for (var i = 0; i < kAllParams.length; i++) {
      values[kAllParams[i]] = view.getFloat32(8 + i * 4, Endian.little);
    }
    return HistorySample(seq: seq, deviceTimeMs: deviceTimeMs, values: values);
  }

  bool get isSentinel => seq == sentinelSeq;
}

class BleHistorySync {
  BleHistorySync._();

  /// Requests every buffered record with seq > [sinceSeq] from [device] and
  /// collects them until the sentinel arrives or [timeout] elapses.
  ///
  /// Returns null (not an empty list) if this device has no history-sync
  /// characteristic at all — the caller should treat that as "nothing to
  /// backfill, proceed with live data only," never as an error to surface.
  /// Returns whatever records arrived (possibly empty, possibly a partial
  /// batch if the timeout fires early) otherwise — partial-but-real data is
  /// still worth keeping rather than discarding.
  static Future<List<HistorySample>?> sync(
    BluetoothDevice device, {
    required int sinceSeq,
    // NICU uses 25 s. A full BG backlog is up to 1395 records paced at
    // ≥20 ms each on the firmware side (~30-60 s), so 25 s would routinely
    // cut a long-gap sync short (the rest would only arrive on the NEXT
    // reconnect). 90 s covers a full buffer with margin; a short backlog
    // still finishes as soon as the sentinel arrives.
    Duration timeout = const Duration(seconds: 90),
  }) async {
    BluetoothCharacteristic? char;
    try {
      final services = await device.discoverServices();
      for (final svc in services) {
        if (svc.uuid.toString().toLowerCase() != kHistoryServiceUuid) {
          continue;
        }
        for (final ch in svc.characteristics) {
          if (ch.uuid.toString().toLowerCase() == kHistorySyncCharUuid) {
            char = ch;
            break;
          }
        }
      }
    } catch (e) {
      debugPrint('[HistSync] service discovery failed: $e');
      return null;
    }

    if (char == null) {
      debugPrint('[HistSync] no history-sync characteristic on this device '
          '(older firmware) — skipping backfill');
      return null;
    }

    final results = <HistorySample>[];
    final completer = Completer<void>();
    StreamSubscription? sub;

    try {
      await char.setNotifyValue(true);
      sub = char.lastValueStream.listen((bytes) {
        final sample = HistorySample.tryParse(Uint8List.fromList(bytes));
        if (sample == null) return; // ignore anything malformed/unexpected
        if (sample.isSentinel) {
          if (!completer.isCompleted) completer.complete();
          return;
        }
        results.add(sample);
      });

      final req = ByteData(4)..setUint32(0, sinceSeq, Endian.little);
      await char.write(req.buffer.asUint8List(), withoutResponse: false);

      await completer.future.timeout(timeout, onTimeout: () {
        debugPrint('[HistSync] sync timed out after ${results.length} '
            'record(s) — keeping what arrived');
      });
    } catch (e) {
      debugPrint('[HistSync] sync failed: $e — keeping ${results.length} '
          'record(s) received so far');
    } finally {
      await sub?.cancel();
      try {
        await char.setNotifyValue(false);
      } catch (_) {}
    }

    // Records stream in oldest-first per history_read_since() on the
    // firmware side, but guard against any out-of-order delivery anyway.
    results.sort((a, b) => a.seq.compareTo(b.seq));

    // Collapse same-seq duplicates. Normally the firmware sends each
    // record once, but resubmitting the sync (e.g. a redundant write to
    // this characteristic while a sync is already running) makes the
    // firmware re-walk and re-notify the same range again — this shows
    // up here as the same seq appearing more than once. After the sort
    // above, duplicates are always adjacent, so a single pass keeping
    // only the first occurrence of each seq is enough to de-dup.
    if (results.length > 1) {
      final deduped = <HistorySample>[results.first];
      for (var i = 1; i < results.length; i++) {
        if (results[i].seq != deduped.last.seq) {
          deduped.add(results[i]);
        }
      }
      if (deduped.length != results.length) {
        debugPrint('[HistSync] dropped ${results.length - deduped.length} '
            'duplicate-seq record(s) from this sync');
      }
      return deduped;
    }
    return results;
  }
}
