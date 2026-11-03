import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../core/api.dart';
import '../../core/format.dart' as f;
import '../../core/library.dart';
import '../../theme.dart';
import '../../ui/kit.dart';
import '../library/file_viewer.dart';
import '../library/library_widgets.dart';
import 'common.dart';

// The Library tab of a group's or a course's page: the sections of its shelf and the files in them, with everything a tutor can do (add a
// section, add files, rename, move and delete). Students see the same shelf, read-only (features/student/library_screens.dart).

/// The names offered when a shelf has no sections yet, and in the card that asks for a name.
const _suggestions = ['PDFs', 'Books', 'Test papers'];

class LibraryTab extends StatefulWidget {
  const LibraryTab({super.key, required this.shelf, required this.className, required this.reload});

  final LibShelf shelf;

  /// What the page above is called ("10th Maths"): said in the cards, and above a file when it is opened.
  final String className;

  /// Changes whenever the page above loaded again, so the shelf is loaded again with it.
  final int reload;

  @override
  State<LibraryTab> createState() => _LibraryTabState();
}

class _LibraryTabState extends State<LibraryTab> {
  List<LibSection>? _sections;
  String? _error;
  int _seenDone = LibraryEnv.uploads.doneCount;

  /// The words typed in the search box: while there are some, the shelf shows the files found instead of its sections.
  final _query = TextEditingController();

  @override
  void initState() {
    super.initState();
    LibraryEnv.uploads.addListener(_onUploads);
    _load();
  }

  @override
  void didUpdateWidget(LibraryTab old) {
    super.didUpdateWidget(old);
    if (old.reload != widget.reload) _load();
  }

  @override
  void dispose() {
    LibraryEnv.uploads.removeListener(_onUploads);
    _query.dispose();
    super.dispose();
  }

  /// A file finished going up: the shelf is loaded again to show it. Any other news (progress) only redraws the rows.
  void _onUploads() {
    if (!mounted) return;
    if (LibraryEnv.uploads.doneCount != _seenDone) {
      _seenDone = LibraryEnv.uploads.doneCount;
      _load();
    }
    setState(() {});
  }

  Future<void> _load() async {
    try {
      final d = await api.get(widget.shelf.path);
      final lib = Map<String, dynamic>.from(d['library'] as Map);
      if (mounted) {
        setState(() {
          _sections = [for (final s in lib['sections'] as List) LibSection.fromJson(Map<String, dynamic>.from(s as Map))];
          _error = null;
        });
      }
    } on ApiException catch (e) {
      if (mounted && _sections == null) setState(() => _error = e.message);
    }
  }

  // ------------------------------------------------------------ sections

  /// Asks for a section's name and makes it. The card stays open, with the reason, when the server refuses the name.
  Future<void> _addSection() async {
    final made = await showCentredCard<Map<String, dynamic>>(
      context,
      title: 'New section',
      subtitle: 'Name it so students know what is inside',
      builder: (ctx) => _NameCard(
        label: 'Section name',
        placeholder: 'e.g. Test papers',
        button: 'Add section',
        suggestions: [for (final s in _suggestions) if (!(_sections ?? const []).any((x) => x.name.toLowerCase() == s.toLowerCase())) s],
        save: (name) async => Map<String, dynamic>.from(await api.post('${widget.shelf.path}/sections', {'name': name}) as Map),
      ),
    );
    if (made != null && mounted) _load();
  }

  /// Makes a section from one of the suggested names without asking.
  Future<void> _create(String name) async {
    try {
      await api.post('${widget.shelf.path}/sections', {'name': name});
      if (mounted) _load();
    } on ApiException catch (e) {
      if (mounted) showProblem(context, e);
    }
  }

