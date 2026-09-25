import 'gas_params.dart';

// ════════════════════════════════════════════════════════════════════════
//  calibration.dart
//  ─────────────────────────────────────────────────────────────────────────
//  Applies a saved calibration parameter set to raw BG_MINI device samples to
//  produce TRUE physiological values (pO2 / pCO2 in mmHg).
//
//  The math here is a 1:1 port of the mapping functions in the reference
//  Python calibration script's "NICU" section — nothing here re-derives or
//  changes the model, it only re-implements the same arithmetic so it can
//  run live in the app:
//
//    SolventumCalcPO2(df, x1o, x2o)   → po2FromLifetime / po2FromIntensity
//    ApplyTemperatureCalibration(...) → correctedTemperature
//    CalcPCO2(df, x1c)                → pco2
//
//  A calibration set is produced OFFLINE by that Python script (run once
//  against reference-instrument data), saved as a small parameter file, and
//  then packed into a "material" QR code's `calib` field by the QR
//  generator tool. Scanning that QR (see scan_qr_page.dart /
//  device_detail_page.dart) hands the 4 vectors below to CsvRecorder,
//  which uses this class to write a second, calibrated CSV alongside the
//  raw one — see csv_recorder.dart's attachCalibration().
//
//  ── ⚠ UNIT CAVEAT — please verify before trusting the output ────────────
//  The Python O2 formulas below subtract 32 from the temperature term,
//  which only makes physical sense if that temperature is in °F. This
//  app's live BLE `temperature` channel is documented (gas_params.dart) as
//  °C. If the calibration parameters you scan were fit against a raw NICU
//  export whose "Temp" column was actually °F, applying them here directly
//  to a °C reading will silently give the wrong pO2. No conversion is
//  applied here because the true unit of the ORIGINAL calibration-time
//  temperature column was not established while porting this code — check
//  a known reference point (e.g. a scan at a known pO2) before trusting
//  live readings, and tell me if a °C→°F conversion needs to be added.
//  The CO2 temperature correction (correctedTemperature) is unaffected —
//  it's a plain offset/gain fit and doesn't assume a unit.
// ════════════════════════════════════════════════════════════════════════

/// One saved calibration parameter set, as scanned from a material QR.
///
/// Field shapes mirror exactly what the Python script's
/// `SaveCalibrationParamsNICU` writes / reads back:
///   x1o  — O2 LIFETIME params  [I0_or_tau0, KSV, KSV_T, offset]   (4)
///   x2o  — O2 INTENSITY params [I0_or_tau0, KSV, KSV_T, offset]   (4)
///   x1c  — CO2 params [leak405, leak470, a, b, c, d]              (6)
///   temp — device→reference temperature fit [slope, intercept]   (2)
class CalibrationParams {
  final List<double> x1o;
  final List<double> x2o;
  final List<double> x1c;
  final List<double> temp;

  const CalibrationParams({
    required this.x1o,
    required this.x2o,
    required this.x1c,
    required this.temp,
  });

  /// Parses the `calib` field of a decoded material-QR JSON payload, e.g.:
  ///   "calib": {
  ///     "x1o": [23.59, 0.022426, -0.000005, 13.13025],
  ///     "x2o": [1.507, 0.0498, 0.00283, 0.2865],
  ///     "x1c": [0.6, 0.085, 0.7, 0.3, 2, 20],
  ///     "temp": [1.0, 0.0]
  ///   }
  /// Returns null if [raw] is missing, malformed, or any vector has the
  /// wrong length / a non-finite value — callers should treat that as "no
  /// usable calibration in this QR" rather than guessing.
  static CalibrationParams? tryParse(dynamic raw) {
    if (raw is! Map) return null;

    List<double>? nums(dynamic v, int expectedLength) {
      if (v is! List || v.length != expectedLength) return null;
      final out = <double>[];
      for (final e in v) {
        final d = e is num ? e.toDouble() : double.tryParse(e.toString());
        if (d == null || !d.isFinite) return null;
        out.add(d);
      }
      return out;
    }

    final x1o = nums(raw['x1o'], 4);
    final x2o = nums(raw['x2o'], 4);
    final x1c = nums(raw['x1c'], 6);
    final temp = nums(raw['temp'], 2);
    if (x1o == null || x2o == null || x1c == null || temp == null) {
      return null;
    }
    return CalibrationParams(x1o: x1o, x2o: x2o, x1c: x1c, temp: temp);
  }

