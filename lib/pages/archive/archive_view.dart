import 'package:fluffychat/config/design_tokens.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/pages/archive/archive.dart';
import 'package:fluffychat/pages/chat_list/chat_list_item.dart';
import 'package:fluffychat/pages/chat_list/dummy_chat_list_item.dart';
import 'package:fluffychat/widgets/cyber/cyber_fx.dart';
import 'package:fluffychat/widgets/cyber/cyber_widgets.dart';
import 'package:fluffychat/widgets/layouts/max_width_body.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:matrix/matrix.dart';

class ArchiveView extends StatelessWidget {
  final ArchiveController controller;

  const ArchiveView(this.controller, {super.key});

  @override
  Widget build(BuildContext context) {
    final cyber = CyberColors.of(context);
    return FutureBuilder<List<Room>>(
      future: controller.getArchive(context),
      builder: (BuildContext context, snapshot) => Scaffold(
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          leading: const Center(child: BackButton()),
          title: CyberGlitchText(
            L10n.of(context).archive,
            style: Theme.of(context).appBarTheme.titleTextStyle ??
                Theme.of(context).textTheme.titleLarge,
          ),
          actions: [
            if (snapshot.data?.isNotEmpty ?? false)
              Padding(
                padding: const EdgeInsets.all(FluffySpacing.sm),
                child: CyberPrimaryButton(
                  label: L10n.of(context).clearArchive,
                  icon: Icons.cleaning_services_outlined,
                  onPressed: controller.forgetAllAction,
                ),
              ),
          ],
        ),
        body: MaxWidthBody(
          withScrolling: false,
          child: Builder(
            builder: (BuildContext context) {
              if (snapshot.hasError) {
                return Center(
                  child: Text(
                    L10n.of(context).oopsSomethingWentWrong,
                    textAlign: TextAlign.center,
                    style: FluffyTypography.bodyL.copyWith(color: cyber.warn),
                  ),
                );
              }
              if (!snapshot.hasData) {
                // Initial loading: shimmer skeleton rows instead of a spinner,
                // keeping the list silhouette while the archive resolves.
                const skeletonCount = 6;
                return ListView.builder(
                  itemCount: skeletonCount,
                  itemBuilder: (context, i) => DummyChatListItem(
                    opacity: (skeletonCount - i) / skeletonCount,
                    animate: true,
                  ),
                );
              } else {
                if (controller.archive.isEmpty) {
                  return Center(
                    child: Icon(
                      Icons.archive_outlined,
                      size: 80,
                      color: cyber.cyan,
                    ),
                  );
                }
                return ListView.builder(
                  itemCount: controller.archive.length,
                  itemBuilder: (BuildContext context, int i) => ChatListItem(
                    controller.archive[i],
                    onForget: () => controller.forgetRoomAction(i),
                    onTap: () => context.go(
                      '/rooms/archive/${controller.archive[i].id}',
                    ),
                  ),
                );
              }
            },
          ),
        ),
      ),
    );
  }
}
