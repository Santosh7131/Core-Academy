import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/api.dart';
import '../../theme.dart';
import '../../ui/kit.dart';
import '../../ui/math_text.dart';
import '../../ui/tokens.dart';
import 'common.dart';
import 'subjects.dart';

// ---------------------------------------------------------------- editor

/// Inserts self-contained `$...$` snippets so no LaTeX knowledge is needed.
const mathSnippets = <(String, String)>[
  ('a/b', r'$\frac{1}{2}$'),
  ('x²', r'$x^{2}$'),
  ('√', r'$\sqrt{2}$'),
  ('×', r'$\times$'),
  ('÷', r'$\div$'),
  ('π', r'$\pi$'),
  ('θ', r'$\theta$'),
  ('≤', r'$\le$'),
  ('≥', r'$\ge$'),
  ('≠', r'$\ne$'),
  ('°', r'$^\circ$'),
];

class MathToolbar extends StatelessWidget {
  const MathToolbar({super.key, required this.onInsert});
  final ValueChanged<String> onInsert;

  @override
  Widget build(BuildContext context) => ChipRow(padding: EdgeInsets.zero, children: [
        for (final (label, snippet) in mathSnippets)
          Pressable(
            onTap: () => onInsert(snippet),
            label: 'Insert $label',
            child: Container(
              height: 34,
              constraints: const BoxConstraints(minWidth: 42),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(rSmall)),
              // As wide as its symbol. A Container with an alignment would take the whole row,
              // and the chips would stack one to a line.
              child: Center(widthFactor: 1, child: Text(label, style: optionStyle.copyWith(fontSize: 15, fontWeight: FontWeight.w600))),
            ),
          ),
      ]);
}

void insertInto(TextEditingController c, String text) {
  final sel = c.selection;
  final start = sel.isValid ? sel.start : c.text.length;
  final end = sel.isValid ? sel.end : c.text.length;
  c.value = TextEditingValue(
    text: c.text.replaceRange(start, end, text),
    selection: TextSelection.collapsed(offset: start + text.length),
  );
}

/// Picks a photo, compresses it on the phone and uploads it. Returns the storage key.
Future<({String key, Uint8List bytes})?> pickAndUploadImage(BuildContext context, ImageSource source) async {
  final file = await ImagePicker().pickImage(source: source, maxWidth: 1600, imageQuality: 80);
  if (file == null) return null;
  final bytes = await file.readAsBytes();
  final up = await api.post('/teacher/uploads');
  await api.putBytes('${up['put_url']}', bytes);
  return (key: '${up['key']}', bytes: bytes);
}

/// The last option in a chapter choice: opens "Add a chapter" instead of choosing one.
const _addChapterChoice = '+add';

class QuestionEditor extends StatefulWidget {
  const QuestionEditor({super.key, this.id});
  final String? id;

  @override
  State<QuestionEditor> createState() => _QuestionEditorState();
}

class _QuestionEditorState extends State<QuestionEditor> {
  final _text = TextEditingController();
  final _options = List.generate(4, (_) => TextEditingController());
  final _solution = TextEditingController();
  final _focus = List.generate(6, (_) => FocusNode());
  int _lastFocus = 0;
  int? _class;
  String? _subjectId;
  List<Subject> _subjects = [];
  String? _chapterId;
  int? _correct;
  num _marks = 1;
  String? _imageKey;
  String? _imageUrl;
  Uint8List? _imageBytes;
  List<Map<String, dynamic>> _chapters = [];
  bool _loading = false;
  bool _busy = false;
  int _usedIn = 0;

  @override
  void initState() {
    super.initState();
    for (final (i, f) in _focus.indexed) {
      f.addListener(() {
        if (f.hasFocus) _lastFocus = i;
      });
    }
    for (final c in [_text, _solution, ..._options]) {
      c.addListener(() => setState(() {}));
    }
    _loadSubjects();
    if (widget.id != null) _load();
  }