  /// Serializes back to the same shape `tryParse` reads — used to write a
  /// traceable `calib_meta` line into the calibrated CSV's header.
  Map<String, dynamic> toJson() => {
        'x1o': x1o,
        'x2o': x2o,
        'x1c': x1c,
        'temp': temp,
      };

  // ── Mapping functions ────────────────────────────────────────────────

  /// True pO2 (mmHg) from the raw Lifetime/phase channel + raw temperature.
  /// Port of SolventumCalcPO2's lifetime branch:
  ///   pO2 = (x1o[0] / (Lifetime - x1o[3]) - 1) / (x1o[1] + x1o[2]*(T-32))
  double po2FromLifetime(double lifetime, double rawTemperature) {
    final denom = x1o[1] + x1o[2] * (rawTemperature - 32);
    return (x1o[0] / (lifetime - x1o[3]) - 1) / denom;
  }

  /// True pO2 (mmHg) from the raw Intensity/magnitude channel + raw temp.
  /// Same form as [po2FromLifetime] with the x2o vector.
  double po2FromIntensity(double intensity, double rawTemperature) {
    final denom = x2o[1] + x2o[2] * (rawTemperature - 32);
    return (x2o[0] / (intensity - x2o[3]) - 1) / denom;
  }

  /// Device thermistor → reference-instrument temperature. Port of
  /// ApplyTemperatureCalibration: `temp[0] * rawTemperature + temp[1]`.
  /// Same units in and out — this is an offset/gain correction only, so
  /// (unlike the O2 formulas above) it carries no Fahrenheit assumption.
  double correctedTemperature(double rawTemperature) =>
      temp[0] * rawTemperature + temp[1];

  /// True pCO2 (mmHg) from the raw 405/470 nm photodiode means and the
  /// *corrected* temperature (see [correctedTemperature]). Port of
  /// CalcPCO2:
  ///   R    = (PD405 - x1c[0]) / (PD470 - x1c[1])
  ///   pCO2 = (x1c[2]*R - x1c[3]) / (x1c[4]*Temp - x1c[5])
  double pco2(double pd405, double pd470, double correctedTemp) {
    final r = (pd405 - x1c[0]) / (pd470 - x1c[1]);
    return (x1c[2] * r - x1c[3]) / (x1c[4] * correctedTemp - x1c[5]);
  }

  /// Applies this calibration to one full sample's worth of raw values —
  /// same mapping, same column set (kAllParams), as csv_recorder.dart's
  /// calibrated-CSV writer, factored out here so the live "Gas Monitor"
  /// view (device_session.dart) and the calibrated CSV both go through
  /// this ONE implementation instead of two copies that could drift apart.
  /// [raw] looks up one raw channel's current value by GasParam.
  Map<GasParam, double> applyTo(double Function(GasParam) raw) {
    final rawTemp = raw(GasParam.temperature);
    final pd405 = raw(GasParam.pd405);
    final pd470 = raw(GasParam.pd470);
    final correctedTemp = correctedTemperature(rawTemp);
    return {
      GasParam.po2Lifetime: po2FromLifetime(raw(GasParam.po2Lifetime), rawTemp),
      GasParam.po2Intensity:
          po2FromIntensity(raw(GasParam.po2Intensity), rawTemp),
      GasParam.pco2Ratio: pco2(pd405, pd470, correctedTemp),
      // pH has no calibration model yet (the NICU calibration QR carries
      // only O2 / CO2 / temperature vectors), so the pH ratio and its two
      // photodiode means pass through RAW — exactly like pd405/pd470 below.
      // In the CALIB view / calibrated CSV the pH column is therefore still
      // the uncalibrated 405/450 ratio.
      GasParam.phRatio: raw(GasParam.phRatio),
      GasParam.temperature: correctedTemp,
      GasParam.pd405: pd405,
      GasParam.pd470: pd470,
      GasParam.ph405: raw(GasParam.ph405),
      GasParam.ph450: raw(GasParam.ph450),
    };
  }
}
