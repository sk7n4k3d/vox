import 'package:flutter_test/flutter_test.dart';
import 'package:fluffychat/config/cyber_themes.dart';
void main() {
  test('6 presets, byName fallback', () {
    expect(CyberThemes.all.length, 6);
    expect(CyberThemes.byName('starlink').id, CyberThemeId.starlink);
    expect(CyberThemes.byName('nexus').id, CyberThemeId.nexus);
    expect(CyberThemes.byName('bogus').id, CyberThemeId.cybercore);
    for (final p in CyberThemes.all) {
      expect(p.tokens.cyan.a, greaterThan(0));
    }
  });
}
