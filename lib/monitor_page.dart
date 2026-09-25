// ════════════════════════════════════════════════════════════════════════
//  monitor_page.dart  — MULTI-PARAMETER (Gas Monitor)
//  ─────────────────────────────────────────────────────────────────────────
//  2nd-level page: lists CONNECTED devices as cards. Each card shows the
//  slot #, patient/name, elapsed time, a disconnect button, and a COMPACT
//  multi-parameter summary (the 4 charted params as small readouts + one
//  mini waveform for the primary pCO₂ Ratio trace). Tapping a card pushes
//  the full per-device DeviceDetailPage.
// ════════════════════════════════════════════════════════════════════════
import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';

import 'ble_manager.dart';
import 'device_session.dart';
import 'device_detail_page.dart';
import 'gas_params.dart';
import 'glass.dart';
import 'theme_manager.dart';

class MonitorPage extends StatelessWidget {
  const MonitorPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: LiquidBackground(
        child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Header(),
              const SizedBox(height: 16),
              Expanded(
                child: ValueListenableBuilder<List<DeviceSession>>(
                  valueListenable: BleManager.instance.sessionsNotifier,
                  builder: (_, sessions, __) {
                    if (sessions.isEmpty) return const _EmptyState();
                    return _SessionList(sessions: sessions);
                  },
                ),
              ),
            ],
          ),
        ),
      ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════
