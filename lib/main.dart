// ════════════════════════════════════════════════════════════════════════
//  main.dart
//  Confidence: HIGH — I wrote this complete file in this conversation.
//  This is verbatim what I produced. The AES refactor in the other
//  conversation likely did not change main.dart (it changes ble_manager,
//  scan_qr_page, session_metadata, history_page, csv_recorder).
// ════════════════════════════════════════════════════════════════════════
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import 'ble_manager.dart';
import 'ble_page.dart';
import 'csv_recorder.dart';
import 'device_session.dart';
import 'glass.dart';
import 'history_page.dart';
import 'monitor_page.dart';
import 'scan_qr_page.dart';
import 'theme_manager.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
  ));
  CsvRecorder.instance.init();
  runApp(const GasMonitorApp());
}

class GasMonitorApp extends StatelessWidget {
  const GasMonitorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: ThemeManager.instance.isDarkNotifier,
      builder: (context, isDark, _) {
        return MaterialApp(
          title: 'BloodGas',
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            brightness: isDark ? Brightness.dark : Brightness.light,
            scaffoldBackgroundColor: ThemeManager.instance.bg,
            colorScheme: isDark
                ? const ColorScheme.dark(
                    primary: ThemeManager.cyan,
                    secondary: ThemeManager.green,
                    surface: ThemeManager.darkSurface,
                  )
                : const ColorScheme.light(
                    primary: ThemeManager.cyan,
                    secondary: ThemeManager.green,
                    surface: ThemeManager.lightSurface,
                  ),
            // Inter: designed for UI/data legibility with real tabular
            // figures, wide weight range — pairs with the glass aesthetic
            // and this app's existing thin/bold numeric display style.
            textTheme: GoogleFonts.interTextTheme(
              isDark ? ThemeData.dark().textTheme : ThemeData.light().textTheme,
            ),
            useMaterial3: true,
          ),
          home: const HomePage(),
        );
      },
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════
class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: ThemeManager.instance.isDarkNotifier,
      builder: (context, isDark, _) {
        final tm = ThemeManager.instance;
        return Scaffold(
          backgroundColor: Colors.transparent,
          body: LiquidBackground(
            child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 20),
                  _buildHeader(context, tm, isDark),
                  const SizedBox(height: 28),

                  Expanded(
                    child: Column(
                      children: [
                        Expanded(
                          child: _BigMenuCard(
                            icon: Icons.monitor_heart_rounded,
                            title: 'GAS MONITOR',
                            subtitle: 'Real-time pO₂ · pCO₂ · pH · temperature',
                            accent: ThemeManager.green,
                            isDark: isDark,
                            badge: _SessionsBadge(),
                            onTap: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                  builder: (_) => const MonitorPage()),
                            ),
                          ),
                        ),
                        const SizedBox(height: 14),
                        Expanded(
                          child: _BigMenuCard(
                            icon: Icons.bluetooth_searching,
                            title: 'BLUETOOTH',
                            subtitle: 'Scan & pair sensors',
                            accent: ThemeManager.purple,
                            isDark: isDark,
                            onTap: () => Navigator.push(
                              context,
                              MaterialPageRoute(builder: (_) => const BlePage()),
                            ),
                          ),
                        ),
                        const SizedBox(height: 14),
                        Expanded(
                          child: _BigMenuCard(
                            icon: Icons.history_edu_outlined,
                            title: 'HISTORY',
                            subtitle: 'Recorded sessions',
                            accent: ThemeManager.cyan,
                            isDark: isDark,
                            onTap: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                  builder: (_) => const HistoryPage()),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  Center(
                    child: Text(
                      'v1.0.0',
                      style: TextStyle(
                          color: tm.textSub,
                          fontSize: 11,
                          letterSpacing: 2),
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
              ),
            ),
          ),
          ),
        );
      },
    );
  }

  Widget _buildHeader(BuildContext context, ThemeManager tm, bool isDark) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Flexible so the title yields instead of overflowing on very
        // narrow screens (the QR button now carries a caption).
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'REAL-TIME',
                style: TextStyle(
                  color: ThemeManager.cyan,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 4,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'BloodGas',
                style: TextStyle(
                  color: tm.textPrimary,
                  fontSize: 30,
                  fontWeight: FontWeight.w500,
                  letterSpacing: 1,
                ),
              ),
            ],
          ),
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            ValueListenableBuilder<List<DeviceSession>>(
              valueListenable: BleManager.instance.sessionsNotifier,
              builder: (_, sessions, __) =>
                  _BleChip(connectedCount: sessions.length),
            ),
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 📷 QR scan shortcut
                GestureDetector(
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const ScanQRPage()),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 38,
                        height: 38,
                        child: GlassCard(
                          borderRadius: 14,
                          elevated: false,
                          accent: ThemeManager.cyan,
                          child: Icon(Icons.qr_code_scanner,
                              color: ThemeManager.cyan, size: 18),
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        'Scan device',
                        style: TextStyle(
                          color: tm.textSub,
                          fontSize: 8,
                          letterSpacing: 0.2,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  height: 38,
                  child: Center(child: _ThemeToggle(isDark: isDark)),
                ),
              ],
            ),
          ],
        ),
      ],
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════
class _SessionsBadge extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<DeviceSession>>(
      valueListenable: BleManager.instance.sessionsNotifier,
      builder: (_, sessions, __) {
        if (sessions.isEmpty) return const SizedBox.shrink();
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
          decoration: BoxDecoration(
            color: ThemeManager.green.withValues(alpha: 0.18),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
                color: ThemeManager.green.withValues(alpha: 0.45)),
          ),
          child: Text(
            '${sessions.length} LIVE',
            style: const TextStyle(
              color: ThemeManager.green,
              fontSize: 9,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.5,
            ),
          ),
        );
      },
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════
class _BigMenuCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Color accent;
  final bool isDark;
  final VoidCallback onTap;
  final Widget? badge;

  const _BigMenuCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.accent,
    required this.isDark,
    required this.onTap,
    this.badge,
  });

  @override
  Widget build(BuildContext context) {
    final tm = ThemeManager.instance;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: double.infinity,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(22),
          boxShadow: isDark
              ? [
                  BoxShadow(
                    color: accent.withValues(alpha: 0.08),
                    blurRadius: 18,
                    offset: const Offset(0, 4),
                  ),
                ]
              : [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.06),
                    blurRadius: 14,
                    offset: const Offset(0, 4),
                  ),
                ],
        ),
        child: GlassCard(
        borderRadius: 22,
        accent: accent,
        frost: true,
        child: Row(
          children: [
            Container(
              width: 6,
              decoration: BoxDecoration(
                color: accent,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(20),
                  bottomLeft: Radius.circular(20),
                ),
              ),
            ),
            const SizedBox(width: 20),
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                    color: accent.withValues(alpha: 0.35), width: 1.5),
              ),
              child: Icon(icon, color: accent, size: 36),
            ),
            const SizedBox(width: 20),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          title,
                          style: TextStyle(
                            color: tm.textPrimary,
                            fontSize: 22,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 1.2,
                            height: 1.1,
                          ),
                        ),
                      ),
                      if (badge != null) badge!,
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    subtitle,
                    style: TextStyle(
                      color: tm.textSub,
                      fontSize: 13,
                      letterSpacing: 0.3,
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(right: 22),
              child: Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  Icons.arrow_forward_rounded,
                  color: accent,
                  size: 20,
                ),
              ),
            ),
          ],
        ),
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════
class _BleChip extends StatelessWidget {
  final int connectedCount;
  const _BleChip({required this.connectedCount});