  /// Moves a section one place up or down the shelf. The list changes on screen at once; the server is told the new order, and when it
  /// refuses (the list changed meanwhile) the tutor is told why and the shelf is loaded again.
  Future<void> _moveSection(LibSection s, int by) async {
    final list = [...?_sections];
    final i = list.indexWhere((x) => x.id == s.id);
    final j = i + by;
    if (i < 0 || j < 0 || j >= list.length) return;
    list.insert(j, list.removeAt(i));
    setState(() => _sections = list);
    try {
      await api.put('${widget.shelf.path}/sections/order', {'ids': [for (final x in list) x.id]});
    } on ApiException catch (e) {
      if (mounted) await showProblem(context, e);
    }
    if (mounted) _load();
  }

  Future<void> _sectionMenu(LibSection s) async {
    final at = (_sections ?? const <LibSection>[]).indexWhere((x) => x.id == s.id);
    final last = (_sections ?? const <LibSection>[]).length - 1;
    final what = await showActions<String>(
      context,
      title: s.name,
      subtitle: f.count(s.files.length, 'file'),
      items: [
        const MenuItem(Ph.plus, 'Add a file', 'add'),
        const MenuItem(Ph.pencilSimple, 'Rename section', 'rename'),
        if (at > 0) const MenuItem(Ph.arrowUp, 'Move up', 'up'),
        if (at >= 0 && at < last) const MenuItem(Ph.arrowDown, 'Move down', 'down'),
        const MenuItem(Ph.trash, 'Delete section', 'delete', danger: true),
      ],
    );
    if (what == null || !mounted) return;
    switch (what) {
      case 'up':
        await _moveSection(s, -1);
      case 'down':
        await _moveSection(s, 1);
      case 'add':
        await _addFile(s);
      case 'rename':
        final r = await showCentredCard<Map<String, dynamic>>(
          context,
          title: 'Rename section',
          subtitle: 'Its files stay where they are',
          builder: (ctx) => _NameCard(
            label: 'Section name',
            placeholder: 'Section name',
            button: 'Save',
            initial: s.name,
            save: (name) async => Map<String, dynamic>.from(await api.patch('/teacher/library/sections/${s.id}', {'name': name}) as Map),
          ),
        );
        if (r != null && mounted) _load();
      case 'delete':
        await _deleteSection(s);
    }
  }

  Future<void> _deleteSection(LibSection s) async {
    final n = s.files.length;
    final yes = await confirmCard(
      context,
      title: 'Delete ${s.name}?',
      body: n == 0
          ? 'This deletes the empty section ${s.name}.'
          : 'This deletes ${s.name} and ${n == 1 ? 'its 1 file' : 'its $n files'}. Students will not be able to open ${n == 1 ? 'it' : 'them'} any more. This cannot be undone.',
      confirm: 'Delete section',
      destructive: true,
    );
    if (!yes || !mounted) return;
    try {
      await api.delete('/teacher/library/sections/${s.id}${n > 0 ? '?with_files=1' : ''}');
      if (mounted) _load();
    } on ApiException catch (e) {
      if (mounted) showProblem(context, e);
    }
  }

  // ------------------------------------------------------------ files

