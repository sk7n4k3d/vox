import 'package:fluffychat/config/design_tokens.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/pages/chat_details/chat_details.dart';
import 'package:fluffychat/pages/chat_details/participant_list_item.dart';
import 'package:fluffychat/utils/fluffy_share.dart';
import 'package:fluffychat/utils/matrix_sdk_extensions/matrix_locals.dart';
import 'package:fluffychat/widgets/avatar.dart';
import 'package:fluffychat/widgets/chat_settings_popup_menu.dart';
import 'package:fluffychat/widgets/cyber/cyber_widgets.dart';
import 'package:fluffychat/widgets/layouts/max_width_body.dart';
import 'package:fluffychat/widgets/matrix.dart';
import 'package:flutter/material.dart';
import 'package:flutter_linkify/flutter_linkify.dart';
import 'package:go_router/go_router.dart';
import 'package:matrix/matrix.dart';

import '../../utils/url_launcher.dart';
import '../../widgets/mxc_image_viewer.dart';
import '../../widgets/qr_code_viewer.dart';

class ChatDetailsView extends StatelessWidget {
  final ChatDetailsController controller;

  const ChatDetailsView(this.controller, {super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cyber = CyberColors.of(context);

    final room = Matrix.of(context).client.getRoomById(controller.roomId!);
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

    final directChatMatrixID = room.directChatMatrixID;
    final roomAvatar = room.avatar;

    return StreamBuilder(
      stream: room.client.onRoomState.stream.where(
        (update) => update.roomId == room.id,
      ),
      builder: (context, snapshot) {
        var members = room.getParticipants().toList()
          ..sort((b, a) => a.powerLevel.compareTo(b.powerLevel));
        members = members.take(10).toList();
        final actualMembersCount =
            (room.summary.mInvitedMemberCount ?? 0) +
            (room.summary.mJoinedMemberCount ?? 0);
        final canRequestMoreMembers = members.length < actualMembersCount;
        final displayname = room.getLocalizedDisplayname(
          MatrixLocals(L10n.of(context)),
        );
        return Scaffold(
          appBar: AppBar(
            leading:
                controller.widget.embeddedCloseButton ??
                const Center(child: BackButton()),
            elevation: 0,
            actions: <Widget>[
              if (room.canonicalAlias.isNotEmpty)
                IconButton(
                  tooltip: L10n.of(context).share,
                  icon: Icon(Icons.qr_code_rounded, color: cyber.cyan),
                  onPressed: () =>
                      showQrCodeViewer(context, room.canonicalAlias),
                )
              else if (directChatMatrixID != null)
                IconButton(
                  tooltip: L10n.of(context).share,
                  icon: Icon(Icons.qr_code_rounded, color: cyber.cyan),
                  onPressed: () =>
                      showQrCodeViewer(context, directChatMatrixID),
                ),
              if (controller.widget.embeddedCloseButton == null)
                ChatSettingsPopupMenu(room, false),
            ],
            title: Text(
              L10n.of(context).chatDetails,
              style: FluffyTypography.headlineM.copyWith(
                color: theme.colorScheme.onSurface,
              ),
            ),
            backgroundColor: Colors.transparent,
          ),
          body: MaxWidthBody(
            child: ListView.builder(
              physics: const NeverScrollableScrollPhysics(),
              shrinkWrap: true,
              itemCount: members.length + 1 + (canRequestMoreMembers ? 1 : 0),
              itemBuilder: (BuildContext context, int i) => i == 0
                  ? Column(
                      crossAxisAlignment: .stretch,
                      children: <Widget>[
                        Row(
                          children: [
                            Padding(
                              padding: const EdgeInsets.all(FluffySpacing.xxl),
                              child: Stack(
                                children: [
                                  Hero(
                                    tag:
                                        controller.widget.embeddedCloseButton !=
                                            null
                                        ? 'embedded_content_banner'
                                        : 'content_banner',
                                    child: Avatar(
                                      mxContent: room.avatar,
                                      name: displayname,
                                      size: Avatar.defaultSize * 2.5,
                                      onTap: roomAvatar != null
                                          ? () => showDialog(
                                              context: context,
                                              builder: (_) =>
                                                  MxcImageViewer(roomAvatar),
                                            )
                                          : null,
                                    ),
                                  ),
                                  if (!room.isDirectChat &&
                                      room.canChangeStateEvent(
                                        EventTypes.RoomAvatar,
                                      ))
                                    Positioned(
                                      bottom: 0,
                                      right: 0,
                                      child: FloatingActionButton.small(
                                        onPressed: controller.setAvatarAction,
                                        heroTag: null,
                                        backgroundColor: cyber.cyan,
                                        foregroundColor: Colors.black,
                                        child: const Icon(
                                          Icons.camera_alt_outlined,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                            Expanded(
                              child: Column(
                                mainAxisAlignment: .center,
                                crossAxisAlignment: .start,
                                children: [
                                  TextButton.icon(
                                    onPressed: () => room.isDirectChat
                                        ? null
                                        : room.canChangeStateEvent(
                                            EventTypes.RoomName,
                                          )
                                        ? controller.setDisplaynameAction()
                                        : FluffyShare.share(
                                            displayname,
                                            context,
                                            copyOnly: true,
                                          ),
                                    icon: Icon(
                                      room.isDirectChat
                                          ? Icons.chat_bubble_outline
                                          : room.canChangeStateEvent(
                                              EventTypes.RoomName,
                                            )
                                          ? Icons.edit_outlined
                                          : Icons.copy_outlined,
                                      size: 16,
                                    ),
                                    style: TextButton.styleFrom(
                                      foregroundColor:
                                          theme.colorScheme.onSurface,
                                      iconColor: cyber.cyan,
                                    ),
                                    label: Text(
                                      room.isDirectChat
                                          ? L10n.of(context).directChat
                                          : displayname,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: FluffyTypography.headlineM
                                          .copyWith(
                                            color: theme.colorScheme.onSurface,
                                          ),
                                    ),
                                  ),
                                  TextButton.icon(
                                    onPressed: () => room.isDirectChat
                                        ? null
                                        : context.push(
                                            '/rooms/${controller.roomId}/details/members',
                                          ),
                                    icon: Icon(
                                      Icons.group_outlined,
                                      size: 14,
                                      color: cyber.violet,
                                    ),
                                    style: TextButton.styleFrom(
                                      foregroundColor: cyber.violet,
                                      iconColor: cyber.violet,
                                    ),
                                    label: Text(
                                      L10n.of(
                                        context,
                                      ).countParticipants(actualMembersCount),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: FluffyTypography.labelL.copyWith(
                                        color: cyber.violet,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        if (room.canChangeStateEvent(EventTypes.RoomTopic) ||
                            room.topic.isNotEmpty) ...[
                          CyberSectionHeader(
                            L10n.of(context).chatDescription,
                            accent: cyber.cyan,
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: FluffySpacing.lg,
                            ),
                            child: CyberGlass(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  if (room.canChangeStateEvent(
                                    EventTypes.RoomTopic,
                                  ))
                                    Align(
                                      alignment: Alignment.centerRight,
                                      child: IconButton(
                                        onPressed: controller.setTopicAction,
                                        tooltip: L10n.of(
                                          context,
                                        ).setChatDescription,
                                        icon: Icon(
                                          Icons.edit_outlined,
                                          color: cyber.cyan,
                                        ),
                                      ),
                                    ),
                                  SelectableLinkify(
                                    text: room.topic.isEmpty
                                        ? L10n.of(context).noChatDescriptionYet
                                        : room.topic,
                                    textScaleFactor: MediaQuery.textScalerOf(
                                      context,
                                    ).scale(1),
                                    options: const LinkifyOptions(
                                      humanize: false,
                                    ),
                                    linkStyle: FluffyTypography.bodyM.copyWith(
                                      color: cyber.cyan,
                                      decorationColor: cyber.cyan,
                                    ),
                                    style: FluffyTypography.bodyM.copyWith(
                                      fontStyle: room.topic.isEmpty
                                          ? FontStyle.italic
                                          : FontStyle.normal,
                                      color: theme.colorScheme.onSurface,
                                      decorationColor:
                                          theme.colorScheme.onSurface,
                                    ),
                                    onOpen: (url) =>
                                        UrlLauncher(context, url.url)
                                            .launchUrl(),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: FluffySpacing.lg),
                        ],
                        if (!room.isDirectChat) ...[
                          CyberSectionHeader(
                            L10n.of(context).settings,
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
                                  CyberSettingsTile(
                                    icon: Icons
                                        .admin_panel_settings_outlined,
                                    accent: cyber.cyan,
                                    title: L10n.of(context).accessAndVisibility,
                                    subtitle: L10n.of(
                                      context,
                                    ).accessAndVisibilityDescription,
                                    onTap: () => context.push(
                                      '/rooms/${room.id}/details/access',
                                    ),
                                  ),
                                  CyberSettingsTile(
                                    icon: Icons.tune_outlined,
                                    accent: cyber.cyan,
                                    title: L10n.of(context).chatPermissions,
                                    subtitle: L10n.of(
                                      context,
                                    ).whoCanPerformWhichAction,
                                    onTap: () => context.push(
                                      '/rooms/${room.id}/details/permissions',
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: FluffySpacing.lg),
                        ],
                        CyberSectionHeader(
                          L10n.of(
                            context,
                          ).countParticipants(actualMembersCount),
                          accent: cyber.violet,
                        ),
                        if (!room.isDirectChat && room.canInvite)
                          Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: FluffySpacing.lg,
                            ),
                            child: CyberGlass(
                              padding: const EdgeInsets.symmetric(
                                vertical: FluffySpacing.xs,
                              ),
                              child: CyberSettingsTile(
                                icon: Icons.add_outlined,
                                accent: cyber.cyan,
                                title: L10n.of(context).inviteContact,
                                onTap: () =>
                                    context.go('/rooms/${room.id}/invite'),
                              ),
                            ),
                          ),
                      ],
                    )
                  : i < members.length + 1
                  ? ParticipantListItem(members[i - 1])
                  : ListTile(
                      title: Text(
                        L10n.of(context).loadCountMoreParticipants(
                          (actualMembersCount - members.length),
                        ),
                        style: FluffyTypography.title.copyWith(
                          color: theme.colorScheme.onSurface,
                        ),
                      ),
                      leading: CircleAvatar(
                        backgroundColor: cyber.violet.withValues(alpha: 0.16),
                        child: Icon(
                          Icons.group_outlined,
                          color: cyber.violet,
                        ),
                      ),
                      onTap: () => context.push(
                        '/rooms/${controller.roomId!}/details/members',
                      ),
                      trailing: Icon(
                        Icons.chevron_right_outlined,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
            ),
          ),
        );
      },
    );
  }
}
