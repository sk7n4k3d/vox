import 'package:fluffychat/config/design_tokens.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/pages/settings_password/settings_password.dart';
import 'package:fluffychat/widgets/cyber/cyber_widgets.dart';
import 'package:fluffychat/widgets/layouts/max_width_body.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

class SettingsPasswordView extends StatelessWidget {
  final SettingsPasswordController controller;
  const SettingsPasswordView(this.controller, {super.key});

  @override
  Widget build(BuildContext context) {
    final cyber = CyberColors.of(context);

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Text(L10n.of(context).changePassword),
      ),
      body: ListTileTheme(
        iconColor: cyber.cyan,
        child: MaxWidthBody(
          child: Padding(
            padding: const EdgeInsets.all(FluffySpacing.lg),
            child: Column(
              children: [
                const SizedBox(height: FluffySpacing.lg),
                CyberGlass(
                  child: TextField(
                    controller: controller.oldPasswordController,
                    obscureText: true,
                    autocorrect: false,
                    autofocus: true,
                    readOnly: controller.loading,
                    decoration: InputDecoration(
                      border: InputBorder.none,
                      prefixIcon: Icon(Icons.lock_outlined, color: cyber.cyan),
                      hintText: '********',
                      labelText:
                          L10n.of(context).pleaseEnterYourCurrentPassword,
                      errorText: controller.oldPasswordError,
                    ),
                  ),
                ),
                const Divider(height: FluffySpacing.xxxxl),
                CyberGlass(
                  child: TextField(
                    controller: controller.newPassword1Controller,
                    obscureText: true,
                    autocorrect: false,
                    readOnly: controller.loading,
                    decoration: InputDecoration(
                      border: InputBorder.none,
                      prefixIcon:
                          Icon(Icons.lock_reset_outlined, color: cyber.cyan),
                      hintText: '********',
                      labelText: L10n.of(context).newPassword,
                      errorText: controller.newPassword1Error,
                    ),
                  ),
                ),
                const SizedBox(height: FluffySpacing.lg),
                CyberGlass(
                  child: TextField(
                    controller: controller.newPassword2Controller,
                    obscureText: true,
                    autocorrect: false,
                    readOnly: controller.loading,
                    decoration: InputDecoration(
                      border: InputBorder.none,
                      prefixIcon:
                          Icon(Icons.repeat_outlined, color: cyber.cyan),
                      hintText: '********',
                      labelText: L10n.of(context).repeatPassword,
                      errorText: controller.newPassword2Error,
                    ),
                  ),
                ),
                const SizedBox(height: FluffySpacing.xxl),
                SizedBox(
                  width: double.infinity,
                  child: CyberPrimaryButton(
                    label: L10n.of(context).changePassword,
                    icon: Icons.lock_reset_outlined,
                    loading: controller.loading,
                    onPressed:
                        controller.loading ? null : controller.changePassword,
                  ),
                ),
                const SizedBox(height: FluffySpacing.lg),
                TextButton(
                  style: TextButton.styleFrom(foregroundColor: cyber.cyan),
                  child: Text(
                    L10n.of(context).passwordRecoverySettings,
                    style: FluffyTypography.labelL.copyWith(color: cyber.cyan),
                  ),
                  onPressed: () => context.go('/rooms/settings/security/3pid'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
