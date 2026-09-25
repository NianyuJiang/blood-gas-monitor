import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:intl/intl.dart';

import 'csv_recorder.dart';
import 'gas_params.dart';
import 'glass.dart';
import 'theme_manager.dart';

// ══════════════════════════════════════════════════════════════════════════
//  HistoryParamDetailPage — full-screen, single-parameter zoomed view for a
//  FINISHED recording loaded from History.
//
//  This is the History-page counterpart of ParamDetailPage (the live "Gas
//  Monitor" zoom view): same enlarged chart, same trailing time-window
//  slider to "stretch the time axis", same rotate-the-phone-for-landscape
//  behavior. The difference is the data source — a static RecordingData
//  parsed from a saved CSV (CsvRecorder.parseFile) instead of a live
//  DeviceSession ring buffer — so this page never changes after it loads;
//  the slider only changes how much of the already-recorded trace is
//  shown, not what's being recorded.
//
//  Reached by tapping a parameter's card on RecordingChartPage
//  (history_page.dart's _buildParamSection).
//
//  RAW / CALIBRATED DATA — History always shows the calibrated (true
//  physiological value) dataset when one exists for this recording
//  (history_page.dart found a paired raw ⇄ calibrated file by filename —
//  see _findPairedRecordingName — and passed both in). There's no toggle
//  here: Gas Monitor is where the nurse picks RAW vs CALIB live; once a
//  recording is in History it should just show the true value. Falls back
//  to the raw dataset only when no calibrated companion file exists.
// ══════════════════════════════════════════════════════════════════════════
class HistoryParamDetailPage extends StatefulWidget {
  /// The raw (sensor-reading) dataset, if available.
  final RecordingData? rawData;

  /// The calibrated (true physiological value) dataset, if available.
  final RecordingData? calibratedData;

  final GasParam param;
  final String title; // e.g. the session's display name
  final String subtitle; // e.g. "#1 · 09/17/2026"
  const HistoryParamDetailPage({
    super.key,
    required this.rawData,
    required this.calibratedData,
    required this.param,
    required this.title,
    required this.subtitle,
  });

  @override
  State<HistoryParamDetailPage> createState() =>
      _HistoryParamDetailPageState();
}

class _HistoryParamDetailPageState extends State<HistoryParamDetailPage> {
  /// 1.0 = show the full recorded trace; smaller = zoom into just the
  /// most recent (trailing) slice of it.
  double _windowFraction = 1.0;

  /// Always prefer the calibrated dataset when one exists for this
  /// recording; fall back to raw only when no calibrated companion file
  /// was found. No user-facing toggle — see the class doc comment above.
  bool get _showCalibrated => widget.calibratedData != null;

  static const _emptyData =
      RecordingData(start: null, end: null, samples: []);

