import 'package:fluffychat/pages/call/active_call_page.dart';
import 'package:fluffychat/pages/call/call_theme.dart';
import 'package:flutter/material.dart';

/// Barre d'appel flottante : reste visible au-dessus de la navigation quand
/// l'appel en cours est minimisé.
///
/// Reste volontairement minimale (avatar, nom, raccrocher). Tout le reste vit
/// dans [ActiveCallPage] — une barre qui propose 8 actions est illisible en
/// bandeau de 64 px.
class CallBar extends StatelessWidget {
  const CallBar({required this.controller, required this.onExpand, super.key});

  final CallController controller;
  final VoidCallback onExpand;

  @override
  Widget build(BuildContext context) {
    final cyber = CallTheme.of(context);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onExpand,
        child: Container(
          height: 64,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: cyber.glassFillStrong,
            border: Border.all(color: cyber.glassBorder),
          ),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    colors: [
                      cyber.cyan.withValues(alpha: 0.35),
                      cyber.magenta.withValues(alpha: 0.35),
                    ],
                  ),
                ),
                child: Text(
                  _initials(controller.remoteName),
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: Colors.white,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      controller.remoteName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Colors.white,
                      ),
                    ),
                    Text(
                      controller.reconnecting ? 'Reconnexion…' : 'En cours',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: controller.reconnecting
                            ? cyber.warn
                            : cyber.glassBorder,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                key: const Key('call-bar-hangup'),
                icon: const Icon(Icons.call_end, color: CallTheme.decline),
                tooltip: 'Raccrocher',
                onPressed: controller.hangup,
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _initials(String name) {
    final parts = name
        .trim()
        .split(RegExp(r'[\s@:._-]+'))
        .where((p) => p.isNotEmpty)
        .take(2)
        .map((p) => p[0].toUpperCase())
        .join();
    return parts.isEmpty ? '?' : parts;
  }
}