class _Header extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final tm = ThemeManager.instance;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
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
        Column(
          children: [
            const Text(
              'GAS MONITOR',
              style: TextStyle(
                color: ThemeManager.green,
                fontSize: 10,
                fontWeight: FontWeight.w700,
                letterSpacing: 3.5,
              ),
            ),
            const SizedBox(height: 2),
            ValueListenableBuilder<List<DeviceSession>>(
              valueListenable: BleManager.instance.sessionsNotifier,
              builder: (_, sessions, __) => Text(
                '${sessions.length}/$kMaxDevices devices',
                style: TextStyle(
                  color: tm.textSub,
                  fontSize: 11,
                  letterSpacing: 1.5,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(width: 38),
      ],
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();
  @override
  Widget build(BuildContext context) {
    final tm = ThemeManager.instance;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.monitor_heart_outlined,
              size: 56, color: ThemeManager.green.withValues(alpha: 0.4)),
          const SizedBox(height: 16),
          Text(
            'NO DEVICES CONNECTED',
            style: TextStyle(
              color: tm.textSub,
              fontSize: 12,
              letterSpacing: 3,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 40),
            child: Text(
              'Real-time blood-gas monitoring.\nScan a QR code or open the Bluetooth page\nto connect up to $kMaxDevices sensors.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: tm.textSub,
                fontSize: 12,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════
class _SessionList extends StatelessWidget {
  final List<DeviceSession> sessions;
  const _SessionList({required this.sessions});

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      itemCount: sessions.length,
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      itemBuilder: (_, i) => _DeviceCard(session: sessions[i]),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════
//  One card per device. Listens to its own session's tick notifier so
//  multiple devices don't trigger each other's rebuilds.
// ══════════════════════════════════════════════════════════════════════════
class _DeviceCard extends StatelessWidget {
  final DeviceSession session;
  const _DeviceCard({required this.session});

  /// Primary parameter surfaced as the card's mini waveform.
  static const GasParam _primary = GasParam.pco2Ratio;

  @override
  Widget build(BuildContext context) {
    final tm = ThemeManager.instance;
    const accent = ThemeManager.green;

    // GlassCard sits OUTSIDE the per-tick ValueListenableBuilder so its
    // BackdropFilter blur isn't re-run on every BLE sample — only the
    // Column below rebuilds live.
    return GestureDetector(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => DeviceDetailPage(session: session),
        ),
      ),
      child: GlassCard(
        accent: accent,
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: ValueListenableBuilder<int>(
          valueListenable: session.tick,
          builder: (_, __, ___) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ── Top bar: slot + patient + disconnect ──
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: accent.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                            color: accent.withValues(alpha: 0.4)),
                      ),
                      child: Text(
                        '#${session.slot}',
                        style: const TextStyle(
                          color: accent,
                          fontSize: 11,
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
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          if (session.patient != null)
                            Text(
                              session.displayName,
                              style: TextStyle(
                                color: tm.textSub,
                                fontSize: 10,
                              ),
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
                          fontSize: 11,
                          letterSpacing: 1.2,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    GestureDetector(
                      onTap: () => _confirmDisconnect(context),
                      child: Container(
                        width: 30,
                        height: 30,
                        decoration: BoxDecoration(
                          color: ThemeManager.red.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                              color: ThemeManager.red.withValues(alpha: 0.4)),
                        ),
                        child: const Icon(Icons.power_settings_new,
                            color: ThemeManager.red, size: 14),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),

                // ── Compact multi-param readouts (5 charted params) ──
                Row(
                  children: [
                    for (int i = 0; i < kChartedParams.length; i++) ...[
                      if (i != 0) const SizedBox(width: 8),
                      Expanded(
                        child: _ParamReadout(
                          param: kChartedParams[i],
                          value: session.valueOf(kChartedParams[i]),
                          tm: tm,
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 12),

                // ── One mini waveform for the primary pCO₂ Ratio trace ──
                Row(
                  children: [
                    Text(
                      _primary.label.toUpperCase(),
                      style: TextStyle(
                        color: _primary.color.withValues(alpha: 0.85),
                        fontSize: 8,
                        letterSpacing: 2,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const Spacer(),
                    _MiniStat(
                      label: 'PEAK',
                      value: _primary.format(session.peakOf(_primary)),
                      unit: _primary.unit,
                      tone: _primary.color,
                      tm: tm,
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                SizedBox(
                  height: 64,
                  child: _MiniWaveform(session: session, param: _primary),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Future<void> _confirmDisconnect(BuildContext context) async {
    final tm = ThemeManager.instance;
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
    }
  }
}

// ══════════════════════════════════════════════════════════════════════════
//  A single compact parameter readout: colored short label + current value
//  (to the param's own precision) + unit.
// ══════════════════════════════════════════════════════════════════════════
class _ParamReadout extends StatelessWidget {
  final GasParam param;
  final double value;
  final ThemeManager tm;
  const _ParamReadout({
    required this.param,
    required this.value,
    required this.tm,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          param.shortLabel,
          style: TextStyle(
            color: param.color,
            fontSize: 9,
            letterSpacing: 1,
            fontWeight: FontWeight.w700,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 3),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            // Five readouts now share this row (pH Ratio was added), so
            // shrink a long value to fit instead of cutting it to "0.98…".
            Flexible(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.bottomLeft,
                child: Text(
                  param.format(value),
                  style: TextStyle(
                    color: tm.textPrimary,
                    fontSize: 20,
                    fontWeight: FontWeight.w300,
                    height: 1.0,
                    letterSpacing: -0.5,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                  maxLines: 1,
                ),
              ),
            ),
            if (param.unit.isNotEmpty) ...[
              const SizedBox(width: 2),
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Text(
                  param.unit,
                  style: TextStyle(color: tm.textSub, fontSize: 9),
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════
class _MiniWaveform extends StatelessWidget {
  final DeviceSession session;
  final GasParam param;
  const _MiniWaveform({required this.session, required this.param});

  @override
  Widget build(BuildContext context) {
    final tm = ThemeManager.instance;
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
        titlesData: const FlTitlesData(show: false),
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
                  fontSize: 12,
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
            barWidth: 1.8,
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

class _MiniStat extends StatelessWidget {
  final String label, value, unit;
  final Color tone;
  final ThemeManager tm;
  const _MiniStat({
    required this.label,
    required this.value,
    required this.unit,
    required this.tone,
    required this.tm,
  });
  @override
  Widget build(BuildContext context) {
    return Row(
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
        const SizedBox(width: 6),
        Text(
          value,
          style: TextStyle(
            color: tm.textPrimary,
            fontSize: 14,
            fontWeight: FontWeight.w600,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        if (unit.isNotEmpty) ...[
          const SizedBox(width: 1),
          Text(
            unit,
            style: TextStyle(color: tm.textSub, fontSize: 10),
          ),
        ],
      ],
    );
  }
}
