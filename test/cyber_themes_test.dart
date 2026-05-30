import 'package:flutter_test/flutter_test.dart';
import 'package:fluffychat/config/cyber_themes.dart';
void main() {
  test('5 presets, byName fallback', () {
    expect(CyberThemes.all.length, 5);
    expect(CyberThemes.byName('nexus').id, CyberThemeId.nexus);
    expect(CyberThemes.byName('bogus').id, CyberThemeId.cybercore);
    for (final p in CyberThemes.all) {
      expect(p.tokens.cyan.a, greaterThan(0));
    }
  });
}
