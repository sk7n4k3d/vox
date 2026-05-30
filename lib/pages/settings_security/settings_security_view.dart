import 'package:fluffychat/config/app_config.dart';
import 'package:fluffychat/config/design_tokens.dart';
import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/config/themes.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/utils/beautify_string_extension.dart';
import 'package:fluffychat/utils/platform_infos.dart';
import 'package:fluffychat/widgets/cyber/cyber_fx.dart';
import 'package:fluffychat/widgets/cyber/cyber_widgets.dart';
import 'package:fluffychat/widgets/layouts/max_width_body.dart';
import 'package:fluffychat/widgets/matrix.dart';
import 'package:fluffychat/widgets/settings_switch_list_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:go_router/go_router.dart';
import 'package:matrix/matrix.dart';

import 'settings_security.dart';

class SettingsSecurityView extends StatelessWidget {
  final SettingsSecurityController controller;

  const SettingsSecurityView(this.controller, {super.key});

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
          L10n.of(context).security,
          style: theme.appBarTheme.titleTextStyle,
        ),
        automaticallyImplyLeading: !FluffyThemes.isColumnMode(context),
        centerTitle: FluffyThemes.isColumnMode(context),
      ),
      body: ListTileTheme(
        iconColor: cyber.cyan,
        child: MaxWidthBody(
          child: FutureBuilder(
            future: Matrix.of(
              context,
            ).client.getCapabilities().timeout(const Duration(seconds: 10)),
            builder: (context, snapshot) {
              final capabilities = snapshot.data;
              final error = snapshot.error;
              if (error == null && capabilities == null) {
                return const Center(
                  child: Padding(
                    padding: EdgeInsets.all(FluffySpacing.lg),
                    child: CircularProgressIndicator.adaptive(strokeWidth: 2),
                  ),
                );
              }
              return Column(
                children: [
                  reduceMotion
                      ? CyberSectionHeader(
                          L10n.of(context).privacy,
                          accent: cyber.success,
                        )
                      : CyberSectionHeader(
                          L10n.of(context).privacy,
                          accent: cyber.success,
                        )
                          .animate(onPlay: (c) => c.stop())
                          .fadeIn(duration: FluffyDurations.fast)
                          .slideX(begin: -0.1),
                  SettingsSwitchListTile.adaptive(
                    title: L10n.of(context).sendTypingNotifications,
                    subtitle: L10n.of(
                      context,
                    ).sendTypingNotificationsDescription,
                    setting: AppSettings.sendTypingNotifications,
                  ),
                  SettingsSwitchListTile.adaptive(
                    title: L10n.of(context).sendReadReceipts,
                    subtitle: L10n.of(context).sendReadReceiptsDescription,
                    setting: AppSettings.sendPublicReadReceipts,
                  ),
                  CyberSettingsTile(
                    icon: Icons.block_outlined,
                    accent: cyber.success,
                    title: L10n.of(context).blockedUsers,
                    subtitle: L10n.of(context).thereAreCountUsersBlocked(
                      Matrix.of(context).client.ignoredUsers.length,
                    ),
                    onTap: () =>
                        context.go('/rooms/settings/security/ignorelist'),
                  ),
                  if (Matrix.of(context).client.encryption != null) ...{
                    if (PlatformInfos.isMobile)
                      CyberSettingsTile(
                        icon: Icons.lock_clock_outlined,
                        accent: cyber.success,
                        title: L10n.of(context).appLock,
                        subtitle: L10n.of(context).appLockDescription,
                        onTap: controller.setAppLockAction,
                      ),
                  },
                  Divider(color: cyber.glassBorder),
                  reduceMotion
                      ? CyberSectionHeader(
                          L10n.of(context).shareKeysWith,
                          accent: cyber.success,
                        )
                      : CyberSectionHeader(
                          L10n.of(context).shareKeysWith,
                          accent: cyber.success,
                        )
                          .animate(onPlay: (c) => c.stop())
                          .fadeIn(duration: FluffyDurations.fast)
                          .slideX(begin: -0.1),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      FluffySpacing.xl,
                      0,
                      FluffySpacing.xl,
                      FluffySpacing.sm,
                    ),
                    child: Text(
                      L10n.of(context).shareKeysWithDescription,
                      style: FluffyTypography.bodyS.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: FluffySpacing.lg,
                    ),
                    child: CyberField(
                      child: DropdownButton<ShareKeysWith>(
                        isExpanded: true,
                        padding: const EdgeInsets.symmetric(
                          horizontal: FluffySpacing.sm,
                        ),
                        borderRadius: BorderRadius.circular(
                          AppConfig.borderRadius / 2,
                        ),
                        underline: const SizedBox.shrink(),
                        dropdownColor: cyber.glassFillStrong,
                        value: Matrix.of(context).client.shareKeysWith,
                        items: ShareKeysWith.values
                            .map(
                              (share) => DropdownMenuItem(
                                value: share,
                                child: Text(share.localized(L10n.of(context))),
                              ),
                            )
                            .toList(),
                        onChanged: controller.changeShareKeysWith,
                      ),
                    ),
                  ),
                  Divider(color: cyber.glassBorder),
                  reduceMotion
                      ? CyberSectionHeader(
                          L10n.of(context).account,
                          accent: cyber.success,
                        )
                      : CyberSectionHeader(
                          L10n.of(context).account,
                          accent: cyber.success,
                        )
                          .animate(onPlay: (c) => c.stop())
                          .fadeIn(duration: FluffyDurations.fast)
                          .slideX(begin: -0.1),
                  ListTile(
                    title: Text(
                      L10n.of(context).yourPublicKey,
                      style: FluffyTypography.title.copyWith(
                        color: theme.colorScheme.onSurface,
                      ),
                    ),
                    leading: Icon(Icons.vpn_key_outlined, color: cyber.cyan),
                    subtitle: SelectableText(
                      Matrix.of(context).client.fingerprintKey.beautified,
                      style: FluffyTypography.code.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  if (capabilities?.mChangePassword?.enabled != false ||
                      error != null)
                    CyberSettingsTile(
                      icon: Icons.password_outlined,
                      accent: cyber.cyan,
                      title: L10n.of(context).changePassword,
                      onTap: () =>
                          context.go('/rooms/settings/security/password'),
                    ),
                  CyberSettingsTile(
                    icon: Icons.delete_sweep_outlined,
                    accent: cyber.warn,
                    title: L10n.of(context).dehydrate,
                    onTap: controller.dehydrateAction,
                  ),
                  Divider(color: cyber.glassBorder),
                  CyberSettingsTile(
                    icon: Icons.delete_outlined,
                    accent: cyber.magenta,
                    title: L10n.of(context).deleteAccount,
                    onTap: controller.deleteAccountAction,
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

extension on ShareKeysWith {
  String localized(L10n l10n) {
    switch (this) {
      case ShareKeysWith.all:
        return l10n.allDevices;
      case ShareKeysWith.crossVerifiedIfEnabled:
        return l10n.crossVerifiedDevicesIfEnabled;
      case ShareKeysWith.crossVerified:
        return l10n.crossVerifiedDevices;
      case ShareKeysWith.directlyVerifiedOnly:
        return l10n.verifiedDevicesOnly;
    }
  }
}
