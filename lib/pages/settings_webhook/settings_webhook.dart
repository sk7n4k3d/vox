import 'dart:async';

import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/utils/sms/sms_bridge.dart';
import 'package:fluffychat/utils/webhook/webhook_calls.dart';
import 'package:fluffychat/utils/webhook/webhook_event.dart';
import 'package:fluffychat/utils/webhook/webhook_queue.dart';
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
  Set<String> excludedRooms = <String>{};
  Set<String> smsThreads = <String>{};
  Set<String> excludedSmsThreads = <String>{};
  List<SmsConversation> smsConversations = const <SmsConversation>[];
  bool smsAll = AppSettings.webhookSmsAll.value;
  bool matrixAll = AppSettings.webhookMatrixAll.value;
  bool smsNewDefault = AppSettings.webhookSmsNew.value;
  bool matrixNewDefault = AppSettings.webhookMatrixNew.value;

  final TextEditingController attemptsController = TextEditingController(
    text: '${AppSettings.webhookRetryAttempts.value}',
  );
  final TextEditingController backoffController = TextEditingController(
    text: '${AppSettings.webhookRetryBackoffS.value}',
  );
  final TextEditingController ttlController = TextEditingController(
    text: '${AppSettings.webhookRetryTtlH.value}',
  );
  bool retryEnabled = AppSettings.webhookRetryEnabled.value;
  bool wifiOnly = AppSettings.webhookWifiOnly.value;
  bool callsEnabled = AppSettings.webhookCallsEnabled.value;

  /// Options avancées : seulement sur GrapheneOS avec l'app Téléphone d'origine
  /// (c'est elle qui enregistre les appels).
  bool grapheneOs = false;
  String? dialerPackage;
  bool recordingsEnabled = AppSettings.webhookRecordings.value;
  int recordingCount = 0;

  bool get advancedAvailable =>
      grapheneOs && dialerPackage == 'com.android.dialer';

  /// Message affiché sous l'interrupteur des appels (permission refusée…).
  String? callsHint;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final secret = await WebhookStore.instance.loadSecret();
    final saved = await WebhookStore.instance.loadRooms();
    final savedExcluded = await WebhookStore.instance.loadExcludedRooms();
    final savedSms = await WebhookStore.instance.loadSmsThreads();
    final savedSmsExcluded =
        await WebhookStore.instance.loadExcludedSmsThreads();
    var conversations = const <SmsConversation>[];
    try {
      conversations = await SmsBridge.instance.listConversations();
    } catch (_) {}
    var graphene = false;
    String? dialer;
    var recordings = 0;
    try {
      graphene = await SmsBridge.instance.isGrapheneOs();
      dialer = await SmsBridge.instance.defaultDialerPackage();
      if (graphene) {
        recordings = (await SmsBridge.instance.listCallRecordings()).length;
      }
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      secretController.text = secret;
      rooms = saved;
      excludedRooms = savedExcluded;
      smsThreads = savedSms;
      excludedSmsThreads = savedSmsExcluded;
      smsConversations = conversations;
      grapheneOs = graphene;
      dialerPackage = dialer;
      recordingCount = recordings;
    });
  }

  Future<void> toggleEnabled(bool value) async {
    await AppSettings.webhookEnabled.setItem(value);
    if (!mounted) return;
    setState(() => enabled = value);
  }

  void toggleSecretVisibility() =>
      setState(() => obscureSecret = !obscureSecret);

  Future<void> toggleSmsAll(bool value) async {
    await AppSettings.webhookSmsAll.setItem(value);
    if (!mounted) return;
    setState(() => smsAll = value);
  }

  Future<void> toggleMatrixAll(bool value) async {
    await AppSettings.webhookMatrixAll.setItem(value);
    if (!mounted) return;
    setState(() => matrixAll = value);
  }

  /// Interrupteur « une nouvelle conversation part par défaut ».
  Future<void> toggleSmsNewDefault(bool value) async {
    await AppSettings.webhookSmsNew.setItem(value);
    if (!mounted) return;
    setState(() => smsNewDefault = value);
  }

  Future<void> toggleMatrixNewDefault(bool value) async {
    await AppSettings.webhookMatrixNew.setItem(value);
    if (!mounted) return;
    setState(() => matrixNewDefault = value);
  }

  /// File de retry des POST ratés : interrupteur, bornes, et « Wi-Fi seulement ».
  Future<void> toggleRetryEnabled(bool value) async {
    await AppSettings.webhookRetryEnabled.setItem(value);
    if (!mounted) return;
    setState(() => retryEnabled = value);
  }

  Future<void> toggleWifiOnly(bool value) async {
    await AppSettings.webhookWifiOnly.setItem(value);
    if (!mounted) return;
    setState(() => wifiOnly = value);
  }

  void onAttemptsChanged(String value) {
    final n = int.tryParse(value.trim());
    if (n == null || n < 1 || n > 50) return;
    unawaited(AppSettings.webhookRetryAttempts.setItem(n));
  }

  void onBackoffChanged(String value) {
    final n = int.tryParse(value.trim());
    if (n == null || n < 5 || n > 3600) return;
    unawaited(AppSettings.webhookRetryBackoffS.setItem(n));
  }

  void onTtlChanged(String value) {
    final n = int.tryParse(value.trim());
    if (n == null || n < 1 || n > 720) return;
    unawaited(AppSettings.webhookRetryTtlH.setItem(n));
  }

  /// Bouton « Réessayer » : force l'envoi même si le backoff n'est pas écoulé.
  Future<void> flushQueue() => WebhookQueue.instance.flush(force: true);

  Future<void> clearQueue() => WebhookQueue.instance.clear();

  /// Journal d'appels : activer demande la permission READ_CALL_LOG, puis lance
  /// le premier import (48 h) pour que les appels passés comptent.
  Future<void> toggleCalls(bool value) async {
    if (!value) {
      await AppSettings.webhookCallsEnabled.setItem(false);
      if (!mounted) return;
      setState(() {
        callsEnabled = false;
        callsHint = null;
      });
      return;
    }
    var granted = await SmsBridge.instance.isCallLogGranted();
    if (!granted) {
      await SmsBridge.instance.requestCallLogPermission();
      // La réponse système arrive de façon asynchrone : on sonde un peu.
      for (var i = 0; i < 20 && !granted; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        granted = await SmsBridge.instance.isCallLogGranted();
      }
    }
    if (!mounted) return;
    if (!granted) {
      setState(
        () => callsHint =
            'Permission refusée : autorise « Appels » pour VOX dans les '
            'réglages Android, puis réessaie.',
      );
      return;
    }
    await AppSettings.webhookCallsEnabled.setItem(true);
    WebhookCalls.instance.start();
    if (!mounted) return;
    setState(() {
      callsEnabled = true;
      callsHint = null;
    });
    unawaited(WebhookCalls.instance.sync());
  }

  Future<void> syncCallsNow() => WebhookCalls.instance.sync();

  /// Enregistrements d'appels (GrapheneOS) : archivés côté Hermes, jamais purgés.
  Future<void> toggleRecordings(bool value) async {
    await AppSettings.webhookRecordings.setItem(value);
    if (!mounted) return;
    setState(() => recordingsEnabled = value);
    if (value) unawaited(WebhookCalls.instance.sync());
  }

  Future<void> syncRecordingsNow() async {
    await WebhookCalls.instance.sync();
    final recordings = await SmsBridge.instance.listCallRecordings();
    if (!mounted) return;
    setState(() => recordingCount = recordings.length);
  }

  /// La conversation part-elle ? Même règle que celle appliquée aux messages.
  bool isRoomSent(String roomId) => isRoomAllowed(
        rooms,
        roomId,
        all: matrixAll,
        newDefault: matrixNewDefault,
        excluded: excludedRooms,
      );

  bool isSmsSent(String threadId) => isSmsThreadAllowed(
        smsThreads,
        threadId,
        all: smsAll,
        newDefault: smsNewDefault,
        excluded: excludedSmsThreads,
      );

  void onUrlChanged(String value) =>
      unawaited(AppSettings.webhookUrl.setItem(value.trim()));

  Future<void> onSecretChanged(String value) =>
      WebhookStore.instance.saveSecret(value.trim());

  Future<void> toggleRoom(String roomId, bool selected) async {
    setState(() {
      if (selected) {
        rooms.add(roomId);
        excludedRooms.remove(roomId);
      } else {
        rooms.remove(roomId);
        excludedRooms.add(roomId);
      }
    });
    await WebhookStore.instance.saveRooms(rooms);
    await WebhookStore.instance.saveExcludedRooms(excludedRooms);
    WebhookService.instance.invalidateFilters();
  }

  Future<void> toggleSmsThread(String threadId, bool selected) async {
    setState(() {
      if (selected) {
        smsThreads.add(threadId);
        excludedSmsThreads.remove(threadId);
      } else {
        smsThreads.remove(threadId);
        excludedSmsThreads.add(threadId);
      }
    });
    await WebhookStore.instance.saveSmsThreads(smsThreads);
    await WebhookStore.instance.saveExcludedSmsThreads(excludedSmsThreads);
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
    attemptsController.dispose();
    backoffController.dispose();
    ttlController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SettingsWebhookView(this);
}
