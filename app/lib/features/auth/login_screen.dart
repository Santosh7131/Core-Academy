import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/api.dart';
import '../../core/session.dart';
import '../../theme.dart';
import '../../ui/kit.dart';
import '../../ui/tokens.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _user = TextEditingController();
  final _password = TextEditingController();
  String _pin = '';
  bool _teacher = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _user.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit(String secret) async {
    FocusScope.of(context).unfocus();
    if (_user.text.trim().isEmpty) {
      setState(() {
        _error = 'Type your username first.';
        _pin = '';
      });
      return;
    }
    if (secret.isEmpty) {
      setState(() => _error = 'Type your password.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await session.login(_user.text, secret);
    } on ApiException catch (e) {
      if (mounted) {
        setState(() {
          _error = e.message;
          _pin = '';
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _digit(String d) {
    if (_busy || _pin.length >= 4) return;
    setState(() {
      _pin += d;
      _error = null;
    });
    if (_pin.length == 4) _submit(_pin);
  }

  void _backspace() {
    if (_busy || _pin.isEmpty) return;
    setState(() => _pin = _pin.substring(0, _pin.length - 1));
  }

  void _toggle() => setState(() {
        _teacher = !_teacher;
        _error = null;
        _pin = '';
        _password.clear();
      });

  @override
  Widget build(BuildContext context) {
    final status = _busy ? (_teacher ? 'Checking your password' : 'Checking your PIN') : _error;
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
                    Kicker(session.tuitionName),
                    const SizedBox(height: 8),
                    Text(_teacher ? 'Tutor login' : 'Log in', style: displayStyle),
                    const SizedBox(height: 10),
                    Text(
                      _teacher
                          ? 'Log in with your username and password.'
                          : 'Your teacher gives you a username and a 4-digit PIN.',
                      style: bodyStyle.copyWith(color: muted),
                    ),
                    const SizedBox(height: 26),
                    GroupedInputs(children: [
                      BareField(
                        controller: _user,
                        placeholder: 'Username',
                        keyboard: TextInputType.visiblePassword,
                        action: _teacher ? TextInputAction.next : TextInputAction.done,
                        onSubmitted: (_) => _teacher ? null : FocusScope.of(context).unfocus(),
                      ),
                      if (_teacher)
                        BareField(
                          controller: _password,
                          placeholder: 'Password',
                          obscure: true,
                          action: TextInputAction.done,
                          onSubmitted: (_) => _submit(_password.text),
                        ),
                    ]),
                    if (_teacher) ...[
                      const SizedBox(height: 14),
                      _Status(text: status, isError: !_busy && _error != null),
                      const SizedBox(height: 14),
                      PrimaryButton(_busy ? 'Logging in' : 'Log in', onTap: _busy ? null : () => _submit(_password.text)),
                    ] else ...[
                      const SizedBox(height: 30),
                      _PinDots(filled: _pin.length, error: !_busy && _error != null),
                      const SizedBox(height: 12),
                      _Status(text: status, isError: !_busy && _error != null),
                      const SizedBox(height: 18),
                      _Keypad(onDigit: _digit, onBackspace: _backspace, enabled: !_busy),
                    ],
                    const Spacer(),
                    const SizedBox(height: 16),
                    Center(child: TextAction(_teacher ? 'I am a student' : 'I am a tutor', onTap: _toggle)),
                    if (_teacher) Center(child: TextAction('New tutor? Create your tuition', onTap: () => context.push('/signup'))),
                    const SizedBox(height: 8),
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

class _Status extends StatelessWidget {
  const _Status({required this.text, required this.isError});
  final String? text;
  final bool isError;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 36,
        child: Center(
          child: Fig(
            text ?? '',
            style: labelStyle.copyWith(fontSize: 12.5, color: isError ? danger : muted),
            textAlign: TextAlign.center,
            maxLines: 2,
          ),
        ),
      );
}

class _PinDots extends StatelessWidget {
  const _PinDots({required this.filled, required this.error});
  final int filled;
  final bool error;

  @override
  Widget build(BuildContext context) => Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        for (var i = 0; i < 4; i++) ...[
          if (i > 0) const SizedBox(width: 18),
          Container(
            width: 16,
            height: 16,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: i < filled ? actionFill : null,
              border: i < filled ? null : Border.all(color: error ? danger : ringIdle, width: 1.8),
            ),
          ),
        ],
      ]);
}

class _Keypad extends StatelessWidget {
  const _Keypad({required this.onDigit, required this.onBackspace, required this.enabled});
  final ValueChanged<String> onDigit;
  final VoidCallback onBackspace;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    Widget key(String d) => Expanded(
          child: Pressable(
            onTap: enabled ? () => onDigit(d) : null,
            label: d,
            child: Container(
              height: 58,
              alignment: Alignment.center,
              decoration: surface(radius: rSmall, shadow: e1),
              child: Text(d, style: numStyle(size: 22, weight: FontWeight.w600, color: enabled ? ink : faint)),
            ),
          ),
        );
    Widget row(List<Widget> keys) => Row(children: [
          for (final (i, k) in keys.indexed) ...[if (i > 0) const SizedBox(width: gapRow), k],
        ]);
    return Column(children: [
      row([key('1'), key('2'), key('3')]),
      const SizedBox(height: gapRow),
      row([key('4'), key('5'), key('6')]),
      const SizedBox(height: gapRow),
      row([key('7'), key('8'), key('9')]),
      const SizedBox(height: gapRow),
      row([
        const Expanded(child: SizedBox(height: 58)),
        key('0'),
        Expanded(
          child: Pressable(
            onTap: enabled ? onBackspace : null,
            label: 'Delete',
            child: SizedBox(height: 58, child: Icon(Ph.backspace, size: 24, color: muted)),
          ),
        ),
      ]),
    ]);
  }
}
