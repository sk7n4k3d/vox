import 'package:fluffychat/config/design_tokens.dart';
import 'package:fluffychat/widgets/cyber/cyber_fx.dart';
import 'package:fluffychat/widgets/cyber/cyber_widgets.dart';
import 'package:fluffychat/widgets/layouts/max_width_body.dart';
import 'package:flutter/material.dart';

import 'settings_ia.dart';

class SettingsIaView extends StatelessWidget {
  final SettingsIaController controller;

  const SettingsIaView(this.controller, {super.key});

  @override
  Widget build(BuildContext context) {
    final cyber = CyberColors.of(context);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        centerTitle: false,
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: const Center(child: BackButton()),
        title: const CyberGlitchText('Assistance IA'),
      ),
      body: MaxWidthBody(
        // MaxWidthBody fournit deja le SingleChildScrollView : un ListView
        // imbrique recoit une hauteur infinie et ne rend rien (ecran vide).
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: FluffySpacing.lg,
              ),
              child: CyberGlass(
                padding: const EdgeInsets.symmetric(
                  vertical: FluffySpacing.xs,
                ),
                child: CyberSettingsTile(
                  icon: Icons.auto_awesome,
                  accent: cyber.cyan,
                  title: 'Activer l\'Assistance IA',
                  subtitle:
                      'Résume les conversations via un serveur compatible OpenAI',
                  trailing: Switch.adaptive(
                    value: controller.enabled,
                    activeThumbColor: cyber.cyan,
                    onChanged: controller.toggleEnabled,
                  ),
                  onTap: () => controller.toggleEnabled(!controller.enabled),
                ),
              ),
            ),
            CyberSectionHeader('Serveur', accent: cyber.violet),
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: FluffySpacing.lg,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const _FieldLabel('URL du serveur'),
                  CyberField(
                    child: TextField(
                      controller: controller.urlController,
                      keyboardType: TextInputType.url,
                      autocorrect: false,
                      decoration: const InputDecoration(
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        hintText: 'https://llm.sk7.sh/v1',
                      ),
                    ),
                  ),
                  const SizedBox(height: FluffySpacing.lg),
                  const _FieldLabel('Clé API'),
                  CyberField(
                    child: TextField(
                      controller: controller.keyController,
                      obscureText: controller.obscureKey,
                      keyboardType: TextInputType.visiblePassword,
                      autocorrect: false,
                      enableSuggestions: false,
                      decoration: InputDecoration(
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        hintText: 'sk-…',
                        suffixIcon: IconButton(
                          icon: Icon(
                            controller.obscureKey
                                ? Icons.visibility_outlined
                                : Icons.visibility_off_outlined,
                            color: cyber.cyan,
                          ),
                          onPressed: controller.toggleObscureKey,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: FluffySpacing.lg),
                  const _FieldLabel('Modèle'),
                  CyberField(
                    child: TextField(
                      controller: controller.modelController,
                      autocorrect: false,
                      decoration: const InputDecoration(
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        hintText: 'qwen3.5-titan1-16x',
                      ),
                    ),
                  ),
                  const SizedBox(height: FluffySpacing.md),
                  Wrap(
                    spacing: FluffySpacing.sm,
                    runSpacing: FluffySpacing.sm,
                    children: [
                      for (final model in SettingsIaController.suggestedModels)
                        ActionChip(
                          label: Text(model),
                          backgroundColor: cyber.glassFillLight,
                          side: BorderSide(color: cyber.glassBorder),
                          onPressed: () => controller.useModel(model),
                        ),
                    ],
                  ),
                  if (controller.availableModels.isNotEmpty) ...[
                    const SizedBox(height: FluffySpacing.md),
                    Text(
                      'Modèles détectés : '
                      '${controller.availableModels.join(', ')}',
                      style: FluffyTypography.bodyS.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                  const SizedBox(height: FluffySpacing.xl),
                  CyberPrimaryButton(
                    label: 'Tester la connexion',
                    icon: Icons.wifi_tethering,
                    loading: controller.testStatus == LlmTestStatus.loading,
                    onPressed: controller.keyController.text.trim().isEmpty
                        ? null
                        : controller.testConnection,
                  ),
                  if (controller.testMessage != null) ...[
                    const SizedBox(height: FluffySpacing.md),
                    _TestResultBanner(
                      success: controller.testStatus == LlmTestStatus.success,
                      message: controller.testMessage!,
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FieldLabel extends StatelessWidget {
  final String label;

  const _FieldLabel(this.label);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: FluffySpacing.sm),
      child: Text(
        label.toUpperCase(),
        style: FluffyTypography.labelM.copyWith(
          color: CyberColors.of(context).cyan,
          letterSpacing: 1.2,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _TestResultBanner extends StatelessWidget {
  final bool success;
  final String message;

  const _TestResultBanner({required this.success, required this.message});

  @override
  Widget build(BuildContext context) {
    final cyber = CyberColors.of(context);
    final accent = success ? cyber.success : cyber.magenta;
    return CyberGlass(
      tint: accent.withValues(alpha: 0.12),
      padding: const EdgeInsets.all(FluffySpacing.md),
      child: Row(
        children: [
          Icon(
            success ? Icons.check_circle_outline : Icons.error_outline,
            color: accent,
          ),
          const SizedBox(width: FluffySpacing.md),
          Expanded(
            child: Text(
              message,
              style: FluffyTypography.bodyM.copyWith(
                color: Theme.of(context).colorScheme.onSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
