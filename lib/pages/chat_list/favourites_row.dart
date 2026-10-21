import 'package:fluffychat/pages/chat_list/chat_list.dart';
import 'package:fluffychat/widgets/avatar.dart';
import 'package:fluffychat/widgets/matrix.dart';
import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';

/// Rangée horizontale des CONVERSATIONS FAVORITES (balise `m.favourite`).
///
/// Un appui ouvre la conversation, un appui long ouvre le menu contextuel
/// (ouvrir / bloquer / signaler / partager / retirer des favoris).
///
/// Remplace la rangée des statuts (présences) quand il y a au moins une
/// conversation favorite : la rangée des présences ne se partageait pas
/// (le profil n'était jamais chargé) et l'utilisateur s'attendait à
/// retrouver ses conversations favorites à cet endroit.
class FavouritesRow extends StatelessWidget {
  final ChatListController controller;

  const FavouritesRow({required this.controller, super.key});

  /// Timestamp du dernier message (ms), 0 si inconnu.
  static int _ts(Room room) =>
      room.lastEvent?.originServerTs.millisecondsSinceEpoch ?? 0;

  @override
  Widget build(BuildContext context) {
    final client = Matrix.of(context).client;
    final rooms = client.rooms
        .where(
          (r) =>
              r.isFavourite && !r.isSpace && r.membership == Membership.join,
        )
        .toList()
      ..sort((a, b) => _ts(b).compareTo(_ts(a)));
    if (rooms.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: 108,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: rooms.length,
        itemBuilder: (context, i) {
          final room = rooms[i];
          final name = room.getLocalizedDisplayname();
          return GestureDetector(
            onTap: () => controller.onChatTap(room),
            onLongPress: () => controller.chatContextAction(room, context),
            child: SizedBox(
              width: 84,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(height: 8),
                  Avatar(mxContent: room.avatar, name: name, size: 56),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 6,
                    ),
                    child: Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