  /// Asks where the file comes from, picks it and starts adding it. It shows in its section at once, with how far it has got.
  Future<void> _addFile(LibSection s) async {
    final how = await showActions<String>(
      context,
      title: 'Add a file',
      subtitle: 'To ${s.name}, in ${widget.className}',
      items: const [
        MenuItem(Ph.filePdf, 'A PDF from this phone', 'pdf'),
        MenuItem(Ph.image, 'A photo from the gallery', 'gallery'),
        MenuItem(Ph.camera, 'Take a photo', 'camera'),
      ],
      footnote: 'PDFs and photos, up to 100 MB each.',
    );
    if (how == null || !mounted) return;
    List<PickedFile> picked;
    try {
      picked = switch (how) {
        'pdf' => await LibraryEnv.sources.pickPdfs(),
        'gallery' => await LibraryEnv.sources.pickPhotos(),
        _ => [?await LibraryEnv.sources.takePhoto()],
      };
    } on PlatformException catch (e) {
      if (mounted) showProblem(context, ApiException(0, 'picker', 'The phone would not give the file.${e.message == null ? '' : ' ${e.message}'}'));
      return;
    }
    if (picked.isEmpty || !mounted) return;
    final tooBig = picked.where((x) => x.size > maxFileBytes).toList();
    final fine = picked.where((x) => x.size > 0 && x.size <= maxFileBytes).toList();
    if (tooBig.isNotEmpty) {
      await showProblem(
        context,
        ApiException(0, 'too_big', tooBig.length == 1 ? '${tooBig.first.name} is bigger than 100 MB, so it cannot be added.' : '${tooBig.length} of those files are bigger than 100 MB, so they cannot be added.'),
      );
    }
    if (fine.isNotEmpty && mounted) LibraryEnv.uploads.add(widget.shelf.key, s.id, fine);
  }

  void _open(LibSection s, LibFile file) => context.push('/library/file', extra: FileViewerArgs(file, where: '${widget.className} · ${s.name}', teacher: true));

  /// Moves a file one place up or down inside its section, the same way a section is moved.
  Future<void> _moveFile(LibSection s, LibFile file, int by) async {
    final all = [...?_sections];
    final at = all.indexWhere((x) => x.id == s.id);
    if (at < 0) return;
    final files = [...all[at].files];
    final i = files.indexWhere((x) => x.id == file.id);
    final j = i + by;
    if (i < 0 || j < 0 || j >= files.length) return;
    files.insert(j, files.removeAt(i));
    all[at] = LibSection(s.id, s.name, files);
    setState(() => _sections = all);
    try {
      await api.put('/teacher/library/sections/${s.id}/files/order', {'ids': [for (final x in files) x.id]});
    } on ApiException catch (e) {
      if (mounted) await showProblem(context, e);
    }
    if (mounted) _load();
  }

  Future<void> _fileMenu(LibSection s, LibFile file) async {
    final at = s.files.indexWhere((x) => x.id == file.id);
    final what = await showActions<String>(
      context,
      title: file.name,
      subtitle: [file.isPdf ? 'PDF' : 'Photo', sizeLabel(file.size), 'in ${s.name}'].join(' · '),
      items: [
        const MenuItem(Ph.pencilSimple, 'Rename', 'rename'),
        const MenuItem(Ph.folderSimple, 'Move to another section', 'move'),
        if (at > 0) const MenuItem(Ph.arrowUp, 'Move up', 'up'),
        if (at >= 0 && at < s.files.length - 1) const MenuItem(Ph.arrowDown, 'Move down', 'down'),
        const MenuItem(Ph.trash, 'Delete this file', 'delete', danger: true),
      ],
    );
    if (what == null || !mounted) return;
    switch (what) {
      case 'up':
        await _moveFile(s, file, -1);
      case 'down':
        await _moveFile(s, file, 1);
      case 'rename':
        final ext = file.name.substring(file.title.length);
        final r = await showCentredCard<Map<String, dynamic>>(
          context,
          title: 'Rename file',
          subtitle: ext.isEmpty ? null : 'It stays a $ext file',
          builder: (ctx) => _NameCard(
            label: 'File name',
            placeholder: 'File name',
            button: 'Save',
            initial: file.title,
            maxLength: 120 - ext.length,
            save: (name) async => Map<String, dynamic>.from(await api.patch('/teacher/library/files/${file.id}', {'name': '$name$ext'}) as Map),
          ),
        );
        if (r != null && mounted) _load();
      case 'move':
        await _move(s, file);
      case 'delete':
        final yes = await confirmCard(
          context,
          title: 'Delete this file?',
          body: '${file.name} will be removed from the Library. Students will not be able to open it any more. This cannot be undone.',
          confirm: 'Delete file',
          destructive: true,
        );
        if (!yes || !mounted) return;
        try {
          await api.delete('/teacher/library/files/${file.id}');
          if (mounted) _load();
        } on ApiException catch (e) {
          if (mounted) showProblem(context, e);
        }
    }
  }

