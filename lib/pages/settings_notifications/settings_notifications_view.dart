import 'package:fluffychat/config/design_tokens.dart';
import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/config/themes.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/pages/settings_notifications/push_rule_extensions.dart';
import 'package:fluffychat/utils/adaptive_bottom_sheet.dart';
import 'package:fluffychat/widgets/cyber/cyber_widgets.dart';
import 'package:fluffychat/widgets/layouts/max_width_body.dart';
import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';

import '../../utils/localized_exception_extension.dart';
import '../../widgets/matrix.dart';
import 'settings_notifications.dart';

class SettingsNotificationsView extends StatelessWidget {
  final SettingsNotificationsController controller;

  const SettingsNotificationsView(this.controller, {super.key});

  @override
  Widget build(BuildContext context) {
    final pushRules = Matrix.of(context).client.globalPushRules;
    final pushCategories = [
      if (pushRules?.override?.isNotEmpty ?? false)
        (rules: pushRules?.override ?? [], kind: PushRuleKind.override),
      if (pushRules?.content?.isNotEmpty ?? false)
        (rules: pushRules?.content ?? [], kind: PushRuleKind.content),
      if (pushRules?.sender?.isNotEmpty ?? false)
        (rules: pushRules?.sender ?? [], kind: PushRuleKind.sender),
      if (pushRules?.underride?.isNotEmpty ?? false)
        (rules: pushRules?.underride ?? [], kind: PushRuleKind.underride),
    ];
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: !FluffyThemes.isColumnMode(context),
        centerTitle: FluffyThemes.isColumnMode(context),
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Text(L10n.of(context).notifications),
      ),
      body: MaxWidthBody(
        child: StreamBuilder(
          stream: Matrix.of(context).client.onSync.stream.where(
            (syncUpdate) =>
                syncUpdate.accountData?.any(
                  (accountData) => accountData.type == 'm.push_rules',
                ) ??
                false,
          ),
          builder: (BuildContext context, _) {
            final theme = Theme.of(context);
            final cyber = CyberColors.of(context);
            return SelectionArea(
              child: Column(
                children: [
                  if (pushRules != null)
                    for (final category in pushCategories) ...[
                      CyberSectionHeader(
                        category.kind.localized(L10n.of(context)),
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
                          child: Column(
                            children: [
                              for (final rule in category.rules)
                                CyberSettingsTile(
                                  icon: Icons.notifications_active_outlined,
                                  accent: cyber.magenta,
                                  title: rule.getPushRuleName(L10n.of(context)),
                                  trailing: Switch.adaptive(
                                    value: rule.enabled,
                                    activeThumbColor: cyber.cyan,
                                    onChanged: controller.isLoading
                                        ? null
                                        : rule.ruleId != '.m.rule.master' &&
                                              Matrix.of(
                                                context,
                                              ).client.allPushNotificationsMuted
                                        ? null
                                        : (_) => controller.togglePushRule(
                                            category.kind,
                                            rule,
                                          ),
                                  ),
                                  subtitle: rule.getPushRuleDescription(
                                    L10n.of(context),
                                  ),
                                  onTap: () => controller.editPushRule(
                                    rule,
                                    category.kind,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  CyberSectionHeader(
                    'Sonnerie appel entrant',
                    accent: cyber.violet,
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: FluffySpacing.lg,
                    ),
                    child: const CyberGlass(
                      padding: EdgeInsets.symmetric(
                        vertical: FluffySpacing.xs,
                      ),
                      child: _CallRingtoneTile(),
                    ),
                  ),
                  CyberSectionHeader(
                    L10n.of(context).devices,
                    accent: cyber.violet,
                  ),
                  FutureBuilder<List<Pusher>?>(
                    future: controller.pusherFuture ??= Matrix.of(
                      context,
                    ).client.getPushers(),
                    builder: (context, snapshot) {
                      if (snapshot.hasError) {
                        Center(
                          child: Text(
                            snapshot.error!.toLocalizedString(context),
                          ),
                        );
                      }
                      if (snapshot.connectionState != ConnectionState.done) {
                        const Center(
                          child: CircularProgressIndicator.adaptive(
                            strokeWidth: 2,
                          ),
                        );
                      }
                      final pushers = snapshot.data ?? [];
                      if (pushers.isEmpty) {
                        return Padding(
                          padding: const EdgeInsets.only(
                            bottom: FluffySpacing.lg,
                          ),
                          child: Center(
                            child: Text(
                              L10n.of(context).noOtherDevicesFound,
                              style: FluffyTypography.bodyM.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        );
                      }
                      return Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: FluffySpacing.lg,
                        ),
                        child: CyberGlass(
                          padding: const EdgeInsets.symmetric(
                            vertical: FluffySpacing.xs,
                          ),
                          child: ListView.builder(
                            physics: const NeverScrollableScrollPhysics(),
                            shrinkWrap: true,
                            itemCount: pushers.length,
                            itemBuilder: (_, i) => CyberSettingsTile(
                              icon: Icons.devices_outlined,
                              accent: cyber.violet,
                              title:
                                  '${pushers[i].appDisplayName} - ${pushers[i].appId}',
                              subtitle: pushers[i].data.url.toString(),
                              onTap: () => controller.onPusherTap(pushers[i]),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: FluffySpacing.lg),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

const _ringtoneOptions = <String, String>{
  'jarvis': 'Jarvis (intégrée)',
  'system': 'Sonnerie système Android',
  'silent': 'Silencieux (vibration seule)',
};

class _CallRingtoneTile extends StatefulWidget {
  const _CallRingtoneTile();

  @override
  State<_CallRingtoneTile> createState() => _CallRingtoneTileState();
}

class _CallRingtoneTileState extends State<_CallRingtoneTile> {
  String _current = AppSettings.callRingtone.value;

  Future<void> _pick() async {
    final selected = await showAdaptiveBottomSheet<String>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CyberSectionHeader('Sonnerie appel entrant'),
            for (final entry in _ringtoneOptions.entries)
              RadioListTile<String>(
                title: Text(entry.value),
                value: entry.key,
                groupValue: _current,
                activeColor: CyberColors.of(sheetContext).cyan,
                onChanged: (value) => Navigator.of(sheetContext).pop(value),
              ),
            const SizedBox(height: FluffySpacing.sm),
          ],
        ),
      ),
    );
    if (selected == null || selected == _current) return;
    await AppSettings.callRingtone.setItem(selected);
    if (!mounted) return;
    setState(() => _current = selected);
  }

  @override
  Widget build(BuildContext context) {
    final cyber = CyberColors.of(context);
    return CyberSettingsTile(
      icon: Icons.phone_in_talk_outlined,
      accent: cyber.cyan,
      title: 'Sonnerie appel entrant',
      subtitle: _ringtoneOptions[_current] ?? _current,
      onTap: _pick,
    );
  }
}
