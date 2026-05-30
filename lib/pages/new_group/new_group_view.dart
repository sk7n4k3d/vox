import 'package:fluffychat/config/design_tokens.dart';
import 'package:fluffychat/config/themes.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/pages/new_group/new_group.dart';
import 'package:fluffychat/utils/localized_exception_extension.dart';
import 'package:fluffychat/widgets/avatar.dart';
import 'package:fluffychat/widgets/cyber/cyber_fx.dart';
import 'package:fluffychat/widgets/cyber/cyber_widgets.dart';
import 'package:fluffychat/widgets/layouts/max_width_body.dart';
import 'package:flutter/material.dart';

class NewGroupView extends StatelessWidget {
  final NewGroupController controller;

  const NewGroupView(this.controller, {super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cyber = CyberColors.of(context);

    final avatar = controller.avatar;
    final error = controller.error;
    final isSpace = controller.createGroupType == CreateGroupType.space;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: Center(
          child: BackButton(
            onPressed: controller.loading ? null : Navigator.of(context).pop,
          ),
        ),
        title: CyberGlitchText(
          isSpace ? L10n.of(context).newSpace : L10n.of(context).createGroup,
          style: FluffyTypography.headlineM.copyWith(
            color: theme.colorScheme.onSurface,
          ),
        ),
      ),
      body: MaxWidthBody(
        child: Column(
          mainAxisSize: .min,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.all(FluffySpacing.lg),
              child: CyberGlass(
                padding: const EdgeInsets.all(FluffySpacing.xs),
                child: SegmentedButton<CreateGroupType>(
                  selected: {controller.createGroupType},
                  onSelectionChanged: controller.setCreateGroupType,
                  segments: [
                    ButtonSegment(
                      value: CreateGroupType.group,
                      label: Text(L10n.of(context).group),
                    ),
                    ButtonSegment(
                      value: CreateGroupType.space,
                      label: Text(L10n.of(context).space),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: FluffySpacing.lg),
            DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                boxShadow: controller.loading
                    ? null
                    : FluffyElevation.glowViolet(cyber.violet, alpha: 0.4),
              ),
              child: InkWell(
                borderRadius: BorderRadius.circular(90),
                onTap: controller.loading ? null : controller.selectPhoto,
                child: CircleAvatar(
                  radius: Avatar.defaultSize,
                  backgroundColor: cyber.violet.withValues(alpha: 0.16),
                  child: avatar == null
                      ? Icon(
                          Icons.add_a_photo_outlined,
                          color: cyber.violet,
                        )
                      : ClipRRect(
                          borderRadius: BorderRadius.circular(90),
                          child: Image.memory(
                            avatar,
                            width: Avatar.defaultSize * 2,
                            height: Avatar.defaultSize * 2,
                            fit: BoxFit.cover,
                          ),
                        ),
                ),
              ),
            ),
            const SizedBox(height: FluffySpacing.xxl),
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: FluffySpacing.xl,
              ),
              child: CyberField(
                child: TextField(
                  autofocus: true,
                  controller: controller.nameController,
                  autocorrect: false,
                  readOnly: controller.loading,
                  decoration: InputDecoration(
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    prefixIcon: Icon(
                      Icons.people_outlined,
                      color: cyber.violet,
                    ),
                    labelText: isSpace
                        ? L10n.of(context).spaceName
                        : L10n.of(context).groupName,
                  ),
                ),
              ),
            ),
            const SizedBox(height: FluffySpacing.lg),
            SwitchListTile.adaptive(
              contentPadding: const EdgeInsets.symmetric(
                horizontal: FluffySpacing.xxl,
              ),
              activeThumbColor: cyber.cyan,
              secondary: Icon(
                Icons.public_outlined,
                color: cyber.cyan,
              ),
              title: Text(
                isSpace
                    ? L10n.of(context).spaceIsPublic
                    : L10n.of(context).groupIsPublic,
                style: FluffyTypography.title.copyWith(
                  color: theme.colorScheme.onSurface,
                ),
              ),
              value: controller.publicGroup,
              onChanged: controller.loading ? null : controller.setPublicGroup,
            ),
            AnimatedSize(
              duration: FluffyThemes.animationDuration,
              curve: FluffyThemes.animationCurve,
              child: controller.publicGroup
                  ? SwitchListTile.adaptive(
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: FluffySpacing.xxl,
                      ),
                      activeThumbColor: cyber.cyan,
                      secondary: Icon(
                        Icons.search_outlined,
                        color: cyber.cyan,
                      ),
                      title: Text(
                        L10n.of(context).groupCanBeFoundViaSearch,
                        style: FluffyTypography.title.copyWith(
                          color: theme.colorScheme.onSurface,
                        ),
                      ),
                      value: controller.groupCanBeFound,
                      onChanged: controller.loading
                          ? null
                          : controller.setGroupCanBeFound,
                    )
                  : const SizedBox.shrink(),
            ),
            AnimatedSize(
              duration: FluffyThemes.animationDuration,
              curve: FluffyThemes.animationCurve,
              child: isSpace
                  ? const SizedBox.shrink()
                  : SwitchListTile.adaptive(
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: FluffySpacing.xxl,
                      ),
                      activeThumbColor: cyber.cyan,
                      secondary: Icon(
                        Icons.lock_outlined,
                        color: cyber.success,
                      ),
                      title: Text(
                        L10n.of(context).enableEncryption,
                        style: FluffyTypography.title.copyWith(
                          color: theme.colorScheme.onSurface,
                        ),
                      ),
                      value: !controller.publicGroup,
                      onChanged: null,
                    ),
            ),
            AnimatedSize(
              duration: FluffyThemes.animationDuration,
              curve: FluffyThemes.animationCurve,
              child: isSpace
                  ? ListTile(
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: FluffySpacing.xxl,
                      ),
                      trailing: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: FluffySpacing.lg,
                        ),
                        child: Icon(
                          Icons.info_outlined,
                          color: cyber.violet,
                        ),
                      ),
                      subtitle: Text(
                        L10n.of(context).newSpaceDescription,
                        style: FluffyTypography.bodyS.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
            Padding(
              padding: const EdgeInsets.all(FluffySpacing.lg),
              child: SizedBox(
                width: double.infinity,
                child: CyberPrimaryButton(
                  loading: controller.loading,
                  onPressed: controller.loading
                      ? null
                      : controller.submitAction,
                  label: isSpace
                      ? L10n.of(context).createNewSpace
                      : L10n.of(context).createGroupAndInviteUsers,
                ),
              ),
            ),
            AnimatedSize(
              duration: FluffyThemes.animationDuration,
              curve: FluffyThemes.animationCurve,
              child: error == null
                  ? const SizedBox.shrink()
                  : ListTile(
                      leading: Icon(
                        Icons.warning_outlined,
                        color: cyber.warn,
                      ),
                      title: Text(
                        error.toLocalizedString(context),
                        style: FluffyTypography.bodyM.copyWith(
                          color: cyber.warn,
                        ),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
