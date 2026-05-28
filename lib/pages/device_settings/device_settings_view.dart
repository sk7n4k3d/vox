import 'package:fluffychat/config/design_tokens.dart';
import 'package:fluffychat/config/themes.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/pages/device_settings/device_settings.dart';
import 'package:fluffychat/widgets/cyber/cyber_widgets.dart';
import 'package:fluffychat/widgets/layouts/max_width_body.dart';
import 'package:flutter/material.dart';

import 'user_device_list_item.dart';

class DevicesSettingsView extends StatelessWidget {
  final DevicesSettingsController controller;

  const DevicesSettingsView(this.controller, {super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: !FluffyThemes.isColumnMode(context),
        centerTitle: FluffyThemes.isColumnMode(context),
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Text(L10n.of(context).devices),
      ),
      body: MaxWidthBody(
        child: FutureBuilder<bool>(
          future: controller.loadUserDevices(context),
          builder: (BuildContext context, snapshot) {
            final theme = Theme.of(context);
            final cyber = CyberColors.of(context);
            if (snapshot.hasError) {
              return Center(
                child: Column(
                  mainAxisSize: .min,
                  children: <Widget>[
                    Icon(Icons.error_outlined, color: cyber.warn),
                    const SizedBox(height: FluffySpacing.sm),
                    Text(
                      snapshot.error.toString(),
                      style: FluffyTypography.bodyM.copyWith(color: cyber.warn),
                    ),
                  ],
                ),
              );
            }
            if (!snapshot.hasData || controller.devices == null) {
              return const Center(
                child: CircularProgressIndicator.adaptive(strokeWidth: 2),
              );
            }
            return ListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: controller.notThisDevice.length + 1,
              itemBuilder: (BuildContext context, int i) {
                if (i == 0) {
                  return Column(
                    mainAxisSize: .min,
                    children: [
                      if (controller.chatBackupEnabled == false)
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: FluffySpacing.lg,
                            vertical: FluffySpacing.sm,
                          ),
                          child: CyberGlass(
                            child: CyberSettingsTile(
                              icon: Icons.info_outlined,
                              accent: cyber.success,
                              title: L10n.of(context).chatBackup,
                              subtitle: L10n.of(
                                context,
                              ).noticeChatBackupDeviceVerification,
                            ),
                          ),
                        ),
                      if (controller.thisDevice != null) ...[
                        CyberSectionHeader(
                          L10n.of(context).thisDevice,
                          accent: cyber.violet,
                        ),
                        UserDeviceListItem(
                          controller.thisDevice!,
                          rename: controller.renameDeviceAction,
                          remove: (d) => controller.removeDevicesAction([d]),
                          verify: controller.verifyDeviceAction,
                          block: controller.blockDeviceAction,
                          unblock: controller.unblockDeviceAction,
                        ),
                      ],
                      if (controller.notThisDevice.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: FluffySpacing.lg,
                            vertical: FluffySpacing.sm,
                          ),
                          child: SizedBox(
                            width: double.infinity,
                            child: TextButton.icon(
                              label: Text(
                                L10n.of(context).removeAllOtherDevices,
                                style: FluffyTypography.title,
                              ),
                              style: TextButton.styleFrom(
                                iconColor: cyber.magenta,
                                foregroundColor: cyber.magenta,
                                backgroundColor:
                                    cyber.magenta.withValues(alpha: 0.12),
                                padding: const EdgeInsets.symmetric(
                                  vertical: FluffySpacing.md,
                                ),
                                shape: const RoundedRectangleBorder(
                                  borderRadius: FluffyRadius.brMd,
                                ),
                              ),
                              icon: const Icon(Icons.delete_outline),
                              onPressed: () => controller.removeDevicesAction(
                                controller.notThisDevice,
                              ),
                            ),
                          ),
                        )
                      else
                        Center(
                          child: Padding(
                            padding: const EdgeInsets.all(FluffySpacing.lg),
                            child: Text(
                              L10n.of(context).noOtherDevicesFound,
                              style: FluffyTypography.bodyM.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ),
                    ],
                  );
                }
                i--;
                return UserDeviceListItem(
                  controller.notThisDevice[i],
                  rename: controller.renameDeviceAction,
                  remove: (d) => controller.removeDevicesAction([d]),
                  verify: controller.verifyDeviceAction,
                  block: controller.blockDeviceAction,
                  unblock: controller.unblockDeviceAction,
                );
              },
            );
          },
        ),
      ),
    );
  }
}
