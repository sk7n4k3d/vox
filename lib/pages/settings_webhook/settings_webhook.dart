import 'dart:async';

import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/utils/sms/sms_bridge.dart';
import 'package:fluffychat/utils/webhook/webhook_service.dart';
import 'package:fluffychat/utils/webhook/webhook_store.dart';
import 'package:fluffychat/widgets/matrix.dart';
import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';

import 'settings_webhook_view.dart';

class SettingsWebhook extends StatefulWidget {
  const SettingsWebhook({super.key});

  @override
  SettingsWebhookController createState() => SettingsWebhookController();
}

class SettingsWebhookController extends State<SettingsWebhook> {
  final TextEditingController urlController =
      TextEditingController(text: AppSettings.webhookUrl.value);
  final TextEditingController secretController = TextEditingController();

  bool enabled = AppSettings.webhookEnabled.value;
  bool obscureSecret = true;
  Set<String> rooms = <String>{};
  Set<String> smsThreads = <String>{};
  List<SmsConversation> smsConversations = const <SmsConversation>[];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final secret = await WebhookStore.instance.loadSecret();
    final saved = await WebhookStore.instance.loadRooms();
    final savedSms = await WebhookStore.instance.loadSmsThreads();
    var conversations = const <SmsConversation>[];
    try {
      conversations = await SmsBridge.instance.listConversations();
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      secretController.text = secret;
      rooms = saved;
      smsThreads = savedSms;
      smsConversations = conversations;
    });
  }

  Future<void> toggleEnabled(bool value) async {
    await AppSettings.webhookEnabled.setItem(value);
    if (!mounted) return;
    setState(() => enabled = value);
  }

  void toggleSecretVisibility() =>
      setState(() => obscureSecret = !obscureSecret);

  void onUrlChanged(String value) =>
      unawaited(AppSettings.webhookUrl.setItem(value.trim()));

  Future<void> onSecretChanged(String value) =>
      WebhookStore.instance.saveSecret(value.trim());

  Future<void> toggleRoom(String roomId, bool selected) async {
    setState(() {
      if (selected) {
        rooms.add(roomId);
      } else {
        rooms.remove(roomId);
      }
    });
    await WebhookStore.instance.saveRooms(rooms);
    WebhookService.instance.invalidateFilters();
  }

  Future<void> toggleSmsThread(String threadId, bool selected) async {
    setState(() {
      if (selected) {
        smsThreads.add(threadId);
      } else {
        smsThreads.remove(threadId);
      }
    });
    await WebhookStore.instance.saveSmsThreads(smsThreads);
    WebhookService.instance.invalidateFilters();
  }

  /// Rooms rejointes, triées par nom d'affichage.
  List<Room> get availableRooms {
    final list = Matrix.of(context).client.rooms.toList();
    list.sort(
      (a, b) => a
          .getLocalizedDisplayname()
          .toLowerCase()
          .compareTo(b.getLocalizedDisplayname().toLowerCase()),
    );
    return list;
  }

  Future<void> sendTest() => WebhookService.instance.sendTest();

  @override
  void dispose() {
    urlController.dispose();
    secretController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SettingsWebhookView(this);
}
