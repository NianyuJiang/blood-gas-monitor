import 'dart:ui';
import 'package:flutter/material.dart';

import 'theme_manager.dart';

// ══════════════════════════════════════════════════════════════════════════
//  Liquid Glass material for the app.
//
//  GlassCard  — a frosted "liquid glass" panel: backdrop blur + translucent
//               tinted fill + specular top highlight + soft edge border + a
//               gentle drop shadow so it floats over the ambient background.
//               The fill/border fills the whole panel (via Positioned.fill),
//               so it works whether the caller sizes the CARD (e.g. a 38×38
//               icon button) or lets the content dictate size (a menu card).
//
//  LiquidBackground — a dark base with soft colored "aurora" blobs. Put it
//               behind a (transparent) Scaffold so the glass has real colour
//               and light to refract.
//
//  GlassPill  — a compact capsule glass button.
// ══════════════════════════════════════════════════════════════════════════

class GlassCard extends StatelessWidget {
  final Widget child;
  final double borderRadius;
  final EdgeInsetsGeometry padding;
  final Color? accent;
  final double blur;

  /// Real backdrop blur is expensive; stacked across many cards it causes
  /// page-transition jank. Off by default — over the soft ambient background
  /// the translucent fill looks all but identical. Turn on only for a few
  /// "hero" surfaces (e.g. the home menu cards).
  final bool frost;

  /// Adds a soft drop shadow so the panel reads as floating glass.
  final bool elevated;

  // NON-const on purpose: GlassCard reads ThemeManager.instance at build
  // time, so it must rebuild on light/dark toggle. A const instance would be
  // cached and freeze at the theme it was first built with.
  // ignore: prefer_const_constructors_in_immutables
  GlassCard({
    super.key,
    required this.child,
    this.borderRadius = 22,
    this.padding = EdgeInsets.zero,
    this.accent,
    this.blur = 14,
    this.frost = false,
    this.elevated = true,
  });

  @override
  Widget build(BuildContext context) {
    final tm = ThemeManager.instance;
    final radius = BorderRadius.circular(borderRadius);
    final isDark = tm.isDark;
    final tintAlpha = tm.glassTintAlpha;
    final accentColor = accent ?? tm.glassTint;
    final accentAlpha = isDark ? 0.08 : 0.05;

    final fillDecoration = BoxDecoration(
      borderRadius: radius,
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          Color.alphaBlend(
            tm.glassTint.withValues(alpha: tintAlpha + 0.06),
            Color.alphaBlend(
              accentColor.withValues(alpha: accentAlpha),
              tm.surface,
            ),
          ),
          Color.alphaBlend(
            tm.glassTint.withValues(alpha: tintAlpha),
            tm.surface,
          ),
        ],
      ),
      border: Border.all(color: tm.glassBorder, width: 1),
    );

    final stack = Stack(
          // passthrough: the base fill receives the SAME constraints the card
          // got, so an outer SizedBox (e.g. a 38×38 icon button) fills the
          // whole button, while content-sized/flex cards still size normally.
          fit: StackFit.passthrough,
          children: [
            // ── Base translucent tinted fill ──
            Container(
              padding: padding,
              decoration: fillDecoration,
              child: child,
            ),
            // ── Diagonal specular sheen (top-left light source) ──
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: radius,
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.center,
                      colors: [
                        tm.glassHighlight.withValues(alpha: isDark ? 0.10 : 0.22),
                        tm.glassHighlight.withValues(alpha: 0),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            // ── Bright specular top edge ──
            Positioned(
              left: 1,
              right: 1,
              top: 1,
              child: IgnorePointer(
                child: Container(
                  height: 1.5,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.only(
                      topLeft: Radius.circular(borderRadius - 1),
                      topRight: Radius.circular(borderRadius - 1),
                    ),
                    gradient: LinearGradient(
                      colors: [
                        tm.glassHighlight.withValues(alpha: 0),
                        tm.glassHighlight,
                        tm.glassHighlight.withValues(alpha: 0),
                      ],
                      stops: const [0, 0.5, 1],
                    ),
                  ),
                ),
              ),
            ),
          ],
    );

    final glass = ClipRRect(
      borderRadius: radius,
      child: frost
          ? BackdropFilter(
              filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
              child: stack,
            )
          : stack,
    );

    if (!elevated) return glass;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: [
          BoxShadow(
            color: (accent ?? Colors.black)
                .withValues(alpha: isDark ? 0.28 : 0.12),
            blurRadius: 22,
            spreadRadius: -4,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: glass,
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════
//  LiquidBackground — ambient colored backdrop behind a transparent Scaffold.
// ══════════════════════════════════════════════════════════════════════════
class LiquidBackground extends StatelessWidget {
  final Widget child;
  const LiquidBackground({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final tm = ThemeManager.instance;
    final isDark = tm.isDark;
    final a = isDark ? 0.22 : 0.13;
    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(color: tm.bg),
        _blob(const Alignment(-1.1, -1.0), ThemeManager.cyan, 340, a),
        _blob(const Alignment(1.2, -0.55), ThemeManager.purple, 380, a),
        _blob(const Alignment(-0.9, 0.95), ThemeManager.green, 360, a * 0.9),
        _blob(const Alignment(1.05, 1.1), ThemeManager.orange, 300, a * 0.7),
        child,
      ],
    );
  }

  Widget _blob(Alignment align, Color color, double size, double alpha) {
    return Align(
      alignment: align,
      child: IgnorePointer(
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(
              colors: [
                color.withValues(alpha: alpha),
                color.withValues(alpha: 0),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════
//  GlassPill — a capsule-shaped liquid-glass button.
// ══════════════════════════════════════════════════════════════════════════
class GlassPill extends StatelessWidget {
  final Widget child;
  final VoidCallback? onTap;
  final Color? accent;
  final EdgeInsetsGeometry padding;
  // NON-const on purpose (see GlassCard) — must rebuild on theme toggle.
  // ignore: prefer_const_constructors_in_immutables
  GlassPill({
    super.key,
    required this.child,
    this.onTap,
    this.accent,
    this.padding = const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: GlassCard(
        borderRadius: 100,
        accent: accent,
        padding: padding,
        child: child,
      ),
    );
  }
}
