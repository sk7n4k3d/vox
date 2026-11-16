import 'dart:io';

import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher_string.dart';

import '../config/app_config.dart';

abstract class PlatformInfos {
  static bool get isWeb => kIsWeb;
  static bool get isLinux => !kIsWeb && Platform.isLinux;
  static bool get isWindows => !kIsWeb && Platform.isWindows;
  static bool get isMacOS => !kIsWeb && Platform.isMacOS;
  static bool get isIOS => !kIsWeb && Platform.isIOS;
  static bool get isAndroid => !kIsWeb && Platform.isAndroid;

  static bool get isCupertinoStyle => isIOS || isMacOS;

  static bool get isMobile => isAndroid || isIOS;

  /// For desktops which don't support ChachedNetworkImage yet
  static bool get isBetaDesktop => isWindows || isLinux;

  static bool get isDesktop => isLinux || isWindows || isMacOS;

  static bool get usesTouchscreen => !isMobile;

  static bool get supportsVideoPlayer =>
      !PlatformInfos.isWindows && !PlatformInfos.isLinux;

  static bool get supportsCustomImageResizer =>
      PlatformInfos.isWeb || PlatformInfos.isMobile;

  /// Web could also record in theory but currently creates broken opus
  static bool get platformCanRecord => (isMobile || isMacOS);

  static String get clientName =>
      '${AppSettings.applicationName.value} ${isWeb ? 'web' : Platform.operatingSystem}${kReleaseMode ? '' : 'Debug'}';

  static Future<String> getVersion() async {
    var version = kIsWeb ? 'Web' : 'Unknown';
    try {
      version = (await PackageInfo.fromPlatform()).version;
    } catch (_) {}
    return version;
  }

  static Future<void> showDialog(BuildContext context) async {
    final version = await PlatformInfos.getVersion();
    if (!context.mounted) return;
    final l10n = L10n.of(context);
    // Dialog « À propos » maison (et non showAboutDialog) : l'icône, le nom et
    // la version sont centrés verticalement au-dessus des actions, et le logo
    // est la vraie identité VoxOne.
    await showAdaptiveDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: Image.asset(
                    'assets/logo.png',
                    width: 56,
                    height: 56,
                    filterQuality: FilterQuality.medium,
                  ),
                ),
                const SizedBox(width: 16),
                Flexible(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        AppSettings.applicationName.value,
                        style: Theme.of(dialogContext).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        l10n.versionWithNumber(version),
                        style: Theme.of(dialogContext).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 8,
              runSpacing: 4,
              children: [
                TextButton.icon(
                  onPressed: () => launchUrlString(AppConfig.sourceCodeUrl),
                  icon: const Icon(Icons.source_outlined),
                  label: Text(l10n.sourceCode),
                ),
                TextButton.icon(
                  onPressed: () {
                    Navigator.of(dialogContext).pop();
                    context.go('/logs');
                  },
                  icon: const Icon(Icons.list_outlined),
                  label: Text(l10n.logs),
                ),
                TextButton.icon(
                  onPressed: () {
                    Navigator.of(dialogContext).pop();
                    context.go('/configs');
                  },
                  icon: const Icon(Icons.settings_applications_outlined),
                  label: Text(l10n.advancedConfigs),
                ),
              ],
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(l10n.close),
          ),
        ],
      ),
    );
  }
}
