import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';

import 'ble_manager.dart';
import 'csv_recorder.dart';
import 'device_session.dart';
import 'gas_params.dart';
import 'glass.dart';
import 'param_detail_page.dart';
import 'scan_qr_page.dart';
import 'theme_manager.dart';

// ══════════════════════════════════════════════════════════════════════════
//  DeviceDetailPage — full-screen live view of a single connected device.
//  Reached by tapping a device card on the Monitor page. Auto-closes if
//  the device disconnects while this page is open.
//
//  Shows one section per charted parameter (4): a big current-value readout
//  + peak stat + a live line chart, stacked in a scrollable column.
// ══════════════════════════════════════════════════════════════════════════
class DeviceDetailPage extends StatelessWidget {
  final DeviceSession session;
  const DeviceDetailPage({super.key, required this.session});

  @override
  Widget build(BuildContext context) {
    final tm = ThemeManager.instance;
    const accent = ThemeManager.green;

    return ValueListenableBuilder<List<DeviceSession>>(
      valueListenable: BleManager.instance.sessionsNotifier,
      builder: (_, sessions, __) {
        if (!sessions.any((s) => s.mac == session.mac)) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (Navigator.canPop(context)) Navigator.pop(context);
          });
        }
        return Scaffold(
          backgroundColor: Colors.transparent,
          body: LiquidBackground(
            child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _DetailHeader(session: session, tm: tm, accent: accent),
                  const SizedBox(height: 12),
                  _QuickNoteField(session: session, tm: tm, accent: accent),
                  const SizedBox(height: 8),
                  _CalibrationBar(session: session, tm: tm),
                  const SizedBox(height: 14),
                  Expanded(
                    // GlassCard shells (in _ParamSection) are built once here,
                    // OUTSIDE the per-tick scope; each section listens to
                    // session.tick internally so only its readout + chart
                    // rebuild per sample — the blur isn't re-run every tick.
                    child: ListView.separated(
                      padding: const EdgeInsets.only(bottom: 8),
                      // 5 charted params + a raw all-channel diagnostic row.
                      itemCount: kChartedParams.length + 1,
                      separatorBuilder: (_, __) => const SizedBox(height: 14),
                      itemBuilder: (_, i) => i < kChartedParams.length
                          ? _ParamSection(
                              session: session,
                              param: kChartedParams[i],
                              tm: tm,
                            )
                          : _RawChannels(session: session, tm: tm),
                    ),
                  ),
                ],
              ),
            ),
          ),
          ),
        );
      },
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════
class _DetailHeader extends StatelessWidget {
  final DeviceSession session;
  final ThemeManager tm;
  final Color accent;
  const _DetailHeader(
      {required this.session, required this.tm, required this.accent});

  @override
  Widget build(BuildContext context) {
    return Row(
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
        const SizedBox(width: 12),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: accent.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: accent.withValues(alpha: 0.4)),
          ),
          child: Text(
            '#${session.slot}',
            style: TextStyle(
              color: accent,
              fontSize: 12,
              fontWeight: FontWeight.w700,
              letterSpacing: 1,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                session.patient ?? session.displayName,
                style: TextStyle(
                  color: tm.textPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              if (session.patient != null)
                Text(
                  session.displayName,
                  style: TextStyle(color: tm.textSub, fontSize: 11),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
            ],
          ),
        ),
        ValueListenableBuilder<String>(
          valueListenable: session.elapsedNotifier,
          builder: (_, e, __) => Text(
            e,
            style: TextStyle(
              color: tm.textSub,
              fontSize: 12,
              letterSpacing: 1.2,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
        const SizedBox(width: 10),
        GestureDetector(
          onTap: () => _confirmDisconnect(context),
          child: Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: ThemeManager.red.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(9),
              border: Border.all(color: ThemeManager.red.withValues(alpha: 0.4)),
            ),
            child: const Icon(Icons.power_settings_new,
                color: ThemeManager.red, size: 16),
          ),
        ),
      ],
    );
  }

  Future<void> _confirmDisconnect(BuildContext context) async {
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
                'DISCONNECT DEVICE',
                style: TextStyle(
                  color: ThemeManager.red,
                  fontSize: 11,
                  letterSpacing: 3,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 14),
              Text(
                '#${session.slot} · ${session.patient ?? session.displayName}',
                style: TextStyle(
                  color: tm.textPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'The current recording will be saved to history.',
                style: TextStyle(color: tm.textSub, fontSize: 12),
              ),
              const SizedBox(height: 20),
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
                        child: Text('DISCONNECT',
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
      await BleManager.instance.disconnect(session.mac);
      if (context.mounted) Navigator.pop(context);
    }
  }
}

