import 'package:fluffychat/config/design_tokens.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/pages/invitation_selection/invitation_selection.dart';
import 'package:fluffychat/widgets/avatar.dart';
import 'package:fluffychat/widgets/cyber/cyber_widgets.dart';
import 'package:fluffychat/widgets/layouts/max_width_body.dart';
import 'package:fluffychat/widgets/matrix.dart';
import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';

import '../../widgets/adaptive_dialogs/user_dialog.dart';

class InvitationSelectionView extends StatelessWidget {
  final InvitationSelectionController controller;

  const InvitationSelectionView(this.controller, {super.key});

  @override
  Widget build(BuildContext context) {
    final room = Matrix.of(
      context,
    ).client.getRoomById(controller.widget.roomId);
    if (room == null) {
      return Scaffold(
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          title: Text(L10n.of(context).oopsSomethingWentWrong),
        ),
        body: Center(
          child: Text(L10n.of(context).youAreNoLongerParticipatingInThisChat),
        ),
      );
    }

    final groupName = room.name.isEmpty ? L10n.of(context).group : room.name;
    final theme = Theme.of(context);
    final cyber = CyberColors.of(context);
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: const Center(child: BackButton()),
        titleSpacing: 0,
        title: Text(
          L10n.of(context).inviteContact,
          style: FluffyTypography.headlineM.copyWith(
            color: theme.colorScheme.onSurface,
          ),
        ),
      ),
      body: MaxWidthBody(
        innerPadding: const EdgeInsets.symmetric(vertical: FluffySpacing.sm),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(FluffySpacing.lg),
              child: CyberGlass(
                borderRadius: FluffyRadius.brFull,
                padding: const EdgeInsets.symmetric(
                  horizontal: FluffySpacing.sm,
                ),
                child: TextField(
                  textInputAction: TextInputAction.search,
                  style: FluffyTypography.bodyL.copyWith(
                    color: theme.colorScheme.onSurface,
                  ),
                  decoration: InputDecoration(
                    filled: false,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    hintStyle: FluffyTypography.bodyL.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    hintText: L10n.of(context).inviteContactToGroup(groupName),
                    prefixIcon: controller.loading
                        ? Padding(
                            padding: const EdgeInsets.symmetric(
                              vertical: FluffySpacing.md,
                              horizontal: FluffySpacing.md,
                            ),
                            child: SizedBox.square(
                              dimension: 24,
                              child: CircularProgressIndicator.adaptive(
                                strokeWidth: 2,
                                valueColor: AlwaysStoppedAnimation<Color>(
                                  cyber.cyan,
                                ),
                              ),
                            ),
                          )
                        : Icon(
                            Icons.search_outlined,
                            color: cyber.cyan,
                          ),
                  ),
                  onChanged: controller.searchUserWithCoolDown,
                ),
              ),
            ),
            StreamBuilder<Object>(
              stream: room.client.onRoomState.stream.where(
                (update) => update.roomId == room.id,
              ),
              builder: (context, snapshot) {
                final participants = room
                    .getParticipants()
                    .map((user) => user.id)
                    .toSet();
                return controller.foundProfiles.isNotEmpty
                    ? ListView.builder(
                        physics: const NeverScrollableScrollPhysics(),
                        shrinkWrap: true,
                        itemCount: controller.foundProfiles.length,
                        itemBuilder: (BuildContext context, int i) =>
                            _InviteContactListTile(
                              profile: controller.foundProfiles[i],
                              isMember: participants.contains(
                                controller.foundProfiles[i].userId,
                              ),
                              onTap: () => controller.inviteAction(
                                context,
                                controller.foundProfiles[i].userId,
                                controller.foundProfiles[i].displayName ??
                                    controller
                                        .foundProfiles[i]
                                        .userId
                                        .localpart ??
                                    L10n.of(context).user,
                              ),
                            ),
                      )
                    : FutureBuilder<List<User>>(
                        future: controller.getContacts(context),
                        builder: (BuildContext context, snapshot) {
                          if (!snapshot.hasData) {
                            return Center(
                              child: CircularProgressIndicator.adaptive(
                                strokeWidth: 2,
                                valueColor: AlwaysStoppedAnimation<Color>(
                                  cyber.cyan,
                                ),
                              ),
                            );
                          }
                          final contacts = snapshot.data!;
                          return ListView.builder(
                            physics: const NeverScrollableScrollPhysics(),
                            shrinkWrap: true,
                            itemCount: contacts.length,
                            itemBuilder: (BuildContext context, int i) =>
                                _InviteContactListTile(
                                  user: contacts[i],
                                  profile: Profile(
                                    avatarUrl: contacts[i].avatarUrl,
                                    displayName:
                                        contacts[i].displayName ??
                                        contacts[i].id.localpart ??
                                        L10n.of(context).user,
                                    userId: contacts[i].id,
                                  ),
                                  isMember: participants.contains(
                                    contacts[i].id,
                                  ),
                                  onTap: () => controller.inviteAction(
                                    context,
                                    contacts[i].id,
                                    contacts[i].displayName ??
                                        contacts[i].id.localpart ??
                                        L10n.of(context).user,
                                  ),
                                ),
                          );
                        },
                      );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _InviteContactListTile extends StatelessWidget {
  final Profile profile;
  final User? user;
  final bool isMember;
  final void Function() onTap;

  const _InviteContactListTile({
    required this.profile,
    this.user,
    required this.isMember,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cyber = CyberColors.of(context);
    final l10n = L10n.of(context);

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(
        horizontal: FluffySpacing.lg,
        vertical: FluffySpacing.xs,
      ),
      leading: Avatar(
        mxContent: profile.avatarUrl,
        name: profile.displayName,
        presenceUserId: profile.userId,
        onTap: () => UserDialog.show(context: context, profile: profile),
      ),
      title: Text(
        profile.displayName ?? profile.userId.localpart ?? l10n.user,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: FluffyTypography.title.copyWith(
          color: theme.colorScheme.onSurface,
        ),
      ),
      subtitle: Text(
        profile.userId,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: FluffyTypography.code.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      trailing: isMember
          ? Container(
              padding: const EdgeInsets.symmetric(
                horizontal: FluffySpacing.md,
                vertical: FluffySpacing.xs,
              ),
              decoration: BoxDecoration(
                color: cyber.violet.withValues(alpha: 0.16),
                borderRadius: FluffyRadius.brFull,
                border: Border.all(
                  color: cyber.violet.withValues(alpha: 0.4),
                ),
              ),
              child: Text(
                l10n.participant,
                style: FluffyTypography.labelL.copyWith(
                  color: cyber.violet,
                  fontWeight: FontWeight.w600,
                ),
              ),
            )
          : CyberPrimaryButton(
              label: l10n.invite,
              icon: Icons.person_add_alt_1_outlined,
              onPressed: onTap,
            ),
    );
  }
}
