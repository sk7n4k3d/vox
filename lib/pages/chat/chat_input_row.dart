import 'package:emoji_picker_flutter/locales/default_emoji_set_locale.dart';
import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/pages/chat/composer/attach_menu_sheet.dart';
import 'package:fluffychat/pages/chat/composer/morphing_send_button.dart';
import 'package:fluffychat/pages/chat/recording_input_row.dart';
import 'package:fluffychat/pages/chat/recording_view_model.dart';
import 'package:fluffychat/pages/chat/voice_record_button.dart';
import 'package:fluffychat/pages/chat/voice_record_gesture_state.dart';
import 'package:fluffychat/pages/chat/voice_recording_overlay.dart';
import 'package:fluffychat/utils/ephemeral/ephemeral_messages.dart';
import 'package:fluffychat/utils/other_party_can_receive.dart';
import 'package:fluffychat/utils/platform_infos.dart';
import 'package:fluffychat/utils/scheduled/scheduled_messages.dart';
import 'package:fluffychat/utils/screen_effects/screen_effect.dart';
import 'package:fluffychat/widgets/avatar.dart';
import 'package:fluffychat/widgets/cyber/ephemeral_picker.dart';
import 'package:fluffychat/widgets/cyber/frosted_composer_surface.dart';
import 'package:fluffychat/widgets/cyber/scheduled_send.dart';
import 'package:fluffychat/widgets/cyber/screen_effect_overlay.dart';
import 'package:fluffychat/widgets/matrix.dart';
import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';

import '../../config/themes.dart';
import 'chat.dart';
import 'input_bar.dart';

class ChatInputRow extends StatefulWidget {
  final ChatController controller;

  static const double height = 56.0;

  const ChatInputRow(this.controller, {super.key});

  @override
  State<ChatInputRow> createState() => _ChatInputRowState();
}

class _ChatInputRowState extends State<ChatInputRow> {
  final ValueNotifier<VoiceRecordGestureState> _gestureNotifier =
      ValueNotifier(VoiceRecordGestureState.zero);

  /// Pilote le glow cyan de la pilule frosted glass selon le focus du champ.
  final ValueNotifier<bool> _focused = ValueNotifier(false);

