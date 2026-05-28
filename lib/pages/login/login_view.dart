import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/widgets/cyber/cyber_widgets.dart';
import 'package:fluffychat/widgets/layouts/login_scaffold.dart';
import 'package:flutter/material.dart';

import 'login.dart';

class LoginView extends StatelessWidget {
  final LoginController controller;

  const LoginView(this.controller, {super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cyber = CyberColors.of(context);

    final homeserver = controller.widget.client.homeserver
        ?.toString()
        .replaceFirst('https://', '');
    final title = homeserver == null
        ? L10n.of(context).loginWithMatrixId
        : L10n.of(context).logInTo(homeserver);

    return LoginScaffold(
      appBar: AppBar(
        leading: controller.loading ? null : const Center(child: BackButton()),
        automaticallyImplyLeading: !controller.loading,
        titleSpacing: !controller.loading ? 0 : null,
        title: Text(title),
      ),
      body: Builder(
        builder: (context) {
          return AutofillGroup(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              children: <Widget>[
                Hero(
                  tag: 'info-logo',
                  child: Image.asset('assets/banner_transparent.png'),
                ),
                const SizedBox(height: 16),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24.0),
                  child: TextField(
                    readOnly: controller.loading,
                    autocorrect: false,
                    autofocus: true,
                    onChanged: controller.checkWellKnownWithCoolDown,
                    controller: controller.usernameController,
                    textInputAction: TextInputAction.next,
                    keyboardType: TextInputType.emailAddress,
                    autofillHints: controller.loading
                        ? null
                        : [AutofillHints.username],
                    decoration: InputDecoration(
                      prefixIcon: Icon(
                        Icons.account_box_outlined,
                        color: cyber.cyan,
                      ),
                      errorText: controller.usernameError,
                      errorStyle: TextStyle(color: cyber.warn),
                      hintText: '@username:domain',
                      labelText: L10n.of(context).matrixId,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24.0),
                  child: TextField(
                    readOnly: controller.loading,
                    autocorrect: false,
                    autofillHints: controller.loading
                        ? null
                        : [AutofillHints.password],
                    controller: controller.passwordController,
                    textInputAction: TextInputAction.go,
                    obscureText: !controller.showPassword,
                    onSubmitted: (_) => controller.login(),
                    decoration: InputDecoration(
                      prefixIcon: Icon(Icons.lock_outlined, color: cyber.cyan),
                      errorText: controller.passwordError,
                      errorStyle: TextStyle(color: cyber.warn),
                      suffixIcon: IconButton(
                        onPressed: controller.toggleShowPassword,
                        icon: Icon(
                          controller.showPassword
                              ? Icons.visibility_off_outlined
                              : Icons.visibility_outlined,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      hintText: '******',
                      labelText: L10n.of(context).password,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24.0),
                  child: CyberPrimaryButton(
                    label: L10n.of(context).login,
                    icon: Icons.login_rounded,
                    loading: controller.loading,
                    onPressed: controller.loading ? null : controller.login,
                  ),
                ),
                const SizedBox(height: 16),
                if (homeserver != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24.0),
                    child: TextButton(
                      onPressed: controller.loading
                          ? () {}
                          : controller.passwordForgotten,
                      style: TextButton.styleFrom(
                        foregroundColor: theme.colorScheme.error,
                      ),
                      child: Text(L10n.of(context).passwordForgotten),
                    ),
                  ),
                const SizedBox(height: 16),
              ],
            ),
          );
        },
      ),
    );
  }
}
