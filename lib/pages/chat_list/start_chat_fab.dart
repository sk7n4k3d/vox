import 'package:fluffychat/config/cyberpunk_theme_extension.dart';
import 'package:fluffychat/config/design_tokens.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// New-chat FAB, themed to match CYBERCORE: a cyan→magenta gradient disc with a
/// magenta neon glow, consistent with [CyberPrimaryButton]. Kept as a Hero so
/// the open-room transition still animates.
class StartChatFab extends StatelessWidget {
  const StartChatFab({super.key});

  @override
  Widget build(BuildContext context) {
    final cyber =
        Theme.of(context).extension<CyberpunkTheme>() ?? CyberpunkTheme.dark();
    return Hero(
      tag: 'start_chat_fab',
      child: Material(
        color: Colors.transparent,
        child: Tooltip(
          message: L10n.of(context).newChat,
          child: InkWell(
            onTap: () => context.go('/rooms/newprivatechat'),
            customBorder: const CircleBorder(),
            child: Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  colors: [cyber.cyan, cyber.magenta],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                boxShadow: FluffyElevation.glowMagenta(cyber.magenta, alpha: 0.5),
              ),
              child: const Icon(
                Icons.edit_square,
                color: Colors.black,
                size: 24,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
