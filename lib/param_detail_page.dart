import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:intl/intl.dart';

import 'device_session.dart';
import 'gas_params.dart';
import 'glass.dart';
import 'theme_manager.dart';

// ══════════════════════════════════════════════════════════════════════════
//  ParamDetailPage — full-screen, single-parameter zoomed view.
//
//  Reached by tapping a parameter's card on DeviceDetailPage. The phone's
//  orientation is unlocked app-wide already (see ios/Info.plist and the
//  absence of any orientation lock in main.dart), so simply rotating the
//  device here gives a wider landscape trace — no extra code needed for
//  that part.
//
//  The chart can only show what's still in the live ring buffer
//  (DeviceSession.maxPoints samples), so "stretching the time axis" means
//  choosing how much of that buffered history to display: a slider picks
//  a trailing time window, from the most recent ~15s out to the full
//  buffered span.
// ══════════════════════════════════════════════════════════════════════════
class ParamDetailPage extends StatefulWidget {
  final DeviceSession session;
  final GasParam param;
  const ParamDetailPage(
      {super.key, required this.session, required this.param});

  @override
  State<ParamDetailPage> createState() => _ParamDetailPageState();
}

class _ParamDetailPageState extends State<ParamDetailPage> {
  /// 1.0 = show the full buffered history; smaller = zoom into just the
  /// most recent slice of it.
  double _windowFraction = 1.0;

  @override
  Widget build(BuildContext context) {
    final tm = ThemeManager.instance;
    final session = widget.session;
    final param = widget.param;
    final accent = param.color;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: LiquidBackground(
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
            child: ValueListenableBuilder<int>(
              valueListenable: session.tick,
              builder: (_, __, ___) {
                final value = session.valueOf(param);
                final allPts = session.seriesFor(param).toList();
                final pts = _windowed(allPts);
                final range = niceRange(pts.map((p) => p.y));

                return Column(
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
                          '#${session.slot} · ${session.displayName}',
                          style: TextStyle(color: tm.textSub, fontSize: 11),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),

                    // ── Big current value + peak ──
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          param.format(value),
                          style: TextStyle(
                            color: accent,
                            fontSize: 52,
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
                                const EdgeInsets.only(bottom: 9, left: 6),
                            child: Text(
                              param.unit,
                              style:
                                  TextStyle(color: tm.textSub, fontSize: 15),
                            ),
                          ),
                        const Spacer(),
                        _StatChip(
                          label: 'PEAK',
                          value: param.format(session.peakOf(param)),
                          unit: param.unit,
                          tone: accent,
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
                                  'Waiting for more samples…',
                                  style: TextStyle(
                                      color: tm.textSub, fontSize: 12),
                                ),
                              )
                            : LineChart(
                                _chartData(pts, range, accent, tm, param),
                                duration: Duration.zero,
                              ),
                      ),
                    ),
                    const SizedBox(height: 14),

                    // ── Time-window slider ("stretch the time axis") ──
                    _WindowSlider(
                      fraction: _windowFraction,
                      shownSeconds: _spanOf(pts),
                      totalSeconds: _spanOf(allPts),
                      enabled: allPts.length >= 2,
                      accent: accent,
                      tm: tm,
                      onChanged: (v) => setState(() => _windowFraction = v),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  /// Trailing slice of [pts] according to [_windowFraction]. 1.0 (default)
  /// returns everything currently buffered; smaller values zoom into just
  /// the most recent portion.
  List<FlSpot> _windowed(List<FlSpot> pts) {
    if (pts.length < 2 || _windowFraction >= 0.999) return pts;
    const minCount = 8;
    final count = (pts.length * _windowFraction)
        .round()
        .clamp(pts.length < minCount ? pts.length : minCount, pts.length);
    return pts.sublist(pts.length - count);
  }

  double _spanOf(List<FlSpot> pts) =>
      pts.length < 2 ? 0 : pts.last.x - pts.first.x;

  LineChartData _chartData(List<FlSpot> pts, ({double minY, double maxY}) range,
      Color accent, ThemeManager tm, GasParam param) {
    final connectedAt = widget.session.connectedAt;
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
                // Real wall-clock time (the iPhone's own clock, same one
                // `connectedAt` was stamped with) rather than a relative
                // "-4m" offset — easier to line up against what was
                // actually happening at the bedside at that moment.
                _formatClock(connectedAt, v),
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

}

/// [secondsSinceConnect] is an x-axis value from the chart (real elapsed
/// seconds since the device connected — see DeviceSession.addSample).
/// Converted back to the iPhone's actual clock time for the axis label.
String _formatClock(DateTime connectedAt, double secondsSinceConnect) {
  final t = connectedAt
      .add(Duration(milliseconds: (secondsSinceConnect * 1000).round()));
  return DateFormat('HH:mm:ss').format(t);
}

String _formatSpan(double seconds) {
  final s = seconds.round();
  if (s < 60) return '${s}s';
  final m = s ~/ 60;
  if (m < 60) return '${m}m';
  final h = m ~/ 60;
  return '${h}h${m % 60}m';
}

// ══════════════════════════════════════════════════════════════════════════
class _WindowSlider extends StatelessWidget {
  final double fraction;
  final double shownSeconds;
  final double totalSeconds;
  final bool enabled;
  final Color accent;
  final ThemeManager tm;
  final ValueChanged<double> onChanged;
  const _WindowSlider({
    required this.fraction,
    required this.shownSeconds,
    required this.totalSeconds,
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
            width: 78,
            child: Text(
              enabled
                  ? '${_formatSpan(shownSeconds)} / '
                      '${_formatSpan(totalSeconds)}'
                  : '—',
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
