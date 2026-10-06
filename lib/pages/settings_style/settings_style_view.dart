import 'dart:ui';

import 'package:dynamic_color/dynamic_color.dart';
import 'package:fluffychat/config/cyber_themes.dart';
import 'package:fluffychat/config/design_tokens.dart';
import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/config/themes.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/pages/chat/events/state_message.dart';
import 'package:fluffychat/utils/account_config.dart';
import 'package:fluffychat/utils/color_value.dart';
import 'package:fluffychat/widgets/avatar.dart';
import 'package:fluffychat/widgets/cyber/cyber_fx.dart';
import 'package:fluffychat/widgets/cyber/cyber_widgets.dart';
import 'package:fluffychat/widgets/layouts/max_width_body.dart';
import 'package:fluffychat/widgets/matrix.dart';
import 'package:fluffychat/widgets/mxc_image.dart';
import 'package:fluffychat/widgets/theme_builder.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:matrix/matrix.dart';

import '../../config/app_config.dart';
import '../../widgets/settings_switch_list_tile.dart';
import 'settings_style.dart';

class SettingsStyleView extends StatelessWidget {
  final SettingsStyleController controller;

  const SettingsStyleView(this.controller, {super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cyber = CyberColors.of(context);
    final reduceMotion = CyberMotion.reduced(context);

    const colorPickerSize = 32.0;
    final client = Matrix.of(context).client;
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: !FluffyThemes.isColumnMode(context),
        centerTitle: FluffyThemes.isColumnMode(context),
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: CyberGlitchText(L10n.of(context).changeTheme),
      ),
      backgroundColor: theme.colorScheme.surface,
      body: MaxWidthBody(
        child: Column(
          crossAxisAlignment: .stretch,
          children: [
            const CyberSectionHeader('THÈME PREMIUM', accent: Color(0xFFA78BFA)),
            _CyberThemePicker(reduceMotion: reduceMotion),
            Padding(
              padding: const EdgeInsets.all(FluffySpacing.md),
              child: SegmentedButton<ThemeMode>(
                selected: {controller.currentTheme},
                onSelectionChanged: (selected) =>
                    controller.switchTheme(selected.single),
                segments: [
                  ButtonSegment(
                    value: ThemeMode.light,
                    label: Text(L10n.of(context).lightTheme),
                    icon: const Icon(Icons.light_mode_outlined),
                  ),
                  ButtonSegment(
                    value: ThemeMode.dark,
                    label: Text(L10n.of(context).darkTheme),
                    icon: const Icon(Icons.dark_mode_outlined),
                  ),
                  ButtonSegment(
                    value: ThemeMode.system,
                    label: Text(L10n.of(context).systemTheme),
                    icon: const Icon(Icons.auto_mode_outlined),
                  ),
                ],
              ),
            ),
            Divider(color: cyber.glassBorder),
            CyberSectionHeader(
              L10n.of(context).setColorTheme,
              accent: cyber.violet,
            ).animate(target: reduceMotion ? 1 : null).fadeIn(
                  duration: FluffyDurations.fast,
                ).slideX(begin: -0.1),
            DynamicColorBuilder(
              builder: (light, dark) {
                final systemColor =
                    Theme.of(context).brightness == Brightness.light
                    ? light?.primary
                    : dark?.primary;
                final colors = [null, AppConfig.chatColor, ...Colors.primaries];
                if (systemColor == null) {
                  colors.remove(null);
                }
                return GridView.builder(
                  shrinkWrap: true,
                  physics: NeverScrollableScrollPhysics(),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 64,
                  ),
                  itemCount: colors.length,
                  itemBuilder: (context, i) {
                    final color = colors[i];
                    return Padding(
                      padding: const EdgeInsets.all(FluffySpacing.md),
                      child: Tooltip(
                        message: color == null
                            ? L10n.of(context).systemTheme
                            : '#${color.hexValue.toRadixString(16).toUpperCase()}',
                        child: InkWell(
                          borderRadius: BorderRadius.circular(colorPickerSize),
                          onTap: () => controller.setChatColor(color),
                          child: Material(
                            color: color ?? systemColor,
                            elevation: 6,
                            borderRadius: BorderRadius.circular(
                              colorPickerSize,
                            ),
                            child: SizedBox(
                              width: colorPickerSize,
                              height: colorPickerSize,
                              child:
                                  controller.currentColor == color &&
                                      (color != null ||
                                          AppSettings.useDynamicColor.value)
                                  ? Center(
                                      child: Icon(
                                        Icons.check,
                                        size: 16,
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.onPrimary,
                                      ),
                                    )
                                  : null,
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                );
              },
            ),
            Divider(color: cyber.glassBorder),
            CyberSectionHeader(
              L10n.of(context).messagesStyle,
              accent: cyber.violet,
            ).animate(target: reduceMotion ? 1 : null).fadeIn(
                  duration: FluffyDurations.fast,
                ).slideX(begin: -0.1),
            StreamBuilder(
              stream: client.onSync.stream.where(
                (syncUpdate) =>
                    syncUpdate.accountData?.any(
                      (accountData) =>
                          accountData.type ==
                          ApplicationAccountConfigExtension.accountDataKey,
                    ) ??
                    false,
              ),
              builder: (context, snapshot) {
                final accountConfig = client.applicationAccountConfig;

                return Column(
                  mainAxisSize: .min,
                  children: [
                    AnimatedContainer(
                      duration: FluffyThemes.animationDuration,
                      curve: FluffyThemes.animationCurve,
                      decoration: const BoxDecoration(),
                      clipBehavior: Clip.hardEdge,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          if (accountConfig.wallpaperUrl != null)
                            Opacity(
                              opacity: controller.wallpaperOpacity,
                              child: ImageFiltered(
                                imageFilter: ImageFilter.blur(
                                  sigmaX: controller.wallpaperBlur,
                                  sigmaY: controller.wallpaperBlur,
                                ),
                                child: MxcImage(
                                  key: ValueKey(accountConfig.wallpaperUrl),
                                  uri: accountConfig.wallpaperUrl,
                                  fit: BoxFit.cover,
                                  isThumbnail: true,
                                  width: FluffyThemes.columnWidth * 2,
                                  height: 212,
                                ),
                              ),
                            ),
                          Column(
                            mainAxisSize: .min,
                            children: [
                              const SizedBox(height: FluffySpacing.lg),
                              StateMessage(
                                Event(
                                  eventId: 'style_dummy',
                                  room: Room(
                                    id: '!style_dummy',
                                    client: client,
                                  ),
                                  content: {'membership': 'join'},
                                  type: EventTypes.RoomMember,
                                  senderId: client.userID!,
                                  originServerTs: DateTime.now(),
                                  stateKey: client.userID,
                                ),
                              ),
                              Padding(
                                padding: EdgeInsets.only(
                                  left: 12 + 12 + Avatar.defaultSize,
                                  right: FluffySpacing.md,
                                  top: accountConfig.wallpaperUrl == null
                                      ? 0
                                      : FluffySpacing.md,
                                  bottom: FluffySpacing.md,
                                ),
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    color: theme.bubbleColor,
                                    borderRadius: BorderRadius.circular(
                                      AppConfig.borderRadius,
                                    ),
                                  ),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: FluffySpacing.lg,
                                      vertical: FluffySpacing.sm,
                                    ),
                                    child: Text(
                                      'Lorem ipsum dolor sit amet, consetetur sadipscing elitr, sed diam nonumy eirmod tempor',
                                      style: TextStyle(
                                        color: theme.onBubbleColor,
                                        fontSize:
                                            AppConfig.messageFontSize *
                                            AppSettings.fontSizeFactor.value,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              Align(
                                alignment: Alignment.centerLeft,
                                child: Padding(
                                  padding: EdgeInsets.only(
                                    right: FluffySpacing.md,
                                    left: FluffySpacing.md,
                                    top: accountConfig.wallpaperUrl == null
                                        ? 0
                                        : FluffySpacing.md,
                                    bottom: FluffySpacing.md,
                                  ),
                                  child: Material(
                                    color:
                                        theme.colorScheme.surfaceContainerHigh,
                                    borderRadius: BorderRadius.circular(
                                      AppConfig.borderRadius,
                                    ),
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: FluffySpacing.lg,
                                        vertical: FluffySpacing.sm,
                                      ),
                                      child: Text(
                                        'Lorem ipsum dolor sit amet',
                                        style: TextStyle(
                                          color: theme.colorScheme.onSurface,
                                          fontSize:
                                              AppConfig.messageFontSize *
                                              AppSettings.fontSizeFactor.value,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    Divider(color: cyber.glassBorder),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: FluffySpacing.lg,
                        vertical: FluffySpacing.sm,
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: CyberPrimaryButton(
                              label: L10n.of(context).setWallpaper,
                              icon: Icons.edit_outlined,
                              onPressed: controller.setWallpaper,
                            ),
                          ),
                          if (accountConfig.wallpaperUrl != null) ...[
                            const SizedBox(width: FluffySpacing.md),
                            IconButton(
                              icon: const Icon(Icons.delete_outlined),
                              color: cyber.magenta,
                              onPressed: controller.deleteChatWallpaper,
                            ),
                          ],
                        ],
                      ),
                    ),
                    if (accountConfig.wallpaperUrl != null) ...[
                      ListTile(
                        title: Text(
                          L10n.of(context).opacity,
                          style: FluffyTypography.title.copyWith(
                            color: theme.colorScheme.onSurface,
                          ),
                        ),
                      ),
                      Slider.adaptive(
                        min: 0.1,
                        max: 1.0,
                        divisions: 9,
                        activeColor: cyber.cyan,
                        semanticFormatterCallback: (d) => d.toString(),
                        value: controller.wallpaperOpacity,
                        onChanged: controller.updateWallpaperOpacity,
                        onChangeEnd: controller.saveWallpaperOpacity,
                      ),
                      ListTile(
                        title: Text(
                          L10n.of(context).blur,
                          style: FluffyTypography.title.copyWith(
                            color: theme.colorScheme.onSurface,
                          ),
                        ),
                      ),
                      Slider.adaptive(
                        min: 0.0,
                        max: 10.0,
                        divisions: 10,
                        activeColor: cyber.cyan,
                        semanticFormatterCallback: (d) => d.toString(),
                        value: controller.wallpaperBlur,
                        onChanged: controller.updateWallpaperBlur,
                        onChangeEnd: controller.saveWallpaperBlur,
                      ),
                    ],
                  ],
                );
              },
            ),
            ListTile(
              leading: Icon(Icons.format_size_outlined, color: cyber.cyan),
              title: Text(
                L10n.of(context).fontSize,
                style: FluffyTypography.title.copyWith(
                  color: theme.colorScheme.onSurface,
                ),
              ),
              trailing: Text(
                '× ${AppSettings.fontSizeFactor.value}',
                style: FluffyTypography.code.copyWith(color: cyber.cyan),
              ),
            ),
            Slider.adaptive(
              min: 0.5,
              max: 2.5,
              divisions: 20,
              activeColor: cyber.cyan,
              value: AppSettings.fontSizeFactor.value,
              semanticFormatterCallback: (d) => d.toString(),
              onChanged: controller.changeFontSizeFactor,
            ),
            ListTile(
              leading: Icon(Icons.font_download_outlined, color: cyber.magenta),
              title: Text(
                'Police des messages',
                style: FluffyTypography.title.copyWith(
                  color: theme.colorScheme.onSurface,
                ),
              ),
              subtitle: Text(
                'SMS et Matrix, même style',
                style: FluffyTypography.bodyM.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              trailing: DropdownButton<String>(
                value: AppSettings.messageFontFamily.value,
                underline: const SizedBox.shrink(),
                dropdownColor: theme.colorScheme.surfaceContainerHigh,
                onChanged: (v) {
                  if (v != null) controller.changeMessageFont(v);
                },
                items: [
                  for (final c in FluffyTypography.messageFontChoices)
                    DropdownMenuItem(
                      value: c.value,
                      child: Text(
                        c.label,
                        // Chaque choix rendu dans SA police = aperçu direct.
                        style: TextStyle(
                          fontFamily: c.value.isEmpty
                              ? FluffyTypography.inter
                              : c.value,
                          color: theme.colorScheme.onSurface,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Divider(color: cyber.glassBorder),
            CyberSectionHeader(
              L10n.of(context).overview,
              accent: cyber.violet,
            ).animate(target: reduceMotion ? 1 : null).fadeIn(
                  duration: FluffyDurations.fast,
                ).slideX(begin: -0.1),
            SettingsSwitchListTile.adaptive(
              title: L10n.of(context).presencesToggle,
              setting: AppSettings.showPresences,
            ),
            SettingsSwitchListTile.adaptive(
              title: L10n.of(context).displayNavigationRail,
              setting: AppSettings.displayNavigationRail,
            ),
          ],
        ),
      ),
    );
  }
}

/// Horizontal picker for the premium theme presets. Each card shows the accent
/// swatches, the name and a short description; tapping it re-skins the whole app
/// instantly via [ThemeController.setCyberTheme].
class _CyberThemePicker extends StatelessWidget {
  final bool reduceMotion;

  const _CyberThemePicker({required this.reduceMotion});

  @override
  Widget build(BuildContext context) {
    final selectedId = AppSettings.cyberThemeId.value;
    return SizedBox(
      height: 132,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(
          horizontal: FluffySpacing.lg,
          vertical: FluffySpacing.sm,
        ),
        itemCount: CyberThemes.all.length,
        separatorBuilder: (_, _) =>
            const SizedBox(width: FluffySpacing.md),
        itemBuilder: (context, i) {
          final preset = CyberThemes.all[i];
          final selected = preset.id.name == selectedId;
          return _ThemeCard(
            preset: preset,
            selected: selected,
            onTap: () =>
                ThemeController.of(context).setCyberTheme(preset.id.name),
          );
        },
      ),
    );
  }
}

class _ThemeCard extends StatelessWidget {
  final CyberThemePreset preset;
  final bool selected;
  final VoidCallback onTap;

  const _ThemeCard({
    required this.preset,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = preset.tokens;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: FluffyDurations.fast,
        width: 150,
        padding: const EdgeInsets.all(FluffySpacing.md),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHigh,
          borderRadius: FluffyRadius.brLg,
          border: Border.all(
            color: selected ? tokens.cyan : theme.colorScheme.outlineVariant,
            width: selected ? 2 : 0.5,
          ),
          boxShadow: selected
              ? [BoxShadow(color: tokens.cyan.withValues(alpha: 0.4), blurRadius: 14)]
              : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                for (final c in [tokens.cyan, tokens.magenta, tokens.violet])
                  Container(
                    width: 18,
                    height: 18,
                    margin: const EdgeInsets.only(right: 4),
                    decoration: BoxDecoration(
                      color: c,
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(color: c.withValues(alpha: 0.5), blurRadius: 6),
                      ],
                    ),
                  ),
                const Spacer(),
                if (selected)
                  Icon(Icons.check_circle_rounded, color: tokens.cyan, size: 20),
              ],
            ),
            const SizedBox(height: FluffySpacing.sm),
            Text(
              preset.label,
              style: FluffyTypography.title.copyWith(
                color: theme.colorScheme.onSurface,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: FluffySpacing.xxs),
            Expanded(
              child: Text(
                preset.description,
                style: FluffyTypography.bodyS.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
