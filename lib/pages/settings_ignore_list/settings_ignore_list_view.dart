import 'package:fluffychat/config/design_tokens.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/widgets/cyber/cyber_widgets.dart';
import 'package:fluffychat/widgets/future_loading_dialog.dart';
import 'package:fluffychat/widgets/layouts/max_width_body.dart';
import 'package:flutter/material.dart';

import '../../widgets/matrix.dart';
import 'settings_ignore_list.dart';

class SettingsIgnoreListView extends StatelessWidget {
  final SettingsIgnoreListController controller;

  const SettingsIgnoreListView(this.controller, {super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cyber = CyberColors.of(context);

    final client = Matrix.of(context).client;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: const Center(child: BackButton()),
        title: Text(L10n.of(context).blockedUsers),
      ),
      body: MaxWidthBody(
        withScrolling: false,
        child: StreamBuilder(
          stream: client.onSync.stream.where(
            (syncUpdate) =>
                syncUpdate.accountData?.any(
                  (accountData) => accountData.type == 'm.ignored_user_list',
                ) ??
                false,
          ),
          builder: (context, asyncSnapshot) {
            if (client.prevBatch == null) {
              return const Center(child: CircularProgressIndicator.adaptive());
            }
            return Column(
              mainAxisSize: .min,
              children: [
                Padding(
                  padding: const EdgeInsets.all(FluffySpacing.lg),
                  child: Column(
                    mainAxisSize: .min,
                    children: [
                      CyberField(
                        child: TextField(
                          controller: controller.controller,
                          autocorrect: false,
                          textInputAction: TextInputAction.done,
                          onSubmitted: (_) => controller.ignoreUser(context),
                          decoration: InputDecoration(
                            border: InputBorder.none,
                            enabledBorder: InputBorder.none,
                            focusedBorder: InputBorder.none,
                            errorText: controller.errorText,
                            hintText: '@bad_guy:domain.abc',
                            floatingLabelBehavior: FloatingLabelBehavior.always,
                            labelText: L10n.of(context).blockUsername,
                            suffixIcon: IconButton(
                              tooltip: L10n.of(context).block,
                              icon: Icon(Icons.add, color: cyber.magenta),
                              onPressed: () => controller.ignoreUser(context),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: FluffySpacing.lg),
                      Text(
                        L10n.of(context).blockListDescription,
                        style: FluffyTypography.bodyS.copyWith(
                          color: cyber.warn,
                        ),
                      ),
                    ],
                  ),
                ),
                Divider(color: cyber.glassBorder),
                Expanded(
                  child: ListView.builder(
                    itemCount: client.ignoredUsers.length,
                    itemBuilder: (c, i) => CyberSettingsTile(
                      icon: Icons.block_outlined,
                      accent: cyber.magenta,
                      title: client.ignoredUsers[i],
                      trailing: IconButton(
                        tooltip: L10n.of(context).delete,
                        icon: Icon(
                          Icons.delete_outlined,
                          color: theme.colorScheme.error,
                        ),
                        onPressed: () => showFutureLoadingDialog(
                          context: context,
                          future: () =>
                              client.unignoreUser(client.ignoredUsers[i]),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
