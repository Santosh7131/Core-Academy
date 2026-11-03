import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/library.dart';
import '../../theme.dart';
import '../../ui/kit.dart';

// The pieces both sides of the Library are made of: a titled box with files in it, a file's row, a file that is still being added, and the
// short card of things to do with a file or a section.

/// A file's picture: a page for a PDF, a soft picture tile for a photo.
class FileTile extends StatelessWidget {
  const FileTile({super.key, required this.photo});
  final bool photo;

  @override
  Widget build(BuildContext context) => Container(
        width: 44,
        height: 44,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: photo ? null : fill,
          gradient: photo
              ? LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: isDark ? const [Color(0xFF3B4863), Color(0xFF28334A)] : const [Color(0xFFC9D4EC), Color(0xFF9DB0D8)],
                )
              : null,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(photo ? Ph.image : Ph.filePdf, size: 22, color: photo ? (isDark ? muted : const Color(0xFFF7F9FD)) : muted),
      );
}

/// The number of files in a section, in a small round tag.
class CountPill extends StatelessWidget {
  const CountPill(this.count, {super.key});
  final int count;

  @override
  Widget build(BuildContext context) => Container(
        constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        alignment: Alignment.center,
        decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(rPill)),
        child: Text('$count', style: numStyle(size: 11.5, color: muted)),
      );
}

/// A titled box: the section's name with how many files it holds and, for a tutor, a button for what can be done with the section; then the
/// rows, split by hairlines; then an optional last row (add a file).
class SectionCard extends StatelessWidget {
  const SectionCard({super.key, required this.name, required this.count, this.onMenu, required this.rows, this.footer});
  final String name;
  final int count;

  /// The "..." button; null on a student's screen, where nothing can be changed.
  final VoidCallback? onMenu;
  final List<Widget> rows;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    Widget rule() => Container(height: 1, margin: const EdgeInsets.symmetric(horizontal: 16), color: hairline);
    return Container(
      decoration: surface(radius: rCard, shadow: e1),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: EdgeInsets.fromLTRB(18, onMenu == null ? 15 : 12, onMenu == null ? 16 : 12, onMenu == null ? 13 : 10),
          child: Row(children: [
            Expanded(child: Fig(name, style: sectionStyle, maxLines: 2)),
            const SizedBox(width: 10),
            CountPill(count),
            if (onMenu != null) ...[
              const SizedBox(width: 8),
              CircleBtn(icon: Ph.dotsThree, size: 36, ground: fill, label: 'Options for $name', onTap: onMenu),
            ],
          ]),
        ),
        for (final r in rows) ...[rule(), r],
        if (footer != null) ...[rule(), footer!],
      ]),
    );
  }
}

/// [text] with the first stretch that matches [query] (capitals do not matter) in heavy ink: what was typed, shown inside what was found.
TextSpan highlighted(String text, String query, TextStyle style) {
  final at = text.toLowerCase().indexOf(query.toLowerCase());
  // Some letters change length when lowered; then the place found is not the place in the text, so nothing is marked.
  if (query.isEmpty || at < 0 || text.toLowerCase().length != text.length) return figSpan(text, style);
  final end = at + query.length;
  return TextSpan(children: [
    figSpan(text.substring(0, at), style),
    figSpan(text.substring(at, end), style.copyWith(fontWeight: FontWeight.w800, color: ink)),
    figSpan(text.substring(end), style),
  ]);
}

/// A finished file: its picture, name and details, and something at the right (the tutor's "...", the student's download). For a file a
/// search found, [section] says which section it is in and [highlight] marks what was typed in its name.
class FileRowView extends StatelessWidget {
  const FileRowView({super.key, required this.file, this.onTap, this.trailing, this.section, this.highlight});
  final LibFile file;
  final VoidCallback? onTap;
  final Widget? trailing;
  final String? section;
  final String? highlight;

