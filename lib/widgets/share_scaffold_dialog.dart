import 'dart:io';

import 'package:cross_file/cross_file.dart';
import 'package:fluffychat/config/app_config.dart';
import 'package:fluffychat/config/themes.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/utils/matrix_sdk_extensions/matrix_locals.dart';
import 'package:fluffychat/utils/sms/sms_bridge.dart';
import 'package:fluffychat/widgets/avatar.dart';
import 'package:fluffychat/widgets/matrix.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:matrix/matrix.dart';

abstract class ShareItem {}

class TextShareItem extends ShareItem {
  final String value;
  TextShareItem(this.value);
}

class ContentShareItem extends ShareItem {
  final Map<String, Object?> value;
  ContentShareItem(this.value);
}

/// Carries the full Matrix [Event] (not just its content map) so a forward to a
/// non-Matrix target (SMS/MMS) can download + decrypt its attachment properly
/// via Event.downloadAndDecryptAttachment. Used alongside ContentShareItem,
/// which stays the path for Matrix→Matrix forwards.
class EventShareItem extends ShareItem {
  final Event event;
  EventShareItem(this.event);
}

class FileShareItem extends ShareItem {
  final XFile value;
  FileShareItem(this.value);
}

class ShareScaffoldDialog extends StatefulWidget {
  final List<ShareItem> items;

  const ShareScaffoldDialog({required this.items, super.key});

  @override
  State<ShareScaffoldDialog> createState() => _ShareScaffoldDialogState();
}

class _ShareScaffoldDialogState extends State<ShareScaffoldDialog> {
  final TextEditingController _filterController = TextEditingController();

  String? selectedRoomId;
  // When a SMS conversation is picked instead of a Matrix room.
  SmsConversation? selectedSms;
  List<SmsConversation> _smsConversations = const [];
  bool _sendingSms = false;

  @override
  void initState() {
    super.initState();
    _loadSms();
  }

  Future<void> _loadSms() async {
    // SMS targets are only relevant when VOX is the default SMS app.
    if (!await SmsBridge.instance.isDefaultSmsApp()) return;
    final convs = await SmsBridge.instance.listConversations();
    if (!mounted) return;
    setState(() => _smsConversations = convs);
  }

  void _toggleRoom(String roomId) {
    setState(() {
      selectedRoomId = roomId;
      selectedSms = null; // mutually exclusive with an SMS target
    });
  }

  void _toggleSms(SmsConversation conv) {
    setState(() {
      selectedSms = conv;
      selectedRoomId = null;
    });
  }

  Future<void> _forwardAction() async {
    // SMS target: send the shared text/image straight through the SMS bridge.
    final sms = selectedSms;
    if (sms != null) {
      await _forwardToSms(sms);
      return;
    }
    final roomId = selectedRoomId;
    if (roomId == null) {
      throw Exception(
        'Started forward action before room was selected. This should never happen.',
      );
    }
    while (context.canPop()) {
      context.pop();
    }
    context.go('/rooms/$roomId', extra: widget.items);
  }

  /// Sends the shared items to an SMS conversation: text → SMS, image → MMS.
  /// Handles three item kinds:
  ///  - TextShareItem  : external shared text → SMS
  ///  - FileShareItem  : external shared file (local path) → MMS if image
  ///  - EventShareItem : a forwarded Matrix message → text to SMS, or an image
  ///    attachment downloaded+decrypted to a temp file then sent as MMS.
  /// ContentShareItem is intentionally skipped here (it's the Matrix→Matrix
  /// path; EventShareItem is the SMS-capable twin of the same event).
  Future<void> _forwardToSms(SmsConversation conv) async {
    setState(() => _sendingSms = true);
    try {
      for (final item in widget.items) {
        if (item is TextShareItem) {
          await SmsBridge.instance.sendSms(conv.address, item.value);
        } else if (item is FileShareItem) {
          if (_looksLikeImage(item.value.mimeType, item.value.path)) {
            await SmsBridge.instance
                .sendMms(conv.address, null, item.value.path);
          }
        } else if (item is EventShareItem) {
          await _forwardEventToSms(conv, item.event);
        }
        // ContentShareItem is intentionally skipped (Matrix→Matrix path).
      }
    } finally {
      if (mounted) {
        while (context.canPop()) {
          context.pop();
        }
      }
    }
  }

  Future<void> _forwardEventToSms(SmsConversation conv, Event event) async {
    final msgtype = event.content.tryGet<String>('msgtype');
    if (msgtype == MessageTypes.Text ||
        msgtype == MessageTypes.Notice ||
        msgtype == MessageTypes.Emote) {
      final body = event.body.trim();
      if (body.isNotEmpty) {
        await SmsBridge.instance.sendSms(conv.address, body);
      }
      return;
    }
    if (msgtype == MessageTypes.Image) {
      try {
        // Downloads AND decrypts (E2EE rooms) the attachment to bytes. The
        // native MMS layer compresses it under the carrier size cap.
        final matrixFile = await event.downloadAndDecryptAttachment();
        final dir = await Directory.systemTemp.createTemp('vox_fwd');
        final name = matrixFile.name.isNotEmpty
            ? matrixFile.name
            : 'image_${event.eventId}.jpg';
        final file = File('${dir.path}/$name');
        await file.writeAsBytes(matrixFile.bytes);
        await SmsBridge.instance.sendMms(conv.address, null, file.path);
      } catch (_) {
        // Download/decrypt failed — fall back to forwarding the caption text.
        final body = event.body.trim();
        if (body.isNotEmpty) {
          await SmsBridge.instance.sendSms(conv.address, body);
        }
      }
      return;
    }
    // Other media types: forward the text body as a best effort.
    final body = event.body.trim();
    if (body.isNotEmpty) {
      await SmsBridge.instance.sendSms(conv.address, body);
    }
  }

