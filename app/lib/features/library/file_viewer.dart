import 'dart:io';

import 'package:flutter/material.dart';
import 'package:pdfx/pdfx.dart';

import '../../core/api.dart';
import '../../core/library.dart';
import '../../theme.dart';
import '../../ui/kit.dart';

/// What the viewer needs to open a file: the file, where it is ("10th Maths · PDFs", shown above its name) and whose link to ask for it.
class FileViewerArgs {
  const FileViewerArgs(this.file, {required this.where, required this.teacher});
  final LibFile file;
  final String where;
  final bool teacher;
}

/// Draws a PDF that is on the phone, page below page with pinch to zoom, and says which page is showing and how many there are.
/// Tests put in a stand-in, because the real one needs the phone.
Widget Function(File file, void Function(int page, int pages) onPage) pdfPages = (file, onPage) => _PdfxPages(file: file, onPage: onPage);

class _PdfxPages extends StatefulWidget {
  const _PdfxPages({required this.file, required this.onPage});
  final File file;
  final void Function(int page, int pages) onPage;

  @override
  State<_PdfxPages> createState() => _PdfxPagesState();
}

class _PdfxPagesState extends State<_PdfxPages> {
  late final _controller = PdfControllerPinch(document: PdfDocument.openFile(widget.file.path));
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Center(child: Padding(padding: const EdgeInsets.all(24), child: Fig(_error!, style: bodyStyle.copyWith(color: muted), textAlign: TextAlign.center)));
    }
    return PdfViewPinch(
      controller: _controller,
      padding: 10,
      backgroundDecoration: BoxDecoration(color: card),
      onDocumentLoaded: (d) => widget.onPage(1, d.pagesCount),
      onPageChanged: (p) => widget.onPage(p, _controller.pagesCount ?? 0),
      onDocumentError: (_) => setState(() => _error = 'This PDF could not be opened. Use Download and open it in another app.'),
      builders: PdfViewPinchBuilders<DefaultBuilderOptions>(
        options: const DefaultBuilderOptions(),
        documentLoaderBuilder: (_) => const SizedBox.shrink(),
        pageLoaderBuilder: (_) => const SizedBox.shrink(),
      ),
    );
  }
}

/// A file opened in the app: a PDF page by page, or a photo to zoom into, with a button to save a copy on the phone. The file is fetched
/// once and kept, so the download button saves what is already here instead of fetching it again.
class FileViewerScreen extends StatefulWidget {
  const FileViewerScreen({super.key, required this.args});
  final FileViewerArgs args;

  @override
  State<FileViewerScreen> createState() => _FileViewerScreenState();
}

class _FileViewerScreenState extends State<FileViewerScreen> {
  File? _local;
  double _progress = 0;
  String? _error;
  bool _saving = false;
  String? _saved;
  String? _saveError;
  int _page = 1;
  int _pages = 0;

  LibFile get _file => widget.args.file;

  @override
  void initState() {
    super.initState();
    _open();
  }

  Future<void> _open() async {
    setState(() {
      _error = null;
      _progress = 0;
    });
    try {
      final file = await LibraryEnv.store.fetch(
        _file,
        teacher: widget.args.teacher,
        progress: (p) {
          if (mounted && (p - _progress >= 0.01 || p == 1)) setState(() => _progress = p);
        },
      );
      if (mounted) setState(() => _local = file);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  Future<void> _save() async {
    final local = _local;
    if (local == null || _saving) return;
    setState(() {
      _saving = true;
      _saved = null;
      _saveError = null;
    });
    try {
      final where = await LibraryEnv.store.save(local, _file);
      if (mounted) setState(() => _saved = where == null ? null : 'Saved to $where');
    } on ApiException catch (e) {
      if (mounted) setState(() => _saveError = e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _body() {
    if (_error != null) return ErrorState(message: _error!, onRetry: _open);
    final local = _local;
    if (local == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 48),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Fig('Opening the file${_progress > 0 ? ' · ${(_progress * 100).floor()}%' : ''}', style: bodyStyle.copyWith(color: muted)),
            const SizedBox(height: 14),
            Track(_progress, height: 5),
          ]),
        ),
      );
    }
    if (!_file.isPdf) {
      return InteractiveViewer(minScale: 1, maxScale: 6, child: Center(child: Image.file(local, fit: BoxFit.contain)));
    }
    return pdfPages(local, (page, pages) {
      if (mounted && (page != _page || pages != _pages)) {
        // This is called while the document is being drawn: the screen is rebuilt after it.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            setState(() {
              _page = page;
              _pages = pages;
            });
          }
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final long = _file.title.length > 22;
    return Scaffold(
      body: SafeArea(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(gutter, 8, gutter, 0),
            child: Row(children: [CircleBtn(icon: Ph.arrowLeft, label: 'Back', onTap: () => Navigator.of(context).maybePop())]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(gutter, 22, gutter, 16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Kicker(widget.args.where),
              const SizedBox(height: 6),
              MediaQuery.withClampedTextScaling(maxScaleFactor: 1.4, child: Fig(_file.title, style: long ? titleStyle : displayStyle, maxLines: 2)),
            ]),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: gutter),
              child: Container(
                clipBehavior: Clip.antiAlias,
                decoration: surface(radius: rCard, shadow: e1),
                child: _body(),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(gutter, 10, gutter, 0),
            child: Center(
              child: _file.isPdf && _pages > 0
                  ? Text('Page $_page of $_pages', style: numStyle(size: 12, weight: FontWeight.w600, color: muted))
                  : const SizedBox(height: 14),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(gutter, 10, gutter, 12),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (_saved != null) ...[InlineNotice(_saved!, tone: Tone.success, icon: Ph.checkCircle), const SizedBox(height: 10)],
              if (_saveError != null) ...[InlineNotice(_saveError!, tone: Tone.danger, icon: Ph.warning), const SizedBox(height: 10)],
              PrimaryButton(
                'Download',
                leadingIcon: Ph.downloadSimple,
                busy: _saving,
                onTap: _local == null ? null : _save,
                disabledReason: _local == null && _error == null ? 'You can download it once it has opened.' : null,
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}
