import 'package:flutter/material.dart';

import '../core/device.dart';
import '../core/updater.dart';
import '../theme.dart';
import '../ui/kit.dart';

// The main app's update card (app/lib/ui/update_card.dart), for the admin app's private updates.

String _mb(int bytes) => '${(bytes / (1024 * 1024)).round()} MB';

/// "Admin 1.0.1 is ready" near the top of Overview, while a newer admin app is out.
class UpdateBanner extends StatelessWidget {
  const UpdateBanner({super.key, this.padding = const EdgeInsets.fromLTRB(gutter, 18, gutter, 0)});
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: updater,
        builder: (context, _) {
          final r = updater.available;
          if (r == null) return const SizedBox.shrink();
          return Padding(padding: padding, child: UpdateCard(release: r));
        },
      );
}

class UpdateCard extends StatelessWidget {
  const UpdateCard({super.key, required this.release});
  final Release release;

  @override
  Widget build(BuildContext context) {
    final r = release;
    final step = updater.step;
    final (String title, String body) = switch (step) {
      UpdateStep.ready => ('Admin ${r.version} is ready', r.notes.isEmpty ? 'Update in the app. ${_mb(r.size)}.' : 'Tap to see what is new. ${_mb(r.size)}.'),
      UpdateStep.allow => (
          'Allow updates',
          'Android asks once if this app may install its own updates. Turn on "Allow from this source", then come back here.',
        ),
      UpdateStep.downloading => ('Downloading ${r.version}', '${(updater.progress * 100).floor()}% of ${_mb(r.size)}'),
      UpdateStep.installing => (
          'Installing ${r.version}',
          updater.silent
              ? 'The app closes for a moment while the update goes in. Then open it again.'
              : 'Tap Update when Android asks. The app closes for a moment while the update goes in.',
        ),
      UpdateStep.failed => ('The update did not finish', updater.problem ?? 'Try again.'),
    };
    final card = Surface(
      shadow: e1,
      padding: const EdgeInsets.fromLTRB(17, 15, 15, 15),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Container(
            width: 40,
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: fill, shape: BoxShape.circle),
            child: Icon(step == UpdateStep.failed ? Ph.warning : Ph.arrowCircleUp, size: 21, color: step == UpdateStep.failed ? warning : ink),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Fig(title, style: rowTitleStyle, maxLines: 2),
              const SizedBox(height: 2),
              Fig(body, style: labelStyle.copyWith(color: muted), maxLines: 4),
            ]),
          ),
          if (step == UpdateStep.ready || step == UpdateStep.failed) ...[
            const SizedBox(width: 10),
            _Pill(step == UpdateStep.failed ? 'Try again' : 'Update', onTap: updater.update),
          ],
        ]),
        if (step == UpdateStep.downloading) ...[const SizedBox(height: 12), Track(updater.progress, height: 6)],
        if (step == UpdateStep.allow) ...[
          const SizedBox(height: 12),
          SecondaryButton('Open Android settings', icon: Ph.gear, onTap: updater.allow),
        ],
      ]),
    );
    if (step != UpdateStep.ready || r.notes.isEmpty) return card;
    return Pressable(label: 'What is new in ${r.version}', onTap: () => _whatsNew(context, r), child: card);
  }

  Future<void> _whatsNew(BuildContext context, Release r) => showCentredCard<void>(
        context,
        title: 'Admin ${r.version}',
        subtitle: 'What is new',
        builder: (ctx) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Flexible(child: SingleChildScrollView(child: Fig(r.notes, style: bodyStyle))),
          const SizedBox(height: 18),
          PrimaryButton('Update now', onTap: () {
            Navigator.of(ctx).pop();
            updater.update();
          }),
        ]),
      );
}

class _Pill extends StatelessWidget {
  const _Pill(this.label, {required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Pressable(
        label: label,
        onTap: onTap,
        child: Container(
          height: 34,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          alignment: Alignment.center,
          decoration: BoxDecoration(color: actionFill, borderRadius: BorderRadius.circular(rPill), boxShadow: e2),
          child: Text(label, style: chipStyle.copyWith(color: actionInk, fontWeight: FontWeight.w600)),
        ),
      );
}

/// Settings: the admin app's version, and a way to look for a newer one now.
class AppVersionPanel extends StatefulWidget {
  const AppVersionPanel({super.key});

  @override
  State<AppVersionPanel> createState() => _AppVersionPanelState();
}

class _AppVersionPanelState extends State<AppVersionPanel> {
  bool _checking = false;
  bool? _newer = false;
  bool _checked = false;

  Future<void> _check() async {
    setState(() {
      _checking = true;
      _checked = false;
    });
    final newer = await updater.check();
    if (!mounted) return;
    setState(() {
      _checking = false;
      _checked = true;
      _newer = newer;
    });
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: updater,
        builder: (context, _) {
          final r = updater.available;
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Surface(
              shadow: e1,
              padding: const EdgeInsets.fromLTRB(17, 14, 17, 14),
              child: Row(children: [
                Expanded(child: Text('Version', style: bodyStyle.copyWith(color: muted))),
                Fig(Device.version ?? '-', style: rowTitleStyle),
              ]),
            ),
            if (r != null) ...[
              const SizedBox(height: 10),
              UpdateCard(release: r),
            ] else ...[
              const SizedBox(height: 10),
              SecondaryButton(_checking ? 'Checking' : 'Check for updates', icon: Ph.arrowsClockwise, onTap: _checking ? null : _check),
            ],
            if (_checked && r == null) ...[
              const SizedBox(height: 10),
              if (_newer == null)
                const InlineNotice('Could not ask the server. Check the internet and try again.', tone: Tone.warning, icon: Ph.warning)
              else
                const InlineNotice('This is the newest version.', tone: Tone.success, icon: Ph.checkCircle),
            ],
          ]);
        },
      );
}