  bool _looksLikeImage(String? mime, String path) {
    if (mime != null && mime.startsWith('image/')) return true;
    final p = path.toLowerCase();
    return p.endsWith('.jpg') || p.endsWith('.jpeg') || p.endsWith('.png') ||
        p.endsWith('.gif') || p.endsWith('.webp');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rooms = Matrix.of(context).client.rooms
        .where(
          (room) =>
              room.canSendDefaultMessages &&
              !room.isSpace &&
              room.membership == Membership.join,
        )
        .toList();
    final filter = _filterController.text.trim().toLowerCase();
    return Scaffold(
      appBar: AppBar(
        leading: Center(child: CloseButton(onPressed: context.pop)),
        title: Text(L10n.of(context).share),
      ),
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            floating: true,
            toolbarHeight: 72,
            scrolledUnderElevation: 0,
            backgroundColor: Colors.transparent,
            automaticallyImplyLeading: false,
            title: TextField(
              controller: _filterController,
              onChanged: (_) => setState(() {}),
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                filled: true,
                fillColor: theme.colorScheme.secondaryContainer,
                border: OutlineInputBorder(
                  borderSide: BorderSide.none,
                  borderRadius: BorderRadius.circular(99),
                ),
                contentPadding: EdgeInsets.zero,
                hintText: L10n.of(context).search,
                hintStyle: TextStyle(
                  color: theme.colorScheme.onPrimaryContainer,
                  fontWeight: FontWeight.normal,
                ),
                floatingLabelBehavior: FloatingLabelBehavior.never,
                prefixIcon: IconButton(
                  onPressed: () {},
                  icon: Icon(
                    Icons.search_outlined,
                    color: theme.colorScheme.onPrimaryContainer,
                  ),
                ),
              ),
            ),
          ),
          SliverList.builder(
            itemCount: rooms.length,
            itemBuilder: (context, i) {
              final room = rooms[i];
              final displayname = room.getLocalizedDisplayname(
                MatrixLocals(L10n.of(context)),
              );
              final value = selectedRoomId == room.id;
              final filterOut = !displayname.toLowerCase().contains(filter);
              if (!value && filterOut) {
                return const SizedBox.shrink();
              }
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0),
                child: Opacity(
                  opacity: filterOut ? 0.5 : 1,
                  child: CheckboxListTile.adaptive(
                    checkboxShape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(90),
                    ),
                    controlAffinity: ListTileControlAffinity.trailing,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(
                        AppConfig.borderRadius,
                      ),
                    ),
                    secondary: Avatar(
                      mxContent: room.avatar,
                      name: displayname,
                      size: Avatar.defaultSize * 0.75,
                    ),
                    title: Text(
                      displayname,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      room.directChatMatrixID ??
                          L10n.of(context).countParticipants(
                            (room.summary.mJoinedMemberCount ?? 0) +
                                (room.summary.mInvitedMemberCount ?? 0),
                          ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    value: selectedRoomId == room.id,
                    onChanged: (_) => _toggleRoom(room.id),
                  ),
                ),
              );
            },
          ),
          // ── SMS conversations ───────────────────────────────────────────
          if (_smsConversations.isNotEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 16, 16, 4),
                child: Text(
                  'SMS',
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.2,
                  ),
                ),
              ),
            ),
          SliverList.builder(
            itemCount: _smsConversations.length,
            itemBuilder: (context, i) {
              final conv = _smsConversations[i];
              final title = conv.title;
              final selected = selectedSms?.threadId == conv.threadId;
              final filterOut = !title.toLowerCase().contains(filter) &&
                  !conv.address.toLowerCase().contains(filter);
              if (!selected && filterOut) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0),
                child: Opacity(
                  opacity: filterOut ? 0.5 : 1,
                  child: CheckboxListTile.adaptive(
                    checkboxShape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(90),
                    ),
                    controlAffinity: ListTileControlAffinity.trailing,
                    shape: RoundedRectangleBorder(
                      borderRadius:
                          BorderRadius.circular(AppConfig.borderRadius),
                    ),
                    secondary: CircleAvatar(
                      radius: Avatar.defaultSize * 0.375,
                      backgroundColor: theme.colorScheme.primaryContainer,
                      backgroundImage: (conv.photoPath != null &&
                              conv.photoPath!.isNotEmpty)
                          ? FileImage(File(conv.photoPath!))
                          : null,
                      child: (conv.photoPath == null ||
                              conv.photoPath!.isEmpty)
                          ? Text(
                              title.isNotEmpty ? title[0].toUpperCase() : '?',
                              style: TextStyle(
                                color: theme.colorScheme.onPrimaryContainer,
                              ),
                            )
                          : null,
                    ),
                    title: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      conv.address,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    value: selected,
                    onChanged: (_) => _toggleSms(conv),
                  ),
                ),
              );
            },
          ),
        ],
      ),
      bottomNavigationBar: AnimatedSize(
        duration: FluffyThemes.animationDuration,
        curve: FluffyThemes.animationCurve,
        child: (selectedRoomId == null && selectedSms == null)
            ? const SizedBox.shrink()
            : Material(
                elevation: 8,
                shadowColor: theme.appBarTheme.shadowColor,
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: ElevatedButton(
                    onPressed: _sendingSms ? null : _forwardAction,
                    child: _sendingSms
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(L10n.of(context).forward),
                  ),
                ),
              ),
      ),
    );
  }
}
