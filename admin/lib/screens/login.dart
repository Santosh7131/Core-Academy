import 'package:flutter/material.dart';

import '../core/api.dart';
import '../core/session.dart';
import '../theme.dart';
import '../ui/kit.dart';

/// The main app's teacher login, for the developer account, with the database to read.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _user = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _user.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_user.text.trim().isEmpty) {
      setState(() => _error = 'Type your username.');
      return;
    }
    if (_password.text.isEmpty) {
      setState(() => _error = 'Type your password.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await session.login(_user.text, _password.text);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = _busy ? 'Checking your password' : _error;
    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, box) => SingleChildScrollView(
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: box.maxHeight),
              child: IntrinsicHeight(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: gutter),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    const SizedBox(height: 36),
                    const Kicker('Core Academy · Admin'),
                    const SizedBox(height: 8),
                    Text('Developer login', style: displayStyle),
                    const SizedBox(height: 10),
                    Text('For the developer account only. Teachers and students use the Core Academy app.', style: bodyStyle.copyWith(color: muted)),
                    const SizedBox(height: 26),
                    GroupedInputs(children: [
                      BareField(
                        controller: _user,
                        placeholder: 'Username',
                        keyboard: TextInputType.visiblePassword,
                        action: TextInputAction.next,
                      ),
                      BareField(
                        controller: _password,
                        placeholder: 'Password',
                        obscure: true,
                        action: TextInputAction.done,
                        onSubmitted: (_) => _submit(),
                      ),
                    ]),
                    const SizedBox(height: 14),
                    SizedBox(
                      height: 36,
                      child: Center(
                        child: Fig(
                          status ?? '',
                          style: labelStyle.copyWith(fontSize: 12.5, color: !_busy && _error != null ? danger : muted),
                          textAlign: TextAlign.center,
                          maxLines: 2,
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),
                    PrimaryButton(_busy ? 'Logging in' : 'Log in', onTap: _busy ? null : _submit),
                    const Spacer(),
                    const SizedBox(height: 24),
                    Text('Database', style: labelStyle, textAlign: TextAlign.center),
                    const SizedBox(height: 10),
                    Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                      for (final (i, (env, label)) in [(Env.live, 'Live'), (Env.dev, 'Dev')].indexed) ...[
                        if (i > 0) const SizedBox(width: 8),
                        SegChip(label, selected: api.env == env, onTap: () async {
                          await session.switchTo(env);
                          if (mounted) setState(() => _error = null);
                        }),
                      ],
                    ]),
                    const SizedBox(height: 10),
                    Text('Live is what students use; dev is the test copy. Each has its own developer login.',
                        style: labelStyle, textAlign: TextAlign.center),
                    const SizedBox(height: 16),
                  ]),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
