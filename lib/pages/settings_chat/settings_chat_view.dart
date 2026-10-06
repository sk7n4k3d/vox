import 'package:fluffychat/config/design_tokens.dart';
import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/config/themes.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/utils/platform_infos.dart';
import 'package:fluffychat/widgets/cyber/cyber_fx.dart';
import 'package:fluffychat/widgets/cyber/cyber_widgets.dart';
import 'package:fluffychat/widgets/layouts/max_width_body.dart';
import 'package:fluffychat/widgets/matrix.dart';
import 'package:fluffychat/widgets/settings_switch_list_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:go_router/go_router.dart';

import 'media_backfill_tile.dart';
import 'settings_chat.dart';

class SettingsChatView extends StatelessWidget {
  final SettingsChatController controller;
  const SettingsChatView(this.controller, {super.key});

  /// One-shot entry animation for a static section header. Falls back to the
  /// plain header under reduce-motion (no animation, no repeat).
  static Widget _animatedHeader(bool reduceMotion, Widget header) {
    if (reduceMotion) return header;
    return header
        .animate(onPlay: (controller) => controller.stop())
        .fadeIn(duration: FluffyDurations.fast)
        .slideX(begin: -0.1);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cyber = CyberColors.of(context);
    final reduceMotion = CyberMotion.reduced(context);

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: CyberGlitchText(
          L10n.of(context).chat,
          style: FluffyTypography.headlineM.copyWith(
            color: theme.colorScheme.onSurface,
          ),
        ),
        automaticallyImplyLeading: !FluffyThemes.isColumnMode(context),
        centerTitle: FluffyThemes.isColumnMode(context),
      ),
      body: Theme(
        data: theme.copyWith(
          switchTheme: SwitchThemeData(
            thumbColor: WidgetStateProperty.resolveWith(
              (states) => states.contains(WidgetState.selected)
                  ? cyber.cyan
                  : null,
            ),
            trackColor: WidgetStateProperty.resolveWith(
              (states) => states.contains(WidgetState.selected)
                  ? cyber.cyan.withValues(alpha: 0.4)
                  : null,
            ),
          ),
        ),
        child: ListTileTheme(
          iconColor: cyber.cyan,
          child: MaxWidthBody(
            child: Column(
              children: [
                _animatedHeader(
                  reduceMotion,
                  CyberSectionHeader(
                    L10n.of(context).chat,
                    accent: cyber.cyan,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: FluffySpacing.lg,
                  ),
                  child: CyberGlass(
                    padding: const EdgeInsets.symmetric(
                      vertical: FluffySpacing.xs,
                    ),
                    child: Column(
                      children: [
                        SettingsSwitchListTile.adaptive(
                          title: L10n.of(context).formattedMessages,
                          subtitle:
                              L10n.of(context).formattedMessagesDescription,
                          setting: AppSettings.renderHtml,
                        ),
                        SettingsSwitchListTile.adaptive(
                          title: L10n.of(context).hideRedactedMessages,
                          subtitle: L10n.of(context).hideRedactedMessagesBody,
                          setting: AppSettings.hideRedactedEvents,
                        ),
                        SettingsSwitchListTile.adaptive(
                          title: L10n.of(context)
                              .hideInvalidOrUnknownMessageFormats,
                          setting: AppSettings.hideUnknownEvents,
                        ),
                        if (PlatformInfos.isMobile)
                          SettingsSwitchListTile.adaptive(
                            title: L10n.of(context).autoplayImages,
                            setting: AppSettings.autoplayImages,
                          ),
                        SettingsSwitchListTile.adaptive(
                          title: 'Effets plein écran',
                          setting: AppSettings.screenEffectsEnabled,
                        ),
                        SettingsSwitchListTile.adaptive(
                          title: 'Exporter les médias vers la galerie',
                          setting: AppSettings.autoExportMedia,
                        ),
                        if (PlatformInfos.isAndroid) const MediaBackfillTile(),
                        SettingsSwitchListTile.adaptive(
                          title: L10n.of(context).sendOnEnter,
                          setting: AppSettings.sendOnEnter,
                        ),
                        SettingsSwitchListTile.adaptive(
                          title: L10n.of(context).swipeRightToLeftToReply,
                          setting: AppSettings.swipeRightToLeftToReply,
                        ),
                        SettingsSwitchListTile.adaptive(
                          title: L10n.of(context).colorfulSenderNames,
                          subtitle: L10n.of(context)
                              .colorfulSenderNamesDescription,
                          setting: AppSettings.colorfulSenderNames,
                        ),
                      ],
                    ),
                  ),
                ),
                _animatedHeader(
                  reduceMotion,
                  CyberSectionHeader(
                    L10n.of(context).customEmojisAndStickers,
                    accent: cyber.cyan,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: FluffySpacing.lg,
                  ),
                  child: CyberGlass(
                    padding: const EdgeInsets.symmetric(
                      vertical: FluffySpacing.xs,
                    ),
                    child: CyberSettingsTile(
                      icon: Icons.emoji_emotions_outlined,
                      accent: cyber.cyan,
                      title: L10n.of(context).customEmojisAndStickers,
                      subtitle: L10n.of(context).customEmojisAndStickersBody,
                      onTap: () => context.go('/rooms/settings/chat/emotes'),
                    ),
                  ),
                ),
                _animatedHeader(
                  reduceMotion,
                  CyberSectionHeader(
                    L10n.of(context).calls,
                    accent: cyber.magenta,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: FluffySpacing.lg,
                  ),
                  child: CyberGlass(
                    padding: const EdgeInsets.symmetric(
                      vertical: FluffySpacing.xs,
                    ),
                    child: SettingsSwitchListTile.adaptive(
                      title: L10n.of(context).experimentalVideoCalls,
                      onChanged: (b) {
                        Matrix.of(context).createVoipPlugin();
                        return;
                      },
                      setting: AppSettings.experimentalVoip,
                    ),
                  ),
                ),
                const SizedBox(height: FluffySpacing.lg),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
