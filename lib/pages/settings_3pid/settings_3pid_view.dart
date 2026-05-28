import 'package:fluffychat/config/design_tokens.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/pages/settings_3pid/settings_3pid.dart';
import 'package:fluffychat/widgets/cyber/cyber_widgets.dart';
import 'package:fluffychat/widgets/layouts/max_width_body.dart';
import 'package:fluffychat/widgets/matrix.dart';
import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';

class Settings3PidView extends StatelessWidget {
  final Settings3PidController controller;

  const Settings3PidView(this.controller, {super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cyber = CyberColors.of(context);

    controller.request ??= Matrix.of(context).client.getAccount3PIDs();
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: const Center(child: BackButton()),
        title: Text(L10n.of(context).passwordRecovery),
        actions: [
          IconButton(
            icon: const Icon(Icons.add_outlined),
            color: cyber.cyan,
            onPressed: controller.add3PidAction,
            tooltip: L10n.of(context).addEmail,
          ),
        ],
      ),
      body: MaxWidthBody(
        withScrolling: false,
        child: FutureBuilder<List<ThirdPartyIdentifier>?>(
          future: controller.request,
          builder:
              (
                BuildContext context,
                AsyncSnapshot<List<ThirdPartyIdentifier>?> snapshot,
              ) {
                if (snapshot.hasError) {
                  return Center(
                    child: Text(
                      snapshot.error.toString(),
                      textAlign: TextAlign.center,
                      style: FluffyTypography.bodyM.copyWith(
                        color: cyber.warn,
                      ),
                    ),
                  );
                }
                if (!snapshot.hasData) {
                  return const Center(
                    child: CircularProgressIndicator.adaptive(strokeWidth: 2),
                  );
                }
                final identifier = snapshot.data!;
                return Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                        FluffySpacing.lg,
                        FluffySpacing.lg,
                        FluffySpacing.lg,
                        FluffySpacing.sm,
                      ),
                      child: CyberGlass(
                        tint: identifier.isEmpty
                            ? cyber.warn.withValues(alpha: 0.08)
                            : null,
                        child: Row(
                          children: [
                            Container(
                              width: 40,
                              height: 40,
                              decoration: BoxDecoration(
                                color: (identifier.isEmpty
                                        ? cyber.warn
                                        : cyber.cyan)
                                    .withValues(alpha: 0.16),
                                borderRadius: FluffyRadius.brMd,
                                border: Border.all(
                                  color: (identifier.isEmpty
                                          ? cyber.warn
                                          : cyber.cyan)
                                      .withValues(alpha: 0.4),
                                ),
                              ),
                              child: Icon(
                                identifier.isEmpty
                                    ? Icons.warning_outlined
                                    : Icons.info_outlined,
                                color: identifier.isEmpty
                                    ? cyber.warn
                                    : cyber.cyan,
                                size: 20,
                              ),
                            ),
                            const SizedBox(width: FluffySpacing.lg),
                            Expanded(
                              child: Text(
                                identifier.isEmpty
                                    ? L10n.of(
                                        context,
                                      ).noPasswordRecoveryDescription
                                    : L10n.of(
                                        context,
                                      ).withTheseAddressesRecoveryDescription,
                                style: FluffyTypography.bodyM.copyWith(
                                  color: theme.colorScheme.onSurface,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    Expanded(
                      child: ListView.builder(
                        padding: const EdgeInsets.symmetric(
                          horizontal: FluffySpacing.lg,
                          vertical: FluffySpacing.sm,
                        ),
                        itemCount: identifier.length,
                        itemBuilder: (BuildContext context, int i) => Padding(
                          padding: const EdgeInsets.only(
                            bottom: FluffySpacing.sm,
                          ),
                          child: CyberGlass(
                            padding: const EdgeInsets.symmetric(
                              horizontal: FluffySpacing.sm,
                              vertical: FluffySpacing.xs,
                            ),
                            child: CyberSettingsTile(
                              icon: identifier[i].iconData,
                              accent: cyber.cyan,
                              title: identifier[i].address,
                              trailing: IconButton(
                                tooltip: L10n.of(context).delete,
                                icon: const Icon(
                                  Icons.delete_forever_outlined,
                                ),
                                color: cyber.magenta,
                                onPressed: () =>
                                    controller.delete3Pid(identifier[i]),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                );
              },
        ),
      ),
    );
  }
}

extension on ThirdPartyIdentifier {
  IconData get iconData {
    switch (medium) {
      case ThirdPartyIdentifierMedium.email:
        return Icons.mail_outline_rounded;
      case ThirdPartyIdentifierMedium.msisdn:
        return Icons.phone_android_outlined;
    }
  }
}
