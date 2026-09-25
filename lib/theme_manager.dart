// ════════════════════════════════════════════════════════════════════════
//  theme_manager.dart
//  Confidence: HIGH — reconstructed from search of older conversation,
//  found ~90% of the file verbatim. Last few getters extrapolated from
//  obvious symmetric pattern.
// ════════════════════════════════════════════════════════════════════════
import 'package:flutter/material.dart';

class ThemeManager {
  ThemeManager._();
  static final ThemeManager instance = ThemeManager._();

  final ValueNotifier<bool> isDarkNotifier = ValueNotifier(true);

  bool get isDark => isDarkNotifier.value;

  void toggle() => isDarkNotifier.value = !isDarkNotifier.value;

  // ── Dark palette ────────────────────────────────────────────────────
  static const Color darkBg          = Color(0xFF0A0E1A);
  static const Color darkSurface     = Color(0xFF111827);
  static const Color darkBorder      = Color(0x1AFFFFFF);
  static const Color darkTextPrimary = Colors.white;
  static const Color darkTextSub     = Color(0x66FFFFFF);

  // ── Light palette ───────────────────────────────────────────────────
  static const Color lightBg          = Color(0xFFF2F4F8);
  static const Color lightSurface     = Color(0xFFFFFFFF);
  static const Color lightBorder      = Color(0x1A000000);
  static const Color lightTextPrimary = Color(0xFF0D1117);
  static const Color lightTextSub     = Color(0x99000000);

  // ── Brand accents (shared by both modes) ────────────────────────────
  static const Color cyan     = Color(0xFF00D4FF);
  static const Color green    = Color(0xFF00C96E);
  static const Color red      = Color(0xFFFF4D4D);
  static const Color orange   = Color(0xFFFF8C00);
  static const Color purple   = Color(0xFF7C6FF7);
  static const Color redChart = Color(0xFFFF6B6B);
  static const Color pink     = Color(0xFFFF5CA8); // pH channels

  // ── Dynamic getters ─────────────────────────────────────────────────
  Color get bg          => isDark ? darkBg          : lightBg;
  Color get surface     => isDark ? darkSurface     : lightSurface;
  Color get border      => isDark ? darkBorder      : lightBorder;
  Color get textPrimary => isDark ? darkTextPrimary : lightTextPrimary;
  Color get textSub     => isDark ? darkTextSub     : lightTextSub;

  // ── Glass (frosted-panel) tokens ─────────────────────────────────────
  // Used for structural/navigational chrome only (menu cards, headers,
  // list rows, dialogs) — never behind live waveform charts, which stay
  // on an opaque surface for legibility and to avoid re-blurring on
  // every sample tick. Values follow the standard glassmorphism recipe:
  // 10–20px blur, 10–30% translucent white tint, hairline border, a
  // brighter top edge to fake a light source hitting the glass.
  Color get glassTint      => Colors.white;
  double get glassTintAlpha => isDark ? 0.10 : 0.55;
  Color get glassBorder    =>
      isDark ? Colors.white.withValues(alpha: 0.14) : Colors.white.withValues(alpha: 0.6);
  Color get glassHighlight =>
      isDark ? Colors.white.withValues(alpha: 0.32) : Colors.white.withValues(alpha: 0.85);
}
