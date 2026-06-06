import 'package:fluffychat/config/design_tokens.dart';
import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/utils/sms/sms_bridge.dart';
import 'package:fluffychat/widgets/cyber/cyber_widgets.dart';
import 'package:fluffychat/widgets/settings_switch_list_tile.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// SMS settings screen.
///
/// In release builds this is a clean settings page: it only shows whether VOX
/// is the default SMS app and lets the user request that role. The send/log/
/// conversation-dump test bench (which printed phone numbers and message
/// bodies in clear) is gated behind [kDebugMode] so no PII leaks in production.
class SmsTestPage extends StatefulWidget {
  const SmsTestPage({super.key});

  @override
  State<SmsTestPage> createState() => _SmsTestPageState();
}

class _SmsTestPageState extends State<SmsTestPage> with WidgetsBindingObserver {
  bool _isDefault = false;
  List<SmsConversation> _convs = const [];
  String _log = '';
  final _addr = TextEditingController();
  final _body = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
    // The clear-text incoming log is debug-only — never subscribe in release.
    if (kDebugMode) {
      SmsBridge.instance.incoming.listen((sms) {
        if (!mounted) return;
        setState(() => _log = '📩 ${sms.address}: ${sms.body}\n$_log');
        _refresh();
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _addr.dispose();
    _body.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    final isDefault = await SmsBridge.instance.isDefaultSmsApp();
    // Only the debug bench needs the full conversation dump; in release we keep
    // the list empty (the real SMS UI lives in the chat list).
    final convs = (kDebugMode && isDefault)
        ? await SmsBridge.instance.listConversations()
        : <SmsConversation>[];
    if (!mounted) return;
    setState(() {
      _isDefault = isDefault;
      _convs = convs;
    });
  }

  @override
  Widget build(BuildContext context) {
    final cyber = CyberColors.of(context);
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Text(kDebugMode ? 'SMS — banc de test' : 'SMS'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(FluffySpacing.lg),
        children: [
          CyberGlass(
            child: Row(
              children: [
                Icon(
                  _isDefault ? Icons.check_circle : Icons.error_outline,
                  color: _isDefault ? cyber.success : cyber.warn,
                ),
                const SizedBox(width: FluffySpacing.md),
                Expanded(
                  child: Text(
                    _isDefault
                        ? 'VOX est l\'app SMS par défaut'
                        : 'VOX n\'est PAS l\'app SMS par défaut',
                    style: FluffyTypography.title
                        .copyWith(color: theme.colorScheme.onSurface),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: FluffySpacing.md),
          if (!_isDefault)
            CyberPrimaryButton(
              label: 'Définir VOX comme app SMS par défaut',
              icon: Icons.sms_outlined,
              onPressed: () async {
                await SmsBridge.instance.requestDefaultSmsRole();
              },
            ),

          // ── Notifications SMS ────────────────────────────────────────────
          const SizedBox(height: FluffySpacing.xl),
          const CyberSectionHeader('NOTIFICATIONS'),
          SettingsSwitchListTile.adaptive(
            title: L10n.of(context).smsNotifications,
            subtitle: L10n.of(context).smsNotificationsDescription,
            setting: AppSettings.smsNotificationsEnabled,
          ),
          SettingsSwitchListTile.adaptive(
            title: L10n.of(context).smsNotificationsPreview,
            subtitle: L10n.of(context).smsNotificationsPreviewDescription,
            setting: AppSettings.smsNotificationsPreview,
          ),
          SettingsSwitchListTile.adaptive(
            title: L10n.of(context).smsNotificationsSound,
            subtitle: L10n.of(context).smsNotificationsSoundDescription,
            setting: AppSettings.smsNotificationsSound,
          ),

          // ── Banc de test (DEBUG uniquement) ──────────────────────────────
          // Envoi manuel + dump des conversations + log en clair. Exposer ça en
          // release fuirait numéros et contenus de SMS (OTP bancaires…), donc
          // tout ce bloc est gated kDebugMode.
          if (kDebugMode) ...[
            const SizedBox(height: FluffySpacing.xl),
            const CyberSectionHeader('ENVOYER UN SMS TEST'),
            CyberGlass(
              child: Column(
                children: [
                  TextField(
                    controller: _addr,
                    keyboardType: TextInputType.phone,
                    decoration: const InputDecoration(labelText: 'Numéro'),
                  ),
                  TextField(
                    controller: _body,
                    decoration: const InputDecoration(labelText: 'Message'),
                  ),
                  const SizedBox(height: FluffySpacing.md),
                  CyberPrimaryButton(
                    label: 'Envoyer',
                    icon: Icons.send_rounded,
                    onPressed: () async {
                      final id = await SmsBridge.instance
                          .sendSms(_addr.text.trim(), _body.text.trim());
                      if (!mounted) return;
                      setState(() => _log = id == null
                          ? '❌ échec envoi\n$_log'
                          : '✅ envoyé (row $id)\n$_log');
                      _refresh();
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: FluffySpacing.xl),
            CyberSectionHeader('CONVERSATIONS (${_convs.length})'),
            for (final c in _convs)
              CyberSettingsTile(
                icon: Icons.message_outlined,
                accent: cyber.cyan,
                title: c.title,
                subtitle: c.snippet,
                trailing: c.unreadCount > 0
                    ? CircleAvatar(
                        radius: 11,
                        backgroundColor: cyber.magenta,
                        child: Text(
                          '${c.unreadCount}',
                          style: const TextStyle(
                            fontSize: 11,
                            color: Colors.black,
                          ),
                        ),
                      )
                    : null,
                onTap: () => SmsBridge.instance.markRead(c.threadId),
              ),
            const SizedBox(height: FluffySpacing.xl),
            if (_log.isNotEmpty) ...[
              const CyberSectionHeader('LOG'),
              CyberGlass(
                child: Text(
                  _log,
                  style: FluffyTypography.code
                      .copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }
}