  ChatController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    controller.inputFocus.addListener(_onFocusChange);
  }

  void _onFocusChange() => _focused.value = controller.inputFocus.hasFocus;

  /// Long-press sur le bouton emoji : choisir un effet plein écran → insère son
  /// emoji déclencheur dans le composer (la détection locale jouera l'effet à
  /// l'envoi, chez l'expéditeur ET le destinataire).
  Future<void> _pickScreenEffect() async {
    final effect = await showScreenEffectPicker(context);
    if (effect == null || !mounted) return;
    final c = controller.sendController;
    final sep = c.text.isEmpty ? '' : ' ';
    c.text = '${c.text}$sep${effect.emoji}';
    c.selection = TextSelection.collapsed(offset: c.text.length);
    controller.inputFocus.requestFocus();
  }

  @override
  void dispose() {
    controller.inputFocus.removeListener(_onFocusChange);
    _focused.dispose();
    _gestureNotifier.dispose();
    super.dispose();
  }

  /// Long-press on the send button: pick a date+time and queue the typed text
  /// for later delivery instead of sending it now. No-op on empty text.
  Future<void> _scheduleSend() async {
    final body = controller.sendController.text.trim();
    if (body.isEmpty) return;
    final when = await ScheduledSend.pickDateTime(context);
    if (when == null || !mounted) return;
    final sendAt = when.millisecondsSinceEpoch;
    await ScheduledMessages.instance.schedule(
      ScheduledMessage(
        id: ScheduledSend.nextId(sendAt: sendAt, body: body),
        body: body,
        sendAt: sendAt,
        roomId: controller.room.id,
      ),
    );
    if (!mounted) return;
    controller.sendController.clear();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Message programmé pour ${ScheduledSend.formatWhen(when)}'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final textMessageOnly =
        controller.sendController.text.isNotEmpty ||
        controller.replyEvent != null ||
        controller.editEvent != null;

    if (!controller.room.otherPartyCanReceiveMessages) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(12.0),
          child: Text(
            L10n.of(context).otherPartyNotLoggedIn,
            style: theme.textTheme.bodySmall,
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    final selectedTextButtonStyle = TextButton.styleFrom(
      foregroundColor: theme.colorScheme.onTertiaryContainer,
    );

    return RecordingViewModel(
      builder: (context, recordingViewModel) {
        Widget content;
        if (recordingViewModel.isRecording && recordingViewModel.isLocked) {
          content = RecordingInputRow(
            state: recordingViewModel,
            onSend: controller.onVoiceMessageSend,
          );
        } else {
          content = _buildEditRow(
            context,
            recordingViewModel,
            theme,
            textMessageOnly,
            selectedTextButtonStyle,
          );
        }
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            VoiceRecordingOverlay(
              state: recordingViewModel,
              gestureNotifier: _gestureNotifier,
            ),
            ScheduledBanner(
              selector: () =>
                  ScheduledMessages.instance.forRoom(controller.room.id),
            ),
            content,
          ],
        );
      },
    );
  }

  Widget _buildEditRow(
    BuildContext context,
    RecordingViewModelState recordingViewModel,
    ThemeData theme,
    bool textMessageOnly,
    ButtonStyle selectedTextButtonStyle,
  ) {
    return Row(
          crossAxisAlignment: .end,
          mainAxisAlignment: .spaceBetween,
          children: controller.selectMode
              ? <Widget>[
                  if (controller.selectedEvents.every(
                    (event) => event.status == EventStatus.error,
                  ))
                    SizedBox(
                      height: ChatInputRow.height,
                      child: TextButton(
                        style: TextButton.styleFrom(
                          foregroundColor: theme.colorScheme.error,
                        ),
                        onPressed: controller.deleteErrorEventsAction,
                        child: Row(
                          children: <Widget>[
                            const Icon(Icons.delete_forever_outlined),
                            Text(L10n.of(context).delete),
                          ],
                        ),
                      ),
                    )
                  else
                    SizedBox(
                      height: ChatInputRow.height,
                      child: TextButton(
                        style: selectedTextButtonStyle,
                        onPressed: controller.forwardEventsAction,
                        child: Row(
                          children: <Widget>[
                            const Icon(Icons.keyboard_arrow_left_outlined),
                            Text(L10n.of(context).forward),
                          ],
                        ),
                      ),
                    ),
                  controller.selectedEvents.length == 1
                      ? controller.selectedEvents.first
                                .getDisplayEvent(controller.timeline!)
                                .status
                                .isSent
                            ? SizedBox(
                                height: ChatInputRow.height,
                                child: TextButton(
                                  style: selectedTextButtonStyle,
                                  onPressed: controller.replyAction,
                                  child: Row(
                                    children: <Widget>[
                                      Text(L10n.of(context).reply),
                                      const Icon(Icons.keyboard_arrow_right),
                                    ],
                                  ),
                                ),
                              )
                            : SizedBox(
                                height: ChatInputRow.height,
                                child: TextButton(
                                  style: selectedTextButtonStyle,
                                  onPressed: controller.sendAgainAction,
                                  child: Row(
                                    children: <Widget>[
                                      Text(L10n.of(context).tryToSendAgain),
                                      const SizedBox(width: 4),
                                      const Icon(Icons.send_outlined, size: 16),
                                    ],
                                  ),
                                ),
                              )
                      : const SizedBox.shrink(),
                ]
              : <Widget>[
                  const SizedBox(width: 8),
                  Expanded(
                    child: ValueListenableBuilder<bool>(
                      valueListenable: _focused,
                      builder: (context, focused, _) => FrostedComposerSurface(
                        focused: focused,
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            IconButton(
                              tooltip: L10n.of(context).more,
                              color: theme.colorScheme.onPrimaryContainer,
                              icon: const Icon(Icons.add_circle_outline),
                              onPressed: () async {
                                final action = await showAttachMenu(
                                  context,
                                  isMobile: PlatformInfos.isMobile,
                                );
                                if (action != null) {
                                  controller.onAddPopupMenuButtonSelected(
                                    action,
                                  );
                                }
                              },
                            ),
                            if (Matrix.of(context).isMultiAccount &&
                                Matrix.of(context).hasComplexBundles &&
                                Matrix.of(context).currentBundle!.length > 1)
                              SizedBox(
                                width: 40,
                                child: _ChatAccountPicker(controller),
                              ),
                            _EphemeralIndicator(controller: controller),
                            Expanded(
                              child: Padding(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 2.0),
                                child: InputBar(
                                  room: controller.room,
                                  minLines: 1,
                                  maxLines: 8,
                                  autofocus: !PlatformInfos.isMobile,
                                  keyboardType: TextInputType.multiline,
                                  textInputAction:
                                      AppSettings.sendOnEnter.value == true &&
                                              PlatformInfos.isMobile
                                          ? TextInputAction.send
                                          : null,
                                  onSubmitted: controller.onInputBarSubmitted,
                                  onSubmitImage:
                                      controller.sendImageFromClipBoard,
                                  focusNode: controller.inputFocus,
                                  controller: controller.sendController,
                                  decoration: InputDecoration(
                                    contentPadding: const EdgeInsets.only(
                                      left: 6.0,
                                      right: 6.0,
                                      bottom: 6.0,
                                      top: 3.0,
                                    ),
                                    counter: const SizedBox.shrink(),
                                    hintText: L10n.of(context).writeAMessage,
                                    hintMaxLines: 1,
                                    border: InputBorder.none,
                                    enabledBorder: InputBorder.none,
                                    filled: false,
                                  ),
                                  onChanged: controller.onInputBarChanged,
                                  suggestionEmojis: getDefaultEmojiLocale(
                                    AppSettings.emojiSuggestionLocale.value
                                            .isNotEmpty
                                        ? Locale(
                                            AppSettings
                                                .emojiSuggestionLocale.value,
                                          )
                                        : Localizations.localeOf(context),
                                  ).fold(
                                    [],
                                    (emojis, category) =>
                                        emojis..addAll(category.emoji),
                                  ),
                                ),
                              ),
                            ),
                            GestureDetector(
                              onLongPress: _pickScreenEffect,
                              child: IconButton(
                                tooltip: L10n.of(context).emojis,
                                color: theme.colorScheme.onPrimaryContainer,
                                icon: Icon(
                                  controller.showEmojiPicker
                                      ? Icons.keyboard
                                      : Icons.add_reaction_outlined,
                                  key: ValueKey(controller.showEmojiPicker),
                                ),
                                onPressed: controller.emojiPickerAction,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  // Léger retrait bas : la pilule frosted glass a un padding
                  // interne (vertical:4) qui remonte son contenu ; sans ça le
                  // bouton détaché 48px aligné en bas (.end) tombe un poil plus
                  // bas que le centre visuel de la pilule.
                  Padding(
                    padding: const EdgeInsets.only(bottom: 7),
                    child: MorphingSendButton(
                      hasText: textMessageOnly,
                      backgroundColor: theme.bubbleColor,
                      foregroundColor: theme.onBubbleColor,
                      onSend: controller.send,
                      onScheduleSend: _scheduleSend,
                    micBuilder: (context) =>
                        PlatformInfos.platformCanRecord &&
                                !controller.sendController.text.isNotEmpty &&
                                controller.editEvent == null
                            ? VoiceRecordButton(
                                controller: controller,
                                recordingState: recordingViewModel,
                                gestureNotifier: _gestureNotifier,
                                backgroundColor: theme.bubbleColor,
                                foregroundColor: theme.onBubbleColor,
                              )
                            : IconButton(
                                key: const Key('send_button'),
                                tooltip: L10n.of(context).send,
                                onPressed: controller.send,
                                style: IconButton.styleFrom(
                                  backgroundColor: theme.bubbleColor,
                                  foregroundColor: theme.onBubbleColor,
                                ),
                                icon: const Icon(Icons.send_outlined),
                              ),
                    ),
                  ),
                  const SizedBox(width: 6),
                ],
        );
  }
}

/// Compact timer chip shown in the composer when disappearing messages are
/// active for the room (or a per-message override is armed). Tapping it sets a
/// one-shot override for the next message; long-pressing edits the room policy.
class _EphemeralIndicator extends StatelessWidget {
  final ChatController controller;
  const _EphemeralIndicator({required this.controller});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: EphemeralMessages.instance,
      builder: (context, _) {
        final policy =
            EphemeralMessages.instance.policyFor(controller.room.id);
        final override = controller.pendingEphemeralOverride;
        final effective = override ?? policy;
        if (!effective.isActive) return const SizedBox.shrink();
        final theme = Theme.of(context);
        return Padding(
          padding: const EdgeInsets.only(bottom: 8.0),
          child: Tooltip(
            message: EphemeralPicker.label(context, effective),
            child: InkResponse(
              onTap: controller.editEphemeralOverride,
              onLongPress: controller.editEphemeralPolicy,
              radius: 22,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: theme.bubbleColor.withValues(
                    alpha: override != null ? 0.30 : 0.18,
                  ),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(
                    color: theme.bubbleColor.withValues(alpha: 0.5),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.timer,
                      size: 14,
                      color: theme.bubbleColor,
                    ),
                    const SizedBox(width: 3),
                    Text(
                      _shortLabel(context, effective),
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: theme.bubbleColor,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  String _shortLabel(BuildContext context, EphemeralDuration d) {
    switch (d) {
      case EphemeralDuration.off:
        return '';
      case EphemeralDuration.afterRead:
        return '👁';
      case EphemeralDuration.seconds30:
        return '30s';
      case EphemeralDuration.minutes5:
        return '5m';
      case EphemeralDuration.hour1:
        return '1h';
      case EphemeralDuration.day1:
        return '1j';
      case EphemeralDuration.week1:
        return '1sem';
    }
  }
}

class _ChatAccountPicker extends StatelessWidget {
  final ChatController controller;

  const _ChatAccountPicker(this.controller);

  void _popupMenuButtonSelected(String mxid, BuildContext context) {
    final client = Matrix.of(
      context,
    ).currentBundle!.firstWhere((cl) => cl!.userID == mxid, orElse: () => null);
    if (client == null) {
      Logs().w('Attempted to switch to a non-existing client $mxid');
      return;
    }
    controller.setSendingClient(client);
  }

  @override
  Widget build(BuildContext context) {
    final clients = controller.currentRoomBundle;
    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: FutureBuilder<Profile>(
        future: controller.sendingClient.fetchOwnProfile(),
        builder: (context, snapshot) => PopupMenuButton<String>(
          useRootNavigator: true,
          onSelected: (mxid) => _popupMenuButtonSelected(mxid, context),
          itemBuilder: (BuildContext context) => clients
              .map(
                (client) => PopupMenuItem(
                  value: client!.userID,
                  child: FutureBuilder<Profile>(
                    future: client.fetchOwnProfile(),
                    builder: (context, snapshot) => ListTile(
                      leading: Avatar(
                        mxContent: snapshot.data?.avatarUrl,
                        name:
                            snapshot.data?.displayName ??
                            client.userID!.localpart,
                        size: 20,
                      ),
                      title: Text(snapshot.data?.displayName ?? client.userID!),
                      contentPadding: const EdgeInsets.all(0),
                    ),
                  ),
                ),
              )
              .toList(),
          child: Avatar(
            mxContent: snapshot.data?.avatarUrl,
            name:
                snapshot.data?.displayName ??
                Matrix.of(context).client.userID!.localpart,
            size: 20,
          ),
        ),
      ),
    );
  }
}
