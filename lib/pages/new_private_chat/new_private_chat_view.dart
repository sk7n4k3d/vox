import 'package:fluffychat/config/app_config.dart';
import 'package:fluffychat/config/design_tokens.dart';
import 'package:fluffychat/config/themes.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/pages/new_private_chat/new_private_chat.dart';
import 'package:fluffychat/utils/localized_exception_extension.dart';
import 'package:fluffychat/utils/platform_infos.dart';
import 'package:fluffychat/utils/url_launcher.dart';
import 'package:fluffychat/widgets/avatar.dart';
import 'package:fluffychat/widgets/cyber/cyber_fx.dart';
import 'package:fluffychat/widgets/cyber/cyber_widgets.dart';
import 'package:fluffychat/widgets/layouts/max_width_body.dart';
import 'package:fluffychat/widgets/matrix.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:matrix/matrix.dart';
import 'package:pretty_qr_code/pretty_qr_code.dart';

import '../../widgets/qr_code_viewer.dart';

class NewPrivateChatView extends StatelessWidget {
  final NewPrivateChatController controller;

  const NewPrivateChatView(this.controller, {super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cyber = CyberColors.of(context);

    final searchResponse = controller.searchResponse;
    final userId = Matrix.of(context).client.userID!;
    return Scaffold(
      appBar: AppBar(
        scrolledUnderElevation: 0,
        elevation: 0,
        leading: const Center(child: BackButton()),
        title: CyberGlitchText(
          L10n.of(context).newChat,
          style: FluffyTypography.headlineM.copyWith(
            color: theme.colorScheme.onSurface,
          ),
        ),
        backgroundColor: Colors.transparent,
        actions: [
          TextButton(
            onPressed: UrlLauncher(
              context,
              AppConfig.startChatTutorial,
            ).launchUrl,
            child: Text(
              L10n.of(context).help,
              style: FluffyTypography.labelL.copyWith(color: cyber.cyan),
            ),
          ),
        ],
      ),
      body: MaxWidthBody(
        withScrolling: false,
        innerPadding: const EdgeInsets.symmetric(vertical: FluffySpacing.sm),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: FluffySpacing.lg,
                vertical: FluffySpacing.sm,
              ),
              child: CyberField(
                focused: controller.controller.text.isNotEmpty,
                child: TextField(
                  controller: controller.controller,
                  onChanged: controller.searchUsers,
                  style: FluffyTypography.bodyM.copyWith(
                    color: theme.colorScheme.onSurface,
                  ),
                  decoration: InputDecoration(
                    hintText: L10n.of(context).searchForUsers,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(
                      vertical: FluffySpacing.md,
                    ),
                    hintStyle: FluffyTypography.bodyM.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    prefixIcon: searchResponse == null
                        ? Icon(Icons.search_outlined, color: cyber.cyan)
                        : FutureBuilder(
                            future: searchResponse,
                            builder: (context, snapshot) {
                              if (snapshot.connectionState !=
                                  ConnectionState.done) {
                                return const Padding(
                                  padding: EdgeInsets.all(FluffySpacing.sm),
                                  child: SizedBox.square(
                                    dimension: 24,
                                    child: CircularProgressIndicator.adaptive(
                                      strokeWidth: 1,
                                    ),
                                  ),
                                );
                              }
                              return Icon(
                                Icons.search_outlined,
                                color: cyber.cyan,
                              );
                            },
                          ),
                    suffixIcon: controller.controller.text.isEmpty
                        ? null
                        : IconButton(
                            icon: Icon(
                              Icons.clear_outlined,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                            onPressed: () {
                              controller.controller.clear();
                              controller.searchUsers();
                            },
                          ),
                  ),
                ),
              ),
            ),
            Expanded(
              child: AnimatedSwitcher(
                duration: FluffyThemes.animationDuration,
                child: searchResponse == null
                    ? ListView(
                        children: [
                          Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: FluffySpacing.lg,
                              vertical: FluffySpacing.sm,
                            ),
                            child: SelectableText.rich(
                              TextSpan(
                                children: [
                                  TextSpan(
                                    text: L10n.of(context).yourGlobalUserIdIs,
                                  ),
                                  TextSpan(
                                    text: Matrix.of(context).client.userID,
                                    style: FluffyTypography.code.copyWith(
                                      color: cyber.cyan,
                                    ),
                                  ),
                                ],
                              ),
                              style: FluffyTypography.bodyS.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                          const SizedBox(height: FluffySpacing.md),
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
                                  CyberSettingsTile(
                                    icon: Icons.adaptive.share_outlined,
                                    accent: cyber.cyan,
                                    title: L10n.of(context).shareInviteLink,
                                    onTap: controller.inviteAction,
                                  ),
                                  CyberSettingsTile(
                                    icon: Icons.group_add_outlined,
                                    accent: cyber.violet,
                                    title: L10n.of(context).createGroup,
                                    onTap: () => context.go('/rooms/newgroup'),
                                  ),
                                  if (PlatformInfos.isMobile)
                                    CyberSettingsTile(
                                      icon: Icons.qr_code_scanner_outlined,
                                      accent: cyber.magenta,
                                      title: L10n.of(context).scanQrCode,
                                      onTap: controller.openScannerAction,
                                    ),
                                ],
                              ),
                            ),
                          ),
                          Center(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: FluffySpacing.xxxxl,
                                vertical: FluffySpacing.xl,
                              ),
                              child: CyberGlass(
                                onTap: () => showQrCodeViewer(context, userId),
                                glow: FluffyElevation.glowCyan(
                                  cyber.cyan,
                                  alpha: 0.25,
                                ),
                                padding: const EdgeInsets.all(FluffySpacing.lg),
                                child: ConstrainedBox(
                                  constraints: const BoxConstraints(
                                    maxWidth: 200,
                                  ),
                                  child: PrettyQrView.data(
                                    data: 'https://matrix.to/#/$userId',
                                    decoration: PrettyQrDecoration(
                                      shape: PrettyQrSmoothSymbol(
                                        roundFactor: 1,
                                        color: cyber.cyan,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      )
                    : FutureBuilder(
                        future: searchResponse,
                        builder: (context, snapshot) {
                          final result = snapshot.data;
                          final error = snapshot.error;
                          if (error != null) {
                            return Column(
                              mainAxisAlignment: .center,
                              children: [
                                Text(
                                  error.toLocalizedString(context),
                                  textAlign: TextAlign.center,
                                  style: FluffyTypography.bodyM.copyWith(
                                    color: cyber.warn,
                                  ),
                                ),
                                const SizedBox(height: FluffySpacing.md),
                                OutlinedButton.icon(
                                  onPressed: controller.searchUsers,
                                  icon: const Icon(Icons.refresh_outlined),
                                  label: Text(L10n.of(context).tryAgain),
                                ),
                              ],
                            );
                          }
                          if (result == null) {
                            return const Center(
                              child: CircularProgressIndicator.adaptive(),
                            );
                          }
                          if (result.isEmpty) {
                            return Column(
                              mainAxisAlignment: .center,
                              children: [
                                Icon(
                                  Icons.search_outlined,
                                  size: 86,
                                  color: cyber.cyan,
                                ),
                                Padding(
                                  padding: const EdgeInsets.all(
                                    FluffySpacing.lg,
                                  ),
                                  child: Text(
                                    L10n.of(context).noUsersFoundWithQuery(
                                      controller.controller.text,
                                    ),
                                    style: FluffyTypography.bodyM.copyWith(
                                      color: theme.colorScheme.onSurfaceVariant,
                                    ),
                                    textAlign: TextAlign.center,
                                  ),
                                ),
                              ],
                            );
                          }
                          return ListView.builder(
                            itemCount: result.length,
                            itemBuilder: (context, i) {
                              final contact = result[i];
                              final displayname =
                                  contact.displayName ??
                                  contact.userId.localpart ??
                                  contact.userId;
                              return ListTile(
                                leading: Avatar(
                                  name: displayname,
                                  mxContent: contact.avatarUrl,
                                  presenceUserId: contact.userId,
                                ),
                                title: Text(
                                  displayname,
                                  style: FluffyTypography.title.copyWith(
                                    color: theme.colorScheme.onSurface,
                                  ),
                                ),
                                subtitle: Text(
                                  contact.userId,
                                  style: FluffyTypography.bodyS.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                                onTap: () => controller.openUserModal(contact),
                              );
                            },
                          );
                        },
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
