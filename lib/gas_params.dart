// ════════════════════════════════════════════════════════════════════════
//  gas_params.dart
//  ─────────────────────────────────────────────────────────────────────────
//  SINGLE SOURCE OF TRUTH for the BloodGas wire format & display model.
//
//  The BG_MINI firmware (ESP32_BG/src/main.c) sends, on every BLE notify,
//  40 bytes PLAINTEXT = 9 × float32 little-endian + 1 × uint32:
//
//    float index │ firmware var    │ physiological meaning
//    ────────────┼─────────────────┼──────────────────────────────
//        0       │ phase_diff_avg  │ pO₂ (Lifetime / phase method)
//        1       │ mag_ratio       │ pO₂ (Intensity / magnitude ratio)
//        2       │ pCO2_ratio      │ pCO₂ (ratiometric 405/470)
//        3       │ pH_ratio        │ pH (ratiometric 405/450)
//        4       │ temperature     │ Temperature (°C, thermistor)
//        5       │ PCO2_405_mean   │ pCO₂ 405 nm photodiode mean (a.u.)
//        6       │ PCO2_470_mean   │ pCO₂ 470 nm photodiode mean (a.u.)
//        7       │ PH_405_mean     │ pH 405 nm photodiode mean (a.u.)
//        8       │ PH_450_mean     │ pH 450 nm photodiode mean (a.u.)
//        9       │ device_time_ms  │ uptime ms — RAW uint32, NOT a float
//
//  Index 9 is not a GasParam: it's the history-buffer timestamp, decoded
//  separately in ble_manager.dart. No AES; all 9 values are kept.
//
//  All parsing, storage, CSV, charts and UI reference GasParam — never a
//  bare float index. Change a label/unit/colour here and it propagates.
// ════════════════════════════════════════════════════════════════════════
import 'package:flutter/material.dart';
import 'theme_manager.dart';

/// Every value carried in one BLE packet, in float-array order.
enum GasParam {
  po2Lifetime,   // float[0]
  po2Intensity,  // float[1]
  pco2Ratio,     // float[2]
  phRatio,       // float[3]
  temperature,   // float[4]
  pd405,         // float[5]  pCO₂ 405 nm photodiode mean
  pd470,         // float[6]  pCO₂ 470 nm photodiode mean
  ph405,         // float[7]  pH 405 nm photodiode mean
  ph450,         // float[8]  pH 450 nm photodiode mean
}

extension GasParamInfo on GasParam {
  /// Byte offset of this param inside the payload = index * 4.
  int get floatIndex => index;

  /// Full human label (used on the detail page + history titles).
  String get label {
    switch (this) {
      case GasParam.po2Lifetime:  return 'pO₂ Lifetime';
      case GasParam.po2Intensity: return 'pO₂ Intensity';
      case GasParam.pco2Ratio:    return 'pCO₂ Ratio';
      case GasParam.phRatio:      return 'pH Ratio';
      case GasParam.temperature:  return 'Temperature';
      case GasParam.pd405:        return 'pCO₂ PD 405';
      case GasParam.pd470:        return 'pCO₂ PD 470';
      case GasParam.ph405:        return 'pH PD 405';
      case GasParam.ph450:        return 'pH PD 450';
    }
  }

  /// Short label for compact chips / small readouts.
  String get shortLabel {
    switch (this) {
      case GasParam.po2Lifetime:  return 'pO₂-L';
      case GasParam.po2Intensity: return 'pO₂-I';
      case GasParam.pco2Ratio:    return 'pCO₂';
      case GasParam.phRatio:      return 'pH';
      case GasParam.temperature:  return 'TEMP';
      case GasParam.pd405:        return 'PD405';
      case GasParam.pd470:        return 'PD470';
      case GasParam.ph405:        return 'pH405';
      case GasParam.ph450:        return 'pH450';
    }
  }

  /// Unit suffix. These signals are uncalibrated, so most are arbitrary units.
  String get unit {
    switch (this) {
      case GasParam.po2Lifetime:  return 'µs';   // phase delay (scaled)
      case GasParam.po2Intensity: return '';          // dimensionless ratio
      case GasParam.pco2Ratio:    return '';           // dimensionless ratio
      case GasParam.phRatio:      return '';           // dimensionless ratio
      case GasParam.temperature:  return '°C';
      case GasParam.pd405:        return 'a.u.';
      case GasParam.pd470:        return 'a.u.';
      case GasParam.ph405:        return 'a.u.';
      case GasParam.ph450:        return 'a.u.';
    }
  }

  /// Accent colour for this parameter's chart / readouts.
  Color get color {
    switch (this) {
      case GasParam.po2Lifetime:  return ThemeManager.green;
      case GasParam.po2Intensity: return ThemeManager.cyan;
      case GasParam.pco2Ratio:    return ThemeManager.orange;
      case GasParam.phRatio:      return ThemeManager.pink;
      case GasParam.temperature:  return ThemeManager.purple;
      case GasParam.pd405:        return ThemeManager.redChart;
      case GasParam.pd470:        return ThemeManager.red;
      case GasParam.ph405:        return ThemeManager.pink;
      case GasParam.ph450:        return ThemeManager.pink;
    }
  }

