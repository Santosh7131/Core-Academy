import 'package:flutter/material.dart';

import '../../core/api.dart';
import '../../core/session.dart';
import '../../theme.dart';
import '../../ui/kit.dart';

/// A new tutor makes their own login. The tuition itself is set up next (SetupScreen): the router
/// sends a signed-in tutor with no tuition there.
class TutorSignUpScreen extends StatefulWidget {
  const TutorSignUpScreen({super.key});

  @override
  State<TutorSignUpScreen> createState() => _TutorSignUpScreenState();
}

class _TutorSignUpScreenState extends State<TutorSignUpScreen> {
  final _name = TextEditingController();
  final _user = TextEditingController();
  final _pass = TextEditingController();
  bool _busy = false;
  bool _show = false;
  String? _error;

  @override
  void dispose() {
    for (final c in [_name, _user, _pass]) {
      c.dispose();
    }
    super.dispose();
  }

  String? _check() {
    if (_name.text.trim().isEmpty) return 'Type your name.';
    if (!RegExp(r'^[a-z0-9._]{3,24}$').hasMatch(_user.text.trim().toLowerCase())) {
      return 'The username uses 3 to 24 lowercase letters, numbers, dots or underscores.';
    }
    if (_pass.text.length < 8) return 'The password needs 8 or more characters.';
    return null;
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();
    final problem = _check();
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await session.signUpTutor(name: _name.text, username: _user.text, password: _pass.text);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PushedPanel(
        kicker: 'New tutor',
        title: 'Create your account',
        children: [
          const SizedBox(height: 26),
          GroupedInputs(children: [
            BareField(controller: _name, placeholder: 'Your name', capitalization: TextCapitalization.words, action: TextInputAction.next),
            BareField(
              controller: _user,
              placeholder: 'Username, in lowercase letters',
              keyboard: TextInputType.visiblePassword,
              action: TextInputAction.next,
            ),
            BareField(
              controller: _pass,
              placeholder: 'Password, 8 or more characters',
              obscure: !_show,
              action: TextInputAction.done,
              onSubmitted: (_) => _submit(),
              suffix: Pressable(
                label: _show ? 'Hide password' : 'Show password',
                onTap: () => setState(() => _show = !_show),
                child: Padding(padding: const EdgeInsets.all(6), child: Icon(_show ? Ph.eyeSlash : Ph.eye, size: 20, color: muted)),
              ),
            ),
          ]),
          AnimatedSize( // motion: approved
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: _error == null ? const SizedBox(width: double.infinity) : Padding(padding: const EdgeInsets.only(top: 14), child: InlineNotice(_error!, tone: Tone.danger, icon: Ph.warning)),
          ),
          const SizedBox(height: 20),
          PrimaryButton('Create account', busy: _busy, onTap: _submit),
        ],
      );
}
