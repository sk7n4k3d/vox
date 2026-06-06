import 'dart:io';

import 'package:fluffychat/config/design_tokens.dart';
import 'package:fluffychat/pages/sms_chat/sms_chat_page.dart';
import 'package:fluffychat/utils/sms/sms_bridge.dart';
import 'package:fluffychat/widgets/cyber/cyber_widgets.dart';
import 'package:flutter/material.dart';

/// "New SMS" screen: type a raw number OR pick a phone contact, then open the
/// SMS conversation (created on first send via the native getOrCreateThreadId).
class NewSmsPage extends StatefulWidget {
  const NewSmsPage({super.key});

  @override
  State<NewSmsPage> createState() => _NewSmsPageState();
}

class _NewSmsPageState extends State<NewSmsPage> {
  final TextEditingController _search = TextEditingController();
  List<SmsContact> _all = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final contacts = await SmsBridge.instance.listContacts();
    if (!mounted) return;
    setState(() {
      _all = contacts;
      _loading = false;
    });
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /// Opens the (possibly new) SMS conversation for [address]. threadId is empty
  /// for a brand-new recipient — the thread is created on the first send.
  void _openConversation(String address, String? name) {
    final addr = address.trim();
    if (addr.isEmpty) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => SmsChatPage(
          threadId: '',
          address: addr,
          displayName: name,
        ),
      ),
    );
  }

  /// Single number → open straight away. Several numbers → bottom-sheet picker.
  Future<void> _pickContact(SmsContact c) async {
    if (c.numbers.length == 1) {
      _openConversation(c.numbers.first.number, c.name);
      return;
    }
    final chosen = await showModalBottomSheet<SmsContactNumber>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(FluffySpacing.md),
              child: Text(
                c.display,
                style: Theme.of(ctx).textTheme.titleMedium,
              ),
            ),
            for (final n in c.numbers)
              ListTile(
                leading: const Icon(Icons.phone_outlined),
                title: Text(n.number),
                subtitle: Text(n.label),
                onTap: () => Navigator.of(ctx).pop(n),
              ),
          ],
        ),
      ),
    );
    if (chosen != null) _openConversation(chosen.number, c.name);
  }

  bool _looksLikeNumber(String s) {
    final t = s.replaceAll(RegExp(r'[\s\-().]'), '');
    return t.isNotEmpty && RegExp(r'^\+?\d{3,}$').hasMatch(t);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cyber = CyberColors.of(context);
    final query = _search.text.trim().toLowerCase();
    final normQuery = query.replaceAll(RegExp(r'[\s\-().]'), '');
    final filtered = query.isEmpty
        ? _all
        : _all
            .where(
              (c) =>
                  c.name.toLowerCase().contains(query) ||
                  c.numbers.any(
                    (n) => n.number
                        .replaceAll(RegExp(r'[\s\-().]'), '')
                        .contains(normQuery),
                  ),
            )
            .toList();
    final typedNumber = _search.text.trim();
    final showDirectSend = _looksLikeNumber(typedNumber);

    return Scaffold(
      appBar: AppBar(title: const Text('Nouveau SMS')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(FluffySpacing.md),
            child: TextField(
              controller: _search,
              autofocus: true,
              keyboardType: TextInputType.text,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                hintText: 'Numéro ou nom du contact',
                prefixIcon: const Icon(Icons.search),
                filled: true,
                fillColor: theme.colorScheme.surfaceContainerHigh,
                border: OutlineInputBorder(
                  borderRadius: FluffyRadius.brLg,
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          // Direct "send to this number" row when the field looks like a number.
          if (showDirectSend)
            ListTile(
              leading: CircleAvatar(
                backgroundColor: cyber.cyan,
                child: const Icon(Icons.send_rounded, color: Colors.black),
              ),
              title: Text('Envoyer un SMS à $typedNumber'),
              onTap: () => _openConversation(typedNumber, null),
            ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : filtered.isEmpty
                    ? Center(
                        child: Text(
                          _all.isEmpty
                              ? 'Aucun contact (autorise l’accès aux contacts)'
                              : 'Aucun contact trouvé',
                          style: FluffyTypography.bodyM.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      )
                    : ListView.builder(
                        itemCount: filtered.length,
                        itemBuilder: (context, i) {
                          final c = filtered[i];
                          final hasPhoto =
                              c.photoPath != null && c.photoPath!.isNotEmpty;
                          return ListTile(
                            leading: CircleAvatar(
                              backgroundColor:
                                  theme.colorScheme.primaryContainer,
                              backgroundImage: hasPhoto
                                  ? FileImage(File(c.photoPath!))
                                  : null,
                              child: hasPhoto
                                  ? null
                                  : Text(
                                      c.display.isNotEmpty
                                          ? c.display[0].toUpperCase()
                                          : '?',
                                      style: TextStyle(
                                        color: theme
                                            .colorScheme.onPrimaryContainer,
                                      ),
                                    ),
                            ),
                            title: Text(
                              c.display,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              c.numbers.length == 1
                                  ? '${c.numbers.first.label} · ${c.numbers.first.number}'
                                  : '${c.numbers.length} numéros',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            onTap: () => _pickContact(c),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}
