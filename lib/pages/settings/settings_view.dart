import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/utils/platform_infos.dart';
import 'package:fluffychat/widgets/matrix.dart';
import 'package:fluffychat/widgets/theme_builder.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:matrix/matrix.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:url_launcher/url_launcher_string.dart';

import 'settings.dart';
import 'settings_profile_header.dart';
import 'settings_section_tile.dart';

class SettingsView extends StatelessWidget {
  final SettingsController controller;

  const SettingsView(this.controller, {super.key});

  // Section colors — premium 2026 palette.
  static const _accountColor = Color(0xFF3B82F6);
  static const _privacyColor = Color(0xFF10B981);
  static const _notificationsColor = Color(0xFFF59E0B);
  static const _appearanceColor = Color(0xFFA855F7);
  static const _chatColor = Color(0xFFEF4444);
  static const _devicesColor = Color(0xFFEAB308);
  static const _storageColor = Color(0xFF6B7280);
  static const _advancedColor = Color(0xFF94A3B8);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = L10n.of(context);
    final client = Matrix.of(context).client;
    final activeRoute =
        GoRouter.of(context).routeInformationProvider.value.uri.path;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.settings),
        leading: Center(
          child: BackButton(onPressed: () => context.go('/rooms')),
        ),
      ),
      body: ListView(
        key: const Key('SettingsListViewContent'),
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          SettingsProfileHeader(controller: controller),
          const SizedBox(height: 8),

          // External account manager (MAS / OIDC) — keeps existing behavior.
          FutureBuilder(
            future: client.getAuthMetadata(),
            builder: (context, snapshot) {
              final accountManageUrl = snapshot.data?.issuer;
              if (accountManageUrl == null) {
                return const SizedBox.shrink();
              }
              return Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 4,
                ),
                child: OutlinedButton.icon(
                  onPressed: () => launchUrl(
                    accountManageUrl,
                    mode: LaunchMode.inAppBrowserView,
                  ),
                  icon: const Icon(Icons.open_in_new_outlined, size: 18),
                  label: Text(l10n.manageAccount),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(46),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                ),
              );
            },
          ),

          const SizedBox(height: 16),

          // Account — homeserver settings + manage account flow.
          SettingsSectionTile(
            icon: Icons.person_outline,
            color: _accountColor,
            title: l10n.account,
            subtitle: _accountSubtitle(client, l10n),
            selected: activeRoute.startsWith('/rooms/settings/homeserver'),
            onTap: () => context.go('/rooms/settings/homeserver'),
          ),

          // Privacy & Security.
          SettingsSectionTile(
            icon: Icons.shield_outlined,
            color: _privacyColor,
            title: l10n.security,
            subtitle: _privacySubtitle(controller, client, l10n),
            selected: activeRoute.startsWith('/rooms/settings/security'),
            onTap: () => context.go('/rooms/settings/security'),
          ),

          // Notifications.
          SettingsSectionTile(
            icon: Icons.notifications_outlined,
            color: _notificationsColor,
            title: l10n.notifications,
            subtitle: _notificationsSubtitle(client, l10n),
            selected:
                activeRoute.startsWith('/rooms/settings/notifications'),
            onTap: () => context.go('/rooms/settings/notifications'),
          ),

          // Appearance.
          SettingsSectionTile(
            icon: Icons.palette_outlined,
            color: _appearanceColor,
            title: l10n.changeTheme,
            subtitle: _appearanceSubtitle(context, l10n),
            selected: activeRoute.startsWith('/rooms/settings/style'),
            onTap: () => context.go('/rooms/settings/style'),
          ),

          // Chat.
          SettingsSectionTile(
            icon: Icons.forum_outlined,
            color: _chatColor,
            title: l10n.chat,
            subtitle: _chatSubtitle(l10n),
            selected: activeRoute.startsWith('/rooms/settings/chat'),
            onTap: () => context.go('/rooms/settings/chat'),
          ),

          // Devices.
          SettingsSectionTile(
            icon: Icons.devices_outlined,
            color: _devicesColor,
            title: l10n.devices,
            subtitle: _devicesSubtitle(client, l10n),
            selected: activeRoute.startsWith('/rooms/settings/devices'),
            onTap: () => context.go('/rooms/settings/devices'),
          ),

          // Storage — no dedicated route, fallback to chat (cache/media live there).
          SettingsSectionTile(
            icon: Icons.storage_outlined,
            color: _storageColor,
            title: 'Storage',
            subtitle: _storageSubtitle(client),
            selected: false,
            onTap: () => context.go('/rooms/settings/chat'),
          ),

          // Advanced — about + logs + version.
          _AdvancedTile(
            color: _advancedColor,
            onTap: () => PlatformInfos.showDialog(context),
          ),

          const SizedBox(height: 24),

          // Chat backup toggle — kept inline like before.
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: SwitchListTile.adaptive(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              controlAffinity: ListTileControlAffinity.trailing,
              value: controller.cryptoIdentityConnected == true,
              secondary: const Icon(Icons.backup_outlined),
              title: Text(l10n.chatBackup),
              onChanged: controller.firstRunBootstrapAction,
            ),
          ),

          const SizedBox(height: 8),

          // Privacy policy — external link.
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: ListTile(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              leading: const Icon(Icons.privacy_tip_outlined),
              title: Text(l10n.privacy),
              trailing: const Icon(Icons.open_in_new_outlined, size: 18),
              onTap: () => launchUrlString(AppSettings.privacyPolicy.value),
            ),
          ),

          const SizedBox(height: 16),
          Divider(color: theme.dividerColor),
          const SizedBox(height: 8),

          // Sign out — destructive at the bottom.
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: ListTile(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              leading: Icon(
                Icons.logout_outlined,
                color: theme.colorScheme.error,
              ),
              title: Text(
                l10n.logout,
                style: TextStyle(
                  color: theme.colorScheme.error,
                  fontWeight: FontWeight.w600,
                ),
              ),
              onTap: controller.logoutAction,
            ),
          ),
        ],
      ),
    );
  }

  // -------- Live subtitle helpers (silent on failure) --------

  String? _accountSubtitle(Client client, L10n l10n) {
    try {
      final mxid = client.userID;
      final host = client.homeserver?.host ?? mxid?.domain;
      if (mxid == null) return host;
      if (host == null) return mxid;
      return '$mxid · $host';
    } catch (_) {
      return null;
    }
  }

  String? _privacySubtitle(
    SettingsController controller,
    Client client,
    L10n l10n,
  ) {
    try {
      if (!client.encryptionEnabled) {
        return 'End-to-end encryption available';
      }
      final connected = controller.cryptoIdentityConnected;
      if (connected == true) {
        return 'E2EE on · cross-signing verified';
      }
      if (connected == false) {
        return 'E2EE on · setup recommended';
      }
      return 'End-to-end encryption on';
    } catch (_) {
      return null;
    }
  }

  String? _notificationsSubtitle(Client client, L10n l10n) {
    try {
      final mutedCount = client.rooms
          .where((r) => r.pushRuleState != PushRuleState.notify)
          .length;
      if (mutedCount == 0) {
        return 'All notifications on';
      }
      return '$mutedCount room${mutedCount > 1 ? 's' : ''} muted';
    } catch (_) {
      return null;
    }
  }

  String? _appearanceSubtitle(BuildContext context, L10n l10n) {
    try {
      final themeController = ThemeController.of(context);
      final mode = themeController.themeMode;
      final modeLabel = switch (mode) {
        ThemeMode.light => 'Light',
        ThemeMode.dark => 'Dark',
        ThemeMode.system => 'System',
      };
      final primary = themeController.primaryColor;
      if (primary != null) {
        // ignore: deprecated_member_use
        final hex = primary.value.toRadixString(16).padLeft(8, '0').substring(2);
        return '$modeLabel · #${hex.toUpperCase()}';
      }
      return modeLabel;
    } catch (_) {
      return null;
    }
  }

  String? _chatSubtitle(L10n l10n) {
    try {
      final renderHtml = AppSettings.renderHtml.value;
      final sendOnEnter = AppSettings.sendOnEnter.value;
      final parts = <String>[];
      if (renderHtml) parts.add('Rich text');
      if (sendOnEnter) parts.add('Send on Enter');
      if (parts.isEmpty) return 'Behavior, emotes, formatting';
      return parts.join(' · ');
    } catch (_) {
      return 'Behavior, emotes, formatting';
    }
  }

  String? _devicesSubtitle(Client client, L10n l10n) {
    try {
      final myDevices = client.userDeviceKeys[client.userID]?.deviceKeys;
      if (myDevices != null && myDevices.isNotEmpty) {
        final n = myDevices.length;
        return '$n active device${n > 1 ? 's' : ''}';
      }
      return 'Manage signed-in sessions';
    } catch (_) {
      return null;
    }
  }

  String? _storageSubtitle(Client client) {
    try {
      // Computing real cache size is async + heavy → keep it cheap here.
      return 'Cache, media & cleanup';
    } catch (_) {
      return null;
    }
  }
}

/// Advanced tile loads the app version asynchronously into its subtitle.
class _AdvancedTile extends StatelessWidget {
  final Color color;
  final VoidCallback onTap;

  const _AdvancedTile({required this.color, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<PackageInfo>(
      future: _packageInfo(),
      builder: (context, snapshot) {
        final info = snapshot.data;
        final subtitle = info != null
            ? 'v${info.version} (${info.buildNumber})'
            : 'Version, logs, source code';
        return SettingsSectionTile(
          icon: Icons.tune_outlined,
          color: color,
          title: 'Advanced',
          subtitle: subtitle,
          onTap: onTap,
        );
      },
    );
  }

  Future<PackageInfo> _packageInfo() async {
    try {
      return await PackageInfo.fromPlatform();
    } catch (_) {
      return PackageInfo(
        appName: '',
        packageName: '',
        version: '0.0.0',
        buildNumber: '0',
      );
    }
  }
}
