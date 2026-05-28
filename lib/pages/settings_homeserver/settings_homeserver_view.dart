import 'dart:convert';

import 'package:fluffychat/config/design_tokens.dart';
import 'package:fluffychat/config/themes.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/utils/localized_exception_extension.dart';
import 'package:fluffychat/widgets/cyber/cyber_widgets.dart';
import 'package:fluffychat/widgets/layouts/max_width_body.dart';
import 'package:flutter/material.dart';
import 'package:flutter_linkify/flutter_linkify.dart';
import 'package:matrix/matrix.dart';
import 'package:url_launcher/url_launcher_string.dart';

import '../../widgets/matrix.dart';
import 'settings_homeserver.dart';

class SettingsHomeserverView extends StatelessWidget {
  final SettingsHomeserverController controller;

  const SettingsHomeserverView(this.controller, {super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cyber = CyberColors.of(context);

    final client = Matrix.of(context).client;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        automaticallyImplyLeading: !FluffyThemes.isColumnMode(context),
        centerTitle: FluffyThemes.isColumnMode(context),
        title: Text(
          L10n.of(
            context,
          ).aboutHomeserver(client.userID?.domain ?? 'Homeserver'),
        ),
      ),
      body: MaxWidthBody(
        withScrolling: true,
        child: SelectionArea(
          child: Column(
            mainAxisSize: .min,
            children: [
              CyberSectionHeader(
                L10n.of(context).serverInformation,
                accent: cyber.cyan,
              ),
              FutureBuilder(
                future: client.getWellknownSupport(),
                builder: (context, snapshot) {
                  final error = snapshot.error;
                  final data = snapshot.data;
                  if (error != null) {
                    return ListTile(
                      leading: Icon(
                        Icons.error_outlined,
                        color: cyber.warn,
                      ),
                      title: Text(
                        error.toLocalizedString(
                          context,
                          ExceptionContext.checkServerSupportInfo,
                        ),
                        style: FluffyTypography.bodyM.copyWith(
                          color: cyber.warn,
                        ),
                      ),
                    );
                  }
                  if (data == null) {
                    return const Center(
                      child: CircularProgressIndicator.adaptive(strokeWidth: 2),
                    );
                  }
                  final supportPage = data.supportPage;
                  final contacts = data.contacts;
                  if (supportPage == null && contacts == null) {
                    return ListTile(
                      leading: Icon(
                        Icons.error_outlined,
                        color: cyber.warn,
                      ),
                      title: Text(
                        L10n.of(context).noContactInformationProvided,
                        style: FluffyTypography.bodyM.copyWith(
                          color: cyber.warn,
                        ),
                      ),
                    );
                  }
                  return Column(
                    mainAxisSize: .min,
                    children: [
                      if (supportPage != null)
                        CyberSettingsTile(
                          icon: Icons.support_agent_outlined,
                          accent: cyber.cyan,
                          title: L10n.of(context).supportPage,
                          subtitle: supportPage.toString(),
                        ),
                      if (contacts != null)
                        ...contacts.map((contact) {
                          return ListTile(
                            leading: Icon(
                              Icons.contact_mail_outlined,
                              color: cyber.cyan,
                            ),
                            title: Text(
                              contact.role.localizedString(L10n.of(context)),
                              style: FluffyTypography.title.copyWith(
                                color: theme.colorScheme.onSurface,
                              ),
                            ),
                            subtitle: Column(
                              mainAxisSize: .min,
                              children: [
                                if (contact.emailAddress != null)
                                  TextButton(
                                    onPressed: () {},
                                    child: Text(contact.emailAddress!),
                                  ),
                                if (contact.matrixId != null)
                                  TextButton(
                                    onPressed: () {},
                                    child: Text(contact.matrixId!),
                                  ),
                              ],
                            ),
                          );
                        }),
                    ],
                  );
                },
              ),
              FutureBuilder(
                future: controller.fetchServerInfo(),
                builder: (context, snapshot) {
                  final error = snapshot.error;
                  if (error != null) {
                    return Column(
                      mainAxisAlignment: .center,
                      children: [
                        Icon(
                          Icons.error_outlined,
                          color: cyber.warn,
                        ),
                        const SizedBox(height: FluffySpacing.md),
                        Text(
                          error.toLocalizedString(context),
                          textAlign: TextAlign.center,
                          style: FluffyTypography.bodyM.copyWith(
                            color: cyber.warn,
                          ),
                        ),
                      ],
                    );
                  }
                  final data = snapshot.data;
                  if (data == null) {
                    return const Center(
                      child: CircularProgressIndicator.adaptive(strokeWidth: 2),
                    );
                  }
                  return Column(
                    mainAxisSize: .min,
                    children: [
                      CyberSettingsTile(
                        icon: Icons.dns_outlined,
                        accent: cyber.cyan,
                        title: L10n.of(context).name,
                        subtitle: data.name,
                      ),
                      CyberSettingsTile(
                        icon: Icons.numbers_outlined,
                        accent: cyber.cyan,
                        title: L10n.of(context).version,
                        subtitle: data.version,
                      ),
                      ListTile(
                        leading: Icon(
                          Icons.hub_outlined,
                          color: cyber.cyan,
                        ),
                        title: Text(
                          L10n.of(context).federationBaseUrl,
                          style: FluffyTypography.title.copyWith(
                            color: theme.colorScheme.onSurface,
                          ),
                        ),
                        subtitle: Linkify(
                          text: data.federationBaseUrl.toString(),
                          textScaleFactor: MediaQuery.textScalerOf(
                            context,
                          ).scale(1),
                          options: const LinkifyOptions(humanize: false),
                          linkStyle: TextStyle(
                            color: cyber.cyan,
                            decorationColor: cyber.cyan,
                          ),
                          onOpen: (link) => launchUrlString(link.url),
                        ),
                      ),
                    ],
                  );
                },
              ),
              Divider(color: cyber.glassBorder),
              FutureBuilder(
                future: client.getWellknown(),
                builder: (context, snapshot) {
                  final error = snapshot.error;
                  if (error != null) {
                    return Column(
                      mainAxisAlignment: .center,
                      children: [
                        Icon(
                          Icons.error_outlined,
                          color: cyber.warn,
                        ),
                        const SizedBox(height: FluffySpacing.md),
                        Text(
                          error.toLocalizedString(context),
                          textAlign: TextAlign.center,
                          style: FluffyTypography.bodyM.copyWith(
                            color: cyber.warn,
                          ),
                        ),
                      ],
                    );
                  }
                  final wellKnown = snapshot.data;
                  if (wellKnown == null) {
                    return const Center(
                      child: CircularProgressIndicator.adaptive(strokeWidth: 2),
                    );
                  }
                  final identityServer = wellKnown.mIdentityServer;
                  return Column(
                    mainAxisSize: .min,
                    children: [
                      CyberSectionHeader(
                        L10n.of(context).clientWellKnownInformation,
                        accent: cyber.cyan,
                      ),
                      ListTile(
                        leading: Icon(
                          Icons.link_outlined,
                          color: cyber.cyan,
                        ),
                        title: Text(
                          L10n.of(context).baseUrl,
                          style: FluffyTypography.title.copyWith(
                            color: theme.colorScheme.onSurface,
                          ),
                        ),
                        subtitle: Linkify(
                          text: wellKnown.mHomeserver.baseUrl.toString(),
                          textScaleFactor: MediaQuery.textScalerOf(
                            context,
                          ).scale(1),
                          options: const LinkifyOptions(humanize: false),
                          linkStyle: TextStyle(
                            color: cyber.cyan,
                            decorationColor: cyber.cyan,
                          ),
                          onOpen: (link) => launchUrlString(link.url),
                        ),
                      ),
                      if (identityServer != null)
                        ListTile(
                          leading: Icon(
                            Icons.badge_outlined,
                            color: cyber.cyan,
                          ),
                          title: Text(
                            L10n.of(context).identityServer,
                            style: FluffyTypography.title.copyWith(
                              color: theme.colorScheme.onSurface,
                            ),
                          ),
                          subtitle: Linkify(
                            text: identityServer.baseUrl.toString(),
                            textScaleFactor: MediaQuery.textScalerOf(
                              context,
                            ).scale(1),
                            options: const LinkifyOptions(humanize: false),
                            linkStyle: TextStyle(
                              color: cyber.cyan,
                              decorationColor: cyber.cyan,
                            ),
                            onOpen: (link) => launchUrlString(link.url),
                          ),
                        ),
                      ...wellKnown.additionalProperties.entries.map(
                        (entry) => ListTile(
                          leading: Icon(
                            Icons.data_object_outlined,
                            color: cyber.cyan,
                          ),
                          title: Text(
                            entry.key,
                            style: FluffyTypography.title.copyWith(
                              color: theme.colorScheme.onSurface,
                            ),
                          ),
                          subtitle: CyberGlass(
                            padding: const EdgeInsets.all(FluffySpacing.lg),
                            child: SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              child: Text(
                                const JsonEncoder.withIndent(
                                  '    ',
                                ).convert(entry.value),
                                style: FluffyTypography.code.copyWith(
                                  color: theme.colorScheme.onSurface,
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
            ],
          ),
        ),
      ),
    );
  }
}

extension on Role {
  String localizedString(L10n l10n) {
    switch (this) {
      case Role.mRoleAdmin:
        return l10n.contactServerAdmin;
      case Role.mRoleSecurity:
        return l10n.contactServerSecurity;
    }
  }
}
