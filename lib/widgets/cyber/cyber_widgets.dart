import 'dart:ui';

import 'package:flutter/material.dart';

import 'package:fluffychat/config/cyberpunk_theme_extension.dart';
import 'package:fluffychat/config/design_tokens.dart';

/// CYBERCORE shared building blocks — used to bring every remaining vanilla
/// screen (auth, settings sub-pages, chat details, new chat, viewers…) up to
/// the fork's dark cyberpunk design language without duplicating glass / glow /
/// hairline boilerplate in each page.
///
/// All visual constants come from [CyberpunkTheme] (colors / glass / blur) and
/// the [FluffySpacing]/[FluffyRadius]/[FluffyTypography] tokens — no magic
/// numbers. Dark-first; reads the extension with a safe fallback.
class CyberColors {
  const CyberColors._();

  static CyberpunkTheme of(BuildContext context) =>
      Theme.of(context).extension<CyberpunkTheme>() ?? CyberpunkTheme.dark();
}

/// A glassy, blurred surface with a hairline border — the canonical CYBERCORE
/// container. Use for cards, field wrappers, floating controls.
class CyberGlass extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry? padding;
  final BorderRadius borderRadius;
  final double? blurSigma;
  final Color? tint;
  final List<BoxShadow>? glow;
  final VoidCallback? onTap;

  const CyberGlass({
    required this.child,
    this.padding,
    this.borderRadius = FluffyRadius.brLg,
    this.blurSigma,
    this.tint,
    this.glow,
    this.onTap,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final cyber = CyberColors.of(context);
    final sigma = blurSigma ?? cyber.blurSigmaSheet;
    final content = ClipRRect(
      borderRadius: borderRadius,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: tint ?? cyber.glassFillLight,
            borderRadius: borderRadius,
            border: Border.all(color: cyber.glassBorder, width: 1),
          ),
          child: Padding(
            padding: padding ?? const EdgeInsets.all(FluffySpacing.lg),
            child: child,
          ),
        ),
      ),
    );
    final glowed = glow == null
        ? content
        : DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: borderRadius,
              boxShadow: glow,
            ),
            child: content,
          );
    if (onTap == null) return glowed;
    return Material(
      color: Colors.transparent,
      borderRadius: borderRadius,
      child: InkWell(
        borderRadius: borderRadius,
        onTap: onTap,
        child: glowed,
      ),
    );
  }
}

/// Section header for settings-style lists — Rajdhani, uppercase, accent-tinted.
class CyberSectionHeader extends StatelessWidget {
  final String label;
  final Color? accent;

  const CyberSectionHeader(this.label, {this.accent, super.key});

  @override
  Widget build(BuildContext context) {
    final cyber = CyberColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        FluffySpacing.xl,
        FluffySpacing.xl,
        FluffySpacing.xl,
        FluffySpacing.sm,
      ),
      child: Text(
        label.toUpperCase(),
        style: FluffyTypography.labelM.copyWith(
          color: accent ?? cyber.cyan,
          letterSpacing: 1.5,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// A tappable settings row inside a [CyberGlass] card: colored icon chip,
/// title (Rajdhani), optional subtitle, trailing chevron or custom widget.
class CyberSettingsTile extends StatelessWidget {
  final IconData icon;
  final Color accent;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;

  const CyberSettingsTile({
    required this.icon,
    required this.accent,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: FluffyRadius.brLg,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: FluffySpacing.md,
            vertical: FluffySpacing.md,
          ),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.16),
                  borderRadius: FluffyRadius.brMd,
                  border: Border.all(color: accent.withValues(alpha: 0.4)),
                ),
                child: Icon(icon, color: accent, size: 20),
              ),
              const SizedBox(width: FluffySpacing.lg),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      style: FluffyTypography.title.copyWith(
                        color: theme.colorScheme.onSurface,
                      ),
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: FluffySpacing.xxs),
                      Text(
                        subtitle!,
                        style: FluffyTypography.bodyS.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (trailing != null)
                trailing!
              else if (onTap != null)
                Icon(
                  Icons.chevron_right_rounded,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A glassy text field wrapper for auth/forms: focus state lights up the cyan
/// border + glow. Wraps any [child] (TextField, etc.) so it inherits the look.
class CyberField extends StatelessWidget {
  final Widget child;
  final bool focused;

  const CyberField({required this.child, this.focused = false, super.key});

  @override
  Widget build(BuildContext context) {
    final cyber = CyberColors.of(context);
    return AnimatedContainer(
      duration: FluffyDurations.fast,
      curve: FluffyCurves.standard,
      decoration: BoxDecoration(
        color: cyber.glassFillLight,
        borderRadius: FluffyRadius.brMd,
        border: Border.all(
          color: focused ? cyber.cyan : cyber.glassBorder,
          width: focused ? 1.5 : 1,
        ),
        boxShadow: focused
            ? FluffyElevation.glowCyan(cyber.cyan, alpha: 0.25)
            : null,
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: FluffySpacing.lg,
        vertical: FluffySpacing.xs,
      ),
      child: child,
    );
  }
}

/// Full-bleed animated cyberpunk background: deep black with a slow cyan→magenta
/// radial mesh. Used behind auth/onboarding for atmosphere (frontend-design:
/// "create atmosphere rather than solid colors").
class CyberBackdrop extends StatelessWidget {
  final Widget child;
  final Animation<double>? animation;

  const CyberBackdrop({required this.child, this.animation, super.key});

  @override
  Widget build(BuildContext context) {
    final cyber = CyberColors.of(context);
    final anim = animation ?? const AlwaysStoppedAnimation<double>(0.5);
    return AnimatedBuilder(
      animation: anim,
      builder: (context, child) {
        final t = anim.value;
        return DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: Alignment(-0.6 + t * 0.4, -0.8 + t * 0.3),
              radius: 1.4,
              colors: [
                cyber.cyan.withValues(alpha: 0.18),
                cyber.magenta.withValues(alpha: 0.10),
                const Color(0xFF05010E),
              ],
              stops: const [0.0, 0.45, 1.0],
            ),
          ),
          child: child,
        );
      },
      child: child,
    );
  }
}

/// A gradient cyan→magenta primary CTA with glow — the signature action button.
class CyberPrimaryButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final bool loading;
  final IconData? icon;

  const CyberPrimaryButton({
    required this.label,
    required this.onPressed,
    this.loading = false,
    this.icon,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final cyber = CyberColors.of(context);
    final enabled = onPressed != null && !loading;
    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: FluffyRadius.brMd,
          gradient: LinearGradient(
            colors: [cyber.cyan, cyber.magenta],
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
          ),
          boxShadow: enabled
              ? FluffyElevation.glowMagenta(cyber.magenta, alpha: 0.4)
              : null,
        ),
        child: Material(
          color: Colors.transparent,
          borderRadius: FluffyRadius.brMd,
          child: InkWell(
            borderRadius: FluffyRadius.brMd,
            onTap: enabled ? onPressed : null,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: FluffySpacing.xl,
                vertical: FluffySpacing.lg,
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (loading)
                    const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.black,
                      ),
                    )
                  else ...[
                    if (icon != null) ...[
                      Icon(icon, color: Colors.black, size: 20),
                      const SizedBox(width: FluffySpacing.sm),
                    ],
                    Text(
                      label,
                      style: FluffyTypography.title.copyWith(
                        color: Colors.black,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