  @override
  Widget build(BuildContext context) {
    final connected = connectedCount > 0;
    final color = connected ? ThemeManager.green : ThemeManager.red;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color,
              boxShadow: connected
                  ? [
                      BoxShadow(
                          color: color.withValues(alpha: 0.5),
                          blurRadius: 5)
                    ]
                  : null,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            connected ? '$connectedCount LIVE' : 'NO LINK',
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.2,
            ),
          ),
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════
class _ThemeToggle extends StatelessWidget {
  final bool isDark;
  const _ThemeToggle({required this.isDark});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => ThemeManager.instance.toggle(),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeInOut,
        width: 72,
        height: 34,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(17),
          color: isDark
              ? const Color(0xFF1E2A3A)
              : const Color(0xFFE0E0E0),
          border: Border.all(
            color: isDark
                ? ThemeManager.cyan.withValues(alpha: 0.3)
                : Colors.black.withValues(alpha: 0.1),
            width: 1.5,
          ),
        ),
        child: Stack(
          children: [
            Positioned(
              left: 9,
              top: 8,
              child: Icon(
                Icons.dark_mode_rounded,
                size: 16,
                color: (isDark ? Colors.white : Colors.black)
                    .withValues(alpha: 0.25),
              ),
            ),
            Positioned(
              right: 9,
              top: 8,
              child: Icon(
                Icons.light_mode_rounded,
                size: 16,
                color: (isDark ? Colors.white : Colors.black)
                    .withValues(alpha: 0.25),
              ),
            ),
            AnimatedPositioned(
              duration: const Duration(milliseconds: 280),
              curve: Curves.easeInOut,
              left: isDark ? 4 : 38,
              top: 4,
              child: Container(
                width: 26,
                height: 26,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isDark ? ThemeManager.cyan : Colors.white,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.2),
                      blurRadius: 6,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Icon(
                  isDark
                      ? Icons.dark_mode_rounded
                      : Icons.light_mode_rounded,
                  size: 14,
                  color: isDark ? Colors.white : Colors.orange.shade600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