  /// CSV column header for this parameter (stable — parsers key off these).
  String get csvKey {
    switch (this) {
      case GasParam.po2Lifetime:  return 'po2_lifetime';
      case GasParam.po2Intensity: return 'po2_intensity';
      case GasParam.pco2Ratio:    return 'pco2_ratio';
      case GasParam.phRatio:      return 'ph_ratio';
      case GasParam.temperature:  return 'temperature';
      case GasParam.pd405:        return 'pco2_405';
      case GasParam.pd470:        return 'pco2_470';
      case GasParam.ph405:        return 'ph_405';
      case GasParam.ph450:        return 'ph_450';
    }
  }

  /// Decimal places to show in readouts.
  int get decimals {
    switch (this) {
      case GasParam.pd405:
      case GasParam.pd470:
      case GasParam.ph405:
      case GasParam.ph450:
        return 0; // ADC means — whole numbers
      case GasParam.temperature:
        return 1;
      default:
        return 2;
    }
  }

  /// Decimals chosen from the value's own magnitude.
  ///
  /// These signals are uncalibrated and their scales differ by orders of
  /// magnitude (ratios can be ~0.003 while a phase delay is ~600). A fixed
  /// 2-decimal format renders small ratios as a useless "0.00", which reads
  /// as "no data". Scale the precision to the number instead.
  int decimalsFor(double v) {
    if (isRawPhotodiode) return 0;
    final a = v.abs();
    if (a == 0) return decimals;
    if (a >= 1000) return 0;
    if (a >= 100) return 1;
    if (a >= 10) return 2;
    if (a >= 1) return 3;
    if (a >= 0.01) return 4;
    return 6;
  }

  /// True for the four raw photodiode-mean channels (recorded, not charted).
  bool get isRawPhotodiode =>
      this == GasParam.pd405 ||
      this == GasParam.pd470 ||
      this == GasParam.ph405 ||
      this == GasParam.ph450;

  /// Human-readable value. Non-finite (NaN / ±inf — e.g. a firmware divide
  /// by zero) renders as an em dash so it is visibly distinct from a real 0.
  String format(double v) {
    if (!v.isFinite) return '—';
    return v.toStringAsFixed(decimalsFor(v));
  }

  /// Compact form for chart axis ticks (keeps labels narrow).
  String formatAxis(double v) {
    if (!v.isFinite) return '';
    final a = v.abs();
    if (a >= 1000) return v.toStringAsFixed(0);
    if (a >= 10) return v.toStringAsFixed(1);
    if (a >= 1) return v.toStringAsFixed(2);
    if (a >= 0.01) return v.toStringAsFixed(3);
    if (a == 0) return '0';
    return v.toStringAsExponential(1);
  }
}

/// The 5 physiological parameters that get a live chart + big readout, in
/// display order (GAS MONITOR and HISTORY): pH Ratio sits between pCO₂
/// Ratio and Temperature. The 4 raw photodiode means are recorded to CSV
/// but NOT charted (same rule as the NICU app's PD_405 / PD_470).
const List<GasParam> kChartedParams = [
  GasParam.po2Lifetime,
  GasParam.po2Intensity,
  GasParam.pco2Ratio,
  GasParam.phRatio,
  GasParam.temperature,
];

/// All 9 parameters carried in the packet (CSV records all of these).
const List<GasParam> kAllParams = GasParam.values;

/// Bytes of measurement values per BLE packet: 9 × float32.
const int kPayloadFloats = 9;
const int kPayloadBytes = kPayloadFloats * 4; // 36

/// Full packet size from history-buffer firmware: the same 9 floats plus a
/// 10th raw uint32 (device uptime in ms). A 36-byte packet (BG firmware
/// before the history buffer) still parses, just without deviceTimeMs.
/// See ble_manager.dart's wire-format note.
const int kWirePacketFloats = 10;
const int kWirePacketBytes = kWirePacketFloats * 4; // 40

/// Compute a "nice" chart Y-range from the values actually being plotted,
/// with headroom, so the trace always fits its box. Handles the very
/// different scales of each parameter (ratios ~1, temps ~30, PD means ~2000).
({double minY, double maxY}) niceRange(Iterable<double> values) {
  double hi = double.negativeInfinity;
  double lo = double.infinity;
  for (final v in values) {
    if (!v.isFinite) continue;
    if (v > hi) hi = v;
    if (v < lo) lo = v;
  }
  if (hi == double.negativeInfinity) return (minY: 0.0, maxY: 1.0);
  if (lo == hi) {
    // Flat line — pad symmetrically so it doesn't sit on an edge.
    final pad = (hi.abs() * 0.1).clamp(0.5, double.infinity);
    return (minY: hi - pad, maxY: hi + pad);
  }
  final span = hi - lo;
  final pad = span * 0.15;
  double minY = lo - pad;
  double maxY = hi + pad;
  // Anchor at zero for non-negative data (cleaner baseline).
  if (lo >= 0 && minY < 0) minY = 0.0;
  if (minY == maxY) maxY = minY + 1.0;
  return (minY: minY, maxY: maxY);
}
