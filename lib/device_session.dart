// ════════════════════════════════════════════════════════════════════════
//  device_session.dart  — MULTI-PARAMETER (Gas Monitor)
//  ─────────────────────────────────────────────────────────────────────────
//  One instance per connected device. Holds everything that belongs to that
//  device — BLE handle, subscription, one waveform buffer PER charted
//  parameter, current + peak value per parameter, session timing, optional
//  patient metadata.
//
//  Lives as long as the device is connected. Survives page navigation
//  because it's owned by BleManager (a singleton), not any widget.
// ════════════════════════════════════════════════════════════════════════
import 'dart:async';
import 'dart:collection';
import 'package:flutter/foundation.dart';
import 'package:fl_chart/fl_chart.dart' show FlSpot;
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'calibration.dart';
import 'gas_params.dart';

class DeviceSession {
  static const int maxPoints = 300;

  final BluetoothDevice device;
  final int slot; // display number 1..4

  /// Optional patient/device info supplied by a QR scan.
  ///   keys: mac, name, patient, age, note
  final Map<String, dynamic> meta;

  // ── BLE wiring ──
  BluetoothCharacteristic? notifyChar;
  StreamSubscription? notifySub;
  StreamSubscription? stateSub;

  // ── Live data ──
  /// Waveform ring-buffer per charted parameter.
  final Map<GasParam, Queue<FlSpot>> series = {
    for (final p in kChartedParams) p: Queue<FlSpot>(),
  };

  /// Latest value for EVERY parameter (all 6, including raw PD).
  final Map<GasParam, double> current = {
    for (final p in kAllParams) p: 0.0,
  };

  /// Running peak (max) for each charted parameter.
  final Map<GasParam, double> peak = {
    for (final p in kChartedParams) p: double.negativeInfinity,
  };

  // ── Calibrated counterparts (Gas Monitor's live RAW/CALIB switch) ──
  //
  // Set by CsvRecorder.attachCalibration() the moment a material QR is
  // scanned for this device — mirrors CsvRecorder's own private per-file
  // `calib`, so both the calibrated CSV and this live view work from the
  // exact same calibration set. Null until then, in which case the switch
  // (device_detail_page.dart's _CalibrationBar) simply doesn't appear and
  // every accessor below behaves exactly as it always has.
  CalibrationParams? calib;

  /// Per-device toggle: whether Gas Monitor's live views (valueOf/peakOf/
  /// seriesFor below) should read the calibrated maps instead of the raw
  /// ones. Deliberately per-session (not a single app-wide switch) since
  /// each connected sensor may carry its own — or no — calibration.
  /// Defaults to false (raw), matching today's behavior exactly for any
  /// device whose switch is never touched.
  final ValueNotifier<bool> showCalibrated = ValueNotifier(false);

  /// Calibrated counterparts of [current] / [series] / [peak] — populated
  /// in addSample() alongside the raw ones whenever [calib] is attached.
  /// Kept as full parallel history (not just a recalculated latest point)
  /// so flipping the switch shows a real calibrated waveform. NOTE: these
  /// only start accumulating from the moment calibration is attached —
  /// unlike the calibrated CSV file (which backfills its earlier rows),
  /// the live chart does not retroactively backfill, so switching to
  /// CALIB right after scanning a QR mid-session will show a shorter
  /// trace than RAW until enough new samples arrive.
  final Map<GasParam, double> calibCurrent = {
    for (final p in kAllParams) p: 0.0,
  };
  final Map<GasParam, Queue<FlSpot>> calibSeries = {
    for (final p in kChartedParams) p: Queue<FlSpot>(),
  };
  final Map<GasParam, double> calibPeak = {
    for (final p in kChartedParams) p: double.negativeInfinity,
  };

  /// Total samples (packets) received.
  int sampleCount = 0;

  // ── Session timing ──
  final DateTime connectedAt = DateTime.now();
  final ValueNotifier<String> elapsedNotifier = ValueNotifier('00:00:00');
  Timer? _clock;

  // ── Per-tick notifier so widgets rebuild just this session ──
  final ValueNotifier<int> tick = ValueNotifier(0);

  /// The most recent device-uptime timestamp (ms since ITS last power-on)
  /// carried in a live packet, if the connected firmware sends one — see
  /// SampleEvent.deviceTimeMs. Null on older firmware, or before the first
  /// sample arrives. Used to anchor a resumed recording's history-sync
  /// timestamps to this device's own clock (see csv_recorder.dart).
  int? lastDeviceTimeMs;

  DeviceSession({
    required this.device,
    required this.slot,
    Map<String, dynamic>? meta,
  }) : meta = meta ?? const {};

  String get mac => device.remoteId.str;

  String get displayName {
    final fromMeta = (meta['name'] as String?)?.trim();
    if (fromMeta != null && fromMeta.isNotEmpty) return fromMeta;
    final fromBle = device.platformName.trim();
    if (fromBle.isNotEmpty) return fromBle;
    return 'Device #$slot';
  }