  @override
  Widget build(BuildContext context) {
    final tm = ThemeManager.instance;
    final data = (_showCalibrated ? widget.calibratedData : widget.rawData) ??
        _emptyData;
    final param = widget.param;
    final accent = param.color;

    final allPts = List<FlSpot>.generate(
      data.samples.length,
      (i) => FlSpot(i.toDouble(), data.samples[i].valueOf(param)),
    );
    final pts = _windowed(allPts);
    final range = niceRange(pts.map((p) => p.y));
    final lastValue = data.samples.isEmpty
        ? double.nan
        : data.samples.last.valueOf(param);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: LiquidBackground(
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ── Header ──
                Row(
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
                    Expanded(
                      child: Text(
                        param.label.toUpperCase(),
                        style: TextStyle(
                          color: accent,
                          fontSize: 14,
                          letterSpacing: 2.5,
                          fontWeight: FontWeight.w700,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Text(
                      '${widget.title} · ${widget.subtitle}',
                      style: TextStyle(color: tm.textSub, fontSize: 11),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
                const SizedBox(height: 14),

                // ── Last recorded value + peak ──
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      param.format(lastValue),
                      style: TextStyle(
                        color: accent,
                        fontSize: 52,
                        fontWeight: FontWeight.w200,
                        height: 0.95,
                        letterSpacing: -1.5,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                    if (param.unit.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 9, left: 6),
                        child: Text(
                          param.unit,
                          style: TextStyle(color: tm.textSub, fontSize: 15),
                        ),
                      ),
                    const Spacer(),
                    _StatChip(
                      label: 'PEAK',
                      value: param.format(data.peakOf(param)),
                      unit: param.unit,
                      tone: accent,
                      tm: tm,
                    ),
                    const SizedBox(width: 18),
                    _StatChip(
                      label: 'MEAN',
                      value: param.format(data.meanOf(param)),
                      unit: param.unit,
                      tone: tm.textSub,
                      tm: tm,
                    ),
                  ],
                ),
                const SizedBox(height: 14),

                // ── Enlarged chart ──
                Expanded(
                  child: GlassCard(
                    borderRadius: 26,
                    accent: accent,
                    padding: const EdgeInsets.fromLTRB(6, 16, 16, 8),
                    child: pts.length < 2
                        ? Center(
                            child: Text(
                              'Not enough data to chart',
                              style:
                                  TextStyle(color: tm.textSub, fontSize: 12),
                            ),
                          )
                        : LineChart(
                            _chartData(data, pts, range, accent, tm, param),
                            duration: Duration.zero,
                          ),
                  ),
                ),
                const SizedBox(height: 14),

                // ── Time-window slider ("stretch the time axis") ──
                _WindowSlider(
                  fraction: _windowFraction,
                  shownLabel: _spanLabel(data, pts),
                  totalLabel: _spanLabel(data, allPts),
                  enabled: allPts.length >= 2,
                  accent: accent,
                  tm: tm,
                  onChanged: (v) => setState(() => _windowFraction = v),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Trailing slice of [pts] according to [_windowFraction]. 1.0 (default)
  /// returns the whole recording; smaller values zoom into just the most
  /// recent portion of it — same behavior as the live ParamDetailPage.
  List<FlSpot> _windowed(List<FlSpot> pts) {
    if (pts.length < 2 || _windowFraction >= 0.999) return pts;
    const minCount = 8;
    final count = (pts.length * _windowFraction)
        .round()
        .clamp(pts.length < minCount ? pts.length : minCount, pts.length);
    return pts.sublist(pts.length - count);
  }

  /// The real timestamp for sample index [i], parsed from that row's
  /// `time` column (an absolute "yyyy-MM-dd HH:mm:ss.ffff" string — see
  /// CsvRecorder._timestamp). Null if missing/unparseable (e.g. an older
  /// recording saved with the previous relative-duration format).
  DateTime? _timestampAt(RecordingData data, int i) {
    if (i < 0 || i >= data.samples.length) return null;
    return DateTime.tryParse(data.samples[i].elapsedText);
  }

  /// "12:03:11 – 12:14:52" wall-clock span of [pts] if real timestamps are
  /// available, otherwise "N samples" as a graceful fallback.
  String _spanLabel(RecordingData data, List<FlSpot> pts) {
    if (pts.isEmpty) return '—';
    final startI = pts.first.x.round();
    final endI = pts.last.x.round();
    final start = _timestampAt(data, startI);
    final end = _timestampAt(data, endI);
    if (start != null && end != null) {
      final fmt = DateFormat('HH:mm:ss');
      return '${fmt.format(start)}–${fmt.format(end)}';
    }
    return '${pts.length} samples';
  }

  LineChartData _chartData(
      RecordingData data,
      List<FlSpot> pts,
      ({double minY, double maxY}) range,
      Color accent,
      ThemeManager tm,
      GasParam param) {
    return LineChartData(
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
        bottomTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            reservedSize: 22,
            interval: (pts.last.x - pts.first.x) / 4,
            getTitlesWidget: (v, _) => Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                _formatAxisClock(data, v),
                style: TextStyle(color: tm.textSub, fontSize: 9),
              ),
            ),
          ),
        ),
        leftTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            reservedSize: 42,
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
            final t = _timestampAt(data, s.x.round());
            final valueLine = '${param.format(s.y)}$unitSuffix';
            return LineTooltipItem(
              valueLine,
              const TextStyle(
                color: Colors.white,
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
              ),
              children: t == null
                  ? null
                  : [
                      TextSpan(
                        text: '\n${DateFormat('HH:mm:ss').format(t)}',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.7),
                          fontSize: 10,
                          fontWeight: FontWeight.w400,
                        ),
                      ),
                    ],
            );
          }).toList(),
        ),
      ),
      lineBarsData: [
        LineChartBarData(
          spots: pts,
          isCurved: true,
          preventCurveOverShooting: true,
          curveSmoothness: 0.25,
          color: accent,
          barWidth: 2.6,
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
    );
  }

  String _formatAxisClock(RecordingData data, double x) {
    final t = _timestampAt(data, x.round());
    if (t == null) return '#${x.round()}';
    return DateFormat('HH:mm:ss').format(t);
  }
}

// ══════════════════════════════════════════════════════════════════════════
class _WindowSlider extends StatelessWidget {
  final double fraction;
  final String shownLabel;
  final String totalLabel;
  final bool enabled;
  final Color accent;
  final ThemeManager tm;
  final ValueChanged<double> onChanged;
  const _WindowSlider({
    required this.fraction,
    required this.shownLabel,
    required this.totalLabel,
    required this.enabled,
    required this.accent,
    required this.tm,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      borderRadius: 18,
      elevated: false,
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Row(
        children: [
          Icon(Icons.unfold_more_rounded, size: 16, color: tm.textSub),
          const SizedBox(width: 8),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 2.5,
                thumbShape:
                    const RoundSliderThumbShape(enabledThumbRadius: 7),
                overlayShape:
                    const RoundSliderOverlayShape(overlayRadius: 14),
              ),
              child: Slider(
                value: fraction.clamp(0.05, 1.0),
                min: 0.05,
                max: 1.0,
                activeColor: accent,
                inactiveColor: tm.border,
                onChanged: enabled ? onChanged : null,
              ),
            ),
          ),
          const SizedBox(width: 4),
          SizedBox(
            width: 128,
            child: Text(
              enabled ? shownLabel : '—',
              textAlign: TextAlign.right,
              style: TextStyle(
                color: tm.textSub,
                fontSize: 10,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════
class _StatChip extends StatelessWidget {
  final String label, value, unit;
  final Color tone;
  final ThemeManager tm;
  const _StatChip({
    required this.label,
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
          label,
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