  @override
  Widget build(BuildContext context) {
    final marked = highlight != null && highlight!.isNotEmpty;
    return Pressable(
      onTap: onTap,
      child: Padding(
        padding: EdgeInsets.fromLTRB(14, 11, trailing == null ? 14 : 8, 11),
        child: Row(children: [
          FileTile(photo: !file.isPdf),
          const SizedBox(width: 13),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (marked) Text.rich(highlighted(file.name, highlight!, rowTitleStyle), maxLines: 2, overflow: TextOverflow.ellipsis) else Fig(file.name, style: rowTitleStyle, maxLines: 2),
              const SizedBox(height: 2),
              if (section == null)
                Fig(file.meta, style: labelStyle, maxLines: 2)
              else
                Text.rich(
                  TextSpan(children: [
                    figSpan('in ', labelStyle),
                    figSpan(section!, labelStyle.copyWith(color: ink, fontWeight: FontWeight.w700)),
                    figSpan(' · ${file.isPdf ? 'PDF' : 'Photo'} · ${sizeLabel(file.size)}', labelStyle),
                  ]),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
            ]),
          ),
          if (trailing != null) ...[const SizedBox(width: 6), trailing!],
        ]),
      ),
    );
  }
}

/// A search field: a magnifier, the words typed, and once there are some, a button that clears them.
class SearchBox extends StatelessWidget {
  const SearchBox({super.key, required this.controller, required this.placeholder, required this.onChanged});
  final TextEditingController controller;
  final String placeholder;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) => Container(
        decoration: surface(radius: rCard, shadow: e1),
        padding: const EdgeInsets.fromLTRB(16, 0, 6, 0),
        child: Row(children: [
          Icon(Ph.magnifyingGlass, size: 19, color: muted),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              controller: controller,
              onChanged: onChanged,
              textInputAction: TextInputAction.search,
              inputFormatters: [LengthLimitingTextInputFormatter(60)],
              autocorrect: false,
              enableSuggestions: false,
              cursorColor: ink,
              style: rowTitleStyle.copyWith(fontWeight: FontWeight.w500, fontSize: 15),
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                hintText: placeholder,
                hintStyle: rowTitleStyle.copyWith(color: faint, fontWeight: FontWeight.w500, fontSize: 15),
                contentPadding: const EdgeInsets.symmetric(vertical: 16),
              ),
            ),
          ),
          ListenableBuilder(
            listenable: controller,
            builder: (context, _) => controller.text.isEmpty
                ? const SizedBox(width: 10)
                : Pressable(
                    label: 'Clear the search',
                    onTap: () {
                      controller.clear();
                      onChanged('');
                    },
                    child: SizedBox(
                      width: 44,
                      height: 44,
                      child: Center(
                        child: Container(
                          width: 28,
                          height: 28,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(color: fill, shape: BoxShape.circle),
                          child: Icon(Ph.x, size: 14, color: muted),
                        ),
                      ),
                    ),
                  ),
          ),
        ]),
      );
}

/// What the Library says when a search finds nothing.
class NothingFound extends StatelessWidget {
  const NothingFound(this.query, {super.key});
  final String query;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 34, 24, 0),
        child: Fig('No file has "${query.trim()}" in its name.', style: bodyStyle.copyWith(color: muted), textAlign: TextAlign.center),
      );
}

/// A round button at the end of a row: big enough to hit with a thumb, quiet enough not to shout.
class RowAction extends StatelessWidget {
  const RowAction({super.key, required this.icon, required this.label, required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Pressable(
        label: label,
        onTap: onTap,
        child: SizedBox(
          width: 44,
          height: 44,
          child: Center(
            child: Container(
              width: 34,
              height: 34,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: fill, shape: BoxShape.circle),
              child: Icon(icon, size: 17, color: body),
            ),
          ),
        ),
      );
}

/// A file that is being added: how far it has got, a way to stop it, and, when it stopped by itself, why and a way to try again.
class UploadRowView extends StatelessWidget {
  const UploadRowView({super.key, required this.job, required this.onCancel, required this.onRetry});
  final UploadJob job;
  final VoidCallback onCancel;
  final VoidCallback onRetry;

