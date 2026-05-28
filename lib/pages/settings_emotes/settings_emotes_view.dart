import 'package:fluffychat/config/design_tokens.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/utils/platform_infos.dart';
import 'package:fluffychat/utils/url_launcher.dart';
import 'package:fluffychat/widgets/cyber/cyber_widgets.dart';
import 'package:fluffychat/widgets/layouts/max_width_body.dart';
import 'package:fluffychat/widgets/mxc_image.dart';
import 'package:fluffychat/widgets/mxc_image_viewer.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:matrix/matrix.dart';

import '../../widgets/matrix.dart';
import 'settings_emotes.dart';

enum PopupMenuEmojiActions { import, export }

class EmotesSettingsView extends StatelessWidget {
  final EmotesSettingsController controller;

  const EmotesSettingsView(this.controller, {super.key});

  @override
  Widget build(BuildContext context) {
    if (controller.widget.roomId != null && controller.room == null) {
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
    final theme = Theme.of(context);
    final cyber = CyberColors.of(context);

    final client = Matrix.of(context).client;
    final imageKeys = controller.pack!.images.keys.toList();
    final packKeys = controller.packKeys;
    if (packKeys != null && packKeys.isEmpty) {
      packKeys.add('');
    }
    final attributionUrl = Uri.tryParse(
      controller.packAttributionController.text,
    );

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        automaticallyImplyLeading: !controller.showSave,
        title: controller.showSave
            ? TextButton(
                onPressed: controller.resetAction,
                child: Text(
                  L10n.of(context).cancel,
                  style: FluffyTypography.title.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              )
            : Text(
                L10n.of(context).customEmojisAndStickers,
                style: FluffyTypography.headlineM.copyWith(
                  color: theme.colorScheme.onSurface,
                ),
              ),
        actions: [
          if (controller.showSave)
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: FluffySpacing.md,
                vertical: FluffySpacing.sm,
              ),
              child: CyberPrimaryButton(
                label: L10n.of(context).saveChanges,
                icon: Icons.check_outlined,
                onPressed: () => controller.save(context),
              ),
            )
          else
            PopupMenuButton<PopupMenuEmojiActions>(
              useRootNavigator: true,
              icon: Icon(Icons.more_vert_outlined, color: cyber.cyan),
              onSelected: (value) {
                switch (value) {
                  case PopupMenuEmojiActions.export:
                    controller.exportAsZip();
                    break;
                  case PopupMenuEmojiActions.import:
                    controller.importEmojiZip();
                    break;
                }
              },
              itemBuilder: (context) => [
                if (!controller.readonly)
                  PopupMenuItem(
                    value: PopupMenuEmojiActions.import,
                    child: Text(L10n.of(context).importFromZipFile),
                  ),
                if (imageKeys.isNotEmpty)
                  PopupMenuItem(
                    value: PopupMenuEmojiActions.export,
                    child: Text(L10n.of(context).exportEmotePack),
                  ),
              ],
            ),
        ],
        bottom: packKeys == null
            ? null
            : PreferredSize(
                preferredSize: const Size.fromHeight(48),
                child: Padding(
                  padding: const EdgeInsets.all(FluffySpacing.xs),
                  child: SizedBox(
                    height: 40,
                    child: ListView.builder(
                      scrollDirection: Axis.horizontal,
                      itemCount: packKeys.length + 1,
                      itemBuilder: (context, i) {
                        if (i == 0) {
                          if (controller.readonly) {
                            return const SizedBox.shrink();
                          }
                          return Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: FluffySpacing.xs,
                            ),
                            child: FilterChip(
                              label: Icon(
                                Icons.add_outlined,
                                size: 20,
                                color: cyber.cyan,
                              ),
                              onSelected: controller.showSave
                                  ? null
                                  : (_) => controller.createImagePack(),
                            ),
                          );
                        }
                        i--;
                        final key = packKeys[i];
                        final event = controller.room?.getState(
                          'im.ponies.room_emotes',
                          packKeys[i],
                        );

                        final eventPack = event?.content
                            .tryGetMap<String, Object?>('pack');
                        final packName =
                            eventPack?.tryGet<String>('display_name') ??
                            eventPack?.tryGet<String>('name') ??
                            (key.isNotEmpty ? key : 'Default');

                        return Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: FluffySpacing.xs,
                          ),
                          child: FilterChip(
                            label: Text(packName),
                            selectedColor: cyber.magenta.withValues(alpha: 0.18),
                            checkmarkColor: cyber.magenta,
                            selected:
                                controller.stateKey == key ||
                                (controller.stateKey == null && key.isEmpty),
                            onSelected: controller.showSave
                                ? null
                                : (_) => controller.setStateKey(key),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
      ),
      body: MaxWidthBody(
        child: Column(
          mainAxisSize: .min,
          crossAxisAlignment: .stretch,
          children: <Widget>[
            if (controller.room != null) ...[
              const SizedBox(height: FluffySpacing.lg),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: FluffySpacing.lg,
                ),
                child: CyberField(
                  child: TextField(
                    maxLength: 256,
                    controller: controller.packDisplayNameController,
                    readOnly: controller.readonly,
                    onSubmitted: (_) => controller.submitDisplaynameAction(),
                    decoration: InputDecoration(
                      counter: const SizedBox.shrink(),
                      border: InputBorder.none,
                      hintText: controller.stateKey,
                      labelText: L10n.of(context).stickerPackName,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: FluffySpacing.sm),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: FluffySpacing.lg,
                ),
                child: CyberField(
                  child: TextField(
                    maxLength: 256,
                    controller: controller.packAttributionController,
                    readOnly: controller.readonly,
                    keyboardType: TextInputType.url,
                    onSubmitted: (_) => controller.submitAttributionAction(),
                    decoration: InputDecoration(
                      counter: const SizedBox.shrink(),
                      border: InputBorder.none,
                      labelText: L10n.of(context).attribution,
                      suffixIcon: attributionUrl == null
                          ? null
                          : IconButton(
                              icon: Icon(
                                Icons.link_outlined,
                                color: cyber.cyan,
                              ),
                              onPressed: () => UrlLauncher(
                                context,
                                attributionUrl.toString(),
                              ).launchUrl(),
                            ),
                    ),
                  ),
                ),
              ),
            ],
            if (!controller.readonly) ...[
              Padding(
                padding: const EdgeInsets.all(FluffySpacing.lg),
                child: CyberPrimaryButton(
                  label: L10n.of(context).createSticker,
                  icon: Icons.upload_outlined,
                  onPressed: controller.createStickers,
                ),
              ),
              const Divider(),
            ],
            if (controller.room != null && imageKeys.isNotEmpty)
              SwitchListTile.adaptive(
                title: Text(
                  L10n.of(context).enableEmotesGlobally,
                  style: FluffyTypography.title.copyWith(
                    color: theme.colorScheme.onSurface,
                  ),
                ),
                activeThumbColor: cyber.cyan,
                value: controller.isGloballyActive(client),
                onChanged: controller.setIsGloballyActive,
              ),
            imageKeys.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(FluffySpacing.lg),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.emoji_emotions_outlined,
                            size: 48,
                            color: cyber.cyan.withValues(alpha: 0.6),
                          ),
                          const SizedBox(height: FluffySpacing.md),
                          Text(
                            L10n.of(context).noEmotesFound,
                            style: FluffyTypography.headlineM.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  )
                : ListView.separated(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    separatorBuilder: (BuildContext context, int i) =>
                        const SizedBox(height: FluffySpacing.sm),
                    padding: const EdgeInsets.symmetric(
                      horizontal: FluffySpacing.lg,
                      vertical: FluffySpacing.sm,
                    ),
                    itemCount: imageKeys.length,
                    itemBuilder: (BuildContext context, int i) {
                      final imageCode = imageKeys[i];
                      final image = controller.pack!.images[imageCode]!;
                      final textEditingController = TextEditingController();
                      textEditingController.text = imageCode;
                      final useShortCuts =
                          (PlatformInfos.isWeb || PlatformInfos.isDesktop);
                      return CyberGlass(
                        padding: const EdgeInsets.symmetric(
                          horizontal: FluffySpacing.md,
                          vertical: FluffySpacing.xs,
                        ),
                        child: Row(
                          children: [
                            _EmoteImage(image.url),
                            const SizedBox(width: FluffySpacing.md),
                            Expanded(
                              child: Shortcuts(
                                shortcuts: !useShortCuts
                                    ? {}
                                    : {
                                        LogicalKeySet(LogicalKeyboardKey.enter):
                                            SubmitLineIntent(),
                                      },
                                child: Actions(
                                  actions: !useShortCuts
                                      ? {}
                                      : {
                                          SubmitLineIntent: CallbackAction(
                                            onInvoke: (i) {
                                              controller.submitImageAction(
                                                imageCode,
                                                image,
                                                textEditingController,
                                              );
                                              return null;
                                            },
                                          ),
                                        },
                                  child: TextField(
                                    readOnly: controller.readonly,
                                    controller: textEditingController,
                                    autocorrect: false,
                                    minLines: 1,
                                    maxLines: 1,
                                    maxLength: 128,
                                    style: FluffyTypography.code.copyWith(
                                      color: theme.colorScheme.onSurface,
                                    ),
                                    decoration: InputDecoration(
                                      hintText: L10n.of(context).emoteShortcode,
                                      prefixText: ': ',
                                      suffixText: ':',
                                      counter: const SizedBox.shrink(),
                                      filled: false,
                                      border: InputBorder.none,
                                      enabledBorder: const OutlineInputBorder(
                                        borderSide: BorderSide(
                                          color: Colors.transparent,
                                        ),
                                      ),
                                    ),
                                    onSubmitted: (s) =>
                                        controller.submitImageAction(
                                          imageCode,
                                          image,
                                          textEditingController,
                                        ),
                                  ),
                                ),
                              ),
                            ),
                            if (!controller.readonly)
                              PopupMenuButton<ImagePackUsage>(
                                onSelected: (usage) =>
                                    controller.toggleUsage(imageCode, usage),
                                itemBuilder: (context) => [
                                  PopupMenuItem(
                                    value: ImagePackUsage.sticker,
                                    child: Row(
                                      mainAxisSize: .min,
                                      children: [
                                        if (image.usage?.contains(
                                              ImagePackUsage.sticker,
                                            ) ??
                                            true)
                                          Icon(
                                            Icons.check_outlined,
                                            color: cyber.cyan,
                                          ),
                                        const SizedBox(width: FluffySpacing.md),
                                        Text(L10n.of(context).useAsSticker),
                                      ],
                                    ),
                                  ),
                                  PopupMenuItem(
                                    value: ImagePackUsage.emoticon,
                                    child: Row(
                                      mainAxisSize: .min,
                                      children: [
                                        if (image.usage?.contains(
                                              ImagePackUsage.emoticon,
                                            ) ??
                                            true)
                                          Icon(
                                            Icons.check_outlined,
                                            color: cyber.cyan,
                                          ),
                                        const SizedBox(width: FluffySpacing.md),
                                        Text(L10n.of(context).useAsEmoji),
                                      ],
                                    ),
                                  ),
                                ],
                                icon: Icon(
                                  Icons.edit_outlined,
                                  color: cyber.cyan,
                                ),
                              ),
                            if (!controller.readonly)
                              IconButton(
                                tooltip: L10n.of(context).delete,
                                onPressed: () =>
                                    controller.removeImageAction(imageCode),
                                icon: Icon(
                                  Icons.delete_outlined,
                                  color: cyber.magenta,
                                ),
                              ),
                          ],
                        ),
                      );
                    },
                  ),
          ],
        ),
      ),
    );
  }
}

class _EmoteImage extends StatelessWidget {
  final Uri mxc;

  const _EmoteImage(this.mxc);

  @override
  Widget build(BuildContext context) {
    const size = 44.0;
    final key = 'sticker_preview_$mxc';
    return InkWell(
      borderRadius: FluffyRadius.brSm,
      onTap: () =>
          showDialog(context: context, builder: (_) => MxcImageViewer(mxc)),
      child: MxcImage(
        key: ValueKey(key),
        cacheKey: key,
        uri: mxc,
        fit: BoxFit.contain,
        width: size,
        height: size,
        isThumbnail: true,
        animated: true,
      ),
    );
  }
}

class SubmitLineIntent extends Intent {}
