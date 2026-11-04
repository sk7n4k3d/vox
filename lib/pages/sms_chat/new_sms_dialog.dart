import 'package:fluffychat/config/design_tokens.dart';
import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/utils/platform_infos.dart';
import 'package:fluffychat/utils/sms/sms_bridge.dart';
import 'package:fluffychat/utils/webhook/webhook_event.dart'
    show normalizeSmsAddress;
import 'package:fluffychat/pages/sms_chat/sms_chat_page.dart';
import 'package:fluffychat/widgets/cyber/cyber_widgets.dart';
import 'package:fluffychat/widgets/matrix.dart';
import 'package:flutter/material.dart';

/// Nouvelle conversation SMS/MMS à la volée : saisie du numéro destinataire.
/// Utilisé en mode SMS/MMS seul (pas d'onboarding Matrix) là où le FAB et le
/// bouton « nouvelle discussion » ouvriraient sinon la sélection de salons
/// Matrix, vide sans compte.
class NewSmsDialog extends StatefulWidget {
  const NewSmsDialog({super.key});

  static bool smsOnlyModeActive(BuildContext context) =>
      PlatformInfos.isAndroid &&
      AppSettings.smsOnlyMode.value &&
      !Matrix.of(context).widget.clients.any((client) => client.isLogged());

  /// Ouvre [SmsChatPage] sur un fil vierge : threadId '-1', numéro saisi.
  /// Les messages échangés ensuite rejoignent le fil natif standard.
  static Future<void> openCompose(BuildContext context) async {
    final number = await showAdaptiveDialog<String>(
      context: context,
      builder: (dialogContext) => const NewSmsDialog(),
    );
    if (number == null || number.isEmpty || !context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SmsChatPage(threadId: '-1', address: number),
      ),
    );
  }

  @override
  State<NewSmsDialog> createState() => _NewSmsDialogState();
}

/// Bandeau d'accueil du mode SMS/MMS seul : demande le rôle d'app SMS
/// par défaut (sans lui, rien ne rentre), sinon explique comment démarrer.
class SmsOnlySetupBanner extends StatefulWidget {
  const SmsOnlySetupBanner({super.key});

  @override
  State<SmsOnlySetupBanner> createState() => _SmsOnlySetupBannerState();
}

class _SmsOnlySetupBannerState extends State<SmsOnlySetupBanner> {
  bool? _isDefault;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final isDefault = await SmsBridge.instance.isDefaultSmsApp();
    if (mounted) setState(() => _isDefault = isDefault);
  }

  @override
  Widget build(BuildContext context) {
    final isDefault = _isDefault;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
      child: CyberGlass(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.sms_outlined,
                  color: CyberColors.of(context).cyan,
                  semanticLabel: null,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Mode SMS/MMS',
                    style: FluffyTypography.title.copyWith(
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              isDefault == null
                  ? 'Vérification du rôle SMS…'
                  : isDefault
                  ? 'VoxOne est prêt : tes conversations SMS et MMS '
                        'apparaîtront ici. Appuie sur Stylo pour écrire à un '
                        'nouveau numéro.'
                  : 'Pour recevoir et envoyer des SMS, VoxOne doit devenir '
                        'ton application SMS par défaut.',
              style: FluffyTypography.bodyM.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            if (isDefault == false) ...[
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: () async {
                  await SmsBridge.instance.requestDefaultSmsRole();
                  await _refresh();
                },
                icon: const Icon(Icons.verified_outlined),
                label: const Text('Définir comme app SMS par défaut'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _NewSmsDialogState extends State<NewSmsDialog> {
  final TextEditingController _number = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _number.dispose();
    super.dispose();
  }

  void _submit() {
    final value = _number.text.trim();
    final normalized = normalizeSmsAddress(value);
    if (!RegExp(r'^\+\d{6,15}$').hasMatch(normalized)) {
      setState(() => _error = 'Numéro invalide');
      return;
    }
    Navigator.of(context).pop(normalized);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog.adaptive(
      title: const Text('Nouveau SMS'),
      content: TextField(
        controller: _number,
        autofocus: true,
        keyboardType: TextInputType.phone,
        inputFormatters: const [],
        decoration: InputDecoration(
          labelText: 'Numéro du destinataire',
          hintText: '06 12 34 56 78 ou +33 6 12 34 56 78',
          errorText: _error,
          border: const OutlineInputBorder(),
        ),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Annuler'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Écrire')),
      ],
    );
  }
}
