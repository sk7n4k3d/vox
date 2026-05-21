import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fluffychat/utils/author_color.dart';

void main() {
  setUp(AuthorColors.debugClearCache);

  group('AuthorColors.forUserId', () {
    test('same userId returns the same color across 1000 calls', () {
      const userId = '@alice:example.org';
      final first = AuthorColors.forUserId(userId, Brightness.light);
      for (var i = 0; i < 1000; i++) {
        expect(
          AuthorColors.forUserId(userId, Brightness.light),
          equals(first),
          reason: 'iteration $i diverged',
        );
      }

      final firstDark = AuthorColors.forUserId(userId, Brightness.dark);
      for (var i = 0; i < 1000; i++) {
        expect(
          AuthorColors.forUserId(userId, Brightness.dark),
          equals(firstDark),
          reason: 'dark iteration $i diverged',
        );
      }
    });

    test('100 random userIds yield >= 6 distinct colors out of 8', () {
      // Deterministic pseudo-random sample so the test is reproducible.
      final ids = <String>[
        for (var i = 0; i < 100; i++) '@user_$i:matrix.example.org',
      ];

      final lightColors = <Color>{
        for (final id in ids) AuthorColors.forUserId(id, Brightness.light),
      };
      final darkColors = <Color>{
        for (final id in ids) AuthorColors.forUserId(id, Brightness.dark),
      };

      expect(
        lightColors.length,
        greaterThanOrEqualTo(6),
        reason: 'light palette under-utilised: $lightColors',
      );
      expect(
        darkColors.length,
        greaterThanOrEqualTo(6),
        reason: 'dark palette under-utilised: $darkColors',
      );
    });

    test(
      'light palette colors all meet WCAG AA contrast against '
      'M3 light surfaceContainerHigh (#E6E0E9)',
      () {
        for (var i = 0; i < AuthorColors.paletteLight.length; i++) {
          final color = AuthorColors.paletteLight[i];
          final ratio = AuthorColors.contrastRatio(
            color,
            AuthorColors.referenceLightBackground,
          );
          expect(
            ratio,
            greaterThanOrEqualTo(4.5),
            reason:
                'paletteLight[$i] = 0x${color.toARGB32().toRadixString(16)} '
                'failed WCAG AA: $ratio < 4.5',
          );
        }
      },
    );

    test(
      'dark palette colors all meet WCAG AA contrast against '
      'M3 dark surfaceContainerHigh (#36343B)',
      () {
        for (var i = 0; i < AuthorColors.paletteDark.length; i++) {
          final color = AuthorColors.paletteDark[i];
          final ratio = AuthorColors.contrastRatio(
            color,
            AuthorColors.referenceDarkBackground,
          );
          expect(
            ratio,
            greaterThanOrEqualTo(4.5),
            reason:
                'paletteDark[$i] = 0x${color.toARGB32().toRadixString(16)} '
                'failed WCAG AA: $ratio < 4.5',
          );
        }
      },
    );

    test('FNV-1a hash stability — fixed inputs map to fixed colors', () {
      // These expectations lock in the algorithm: any change to the
      // hashing strategy (e.g. switching back to String.hashCode) would
      // make every user "jump" to a different color across releases.
      const samples = <String, int>{
        '@alice:example.org': 5,
        '@bob:example.org': 2,
        '@carol:matrix.org': 7,
        '@dave:matrix.org': 4,
        '': 5,
      };

      samples.forEach((userId, expectedIndex) {
        final expectedLight = AuthorColors.paletteLight[expectedIndex];
        final expectedDark = AuthorColors.paletteDark[expectedIndex];
        expect(
          AuthorColors.forUserId(userId, Brightness.light),
          equals(expectedLight),
          reason: 'light bucket for "$userId" should be $expectedIndex',
        );
        expect(
          AuthorColors.forUserId(userId, Brightness.dark),
          equals(expectedDark),
          reason: 'dark bucket for "$userId" should be $expectedIndex',
        );
      });
    });

    test('contrastRatio sanity — black vs white is 21', () {
      expect(
        AuthorColors.contrastRatio(
          const Color(0xFF000000),
          const Color(0xFFFFFFFF),
        ),
        closeTo(21.0, 0.01),
      );
      expect(
        AuthorColors.contrastRatio(
          const Color(0xFFFFFFFF),
          const Color(0xFFFFFFFF),
        ),
        closeTo(1.0, 0.01),
      );
    });
  });

  group('AuthorColor extension', () {
    test('extension delegates to AuthorColors.forUserId', () {
      const userId = '@eve:example.org';
      expect(
        userId.authorColor(Brightness.light),
        equals(AuthorColors.forUserId(userId, Brightness.light)),
      );
      expect(
        userId.authorColor(Brightness.dark),
        equals(AuthorColors.forUserId(userId, Brightness.dark)),
      );
    });
  });
}
