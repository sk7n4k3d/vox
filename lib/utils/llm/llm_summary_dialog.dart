import 'package:fluffychat/config/cyberpunk_theme_extension.dart';
import 'package:fluffychat/config/design_tokens.dart';
import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/utils/llm/llm_client.dart';
import 'package:fluffychat/utils/llm/llm_summary.dart';
import 'package:fluffychat/widgets/adaptive_dialogs/adaptive_dialog_action.dart';
import 'package:fluffychat/widgets/adaptive_dialogs/cyber_dialog_shell.dart';
import 'package:fluffychat/widgets/cyber/cyber_widgets.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// Point d'entrée unique des actions « Résumé IA ».
///
/// - Assistance désactivée ou clé vide → dialogue d'invitation vers les
///   réglages (aucun appel réseau).
/// - Sinon → dialogue glass avec état de chargement, puis résumé ou erreur.
/// Le traitement est asynchrone : l'UI n'est jamais bloquée.
Future<void> showLlmSummary({
  required BuildContext context,
  required String transcript,
}) async {
  if (!AppSettings.llmEnabled.value ||
      AppSettings.llmApiKey.value.trim().isEmpty) {
    await _showEnableDialog(context);
    return;
  }
  await showDialog<void>(
    context: context,
    builder: (context) => CyberDialogShell(
      child: _LlmSummaryDialog(transcript: transcript),
    ),
  );
}

Future<void> _showEnableDialog(BuildContext context) async {
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => CyberDialogShell(
      child: AlertDialog.adaptive(
        title: const Text('Résumé IA'),
        content: const Text(
          'Active l\'Assistance IA dans les réglages pour utiliser le résumé.',
        ),
        actions: [
          AdaptiveDialogAction(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Fermer'),
          ),
          AdaptiveDialogAction(
            onPressed: () {
              Navigator.of(dialogContext).pop();
              context.go('/rooms/settings/ia');
            },
            child: const Text('Réglages'),
          ),
        ],
      ),
    ),
  );
}

class _LlmSummaryDialog extends StatefulWidget {
  final String transcript;

  const _LlmSummaryDialog({required this.transcript});

  @override
  State<_LlmSummaryDialog> createState() => _LlmSummaryDialogState();
}

class _LlmSummaryDialogState extends State<_LlmSummaryDialog> {
  bool _loading = false;
  String? _summary;
  String? _error;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    final transcript = widget.transcript.trim();
    if (transcript.isEmpty) {
      setState(() => _error = 'Pas assez de messages à résumer.');
      return;
    }
    setState(() => _loading = true);
    try {
      final summary = await LlmClient.fromSettings().chat([
        {'role': 'system', 'content': kLlmSummarySystemPrompt},
        {'role': 'user', 'content': transcript},
      ]);
      if (!mounted) return;
      setState(() {
        _loading = false;
        _summary = summary;
      });
    } on LlmException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Serveur injoignable';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final cyber = CyberColors.of(context);
    return AlertDialog.adaptive(
      title: const Text('Résumé IA'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 320),
        child: _buildContent(cyber),
      ),
      actions: [
        AdaptiveDialogAction(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Fermer'),
        ),
      ],
    );
  }

  Widget _buildContent(CyberpunkTheme cyber) {
    if (_loading) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: cyber.cyan,
            ),
          ),
          const SizedBox(width: FluffySpacing.md),
          const Flexible(child: Text('Analyse de la conversation…')),
        ],
      );
    }
    if (_error != null) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline, color: cyber.magenta),
          const SizedBox(width: FluffySpacing.md),
          Flexible(child: Text(_error!)),
        ],
      );
    }
    return SelectableText(_summary ?? '');
  }
}
