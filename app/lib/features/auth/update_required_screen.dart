import 'package:flutter/material.dart';

import '../../core/brand.dart';
import '../../core/updater.dart';
import '../../theme.dart';
import '../../ui/kit.dart';
import '../../ui/update_card.dart';

/// Shown instead of every other screen when the server no longer accepts this version of the app (a major update
/// is out). The router sends everyone here until the new version is installed, signed in or not. The update itself
/// is the one the Home banner offers: the same steps, with the permission Android asks for once.
class UpdateRequiredScreen extends StatefulWidget {
  const UpdateRequiredScreen({super.key});

  @override
  State<UpdateRequiredScreen> createState() => _UpdateRequiredScreenState();
}

class _UpdateRequiredScreenState extends State<UpdateRequiredScreen> {
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    if (updater.available == null) _check();
  }

  Future<void> _check() async {
    setState(() => _checking = true);
    await updater.check(force: true);
    if (mounted) setState(() => _checking = false);
  }

  @override
  Widget build(BuildContext context) => PopScope(
        canPop: false,
        child: Scaffold(
          body: SafeArea(
            child: ListenableBuilder(
              listenable: updater,
              builder: (context, _) {
                final r = updater.available;
                final ready = r != null && updater.step == UpdateStep.ready;
                return Column(children: [
                  Expanded(
                    child: Center(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.symmetric(horizontal: gutter + 8, vertical: 24),
                        child: Column(mainAxisSize: MainAxisSize.min, children: [
                          Container(
                            width: 92,
                            height: 92,
                            decoration: surface(radius: rPill, shadow: e2),
                            child: Icon(Ph.arrowCircleUp, size: 40, color: ink),
                          ),
                          const SizedBox(height: 26),
                          const Kicker('Update needed'),
                          const SizedBox(height: 10),
                          Text('Please update $appName', style: displayStyle, textAlign: TextAlign.center),
                          const SizedBox(height: 14),
                          Fig(
                            'This version can no longer open your tests. The update takes about a minute, and your login, tests and results stay as they are.',
                            style: bodyStyle.copyWith(color: muted),
                            textAlign: TextAlign.center,
                          ),
                          // After the first tap the steps (Android's permission, the download, a failure) show here.
                          if (r != null && !ready) ...[const SizedBox(height: 26), UpdateCard(release: r)],
                          if (r == null) ...[
                            const SizedBox(height: 26),
                            if (_checking)
                              Fig('Looking for the new version', style: labelStyle, textAlign: TextAlign.center)
                            else ...[
                              Fig(
                                updater.enabled
                                    ? 'The new version could not be found. Check the internet and try again.'
                                    : 'This test build does not look for updates.',
                                style: labelStyle,
                                textAlign: TextAlign.center,
                              ),
                              if (updater.enabled) ...[
                                const SizedBox(height: 14),
                                SecondaryButton('Try again', icon: Ph.arrowsClockwise, onTap: _check),
                              ],
                            ],
                          ],
                        ]),
                      ),
                    ),
                  ),
                  if (ready)
                    Container(
                      padding: const EdgeInsets.fromLTRB(gutter, 14, gutter, 12),
                      decoration: BoxDecoration(border: Border(top: BorderSide(color: hairline))),
                      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        PrimaryButton('Update to version ${r.version}', leadingIcon: Ph.arrowCircleUp, onTap: updater.update),
                        const SizedBox(height: 9),
                        Fig('${(r.size / (1024 * 1024)).round()} MB · uses your internet', style: labelStyle, textAlign: TextAlign.center),
                      ]),
                    ),
                ]);
              },
            ),
          ),
        ),
      );
}