  Future<void> _move(LibSection from, LibFile file) async {
    final others = [for (final x in _sections ?? const <LibSection>[]) if (x.id != from.id) x];
    if (others.isEmpty) {
      final add = await showCentredCard<bool>(
        context,
        title: 'Add another section first',
        builder: (ctx) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Fig('A file moves from one section to another. This shelf has only ${from.name} so far.', style: bodyStyle),
          const SizedBox(height: 18),
          PrimaryButton('Add a section', leadingIcon: Ph.plus, onTap: () => Navigator.of(ctx).pop(true)),
        ]),
      );
      if (add == true && mounted) await _addSection();
      return;
    }
    final to = await showChoices<String>(
      context,
      title: 'Move to',
      subtitle: file.name,
      options: [for (final x in others) Choice(x.id, x.name, count: x.files.length)],
      selected: null,
    );
    if (to?.value == null || !mounted) return;
    try {
      await api.patch('/teacher/library/files/${file.id}', {'section_id': to!.value});
      if (mounted) _load();
    } on ApiException catch (e) {
      if (mounted) showProblem(context, e);
    }
  }

  // ------------------------------------------------------------ the page

  @override
  Widget build(BuildContext context) {
    final sections = _sections;
    if (sections == null) return _error != null ? ErrorState(message: _error!, onRetry: _load) : const LoadingState(rows: 2);
    if (sections.isEmpty) return _empty();
    final jobs = LibraryEnv.uploads.forShelf(widget.shelf.key);
    final q = _query.text.trim();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      // Something to search once there is a file on the shelf.
      if (sections.any((s) => s.files.isNotEmpty)) ...[
        SearchBox(controller: _query, placeholder: 'Search files', onChanged: (_) => setState(() {})),
        const SizedBox(height: 14),
      ],
      if (q.isNotEmpty)
        ..._found(sections, q)
      else ...[
        for (final s in sections) ...[
          SectionCard(
            name: s.name,
            count: s.files.length,
            onMenu: () => _sectionMenu(s),
            rows: [
              for (final file in s.files)
                FileRowView(
                  file: file,
                  onTap: () => _open(s, file),
                  trailing: RowAction(icon: Ph.dotsThreeVertical, label: 'Options for ${file.name}', onTap: () => _fileMenu(s, file)),
                ),
              for (final j in jobs.where((j) => j.sectionId == s.id))
                UploadRowView(job: j, onCancel: () => LibraryEnv.uploads.cancel(j), onRetry: () => LibraryEnv.uploads.retry(j)),
            ],
            footer: _AddFileRow(onTap: () => _addFile(s)),
          ),
          const SizedBox(height: gapRow),
        ],
        SecondaryButton('Add a section', icon: Ph.plus, onTap: _addSection),
        if (jobs.isNotEmpty) ...[
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Padding(padding: const EdgeInsets.only(top: 1), child: Icon(Ph.info, size: 16, color: faint)),
              const SizedBox(width: 10),
              Expanded(child: Fig('Keep the app open while files are added. Students see a file once it has finished, and are told about it then.', style: labelStyle)),
            ]),
          ),
        ],
      ],
    ]);
  }

  /// The files with the typed words in their name, from every section, each saying which section it is in.
  List<Widget> _found(List<LibSection> sections, String q) {
    final found = findFiles(sections, q);
    if (found.isEmpty) return [NothingFound(q)];
    return [
      SectionCard(
        name: 'Found',
        count: found.length,
        rows: [
          for (final x in found)
            FileRowView(
              file: x.file,
              section: x.section.name,
              highlight: q,
              onTap: () => _open(x.section, x.file),
              trailing: RowAction(icon: Ph.dotsThreeVertical, label: 'Options for ${x.file.name}', onTap: () => _fileMenu(x.section, x.file)),
            ),
        ],
      ),
    ];
  }

  Widget _empty() => Column(children: [
        EmptyState(
          icon: Ph.books,
          title: 'Nothing here yet',
          body: 'Add a section, like PDFs or Books, then put files in it. Your students can read and download them, but not change them.',
          action: SizedBox(width: 210, child: PrimaryButton('Add a section', leadingIcon: Ph.plus, onTap: _addSection)),
        ),
        Fig('Or start with one of these', style: labelStyle),
        const SizedBox(height: 14),
        Wrap(spacing: 8, runSpacing: 8, alignment: WrapAlignment.center, children: [for (final n in _suggestions) SuggestPill(n, onTap: () => _create(n))]),
      ]);
}

