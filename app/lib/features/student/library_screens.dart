import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/api.dart';
import '../../core/changes.dart';
import '../../core/format.dart' as f;
import '../../core/levels.dart';
import '../../core/library.dart';
import '../../theme.dart';
import '../../ui/kit.dart';
import '../library/file_viewer.dart';
import '../library/library_widgets.dart';

// The student's side of the Library: the classes (groups and courses) that have files, one class's sections, and a file to read or download.
// Students can only read here; the tutor changes the shelves (features/teacher/library_tab.dart).

/// One class's shelf as a student sees it: a group they are in or a course they are in, with the sections that have files.
class ClassShelf {
  const ClassShelf({required this.key, required this.isCourse, required this.title, required this.sections});

  /// 'group:10:' and the subject's id, or 'course:' and the course's id: how the class page finds its shelf again.
  final String key;
  final bool isCourse;
  final String title;
  final List<LibSection> sections;

  int get files => sections.fold(0, (n, s) => n + s.files.length);

  /// "4 files in 3 sections".
  String get meta => '${f.count(files, 'file')} in ${f.count(sections.length, 'section')}';
}

/// Every shelf the student can read, groups first and then courses.
Future<List<ClassShelf>> loadShelves() async {
  final r = await api.get('/student/library') as Map;
  List<LibSection> sections(Object? raw) => [for (final s in (raw as List? ?? const [])) LibSection.fromJson(Map<String, dynamic>.from(s as Map))];
  return [
    for (final g in (r['groups'] as List? ?? const []))
      ClassShelf(
        key: 'group:${g['class_level']}:${g['subject_id']}',
        isCourse: false,
        title: groupName((g['class_level'] as num).toInt(), '${g['subject']}'),
        sections: sections(g['sections']),
      ),
    for (final c in (r['courses'] as List? ?? const []))
      ClassShelf(key: 'course:${c['id']}', isCourse: true, title: '${c['name']}', sections: sections(c['sections'])),
  ];
}

/// A class's page, with its name so the page has its title before it has loaded.
String libraryClassPath(ClassShelf s) => '/s/library/class?k=${Uri.encodeComponent(s.key)}&name=${Uri.encodeComponent(s.title)}';

/// The Library tab of the student's home: the classes that have files, one row each.
List<Widget> libraryRows(List<ClassShelf> shelves, {required void Function(ClassShelf shelf) onOpen}) => [
      const SizedBox(height: 18),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: gutter),
        child: Column(children: [
          for (final (i, s) in shelves.indexed) ...[
            if (i > 0) const SizedBox(height: gapRow),
            TaggedRow(title: s.title, meta: s.meta, tag: TagChip(s.isCourse ? 'Course' : 'Group', outlined: true), chevron: true, onTap: () => onOpen(s)),
          ],
        ]),
      ),
    ];

/// One class's files: its sections, each with its files, to open or to download.
class LibraryClassScreen extends StatefulWidget {
  const LibraryClassScreen({super.key, required this.shelfKey, required this.name});
  final String shelfKey;
  final String name;

  @override
  State<LibraryClassScreen> createState() => _LibraryClassScreenState();
}

class _LibraryClassScreenState extends State<LibraryClassScreen> with WidgetsBindingObserver, AutoRefresh<LibraryClassScreen> {
  ClassShelf? _shelf;
  bool _loaded = false;
  String? _error;

  /// Files being downloaded, with how far each has got (0 to 1).
  final _downloading = <String, double>{};
  String? _notice;
  bool _noticeBad = false;

  /// The words typed in the search box: while there are some, the page shows the files found instead of its sections.
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Set<Area> get refreshAreas => {Area.student};

  // A file the tutor adds shows up within a minute while this is on screen.
  @override
  Duration? get pollEvery => const Duration(seconds: 60);

