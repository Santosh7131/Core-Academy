import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/api.dart';
import '../../theme.dart';
import '../../ui/kit.dart';

/// The code a student types to ask to join this tuition. Shown right after the tuition is made
/// ([first]) and from Settings.
class ShareCodeScreen extends StatefulWidget {
  const ShareCodeScreen({super.key, this.first = false});
  final bool first;

  @override
  State<ShareCodeScreen> createState() => _ShareCodeScreenState();
}

class _ShareCodeScreenState extends State<ShareCodeScreen> {
  Map<String, dynamic>? _t;
  String? _error;
  String? _notice;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await api.get('/teacher/tuition');
      if (mounted) {
        setState(() {
          _t = Map<String, dynamic>.from(r['tuition']);
          _error = null;
        });
      }
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  String get _code => '${_t?['join_code_shown'] ?? ''}';

  String get _message => 'Join ${_t?['name']} in the app. Log in, choose "Join another tuition" and enter the code $_code.';

  @override
  Widget build(BuildContext context) {
    final t = _t;
    return PushedPanel(
      kicker: t == null ? 'Your tuition' : '${t['name']}',
      title: widget.first ? 'Your tuition is ready' : 'Join code',
      onBack: widget.first ? () => context.go('/t') : null,
      footer: widget.first ? PrimaryButton('Go to Home', onTap: () => context.go('/t')) : null,
      children: [
        const SizedBox(height: 14),
        if (t == null && _error != null)
          ErrorState(message: _error!, onRetry: _load)
        else if (t == null)
          const LoadingState(rows: 2)
        else ...[
          Fig('Students type this code in the app to ask to join.', style: bodyStyle.copyWith(color: muted)),
          const SizedBox(height: 20),
          Surface(
            shadow: e1,
            padding: const EdgeInsets.fromLTRB(20, 22, 20, 22),
            child: Column(children: [
              Text(_code, style: numStyle(size: 44, weight: FontWeight.w700).copyWith(letterSpacing: 5), textAlign: TextAlign.center),
              const SizedBox(height: 6),
              Fig(t['join_open'] == false ? 'Joining is closed right now' : 'Anyone with this code can ask to join', style: labelStyle, textAlign: TextAlign.center),
            ]),
          ),
          const SizedBox(height: 16),
          Row(children: [
            Expanded(
              child: SecondaryButton('Copy', icon: Ph.copy, onTap: () {
                Clipboard.setData(ClipboardData(text: _message));
                setState(() => _notice = 'Copied. Paste it into a message.');
              }),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: PrimaryButton('Share', icon: Ph.shareNetwork, onTap: () => SharePlus.instance.share(ShareParams(text: _message))),
            ),
          ]),
          if (_notice != null) ...[const SizedBox(height: 14), InlineNotice(_notice!, tone: Tone.success, icon: Ph.checkCircle)],
        ],
      ],
    );
  }
}
