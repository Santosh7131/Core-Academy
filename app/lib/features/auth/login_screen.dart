import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../core/api.dart';
import '../../core/session.dart';
import '../../theme.dart';
import '../../ui/brand_mark.dart';
import '../../ui/kit.dart';

/// One screen for both kinds of login: a student's username and 4-digit PIN, a tutor's username and
/// password. The phone's own keyboard does the typing.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _user = TextEditingController();
  final _secret = TextEditingController();
  bool _tutor = false;
  bool _busy = false;
  bool _show = false;
  String? _error;

  @override
  void dispose() {
    _user.dispose();
    _secret.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    FocusScope.of(context).unfocus();
    final name = _user.text.trim();
    final secret = _secret.text;
    String? problem;
    if (name.isEmpty) {
      problem = 'Type your username.';
    } else if (secret.isEmpty) {
      problem = _tutor ? 'Type your password.' : 'Type your PIN.';
    } else if (!_tutor && secret.length != 4) {
      problem = 'Your PIN has 4 digits.';
    }
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await session.login(name, secret);
    } on ApiException catch (e) {
      if (mounted) {
        setState(() {
          _error = e.message;
          _secret.clear();
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _choose(int i) {
    if (_busy || (i == 1) == _tutor) return;
    setState(() {
      _tutor = i == 1;
      _error = null;
      _secret.clear();
      _show = false;
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: AutofillGroup(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(gutter, 28, gutter, 24),
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              children: staggered([
                Row(children: [
                  const BrandMark(size: 46),
                  const SizedBox(width: 12),
                  Expanded(child: Kicker(session.tuitionName)),
                ]),
                const SizedBox(height: 30),
                Text('Welcome back', style: displayStyle),
                const SizedBox(height: 26),
                SegmentedToggle(labels: const ['Student', 'Tutor'], index: _tutor ? 1 : 0, onChanged: _choose),
                const SizedBox(height: 16),
                GroupedInputs(children: [
                  BareField(
                    controller: _user,
                    placeholder: 'Username',
                    keyboard: TextInputType.visiblePassword,
                    action: TextInputAction.next,
                    autofillHints: const [AutofillHints.username],
                    onChanged: (_) => _error == null ? null : setState(() => _error = null),
                  ),
                  BareField(
                    controller: _secret,
                    placeholder: _tutor ? 'Password' : 'PIN, 4 digits',
                    obscure: !_show,
                    keyboard: _tutor ? TextInputType.visiblePassword : TextInputType.number,
                    action: TextInputAction.done,
                    autofillHints: const [AutofillHints.password],
                    inputFormatters: _tutor ? null : [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(4)],
                    onSubmitted: (_) => _submit(),
                    onChanged: (_) => _error == null ? null : setState(() => _error = null),
                    suffix: Pressable(
                      label: _show ? 'Hide' : 'Show',
                      onTap: () => setState(() => _show = !_show),
                      child: Padding(padding: const EdgeInsets.all(6), child: Icon(_show ? Ph.eyeSlash : Ph.eye, size: 20, color: muted)),
                    ),
                  ),
                ]),
                AnimatedSize( // motion: approved
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeOutCubic,
                  alignment: Alignment.topCenter,
                  child: _error == null
                      ? const SizedBox(width: double.infinity, height: 16)
                      : Padding(padding: const EdgeInsets.only(top: 14, bottom: 14), child: InlineNotice(_error!, tone: Tone.danger, icon: Ph.warning)),
                ),
                PrimaryButton('Log in', busy: _busy, onTap: _submit),
                const SizedBox(height: 18),
                if (_tutor)
                  Center(child: TextAction('New tutor? Create your tuition', onTap: () => context.push('/signup')))
                else
                  Center(child: Text('Your tutor gives you a username and PIN.', style: labelStyle)),
              ], prefix: 'login', stepMs: 70),
            ),
          ),
        ),
      );
}
