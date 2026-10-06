import 'package:collection/collection.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/utils/color_value.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ThemeBuilder extends StatefulWidget {
  final Widget Function(
    BuildContext context,
    ThemeMode themeMode,
    Color? primaryColor,
  )
  builder;

  final String themeModeSettingsKey;
  final String primaryColorSettingsKey;

  const ThemeBuilder({
    required this.builder,
    this.themeModeSettingsKey = 'theme_mode',
    this.primaryColorSettingsKey = 'primary_color',
    super.key,
  });

  @override
  State<ThemeBuilder> createState() => ThemeController();
}

class ThemeController extends State<ThemeBuilder> {
  SharedPreferences? _sharedPreferences;
  ThemeMode? _themeMode;
  Color? _primaryColor;

  ThemeMode get themeMode => _themeMode ?? ThemeMode.system;

  Color? get primaryColor => _primaryColor;

  static ThemeController of(BuildContext context) =>
      Provider.of<ThemeController>(context, listen: false);

  Future<void> _loadData(_) async {
    final preferences = _sharedPreferences ??=
        await SharedPreferences.getInstance();

    final rawThemeMode = preferences.getString(widget.themeModeSettingsKey);
    final rawColor = preferences.getInt(widget.primaryColorSettingsKey);

    setState(() {
      _themeMode = ThemeMode.values.singleWhereOrNull(
        (value) => value.name == rawThemeMode,
      );
      _primaryColor = rawColor == null ? null : Color(rawColor);
    });
  }

  Future<void> setThemeMode(ThemeMode newThemeMode) async {
    final preferences = _sharedPreferences ??=
        await SharedPreferences.getInstance();
    await preferences.setString(widget.themeModeSettingsKey, newThemeMode.name);
    setState(() {
      _themeMode = newThemeMode;
    });
  }

  Future<void> setPrimaryColor(Color? newPrimaryColor) async {
    final preferences = _sharedPreferences ??=
        await SharedPreferences.getInstance();
    if (newPrimaryColor == null) {
      await preferences.remove(widget.primaryColorSettingsKey);
    } else {
      await preferences.setInt(
        widget.primaryColorSettingsKey,
        newPrimaryColor.hexValue,
      );
    }
    setState(() {
      _primaryColor = newPrimaryColor;
    });
  }

  /// Selects a premium theme preset (see CyberThemes). Persists the id and
  /// clears any custom primary color so the preset's own seed takes effect,
  /// then rebuilds the whole app via setState.
  Future<void> setCyberTheme(String presetId) async {
    final preferences = _sharedPreferences ??=
        await SharedPreferences.getInstance();
    await AppSettings.cyberThemeId.setItem(presetId);
    await AppSettings.useDynamicColor.setItem(false);
    await preferences.remove(widget.primaryColorSettingsKey);
    setState(() {
      _primaryColor = null;
    });
  }

  @override
  void initState() {
    WidgetsBinding.instance.addPostFrameCallback(_loadData);
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    return Provider(
      create: (_) => this,
      child: DynamicColorBuilder(
        // Priorité : couleur choisie dans la palette > couleur du fond d'écran
        // (pastille « Système ») > seed du preset. Avant, `light?.primary`
        // s'appliquait même sans pastille « Système » : le fond d'écran Android
        // écrasait le seed du preset, donc changer de thème ne changeait que les
        // accents CYBER et laissait les couleurs Material sur celles du fond
        // d'écran — d'où l'impression que les couleurs d'accentuation n'étaient
        // pas prises en compte.
        builder: (light, _) => widget.builder(
          context,
          themeMode,
          primaryColor ??
              (AppSettings.useDynamicColor.value ? light?.primary : null),
        ),
      ),
    );
  }
}
