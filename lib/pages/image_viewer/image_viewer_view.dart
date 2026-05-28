import 'package:fluffychat/config/design_tokens.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/pages/image_viewer/video_player.dart';
import 'package:fluffychat/utils/platform_infos.dart';
import 'package:fluffychat/widgets/cyber/cyber_widgets.dart';
import 'package:fluffychat/widgets/hover_builder.dart';
import 'package:fluffychat/widgets/mxc_image.dart';
import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';

import 'image_viewer.dart';

class ImageViewerView extends StatelessWidget {
  final ImageViewerController controller;

  const ImageViewerView(this.controller, {super.key});

  @override
  Widget build(BuildContext context) {
    final cyber = CyberColors.of(context);
    final iconButtonStyle = IconButton.styleFrom(
      backgroundColor: cyber.glassFillStrong,
      foregroundColor: cyber.cyan,
      shape: const RoundedRectangleBorder(borderRadius: FluffyRadius.brMd),
      side: BorderSide(color: cyber.glassBorder),
    );
    return GestureDetector(
      onTap: () => Navigator.of(context).pop(),
      child: Scaffold(
        backgroundColor: Colors.black.withValues(alpha: 0.5),
        extendBodyBehindAppBar: true,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          leading: IconButton(
            style: iconButtonStyle,
            icon: const Icon(Icons.close),
            onPressed: Navigator.of(context).pop,
            color: cyber.cyan,
            tooltip: L10n.of(context).close,
          ),
          actions: [
            IconButton(
              style: iconButtonStyle,
              icon: const Icon(Icons.reply_outlined),
              onPressed: controller.forwardAction,
              color: cyber.cyan,
              tooltip: L10n.of(context).share,
            ),
            const SizedBox(width: FluffySpacing.sm),
            IconButton(
              style: iconButtonStyle,
              icon: const Icon(Icons.download_outlined),
              onPressed: () => controller.saveFileAction(context),
              color: cyber.cyan,
              tooltip: L10n.of(context).downloadFile,
            ),
            const SizedBox(width: FluffySpacing.sm),
            if (PlatformInfos.isMobile)
              // Use builder context to correctly position the share dialog on iPad
              Padding(
                padding: const EdgeInsets.only(right: FluffySpacing.sm),
                child: Builder(
                  builder: (context) => IconButton(
                    style: iconButtonStyle,
                    onPressed: () => controller.shareFileAction(context),
                    tooltip: L10n.of(context).share,
                    color: cyber.cyan,
                    icon: Icon(Icons.adaptive.share_outlined),
                  ),
                ),
              ),
          ],
        ),
        body: HoverBuilder(
          builder: (context, hovered) => Stack(
            children: [
              KeyboardListener(
                focusNode: controller.focusNode,
                onKeyEvent: controller.onKeyEvent,
                child: PageView.builder(
                  scrollDirection: Axis.vertical,
                  controller: controller.pageController,
                  itemCount: controller.allEvents.length,
                  itemBuilder: (context, i) {
                    final event = controller.allEvents[i];
                    switch (event.messageType) {
                      case MessageTypes.Video:
                        return Padding(
                          padding: const EdgeInsets.only(top: FluffySpacing.xxxl),
                          child: Center(
                            child: GestureDetector(
                              // Ignore taps to not go back here:
                              onTap: () {},
                              child: EventVideoPlayer(event),
                            ),
                          ),
                        );
                      case MessageTypes.Image:
                      case MessageTypes.Sticker:
                      default:
                        return InteractiveViewer(
                          minScale: 1.0,
                          maxScale: 10.0,
                          onInteractionEnd: controller.onInteractionEnds,
                          child: Center(
                            child: Hero(
                              tag: event.eventId,
                              child: GestureDetector(
                                // Ignore taps to not go back here:
                                onTap: () {},
                                child: MxcImage(
                                  key: ValueKey(event.eventId),
                                  event: event,
                                  fit: BoxFit.contain,
                                  isThumbnail: false,
                                  animated: true,
                                ),
                              ),
                            ),
                          ),
                        );
                    }
                  },
                ),
              ),
              if (hovered)
                Align(
                  alignment: Alignment.centerRight,
                  child: Column(
                    mainAxisSize: .min,
                    children: [
                      if (controller.canGoBack)
                        Padding(
                          padding: const EdgeInsets.all(FluffySpacing.md),
                          child: IconButton(
                            style: iconButtonStyle,
                            tooltip: L10n.of(context).previous,
                            icon: const Icon(Icons.arrow_upward_outlined),
                            onPressed: controller.prevImage,
                          ),
                        ),
                      if (controller.canGoNext)
                        Padding(
                          padding: const EdgeInsets.all(FluffySpacing.md),
                          child: IconButton(
                            style: iconButtonStyle,
                            tooltip: L10n.of(context).next,
                            icon: const Icon(Icons.arrow_downward_outlined),
                            onPressed: controller.nextImage,
                          ),
                        ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