  @override
  Future<void> refreshQuietly() => _load();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    markLoaded();
    try {
      final all = await loadShelves();
      if (mounted) {
        setState(() {
          _shelf = all.where((s) => s.key == widget.shelfKey).firstOrNull;
          _loaded = true;
          _error = null;
        });
      }
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  void _open(LibSection s, LibFile file) =>
      context.push('/library/file', extra: FileViewerArgs(file, where: '${_shelf?.title ?? widget.name} · ${s.name}', teacher: false));

  /// Saves a copy in the phone's Downloads, fetching the file first when it is not on the phone yet.
  Future<void> _download(LibFile file) async {
    if (_downloading.containsKey(file.id)) return;
    setState(() {
      _downloading[file.id] = 0;
      _notice = null;
    });
    try {
      final local = await LibraryEnv.store.fetch(
        file,
        teacher: false,
        progress: (p) {
          if (mounted && (p - (_downloading[file.id] ?? 0) >= 0.02 || p == 1)) setState(() => _downloading[file.id] = p);
        },
      );
      final where = await LibraryEnv.store.save(local, file);
      if (mounted) {
        setState(() {
          _notice = where == null ? null : '${file.name} is saved in $where.';
          _noticeBad = false;
        });
      }
    } on ApiException catch (e) {
      if (mounted) {
        setState(() {
          _notice = e.message;
          _noticeBad = true;
        });
      }
    } finally {
      if (mounted) setState(() => _downloading.remove(file.id));
    }
  }

  /// What sits at the end of a file's row: its download button, or how far the download has got.
  Widget _trailing(LibFile file) => _downloading.containsKey(file.id)
      ? SizedBox(
          width: 44,
          height: 44,
          child: Center(child: Text('${((_downloading[file.id] ?? 0) * 100).floor()}%', style: numStyle(size: 11, weight: FontWeight.w600, color: muted))),
        )
      : RowAction(icon: Ph.downloadSimple, label: 'Download ${file.name}', onTap: () => _download(file));

  /// The files with the typed words in their name, from every section, each saying which section it is in.
  List<Widget> _found(ClassShelf shelf, String q) {
    final found = findFiles(shelf.sections, q);
    if (found.isEmpty) return [NothingFound(q)];
    return [
      SectionCard(
        name: 'Found',
        count: found.length,
        rows: [
          for (final x in found)
            FileRowView(file: x.file, section: x.section.name, highlight: q, onTap: () => _open(x.section, x.file), trailing: _trailing(x.file)),
        ],
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final shelf = _shelf;
    final q = _search.text.trim();
    return PushedPanel(
      onRefresh: _load,
      kicker: 'Library',
      title: shelf?.title ?? widget.name,
      children: [
        if (!_loaded && _error != null)
          ErrorState(message: _error!, onRetry: _load)
        else if (!_loaded)
          const LoadingState(rows: 3)
        else if (shelf == null)
          const EmptyState(icon: Ph.books, title: 'No files here yet', body: 'When your tutor adds files to this class, they show up here.')
        else ...[
          // Outside the list that comes in row by row, so a notice that appears does not make the sections play their entrance again.
          if (_notice != null) ...[
            const SizedBox(height: 18),
            InlineNotice(_notice!, tone: _noticeBad ? Tone.danger : Tone.success, icon: _noticeBad ? Ph.warning : Ph.checkCircle),
          ],
          // Something to search once there is a file on the shelf.
          if (shelf.files > 0) ...[
            SizedBox(height: _notice == null ? 18 : gapRow),
            SearchBox(controller: _search, placeholder: 'Search files', onChanged: (_) => setState(() {})),
          ],
          if (q.isNotEmpty) ...[
            const SizedBox(height: 14),
            ..._found(shelf, q),
          ] else
            ...staggered(
              [
                SizedBox(height: shelf.files > 0 ? 14 : (_notice == null ? 18 : gapRow)),
                for (final s in shelf.sections) ...[
                  SectionCard(
                    name: s.name,
                    count: s.files.length,
                    rows: [
                      for (final file in s.files) FileRowView(file: file, onTap: () => _open(s, file), trailing: _trailing(file)),
                    ],
                  ),
                  const SizedBox(height: gapRow),
                ],
              ],
              scope: this,
              prefix: 'lib',
              stepMs: 60,
            ),
        ],
      ],
    );
  }
}