  String get _status {
    switch (job.state) {
      case UploadState.waiting:
        return 'Waiting · ${sizeLabel(job.file.size)}';
      case UploadState.sending:
        final left = job.timeLeft;
        return '${sizeLabel(job.file.size)} · ${job.percent}%${left == null ? '' : ' · $left'}';
      case UploadState.finishing:
        return 'Almost done';
      case UploadState.stopped:
        return job.offline || job.sent > 0 && job.retryable ? 'Stopped at ${job.percent}%, ${job.problem ?? 'something went wrong'}' : '${job.problem}';
    }
  }

  @override
  Widget build(BuildContext context) {
    final stopped = job.state == UploadState.stopped;
    final working = job.state == UploadState.sending || job.state == UploadState.finishing;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 11, 10, 11),
      child: Row(children: [
        FileTile(photo: !job.file.contentType.contains('pdf')),
        const SizedBox(width: 13),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Fig(job.file.name, style: rowTitleStyle, maxLines: 2),
            const SizedBox(height: 2),
            Fig(_status, style: labelStyle.copyWith(color: stopped ? warning : muted), maxLines: 3),
            if (working) ...[const SizedBox(height: 8), Track(job.state == UploadState.finishing ? 1 : job.fraction, height: 4)],
          ]),
        ),
        const SizedBox(width: 8),
        if (stopped && job.retryable) _SmallButton('Try again', onRetry) else RowAction(icon: Ph.x, label: stopped ? 'Remove ${job.file.name}' : 'Stop adding ${job.file.name}', onTap: onCancel),
      ]),
    );
  }
}

class _SmallButton extends StatelessWidget {
  const _SmallButton(this.label, this.onTap);
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Pressable(
        label: label,
        onTap: onTap,
        child: Container(
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          alignment: Alignment.center,
          decoration: surface(radius: rPill, shadow: e1),
          child: Text(label, style: chipStyle.copyWith(color: ink, fontWeight: FontWeight.w700)),
        ),
      );
}

/// One thing a card offers: an icon, words, and what it answers with.
class MenuItem<T> {
  const MenuItem(this.icon, this.label, this.value, {this.danger = false});
  final IconData icon;
  final String label;
  final T value;
  final bool danger;
}

/// A short card of things to do, one to a row (add a file; rename, move or delete one). Returns the value of the row tapped.
Future<T?> showActions<T>(BuildContext context, {required String title, String? subtitle, required List<MenuItem<T>> items, String? footnote}) =>
    showCentredCard<T>(
      context,
      title: title,
      subtitle: subtitle,
      builder: (ctx) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        for (final (i, x) in items.indexed) ...[
          if (i > 0) Container(height: 1, margin: const EdgeInsets.symmetric(horizontal: 4), color: hairline),
          Pressable(
            label: x.label,
            onTap: () => Navigator.of(ctx).pop(x.value),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 15),
              child: Row(children: [
                Icon(x.icon, size: 21, color: x.danger ? danger : body),
                const SizedBox(width: 14),
                Expanded(child: Fig(x.label, style: rowTitleStyle.copyWith(color: x.danger ? danger : ink))),
              ]),
            ),
          ),
        ],
        if (footnote != null) ...[const SizedBox(height: 10), Fig(footnote, style: labelStyle)],
      ]),
    );

/// A small pill that suggests a section name: a plus and the name.
class SuggestPill extends StatelessWidget {
  const SuggestPill(this.label, {super.key, required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Pressable(
        label: 'Add $label',
        onTap: onTap,
        child: Container(
          height: 38,
          padding: const EdgeInsets.fromLTRB(12, 0, 15, 0),
          decoration: surface(radius: rPill, shadow: e1),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Ph.plus, size: 15, color: muted),
            const SizedBox(width: 7),
            Text(label, style: chipStyle.copyWith(color: ink, fontWeight: FontWeight.w700)),
          ]),
        ),
      );
}
