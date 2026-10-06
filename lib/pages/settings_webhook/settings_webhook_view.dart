import 'package:fluffychat/config/cyberpunk_theme_extension.dart';
import 'package:fluffychat/config/design_tokens.dart';
import 'package:fluffychat/utils/webhook/webhook_service.dart';
import 'package:fluffychat/widgets/cyber/cyber_fx.dart';
import 'package:fluffychat/widgets/cyber/cyber_widgets.dart';
import 'package:fluffychat/widgets/layouts/max_width_body.dart';
import 'package:flutter/material.dart';

import 'settings_webhook.dart';

class SettingsWebhookView extends StatelessWidget {
  final SettingsWebhookController controller;

  const SettingsWebhookView(this.controller, {super.key});

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
        title: const CyberGlitchText('Webhook'),
      ),
      body: MaxWidthBody(
        // MaxWidthBody fournit deja le SingleChildScrollView (un ListView
        // imbrique recevrait une hauteur infinie).
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: FluffySpacing.lg),
              child: CyberGlass(
                padding: const EdgeInsets.symmetric(
                  vertical: FluffySpacing.xs,
                ),
                child: CyberSettingsTile(
                  icon: Icons.webhook_outlined,
                  accent: cyber.cyan,
                  title: 'Activer le webhook',
                  subtitle: 'POST signé (HMAC) à chaque message SMS/MMS/Matrix',
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
              padding: const EdgeInsets.symmetric(horizontal: FluffySpacing.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const _FieldLabel('URL du webhook'),
                  CyberField(
                    child: TextField(
                      controller: controller.urlController,
                      keyboardType: TextInputType.url,
                      autocorrect: false,
                      decoration: const InputDecoration(
                        border: InputBorder.none,
                        hintText: 'https://…',
                      ),
                      onChanged: controller.onUrlChanged,
                    ),
                  ),
                  const SizedBox(height: FluffySpacing.lg),
                  const _FieldLabel('Secret HMAC'),
                  CyberField(
                    child: TextField(
                      controller: controller.secretController,
                      obscureText: controller.obscureSecret,
                      autocorrect: false,
                      enableSuggestions: false,
                      decoration: InputDecoration(
                        border: InputBorder.none,
                        hintText: 'secret partagé avec Hermes',
                        suffixIcon: IconButton(
                          icon: Icon(
                            controller.obscureSecret
                                ? Icons.visibility_outlined
                                : Icons.visibility_off_outlined,
                          ),
                          onPressed: controller.toggleSecretVisibility,
                        ),
                      ),
                      onChanged: controller.onSecretChanged,
                    ),
                  ),
                  const SizedBox(height: FluffySpacing.sm),
                  Text(
                    'Signature générique V2 : en-têtes X-Webhook-Timestamp et '
                    'X-Webhook-Signature-V2 (hex HMAC-SHA256 de '
                    '« horodatage.corps »), le format que valide la plateforme '
                    'webhook de Hermes.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            CyberSectionHeader(
              'Conversations Matrix (${controller.rooms.length} cochée'
              '${controller.rooms.length > 1 ? 's' : ''})',
              accent: cyber.cyan,
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: FluffySpacing.lg),
              child: CyberGlass(
                padding: const EdgeInsets.symmetric(
                  vertical: FluffySpacing.xs,
                ),
                child: Column(
                  children: _roomTiles(controller, cyber),
                ),
              ),
            ),
            CyberSectionHeader('Vérification', accent: cyber.violet),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: FluffySpacing.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ValueListenableBuilder<WebhookStats>(
                    valueListenable: WebhookService.instance.stats,
                    builder: (context, stats, _) => Text(
                      '${stats.sent} envoyé(s), ${stats.failed} échec(s)'
                      '${stats.lastError != null ? ' — ${stats.lastError}' : ''}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  const SizedBox(height: FluffySpacing.sm),
                  OutlinedButton.icon(
                    onPressed: controller.sendTest,
                    icon: const Icon(Icons.send_outlined),
                    label: const Text('Envoyer un événement de test'),
                  ),
                  const SizedBox(height: FluffySpacing.lg),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Une ligne par room rejointe : cochée = ses messages partent au webhook.
  List<Widget> _roomTiles(
    SettingsWebhookController controller,
    CyberpunkTheme cyber,
  ) {
    final rooms = controller.availableRooms;
    if (rooms.isEmpty) {
      return const [
        Padding(
          padding: EdgeInsets.all(FluffySpacing.md),
          child: Text('Aucune conversation Matrix'),
        ),
      ];
    }
    return rooms
        .map(
          (room) => CheckboxListTile.adaptive(
            dense: true,
            value: controller.rooms.contains(room.id),
            activeColor: cyber.cyan,
            title: Text(
              room.getLocalizedDisplayname(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            onChanged: (v) => controller.toggleRoom(room.id, v == true),
          ),
        )
        .toList();
  }
}

class _FieldLabel extends StatelessWidget {
  final String label;

  const _FieldLabel(this.label);

  @override
  Widget build(BuildContext context) => Padding(
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