  String? get patient {
    final p = (meta['patient'] as String?)?.trim();
    return (p == null || p.isEmpty) ? null : p;
  }

  // ── Convenience accessors ──
  // These three all branch on showCalibrated, so EVERY page that reads a
  // device's live value/peak/waveform through them (monitor_page.dart,
  // device_detail_page.dart, param_detail_page.dart) automatically shows
  // calibrated data once the switch is flipped, with no per-page changes
  // needed beyond calling these instead of reading `current`/`peak`/
  // `series` directly.
  /// Latest value, or NaN if this channel has never delivered a finite value
  /// (the UI shows "—" for NaN so it can't be mistaken for a reading of 0).
  double valueOf(GasParam p) =>
      (showCalibrated.value ? calibCurrent[p] : current[p]) ?? double.nan;
  double peakOf(GasParam p) {
    final v = showCalibrated.value ? calibPeak[p] : peak[p];
    return (v == null || v == double.negativeInfinity) ? double.nan : v;
  }

  /// Waveform points for [p] — calibrated or raw depending on
  /// [showCalibrated]. Prefer this over reading `series`/`calibSeries`
  /// directly so every chart stays in sync with the per-device switch.
  Queue<FlSpot> seriesFor(GasParam p) =>
      (showCalibrated.value ? calibSeries[p] : series[p]) ?? Queue<FlSpot>();

  void startClock() {
    _clock?.cancel();
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      final e = DateTime.now().difference(connectedAt);
      elapsedNotifier.value =
          '${e.inHours.toString().padLeft(2, '0')}:'
          '${(e.inMinutes % 60).toString().padLeft(2, '0')}:'
          '${(e.inSeconds % 60).toString().padLeft(2, '0')}';
    });
  }

  void stopClock() => _clock?.cancel();

  /// Process a new packet: [values] holds all 6 floats in GasParam order.
  ///
  /// A channel can legitimately arrive non-finite (the firmware divides
  /// magnitudes/photodiode means, so a zero denominator yields NaN/inf).
  /// Those are kept as NaN — the UI renders them as "—" — rather than being
  /// coerced to 0.0, which would look like a real reading. They are also
  /// skipped for peak tracking and never pushed into the waveform, so one
  /// bad channel can't flatten or blank its chart.
  void addSample(List<double> values, {int? deviceTimeMs}) {
    if (deviceTimeMs != null) lastDeviceTimeMs = deviceTimeMs;
    // Real elapsed seconds since connect, not a sample-count index — this
    // gives every waveform point a genuine time coordinate, which the
    // per-parameter zoom view (param_detail_page.dart) uses to let a nurse
    // "stretch" the chart to a real time window rather than a sample count.
    // DateTime.now() only moves forward, so x stays strictly increasing —
    // safe for fl_chart's curved lines exactly like the old counter was.
    final x = DateTime.now().difference(connectedAt).inMilliseconds / 1000.0;
    for (final p in kAllParams) {
      final raw =
          p.floatIndex < values.length ? values[p.floatIndex] : double.nan;
      current[p] = raw;
      if (raw.isFinite && peak.containsKey(p)) {
        final pk = peak[p]!;
        if (raw > pk) peak[p] = raw;
      }
    }
    for (final p in kChartedParams) {
      final v = current[p]!;
      if (!v.isFinite) continue; // hold the trace; don't plot a fake point
      final q = series[p]!;
      q.add(FlSpot(x, v));
      if (q.length > maxPoints) q.removeFirst();
    }

    // Calibrated counterparts — same x coordinate, computed from this same
    // sample, whenever a calibration is attached. See the calib* fields'
    // doc comments above for what this does and doesn't backfill.
    final c = calib;
    if (c != null) {
      final calibValues = c.applyTo((p) => current[p] ?? double.nan);
      for (final p in kAllParams) {
        final cv = calibValues[p] ?? double.nan;
        calibCurrent[p] = cv;
        if (cv.isFinite && calibPeak.containsKey(p)) {
          final pk = calibPeak[p]!;
          if (cv > pk) calibPeak[p] = cv;
        }
      }
      for (final p in kChartedParams) {
        final v = calibCurrent[p]!;
        if (!v.isFinite) continue;
        final q = calibSeries[p]!;
        q.add(FlSpot(x, v));
        if (q.length > maxPoints) q.removeFirst();
      }
    }

    sampleCount++;
    tick.value++;
  }

  void resetStats() {
    for (final p in kChartedParams) {
      peak[p] = double.negativeInfinity;
      calibPeak[p] = double.negativeInfinity;
    }
    tick.value++;
  }

  Future<void> dispose() async {
    stopClock();
    await notifySub?.cancel();
    await stateSub?.cancel();
    elapsedNotifier.dispose();
    showCalibrated.dispose();
    tick.dispose();
  }
}
