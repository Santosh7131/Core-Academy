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
          const SizedBox(height: 10),
          Fig('Next you set up your tuition: the classes and subjects you teach, and how students join.',
              style: bodyStyle.copyWith(color: muted)),
          const SizedBox(height: 24),
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
              obscure: true,
              action: TextInputAction.done,
              onSubmitted: (_) => _submit(),
            ),
          ]),
          if (_error != null) ...[const SizedBox(height: 14), InlineNotice(_error!, icon: Ph.warning)],
          const SizedBox(height: 20),
          PrimaryButton(_busy ? 'Creating' : 'Create account', onTap: _busy ? null : _submit),
        ],
      );
}
