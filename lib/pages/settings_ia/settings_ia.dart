import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/utils/llm/llm_client.dart';
import 'package:flutter/material.dart';

import 'settings_ia_view.dart';

enum LlmTestStatus { idle, loading, success, error }

class SettingsIa extends StatefulWidget {
  const SettingsIa({super.key});

  @override
  SettingsIaController createState() => SettingsIaController();
}

class SettingsIaController extends State<SettingsIa> {
  bool get enabled => AppSettings.llmEnabled.value;

  late final TextEditingController urlController = TextEditingController(
    text: AppSettings.llmBaseUrl.value,
  );
  late final TextEditingController keyController = TextEditingController(
    text: AppSettings.llmApiKey.value,
  );
  late final TextEditingController modelController = TextEditingController(
    text: AppSettings.llmModel.value,
  );

  bool obscureKey = true;

  LlmTestStatus testStatus = LlmTestStatus.idle;
  String? testMessage;
  List<String> availableModels = const [];

  static const List<String> suggestedModels = [
    'qwen3.5-titan1-16x',
    'ornith1.5-titan1-4x',
    'ornith1.5-titan2-4x',
  ];

  @override
  void initState() {
    super.initState();
    urlController.addListener(_persistUrl);
    keyController.addListener(_persistKey);
    modelController.addListener(_persistModel);
  }

  @override
  void dispose() {
    urlController.removeListener(_persistUrl);
    keyController.removeListener(_persistKey);
    modelController.removeListener(_persistModel);
    urlController.dispose();
    keyController.dispose();
    modelController.dispose();
    super.dispose();
  }

  void _persistUrl() => AppSettings.llmBaseUrl.setItem(urlController.text.trim());

  void _persistKey() {
    AppSettings.llmApiKey.setItem(keyController.text.trim());
    if (mounted) setState(() {});
  }

  void _persistModel() =>
      AppSettings.llmModel.setItem(modelController.text.trim());

  void toggleObscureKey() => setState(() => obscureKey = !obscureKey);

  Future<void> toggleEnabled(bool value) async {
    await AppSettings.llmEnabled.setItem(value);
    if (mounted) setState(() {});
  }

  void useModel(String model) {
    modelController.text = model;
    setState(() {});
  }

  Future<void> testConnection() async {
    final key = keyController.text.trim();
    if (key.isEmpty) return;
    setState(() {
      testStatus = LlmTestStatus.loading;
      testMessage = null;
    });
    try {
      final models = await LlmClient(
        baseUrl: urlController.text.trim(),
        apiKey: key,
        model: modelController.text.trim(),
      ).fetchModels();
      if (!mounted) return;
      setState(() {
        testStatus = LlmTestStatus.success;
        testMessage = 'Connexion OK — ${models.length} modèles disponibles';
        availableModels = models.map((m) => m.id).toList();
      });
    } on LlmException catch (e) {
      if (!mounted) return;
      setState(() {
        testStatus = LlmTestStatus.error;
        testMessage = e.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        testStatus = LlmTestStatus.error;
        testMessage = 'Serveur injoignable';
      });
    }
  }

  @override
  Widget build(BuildContext context) => SettingsIaView(this);
}
