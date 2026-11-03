import 'package:flutter/material.dart';

import '../core/brand.dart';
import '../core/format.dart' as f;
import '../core/updater.dart';
import '../theme.dart';
import 'kit.dart';

String _mb(int bytes) => '${(bytes / (1024 * 1024)).round()} MB';

/// "Version 1.2.1 is ready" near the top of Home, while a newer version of the app is out.
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

/// A newer version and where its update has got to: ready, waiting for Android's permission,
/// downloading, installing, or stopped with the reason.
class UpdateCard extends StatelessWidget {
  const UpdateCard({super.key, required this.release});
  final Release release;

  @override
  Widget build(BuildContext context) {
    final r = release;
    final step = updater.step;
    final (String title, String body) = switch (step) {
      UpdateStep.ready => (
          'Version ${r.version} is ready',
          r.notes.isEmpty ? 'Update in the app. Logins, tests and results stay as they are.' : 'Tap to see what is new. ${_mb(r.size)}.',
        ),
      UpdateStep.allow => (
          'Allow updates',
          'Android asks once if $appName may install its own updates. Turn on "Allow from this source", then come back here.',
        ),
      UpdateStep.downloading => ('Downloading version ${r.version}', '${(updater.progress * 100).floor()}% of ${_mb(r.size)}'),
      UpdateStep.installing => (
          'Installing version ${r.version}',
          updater.silent
              ? '$appName closes for a moment while the update goes in. Then open it again.'
              : 'Tap Update when Android asks. $appName closes for a moment while the update goes in.',
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
    return Pressable(label: 'What is new in version ${r.version}', onTap: () => _whatsNew(context, r), child: card);
  }

  Future<void> _whatsNew(BuildContext context, Release r) => showCentredCard<void>(
        context,
        title: 'Version ${r.version}',
        subtitle: 'What is new',
        builder: (ctx) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Fig(r.notes, style: bodyStyle),
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

/// A newer version is out and a student is about to start a test: offers the update first, because it closes the app for a moment while
/// it goes in. True when she chooses to start anyway; false when she closed the card or began the update.
Future<bool> offerUpdateFirst(BuildContext context, {required Release release, required String testTitle, DateTime? closes}) async {
  final startAnyway = await showCentredCard<bool>(
    context,
    title: 'Update first',
    subtitle: 'Version ${release.version} is ready · ${_mb(release.size)}',
    builder: (ctx) => _UpdateFirst(release: release, testTitle: testTitle, closes: closes, onStartAnyway: () => Navigator.of(ctx).pop(true)),
  );
  return startAnyway ?? false;
}

class _UpdateFirst extends StatelessWidget {
  const _UpdateFirst({required this.release, required this.testTitle, required this.closes, required this.onStartAnyway});
  final Release release;
  final String testTitle;
  final DateTime? closes;
  final VoidCallback onStartAnyway;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: updater,
        builder: (context, _) {
          final step = updater.step;
          // Once the update is on its way a test must not start: Android closes the app while the new version goes in.
          final working = step == UpdateStep.downloading || step == UpdateStep.installing;
          return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Fig('Update now, then start your test. It takes about a minute, and your login, tests and results stay as they are.', style: bodyStyle),
            if (closes != null) ...[
              const SizedBox(height: 11),
              Text.rich(TextSpan(children: [
                figSpan(testTitle, bodyStyle.copyWith(color: ink, fontWeight: FontWeight.w600)),
                figSpan(' stays open until ${f.whenDate(closes!)}.', bodyStyle),
              ])),
            ],
            const SizedBox(height: 20),
            // After the first tap the steps (Android's permission, the download, a failure) show here, as they do on Home.
            if (step == UpdateStep.ready)
              PrimaryButton('Update to version ${release.version}', leadingIcon: Ph.arrowCircleUp, onTap: updater.update)
            else
              UpdateCard(release: release),
            if (!working) ...[
              const SizedBox(height: 4),
              Center(child: TextAction('Start anyway', onTap: onStartAnyway)),
            ],
          ]);
        },
      );
}

/// Settings and Profile: the version on this phone, and a way to look for a newer one now.
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
    final newer = await updater.check(force: true);
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
                Fig(updater.version ?? '-', style: rowTitleStyle),
              ]),
            ),
            if (r != null) ...[
              const SizedBox(height: 10),
              UpdateCard(release: r),
            ] else if (updater.enabled) ...[
              const SizedBox(height: 10),
              SecondaryButton(_checking ? 'Checking' : 'Check for updates', icon: Ph.arrowsClockwise, onTap: _checking ? null : _check),
            ],
            if (_checked && r == null) ...[
              const SizedBox(height: 10),
              if (_newer == null)
                const InlineNotice('Could not reach the update server. Check the internet and try again.', tone: Tone.warning, icon: Ph.warning)
              else
                const InlineNotice('This is the newest version.', tone: Tone.success, icon: Ph.checkCircle),
            ],
          ]);
        },
      );
}
