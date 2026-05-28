import 'package:fluffychat/config/design_tokens.dart';
import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/config/themes.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/utils/platform_infos.dart';
import 'package:fluffychat/widgets/cyber/cyber_widgets.dart';
import 'package:fluffychat/widgets/layouts/max_width_body.dart';
import 'package:fluffychat/widgets/matrix.dart';
import 'package:fluffychat/widgets/settings_switch_list_tile.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'settings_chat.dart';

class SettingsChatView extends StatelessWidget {
  final SettingsChatController controller;
  const SettingsChatView(this.controller, {super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cyber = CyberColors.of(context);

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Text(L10n.of(context).chat),
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
                CyberSectionHeader(
                  L10n.of(context).chat,
                  accent: cyber.cyan,
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
                CyberSectionHeader(
                  L10n.of(context).customEmojisAndStickers,
                  accent: cyber.cyan,
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
                CyberSectionHeader(
                  L10n.of(context).calls,
                  accent: cyber.magenta,
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
