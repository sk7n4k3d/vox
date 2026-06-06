import 'dart:async';

import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/config/themes.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/utils/biometric_auth.dart';
import 'package:fluffychat/widgets/app_lock.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class LockScreen extends StatefulWidget {
  const LockScreen({super.key});

  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> {
  String? _errorText;
  int _coolDownSeconds = 5;
  bool _inputBlocked = false;
  bool _biometricAvailable = false;
  final TextEditingController _textEditingController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _maybeBiometric();
  }

  Future<void> _maybeBiometric() async {
    if (!AppSettings.appLockBiometric.value) return;
    final available = await BiometricAuth.instance.isAvailable;
    if (!mounted) return;
    setState(() => _biometricAvailable = available);
    if (available) _promptBiometric();
  }

  Future<void> _promptBiometric() async {
    final ok = await BiometricAuth.instance
        .authenticate(L10n.of(context).appLock);
    if (!mounted) return;
    if (ok) AppLock.of(context).unlockDirectly();
  }

  Future<void> tryUnlock(String text) async {
    text = text.trim();
    setState(() {
      _errorText = null;
    });
    if (text.length < 4) return;

    final enteredPin = int.tryParse(text);
    if (enteredPin == null || text.length != 4) {
      setState(() {
        _errorText = L10n.of(context).invalidInput;
      });
      _textEditingController.clear();
      return;
    }

    if (AppLock.of(context).unlock(text)) {
      setState(() {
        _inputBlocked = false;
        _errorText = null;
      });
      _textEditingController.clear();
      return;
    }

    setState(() {
      _errorText = L10n.of(context).wrongPinEntered(_coolDownSeconds);
      _inputBlocked = true;
    });
    Future.delayed(Duration(seconds: _coolDownSeconds)).then((_) {
      setState(() {
        _inputBlocked = false;
        _coolDownSeconds *= 2;
        _errorText = null;
      });
    });
    _textEditingController.clear();
  }

  @override
  Widget build(BuildContext context) {
    return ScaffoldMessenger(
      child: Scaffold(
        appBar: AppBar(
          title: Text(L10n.of(context).pleaseEnterYourPin),
          centerTitle: true,
        ),
        extendBodyBehindAppBar: true,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: FluffyThemes.columnWidth,
              ),
              child: ListView(
                shrinkWrap: true,
                children: [
                  Center(
                    child: Image.asset('assets/info-logo.png', width: 256),
                  ),
                  TextField(
                    controller: _textEditingController,
                    textInputAction: TextInputAction.done,
                    keyboardType: TextInputType.number,
                    obscureText: true,
                    autofocus: true,
                    textAlign: TextAlign.center,
                    readOnly: _inputBlocked,
                    onChanged: tryUnlock,
                    onSubmitted: tryUnlock,
                    style: const TextStyle(fontSize: 40),
                    inputFormatters: [LengthLimitingTextInputFormatter(4)],
                    decoration: InputDecoration(
                      errorText: _errorText,
                      hintText: '****',
                      suffix: IconButton(
                        icon: const Icon(Icons.lock_open_outlined),
                        onPressed: () => tryUnlock(_textEditingController.text),
                      ),
                    ),
                  ),
                  if (_inputBlocked)
                    const Padding(
                      padding: EdgeInsets.all(8.0),
                      child: LinearProgressIndicator(),
                    ),
                  if (_biometricAvailable)
                    Padding(
                      padding: const EdgeInsets.only(top: 24),
                      child: Center(
                        child: IconButton.filledTonal(
                          iconSize: 32,
                          onPressed: _inputBlocked ? null : _promptBiometric,
                          tooltip: L10n.of(context).appLock,
                          icon: const Icon(Icons.fingerprint),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