  Future<void> _loadSubjects() async {
    try {
      final subjects = await loadSubjects();
      if (!mounted) return;
      setState(() {
        _subjects = subjects;
        // New questions start in Maths; an existing one keeps its subject from _load.
        _subjectId ??= subjects.where((x) => x.isDefault).map((x) => x.id).firstOrNull;
      });
      _loadChapters();
    } on ApiException catch (e) {
      if (mounted) showProblem(context, e);
    }
  }

  @override
  void dispose() {
    for (final c in [_text, _solution, ..._options]) {
      c.dispose();
    }
    for (final f in _focus) {
      f.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final r = await api.get('/teacher/questions/${widget.id}');
      final q = Map<String, dynamic>.from(r['question']);
      _text.text = '${q['text']}';
      final opts = (q['options'] as List).cast<String>();
      for (var i = 0; i < 4; i++) {
        _options[i].text = opts[i];
      }
      _solution.text = '${q['solution'] ?? ''}';
      _class = q['class_level'] as int;
      _subjectId = q['subject_id'] as String?;
      _chapterId = q['chapter_id'] as String?;
      _correct = q['correct_option'] as int;
      _marks = q['marks'] as num;
      _imageKey = q['image_key'] as String?;
      _imageUrl = q['image_url'] as String?;
      _usedIn = q['used_in'] as int;
      await _loadChapters();
    } on ApiException catch (e) {
      if (mounted) showProblem(context, e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadChapters() async {
    if (_class == null || _subjectId == null) return;
    final r = await api.get('/teacher/chapters?class=$_class&subject=$_subjectId');
    if (mounted) setState(() => _chapters = (r['chapters'] as List).cast<Map<String, dynamic>>());
  }

  TextEditingController get _focused => switch (_lastFocus) {
        0 => _text,
        5 => _solution,
        final i => _options[i - 1],
      };

  Future<void> _addChapter() async {
    final c = TextEditingController();
    final name = await showCentredCard<String>(
      context,
      title: 'Add a chapter',
      builder: (ctx) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        GroupedInputs(children: [
          BareField(controller: c, placeholder: 'Chapter name', autofocus: true, capitalization: TextCapitalization.words, onSubmitted: (v) => Navigator.of(ctx).pop(v)),
        ]),
        const SizedBox(height: 16),
        PrimaryButton('Add', onTap: () => Navigator.of(ctx).pop(c.text)),
      ]),
    );
    if (name == null || name.trim().isEmpty || _class == null) return;
    try {
      final r = await api.post('/teacher/chapters', {'class_level': _class, 'subject_id': _subjectId, 'name': name.trim()});
      await _loadChapters();
      setState(() => _chapterId = '${r['chapter']['id']}');
    } on ApiException catch (e) {
      if (mounted) showProblem(context, e);
    }
  }

  Future<void> _pickImage() async {
    final source = await showCentredCard<ImageSource>(
      context,
      title: 'Add a diagram',
      builder: (ctx) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SecondaryButton('Take a photo', icon: Ph.camera, onTap: () => Navigator.of(ctx).pop(ImageSource.camera)),
        const SizedBox(height: 10),
        SecondaryButton('Choose from gallery', icon: Ph.images, onTap: () => Navigator.of(ctx).pop(ImageSource.gallery)),
      ]),
    );
    if (source == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final up = await pickAndUploadImage(context, source);
      if (up != null) {
        setState(() {
        _imageKey = up.key;
        _imageBytes = up.bytes;
        _imageUrl = null;
      });
      }
    } on ApiException catch (e) {
      if (mounted) showProblem(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String? get _missing {
    if (_class == null) return 'Choose a class.';
    if (_subjectId == null) return 'Choose a subject.';
    if (_text.text.trim().isEmpty) return 'Type the question.';
    if (_options.any((o) => o.text.trim().isEmpty)) return 'Fill in all four options.';
    if (_correct == null) return 'Tap the circle next to the right answer.';
    return null;
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    final body = {
      'class_level': _class,
      'subject_id': _subjectId,
      'chapter_id': _chapterId,
      'text': _text.text.trim(),
      'options': [for (final o in _options) o.text.trim()],
      'correct_option': _correct,
      'solution': _solution.text.trim().isEmpty ? null : _solution.text.trim(),
      'marks': _marks,
      'image_key': _imageKey,
    };
    try {
      if (widget.id == null) {
        await api.post('/teacher/questions', body);
      } else {
        final r = await api.patch('/teacher/questions/${widget.id}', body);
        // A corrected answer re-marks the tests already written with this question.
        final n = (r['regraded'] as int?) ?? 0;
        if (n > 0 && mounted) {
          await showCentredCard<void>(
            context,
            title: 'Marks updated',
            builder: (ctx) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Fig(
                '${n == 1 ? '1 test already written has' : '$n tests already written have'} this question. '
                '${n == 1 ? 'It was' : 'They were'} marked again with the new answer.',
                style: bodyStyle.copyWith(color: muted),
              ),
              const SizedBox(height: 18),
              PrimaryButton('OK', onTap: () => Navigator.of(ctx).pop()),
            ]),
          );
        }
      }
      if (mounted) context.pop(true);
    } on ApiException catch (e) {
      if (mounted) showProblem(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    final ok = await confirmCard(
      context,
      title: 'Delete this question?',
      body: _usedIn > 0
          ? 'It is in ${_usedIn == 1 ? 'a test' : '$_usedIn tests'}. It will be taken out of ${_usedIn == 1 ? 'it' : 'them'} and deleted, unless students have written ${_usedIn == 1 ? 'it' : 'one of them'}.'
          : 'It will be deleted.',
      confirm: 'Delete',
      destructive: true,
    );
    if (!ok) return;
    try {
      await api.delete('/teacher/questions/${widget.id}');
      if (mounted) context.pop(true);
    } on ApiException catch (e) {
      if (mounted) showProblem(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const PushedPanel(title: 'Question', children: [LoadingState()]);
    final missing = _missing;
    return PushedPanel(
      kicker: widget.id == null ? 'New question' : (_usedIn > 0 ? 'Used in $_usedIn test${_usedIn == 1 ? '' : 's'}' : 'Question'),
      title: widget.id == null ? 'New question' : 'Edit question',
      headerTrailing: widget.id == null ? null : CircleBtn(icon: Ph.trash, label: 'Delete', tint: danger, onTap: _delete),
      footer: PrimaryButton('Save question', busy: _busy, onTap: missing == null ? _save : null, disabledReason: _busy ? null : missing),
      children: [
        // Fixing a question in a test: its class, subject and chapter stay as they are.
        if (widget.id == null) ...[
          const FormLabel('Class'),
          ClassField(
            value: _class,
            onChanged: (c) {
              setState(() {
                _class = c;
                _chapterId = null;
              });
              _loadChapters();
            },
          ),
          const FormLabel('Subject'),
          SubjectField(
            subjects: _subjects,
            value: _subjectId,
            onChanged: (v) {
              setState(() {
                _subjectId = v;
                _chapterId = null;
                _chapters = [];
              });
              _loadChapters();
            },
          ),
          if (_class != null && _subjectId != null) ...[
            const FormLabel('Chapter'),
            SelectField(
              value: _chapters.where((c) => c['id'] == _chapterId).map((c) => '${c['name']}').firstOrNull,
              placeholder: 'No chapter',
              onTap: () async {
                final c = await showChoices<String>(
                  context,
                  title: 'Chapter',
                  subtitle: groupName(_class!, _subjects.where((s) => s.id == _subjectId).map((s) => s.name).firstOrNull ?? ''),
                  options: [
                    const Choice(null, 'No chapter'),
                    for (final ch in _chapters) Choice('${ch['id']}', '${ch['name']}'),
                    const Choice(_addChapterChoice, 'Add a new chapter'),
                  ],
                  selected: _chapterId,
                );
                if (c == null) return;
                if (c.value == _addChapterChoice) {
                  _addChapter();
                } else {
                  setState(() => _chapterId = c.value);
                }
              },
            ),
          ],
        ],
        const FormLabel('Question'),
        GroupedInputs(children: [
          BareField(controller: _text, focusNode: _focus[0], placeholder: 'Type the question', maxLines: null, minLines: 2, capitalization: TextCapitalization.sentences),
        ]),
        const SizedBox(height: 10),
        MathToolbar(onInsert: (s) {
          insertInto(_focused, s);
          _focus[_lastFocus].requestFocus();
        }),
        const FormLabel('Options. Tap the circle next to the right answer.'),
        GroupedInputs(children: [
          for (var i = 0; i < 4; i++)
            Row(children: [
              const SizedBox(width: 13),
              Pressable(
                onTap: () => setState(() => _correct = i),
                label: 'Mark option ${'ABCD'[i]} as right',
                child: Container(
                  width: 30,
                  height: 30,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _correct == i ? success : null,
                    border: _correct == i ? null : Border.all(color: ringIdle, width: 1.8),
                  ),
                  child: _correct == i
                      ? const Icon(Ph.check, size: 16, color: Colors.white)
                      : Text('ABCD'[i], style: tagStyle.copyWith(fontSize: 12, color: muted)),
                ),
              ),
              Expanded(child: BareField(controller: _options[i], focusNode: _focus[i + 1], placeholder: 'Option ${'ABCD'[i]}')),
            ]),
        ]),
        const FormLabel('Preview'),
        Surface(
          shadow: e1,
          padding: const EdgeInsets.fromLTRB(17, 15, 17, 15),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            MathText(_text.text.isEmpty ? 'The question appears here' : _text.text, style: optionStyle.copyWith(color: _text.text.isEmpty ? faint : ink)),
            const SizedBox(height: 10),
            for (var i = 0; i < 4; i++)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  SizedBox(width: 22, child: Text('ABCD'[i], style: tagStyle.copyWith(fontSize: 12, color: _correct == i ? success : muted))),
                  Expanded(child: MathText(_options[i].text.isEmpty ? '-' : _options[i].text, style: bodyStyle.copyWith(color: ink))),
                ]),
              ),
          ]),
        ),
        const FormLabel('Diagram (optional)'),
        if (_imageBytes != null || _imageUrl != null)
          Stack(children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(rSmall),
              child: _imageBytes != null ? Image.memory(_imageBytes!) : Image.network(_imageUrl!),
            ),
            Positioned(
              top: 8,
              right: 8,
              child: CircleBtn(icon: Ph.x, label: 'Remove diagram', onTap: () => setState(() {
                _imageKey = null;
                _imageBytes = null;
                _imageUrl = null;
              })),
            ),
          ])
        else
          SecondaryButton('Add a diagram', icon: Ph.image, onTap: _busy ? null : _pickImage),
        const FormLabel('Worked solution (optional)'),
        GroupedInputs(children: [
          BareField(controller: _solution, focusNode: _focus[5], placeholder: 'Shown to students after they submit', maxLines: null, minLines: 2, capitalization: TextCapitalization.sentences),
        ]),
        const FormLabel('Marks'),
        ChipRow(padding: EdgeInsets.zero, children: [
          for (final m in [1, 2, 3, 4, 5]) SegChip('$m', selected: _marks == m, onTap: () => setState(() => _marks = m)),
        ]),
        if (widget.id != null) ...[
          const SizedBox(height: 30),
          Center(child: TextAction('Delete this question', color: danger, onTap: _delete)),
        ],
      ],
    );
  }
}