// ══════════════════════════════════════════════════════════════════════════
//  Quick note field — lets the nurse log a short piece of info (patient
//  name, status, anything worth flagging) without leaving the live view.
//  Each entry is timestamped and appended to the active recording's notes
//  (visible right away on the History page) and to the CSV itself as a
//  comment row, via CsvRecorder.appendNote — see csv_recorder.dart.
// ══════════════════════════════════════════════════════════════════════════
class _QuickNoteField extends StatefulWidget {
  final DeviceSession session;
  final ThemeManager tm;
  final Color accent;
  const _QuickNoteField(
      {required this.session, required this.tm, required this.accent});

  @override
  State<_QuickNoteField> createState() => _QuickNoteFieldState();
}

class _QuickNoteFieldState extends State<_QuickNoteField> {
  final _ctrl = TextEditingController();
  bool _sending = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final text = _ctrl.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    await CsvRecorder.instance.appendNote(widget.session.mac, text);
    if (!mounted) return;
    _ctrl.clear();
    setState(() => _sending = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: const Text('Logged'),
      backgroundColor: widget.accent.withValues(alpha: 0.85),
      duration: const Duration(milliseconds: 900),
      behavior: SnackBarBehavior.floating,
      margin: const EdgeInsets.all(16),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final tm = widget.tm;
    return GlassCard(
      borderRadius: 18,
      elevated: false,
      padding: const EdgeInsets.fromLTRB(14, 2, 6, 2),
      child: Row(
        children: [
          Icon(Icons.edit_note_rounded, size: 18, color: tm.textSub),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _ctrl,
              style: TextStyle(color: tm.textPrimary, fontSize: 13),
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _submit(),
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                hintText: 'Log a quick note — patient, status…',
                hintStyle: TextStyle(color: tm.textSub, fontSize: 13),
              ),
            ),
          ),
          IconButton(
            onPressed: _sending ? null : _submit,
            icon: Icon(Icons.send_rounded, size: 18, color: widget.accent),
          ),
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════
//  Calibration bar — lets a nurse scan a material QR that carries a saved
//  calibration parameter set (see calibration.dart / QR generator's
//  "Load calibration file" field). Scanning one does NOT touch the raw
//  live charts or the raw recording — it tells CsvRecorder to start a
//  SECOND CSV, same format as the raw one, where the four physiological
//  channels are converted to true pO2/pCO2 (mmHg). See
//  CsvRecorder.attachCalibration.
// ══════════════════════════════════════════════════════════════════════════
class _CalibrationBar extends StatefulWidget {
  final DeviceSession session;
  final ThemeManager tm;
  const _CalibrationBar({required this.session, required this.tm});

  @override
  State<_CalibrationBar> createState() => _CalibrationBarState();
}

class _CalibrationBarState extends State<_CalibrationBar> {
  String? _materialLabel; // non-null once a calibration is active
  bool _busy = false;

  Future<void> _scan() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final result = await ScanQRPage.pickMaterialForCalibration(context);
      if (result == null) return;
      final ok = await CsvRecorder.instance.attachCalibration(
        widget.session.mac,
        result.calib,
        result.materialMeta,
      );
      if (!mounted) return;
      if (ok) {
        final label = (result.materialMeta['material'] as String?)?.trim();
        setState(() {
          _materialLabel =
              (label != null && label.isNotEmpty) ? label : 'calibration set';
        });
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: const Text('Calibration applied — writing a true-value copy'),
          backgroundColor: ThemeManager.green.withValues(alpha: 0.85),
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.all(16),
        ));
      } else {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('No active recording yet — try again in a moment'),
          backgroundColor: ThemeManager.orange,
          duration: Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
          margin: EdgeInsets.all(16),
        ));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tm = widget.tm;
    // Derived from the session itself (not the locally-tracked
    // _materialLabel) so this stays correct across widget rebuilds —
    // _materialLabel resets to null whenever this State is recreated
    // (e.g. navigating away and back), even though the calibration
    // attached to the session is still very much active.
    final calibrated = widget.session.calib != null;
    final label = _materialLabel ?? 'calibration set';
    return GlassCard(
      borderRadius: 18,
      elevated: false,
      padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
      child: Row(
        children: [
          Icon(
            calibrated ? Icons.verified_rounded : Icons.qr_code_scanner_rounded,
            size: 18,
            color: calibrated ? ThemeManager.green : tm.textSub,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              calibrated
                  ? 'Calibrated: $label — also recording true pO₂/pCO₂'
                  : 'Scan a material QR to also record true pO₂/pCO₂ (mmHg)',
              style: TextStyle(
                color: calibrated ? ThemeManager.green : tm.textSub,
                fontSize: 12,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          // Live RAW/CALIB switch — per device, only shown once a
          // calibration is actually attached to this session. Flipping it
          // just toggles session.showCalibrated and bumps session.tick,
          // which every ValueListenableBuilder<int> already listening to
          // tick (param sections, raw channels, mini waveforms elsewhere)
          // picks up immediately via DeviceSession.valueOf/peakOf/seriesFor.
          if (calibrated) ...[
            const SizedBox(width: 8),
            _CalibSwitchPill(session: widget.session, tm: tm),
            const SizedBox(width: 4),
          ],
          IconButton(
            onPressed: _busy ? null : _scan,
            icon: _busy
                ? SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: tm.textSub),
                  )
                : Icon(Icons.qr_code_scanner_rounded,
                    size: 18, color: tm.textSub),
          ),
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════
//  Compact RAW/CALIB segmented pill for the live Gas Monitor view — same
//  visual language as history_param_detail_page.dart's _RawCalibSwitch, but
//  wired to a DeviceSession's own per-device showCalibrated notifier instead
//  of local page state, so the choice is tied to the device, not the page.
// ══════════════════════════════════════════════════════════════════════════
class _CalibSwitchPill extends StatelessWidget {
  final DeviceSession session;
  final ThemeManager tm;
  const _CalibSwitchPill({required this.session, required this.tm});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: session.showCalibrated,
      builder: (_, showCalibrated, __) {
        return GlassCard(
          borderRadius: 14,
          elevated: true,
          padding: const EdgeInsets.all(2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _segment('RAW', !showCalibrated, () => _set(false)),
              _segment('CALIB', showCalibrated, () => _set(true)),
            ],
          ),
        );
      },
    );
  }

  void _set(bool value) {
    if (session.showCalibrated.value == value) return;
    session.showCalibrated.value = value;
    session.tick.value++;
  }

  Widget _segment(String label, bool active, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          color: active
              ? ThemeManager.green.withValues(alpha: 0.22)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: active ? ThemeManager.green : tm.textSub,
            fontSize: 9,
            letterSpacing: 1,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════
//  One section per charted parameter: big current readout + peak stat, then
//  a live auto-ranging line chart (plain opaque surface so the trace reads
//  cleanly, matching the app's bedside-monitor aesthetic).
// ══════════════════════════════════════════════════════════════════════════
class _ParamSection extends StatelessWidget {
  final DeviceSession session;
  final GasParam param;
  final ThemeManager tm;
  const _ParamSection(
      {required this.session, required this.param, required this.tm});

  @override
  Widget build(BuildContext context) {
    final accent = param.color;
    // GlassCard shell built once; only the readout + chart rebuild per tick.
    // Tapping anywhere on the card (including over the mini chart) opens the
    // enlarged single-parameter view — same tap-through pattern already used
    // for the device cards on the Monitor page.
    return GestureDetector(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ParamDetailPage(session: session, param: param),
        ),
      ),
      child: GlassCard(
      borderRadius: 26,
      accent: accent,
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
      child: ValueListenableBuilder<int>(
        valueListenable: session.tick,
        builder: (_, __, ___) {
          final value = session.valueOf(param);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Big current-value readout + peak stat ──
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          param.label.toUpperCase(),
                          style: TextStyle(
                            color: accent.withValues(alpha: 0.9),
                            fontSize: 10,
                            letterSpacing: 2.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(
                              param.format(value),
                              style: TextStyle(
                                color: accent,
                                fontSize: 44,
                                fontWeight: FontWeight.w200,
                                height: 0.95,
                                letterSpacing: -1.5,
                                fontFeatures: const [
                                  FontFeature.tabularFigures()
                                ],
                              ),
                            ),
                            if (param.unit.isNotEmpty)
                              Padding(
                                padding:
                                    const EdgeInsets.only(bottom: 8, left: 6),
                                child: Text(
                                  param.unit,
                                  style: TextStyle(
                                      color: tm.textSub, fontSize: 14),
                                ),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  _PeakStat(
                    value: param.format(session.peakOf(param)),
                    unit: param.unit,
                    tone: accent,
                    tm: tm,
                  ),
                ],
              ),
              const SizedBox(height: 10),
              // ── Live chart ──
              SizedBox(
                height: 140,
                child: _ParamChart(session: session, param: param, tm: tm),
              ),
            ],
          );
        },
      ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════
//  Auto-ranging + clipping line chart for a single parameter, with a left
//  axis so it reads like a real bedside monitor trace.
// ══════════════════════════════════════════════════════════════════════════
//  Raw channel readout — every float in the BLE packet, including the two
//  photodiode means that aren't charted. Diagnostic: if a channel shows "—"
//  or a flat 0 here, the sensor is sending that (NaN / no value), so the
//  blank chart above is the data, not the display.
// ══════════════════════════════════════════════════════════════════════════
class _RawChannels extends StatelessWidget {
  final DeviceSession session;
  final ThemeManager tm;
  const _RawChannels({required this.session, required this.tm});

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      borderRadius: 26,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: ValueListenableBuilder<int>(
        valueListenable: session.tick,
        builder: (_, __, ___) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    'RAW CHANNELS',
                    style: TextStyle(
                      color: tm.textSub,
                      fontSize: 10,
                      letterSpacing: 2.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '${session.sampleCount} pkt',
                    style: TextStyle(
                      color: tm.textSub,
                      fontSize: 10,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              for (final p in kAllParams)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    children: [
                      Container(
                        width: 7,
                        height: 7,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          // Always the true raw reading here — this panel is
                          // an explicit "RAW CHANNELS" diagnostic, so it must
                          // not flip with the RAW/CALIB switch above (that
                          // switch only affects the charted params via
                          // valueOf/peakOf/seriesFor).
                          color: p.color.withValues(
                              alpha: (session.current[p] ?? double.nan)
                                      .isFinite
                                  ? 1
                                  : 0.25),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          p.label,
                          style: TextStyle(
                            color: tm.textSub,
                            fontSize: 11.5,
                          ),
                        ),
                      ),
                      Text(
                        p.format(session.current[p] ?? double.nan),
                        style: TextStyle(
                          color: (session.current[p] ?? double.nan).isFinite
                              ? tm.textPrimary
                              : ThemeManager.red,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                      if (p.unit.isNotEmpty) ...[
                        const SizedBox(width: 3),
                        Text(
                          p.unit,
                          style: TextStyle(color: tm.textSub, fontSize: 10),
                        ),
                      ],
                    ],
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════
class _ParamChart extends StatelessWidget {
  final DeviceSession session;
  final GasParam param;
  final ThemeManager tm;
  const _ParamChart(
      {required this.session, required this.param, required this.tm});

  @override
  Widget build(BuildContext context) {
    final accent = param.color;
    final pts = session.seriesFor(param).toList();
    final range = niceRange(pts.map((p) => p.y));
    return LineChart(
      LineChartData(
        minY: range.minY,
        maxY: range.maxY,
        clipData: const FlClipData.all(),
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          horizontalInterval: (range.maxY - range.minY) / 4,
          getDrawingHorizontalLine: (_) => FlLine(
            color: tm.border,
            strokeWidth: 0.5,
            dashArray: const [3, 6],
          ),
        ),
        borderData: FlBorderData(show: false),
        titlesData: FlTitlesData(
          topTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          bottomTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 38,
              interval: (range.maxY - range.minY) / 4,
              getTitlesWidget: (v, _) => Text(
                param.formatAxis(v),
                style: TextStyle(
                  color: tm.textSub,
                  fontSize: 9,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ),
        ),
        lineTouchData: LineTouchData(
          enabled: true,
          handleBuiltInTouches: true,
          touchTooltipData: LineTouchTooltipData(
            getTooltipColor: (_) => Colors.black.withValues(alpha: 0.82),
            tooltipRoundedRadius: 8,
            tooltipPadding:
                const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            getTooltipItems: (spots) => spots.map((s) {
              final unitSuffix = param.unit.isEmpty ? '' : ' ${param.unit}';
              return LineTooltipItem(
                '${param.format(s.y)}$unitSuffix',
                const TextStyle(
                  color: Colors.white,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                ),
              );
            }).toList(),
          ),
        ),
        lineBarsData: [
          LineChartBarData(
            spots: pts.isEmpty ? [const FlSpot(0, 0)] : pts,
            isCurved: true,
            preventCurveOverShooting: true,
            curveSmoothness: 0.25,
            color: accent,
            barWidth: 2.2,
            isStrokeCapRound: true,
            dotData: const FlDotData(show: false),
            belowBarData: BarAreaData(
              show: true,
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  accent.withValues(alpha: 0.22),
                  accent.withValues(alpha: 0),
                ],
              ),
            ),
          ),
        ],
      ),
      duration: Duration.zero,
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════
class _PeakStat extends StatelessWidget {
  final String value, unit;
  final Color tone;
  final ThemeManager tm;
  const _PeakStat({
    required this.value,
    required this.unit,
    required this.tone,
    required this.tm,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text(
          'PEAK',
          style: TextStyle(
            color: tone.withValues(alpha: 0.85),
            fontSize: 9,
            letterSpacing: 2,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 4),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              value,
              style: TextStyle(
                color: tm.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.w600,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            if (unit.isNotEmpty) ...[
              const SizedBox(width: 3),
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Text(unit,
                    style: TextStyle(color: tm.textSub, fontSize: 10)),
              ),
            ],
          ],
        ),
      ],
    );
  }
}
