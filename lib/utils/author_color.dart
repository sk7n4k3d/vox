import 'dart:collection';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Stable, deterministic per-author color computation based on the Matrix
/// userId (which is immutable for the lifetime of the account, contrary to
/// the displayname).
///
/// The hash function used is FNV-1a 32 bit. Unlike Dart's [String.hashCode]
/// (which is implementation-defined and may differ between platforms or
/// Dart releases), FNV-1a yields the same integer for the same input
/// across every Dart runtime — guaranteeing that all clients display the
/// same color for the same user.
///
/// Two carefully calibrated palettes of 8 colors each are provided. Each
/// color is guaranteed to meet the WCAG AA contrast ratio (>= 4.5:1)
/// against the corresponding Material 3 `surfaceContainerHigh` color used
/// by the message bubbles in FluffyChat (`#E6E0E9` for light, `#36343B`
/// for dark).
class AuthorColors {
  AuthorColors._();

  /// Material 3 default light `surfaceContainerHigh`. Used as the
  /// reference background for the WCAG AA contrast calibration of
  /// [paletteLight].
  static const Color referenceLightBackground = Color(0xFFE6E0E9);

  /// Material 3 default dark `surfaceContainerHigh`. Used as the
  /// reference background for the WCAG AA contrast calibration of
  /// [paletteDark].
  static const Color referenceDarkBackground = Color(0xFF36343B);

  /// Light-mode palette — calibrated to pass WCAG AA (>= 4.5:1) against
  /// [referenceLightBackground].
  static const List<Color> paletteLight = <Color>[
    Color(0xFFA93226), // 0 — Red
    Color(0xFFA04000), // 1 — Orange
    Color(0xFF8E44AD), // 2 — Purple
    Color(0xFF0E6655), // 3 — Green
    Color(0xFF1F618D), // 4 — Cyan
    Color(0xFF2C3E50), // 5 — Blue
    Color(0xFFC2185B), // 6 — Pink
    Color(0xFF7F4F24), // 7 — Brown
  ];

  /// Dark-mode palette — calibrated to pass WCAG AA (>= 4.5:1) against
  /// [referenceDarkBackground].
  static const List<Color> paletteDark = <Color>[
    Color(0xFFFF8A80), // 0 — Red
    Color(0xFFFFB74D), // 1 — Orange
    Color(0xFFCE93D8), // 2 — Purple
    Color(0xFFA5D6A7), // 3 — Green
    Color(0xFF81D4FA), // 4 — Cyan
    Color(0xFF90CAF9), // 5 — Blue
    Color(0xFFF48FB1), // 6 — Pink
    Color(0xFFBCAAA4), // 7 — Brown
  ];

  /// Maximum entries kept per brightness LRU cache. With 512 entries
  /// each, the worst case memory footprint stays under ~64 KB and covers
  /// the active set of any realistic federated room.
  /// Sprint 2 audit finding-011: previously unbounded → memory leak risk.
  static const int _kCacheCap = 512;

  static final LinkedHashMap<String, Color> _cacheLight =
      LinkedHashMap<String, Color>();
  static final LinkedHashMap<String, Color> _cacheDark =
      LinkedHashMap<String, Color>();

  /// Returns the deterministic color for [userId] under the given
  /// [brightness]. Bounded LRU cache (512 entries / brightness).
  static Color forUserId(String userId, Brightness brightness) {
    final cache = brightness == Brightness.dark ? _cacheDark : _cacheLight;
    final cached = cache[userId];
    if (cached != null) {
      // Refresh recency.
      cache.remove(userId);
      cache[userId] = cached;
      return cached;
    }

    final palette = brightness == Brightness.dark
        ? paletteDark
        : paletteLight;
    final color = palette[_fnv1a32(userId) % palette.length];
    if (cache.length >= _kCacheCap) {
      cache.remove(cache.keys.first);
    }
    cache[userId] = color;
    return color;
  }

  /// Computes the WCAG relative luminance of [color] in the sRGB color
  /// space.
  ///
  /// See <https://www.w3.org/TR/WCAG21/#dfn-relative-luminance>.
  static double relativeLuminance(Color color) {
    double channel(int v) {
      final c = v / 255.0;
      return c <= 0.03928 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4) as double;
    }

    final r = channel(((color.r) * 255.0).round() & 0xFF);
    final g = channel(((color.g) * 255.0).round() & 0xFF);
    final b = channel(((color.b) * 255.0).round() & 0xFF);
    return 0.2126 * r + 0.7152 * g + 0.0722 * b;
  }

  /// Computes the WCAG contrast ratio between [a] and [b]. Returns a
  /// value in `[1.0, 21.0]`.
  ///
  /// See <https://www.w3.org/TR/WCAG21/#dfn-contrast-ratio>.
  static double contrastRatio(Color a, Color b) {
    final la = relativeLuminance(a);
    final lb = relativeLuminance(b);
    final lighter = math.max(la, lb);
    final darker = math.min(la, lb);
    return (lighter + 0.05) / (darker + 0.05);
  }

  /// Clears the internal color cache. Exposed for testing only.
  @visibleForTesting
  static void debugClearCache() {
    _cacheLight.clear();
    _cacheDark.clear();
  }
}

/// FNV-1a 32 bit hash. Deterministic across all Dart runtimes — unlike
/// [String.hashCode] which is implementation-defined.
///
/// See <http://www.isthe.com/chongo/tech/comp/fnv/>.
int _fnv1a32(String input) {
  const offsetBasis = 0x811C9DC5; // 2166136261
  const prime = 0x01000193; // 16777619
  var hash = offsetBasis;
  for (final byte in utf8.encode(input)) {
    hash ^= byte;
    hash = (hash * prime) & 0xFFFFFFFF;
  }
  return hash;
}

/// Convenience extension exposing the per-author color from a userId.
extension AuthorColor on String {
  /// Returns the deterministic color associated with this userId for
  /// the given [brightness]. Equivalent to
  /// `AuthorColors.forUserId(this, brightness)`.
  Color authorColor(Brightness brightness) =>
      AuthorColors.forUserId(this, brightness);
}