/// The last row of a section: where a tutor adds a file to it.
class _AddFileRow extends StatelessWidget {
  const _AddFileRow({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Pressable(
        label: 'Add a file',
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
          child: Row(children: [
            Icon(Ph.plus, size: 17, color: muted),
            const SizedBox(width: 10),
            Text('Add a file', style: chipStyle.copyWith(color: body, fontWeight: FontWeight.w700)),
          ]),
        ),
      );
}

/// A card that asks for a name (a new section, a section or a file being renamed). It sends the name itself and closes with the server's
/// answer; when the server refuses it (a name already used) the reason shows here and the card stays.
class _NameCard extends StatefulWidget {
  const _NameCard({
    required this.label,
    required this.placeholder,
    required this.button,
    required this.save,
    this.initial = '',
    this.suggestions = const [],
    this.maxLength = 40,
  });

  final String label;
  final String placeholder;
  final String button;
  final String initial;
  final List<String> suggestions;
  final int maxLength;
  final Future<Map<String, dynamic>> Function(String name) save;

  @override
  State<_NameCard> createState() => _NameCardState();
}

class _NameCardState extends State<_NameCard> {
  late final _name = TextEditingController(text: widget.initial);
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  bool get _ready => _name.text.trim().isNotEmpty && _name.text.trim() != widget.initial;

  Future<void> _send() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await widget.save(_name.text.trim());
      if (mounted) Navigator.of(context).pop(r);
    } on ApiException catch (e) {
      if (mounted) {
        setState(() {
          _error = e.message;
          _busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(widget.label, style: labelStyle),
        const SizedBox(height: 8),
        GroupedInputs(children: [
          BareField(
            controller: _name,
            placeholder: widget.placeholder,
            autofocus: true,
            maxLength: widget.maxLength,
            capitalization: TextCapitalization.sentences,
            action: TextInputAction.done,
            onChanged: (_) => setState(() => _error = null),
            onSubmitted: (_) {
              if (_ready && !_busy) _send();
            },
          ),
        ]),
        ListenableBuilder(
          listenable: _name,
          builder: (context, _) {
            final typed = _name.text.trim().toLowerCase();
            final shown = [for (final s in widget.suggestions) if (s.toLowerCase() != typed) s];
            if (shown.isEmpty) return const SizedBox.shrink();
            return Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Wrap(spacing: 8, runSpacing: 8, children: [
                for (final s in shown)
                  SuggestPill(s, onTap: () {
                    _name.text = s;
                    _name.selection = TextSelection.collapsed(offset: s.length);
                    setState(() => _error = null);
                  }),
              ]),
            );
          },
        ),
        if (_error != null) ...[const SizedBox(height: 12), InlineNotice(_error!, tone: Tone.danger, icon: Ph.warning)],
        const SizedBox(height: 16),
        ListenableBuilder(
          listenable: _name,
          builder: (context, _) => PrimaryButton(widget.button, busy: _busy, onTap: _ready ? _send : null),
        ),
      ]);
}
