import 'package:fluffychat/config/app_config.dart';
import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/config/themes.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/utils/platform_infos.dart';
import 'package:fluffychat/widgets/cyber/cyber_widgets.dart';
import 'package:flutter/material.dart';
import 'package:particles_network/particles_network.dart';
import 'package:url_launcher/url_launcher_string.dart';

/// CYBERCORE auth shell — used by login / sign-in / intro / bootstrap. A slow
/// cyan→magenta radial mesh ([CyberBackdrop]) sits behind a transparent
/// scaffold so the whole auth flow reads as the fork's dark cyberpunk identity
/// instead of plain Material surfaces.
class LoginScaffold extends StatefulWidget {
  final Widget body;
  final AppBar? appBar;
  final Widget? bottomNavigationBar;

  const LoginScaffold({
    super.key,
    required this.body,
    this.appBar,
    this.bottomNavigationBar,
  });

  @override
  State<LoginScaffold> createState() => _LoginScaffoldState();
}

class _LoginScaffoldState extends State<LoginScaffold>
    with SingleTickerProviderStateMixin {
  late final AnimationController _meshController = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 12),
  );

  @override
  void initState() {
    super.initState();
    if (!WidgetsBinding.instance.platformDispatcher.accessibilityFeatures
        .disableAnimations) {
      _meshController.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _meshController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cyber = CyberColors.of(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        final isMobileMode = !FluffyThemes.isColumnModeByWidth(
          constraints.maxWidth,
        );
        if (isMobileMode) {
          return CyberBackdrop(
            animation: _meshController,
            child: Scaffold(
              key: const Key('LoginScaffold'),
              backgroundColor: Colors.transparent,
              appBar: widget.appBar,
              body: SafeArea(child: widget.body),
              bottomNavigationBar: widget.bottomNavigationBar,
            ),
          );
        }
        return CyberBackdrop(
          animation: _meshController,
          child: Stack(
            children: [
              if (!MediaQuery.disableAnimationsOf(context))
                ParticleNetwork(
                  maxSpeed: 0.25,
                  particleColor: cyber.cyan,
                  lineColor: cyber.magenta,
                ),
              Column(
                children: [
                  const SizedBox(height: 16),
                  Expanded(
                    child: Center(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16.0),
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(
                              AppConfig.borderRadius,
                            ),
                            boxShadow: cyber.neonGlow,
                          ),
                          child: Material(
                            borderRadius: BorderRadius.circular(
                              AppConfig.borderRadius,
                            ),
                            clipBehavior: Clip.hardEdge,
                            elevation:
                                theme.appBarTheme.scrolledUnderElevation ?? 4,
                            shadowColor: theme.appBarTheme.shadowColor,
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(
                                maxWidth: 480,
                                maxHeight: 640,
                              ),
                              child: Scaffold(
                                key: const Key('LoginScaffold'),
                                appBar: widget.appBar,
                                body: SafeArea(child: widget.body),
                                bottomNavigationBar: widget.bottomNavigationBar,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const _PrivacyButtons(mainAxisAlignment: .center),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

class _PrivacyButtons extends StatelessWidget {
  final MainAxisAlignment mainAxisAlignment;
  const _PrivacyButtons({required this.mainAxisAlignment});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final shadowTextStyle = TextStyle(color: theme.colorScheme.secondary);
    return SizedBox(
      height: 64,
      child: Padding(
        padding: const EdgeInsets.all(8.0),
        child: Row(
          mainAxisAlignment: mainAxisAlignment,
          children: [
            TextButton(
              onPressed: () => launchUrlString(AppSettings.website.value),
              child: Text(L10n.of(context).website, style: shadowTextStyle),
            ),
            TextButton(
              onPressed: () => launchUrlString(AppConfig.supportUrl),
              child: Text(L10n.of(context).help, style: shadowTextStyle),
            ),
            TextButton(
              onPressed: () => launchUrlString(AppSettings.privacyPolicy.value),
              child: Text(L10n.of(context).privacy, style: shadowTextStyle),
            ),
            TextButton(
              onPressed: () => PlatformInfos.showDialog(context),
              child: Text(L10n.of(context).about, style: shadowTextStyle),
            ),
          ],
        ),
      ),
    );
  }
}
