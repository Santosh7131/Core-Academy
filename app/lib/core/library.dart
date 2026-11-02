import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart' show DateFormat;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'api.dart';
import 'changes.dart';
import 'format.dart' as f;

// The Library: files a tutor puts on the shelf of a group or a course, for its people to read and download. A shelf has sections ("PDFs",
// "Books"), a section has files (PDFs and photos of up to 100 MB). This file is what both sides share: what a file is, how a tutor's files
// are picked and sent (straight to storage, in parts when they are big), and how a file is fetched, kept on the phone and saved.

/// The most one file may weigh, as the server says it.
const maxFileBytes = 100 * 1024 * 1024;

// ---------------------------------------------------------------- what a file is

/// A file on a shelf, as the server describes it.
class LibFile {
  const LibFile({required this.id, required this.sectionId, required this.name, required this.kind, required this.contentType, required this.size, this.added});

  factory LibFile.fromJson(Map<String, dynamic> j) => LibFile(
        id: '${j['id']}',
        sectionId: '${j['section_id']}',
        name: '${j['name']}',
        kind: '${j['kind']}',
        contentType: '${j['content_type']}',
        size: (j['size_bytes'] as num).toInt(),
        added: f.parseTime(j['created_at']),
      );

  final String id;
  final String sectionId;
  final String name;

  /// 'pdf' or 'photo'.
  final String kind;
  final String contentType;
  final int size;
  final DateTime? added;

  bool get isPdf => kind == 'pdf';

  /// "Chapter 4 notes", for a title: the name without its extension.
  String get title => name.replaceFirst(RegExp(r'\.(pdf|jpe?g|png|webp)$', caseSensitive: false), '');

  /// The name a saved copy gets: the name, with the extension the file needs when the name has none.
  String get saveName => name == title ? '$name.${_extensionOf(contentType)}' : name;

  /// "PDF · 3.8 MB · Thu 29 Oct".
  String get meta => [isPdf ? 'PDF' : 'Photo', sizeLabel(size), if (added != null) f.shortDate(added!)].join(' · ');
}

String _extensionOf(String contentType) => switch (contentType) {
      'application/pdf' => 'pdf',
      'image/png' => 'png',
      'image/webp' => 'webp',
      _ => 'jpg',
    };

/// A titled box of files on a shelf.
class LibSection {
  const LibSection(this.id, this.name, this.files);

  factory LibSection.fromJson(Map<String, dynamic> j) => LibSection(
        '${j['id']}',
        '${j['name']}',
        [for (final x in (j['files'] as List? ?? const [])) LibFile.fromJson(Map<String, dynamic>.from(x as Map))],
      );

  final String id;
  final String name;
  final List<LibFile> files;
}

/// "412 KB", "3.8 MB", "62 MB".
String sizeLabel(int bytes) {
  if (bytes < 1024 * 1024) return '${(bytes / 1024).ceil().clamp(1, 1023)} KB';
  final mb = bytes / (1024 * 1024);
  return mb >= 100 ? '${mb.round()} MB' : '${mb.toStringAsFixed(1)} MB';
}

/// The type a file's name says it is, or null for anything but a PDF or a photo.
String? contentTypeOf(String name) => switch (RegExp(r'\.([A-Za-z0-9]+)$').firstMatch(name)?.group(1)?.toLowerCase()) {
      'pdf' => 'application/pdf',
      'jpg' || 'jpeg' => 'image/jpeg',
      'png' => 'image/png',
      'webp' => 'image/webp',
      _ => null,
    };

/// "Photo 2 Nov 2026 5.42 pm.jpg": the name of a photo taken with the camera, which has none of its own worth keeping.
String photoName(DateTime t) => 'Photo ${DateFormat('d MMM yyyy h.mm').format(t)} ${t.hour < 12 ? 'am' : 'pm'}.jpg';

// ---------------------------------------------------------------- a shelf

/// A group's or a course's shelf: where its library is on the server, and a key the uploads under way are filed by.
class LibShelf {
  const LibShelf.group(int classLevel, String subjectId)
      : key = 'group:$classLevel:$subjectId',
        path = '/teacher/groups/$classLevel/$subjectId/library';
  const LibShelf.course(String courseId)
      : key = 'course:$courseId',
        path = '/teacher/courses/$courseId/library';

  final String key;
  final String path;
}

// ---------------------------------------------------------------- picking files

/// A file the tutor picked, which can be read in slices so that a big one never has to sit in memory whole.
class PickedFile {
  const PickedFile({required this.name, required this.size, required this.contentType, required this.open});
  final String name;
  final int size;
  final String contentType;

  /// The bytes from [start] up to (not including) [end].
  final Stream<List<int>> Function(int start, int end) open;
}

/// The bytes of [source] from [start] up to [end], for a file that can only be read from its beginning.
Stream<List<int>> sliceOf(Stream<List<int>> source, int start, int end) async* {
  var pos = 0;
  await for (final chunk in source) {
    final next = pos + chunk.length;
    if (next > start && pos < end) {
      final from = start > pos ? start - pos : 0;
      final to = end < next ? end - pos : chunk.length;
      yield from == 0 && to == chunk.length ? chunk : chunk.sublist(from, to);
    }
    pos = next;
    if (pos >= end) break;
  }
}

/// The phone's files, gallery and camera. Tests put their own in.
class LibrarySources {
  const LibrarySources();

  /// Opens the file picker for PDFs, several at once.
  Future<List<PickedFile>> pickPdfs() async {
    final files = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['pdf']);
    return [for (final x in files) await _picked(x.name, x.length(), () => x.path, x.readAsByteStream)];
  }

  /// Photos from the gallery, several at once.
  Future<List<PickedFile>> pickPhotos() async {
    final xs = await ImagePicker().pickMultiImage();
    return [for (final x in xs) await _picked(x.name, x.length(), () => x.path, x.openRead, type: x.mimeType)];
  }

  /// A photo taken with the camera, or null when the tutor came back without one.
  Future<PickedFile?> takePhoto() async {
    final x = await ImagePicker().pickImage(source: ImageSource.camera);
    if (x == null) return null;
    return _picked(photoName(DateTime.now()), x.length(), () => x.path, x.openRead, type: 'image/jpeg');
  }

  Future<PickedFile> _picked(String name, Future<int?> size, String? Function() path, Stream<List<int>> Function() whole, {String? type}) async {
    final bytes = await size ?? 0;
    final p = path();
    return PickedFile(
      name: name,
      size: bytes,
      contentType: contentTypeOf(name) ?? type ?? 'application/octet-stream',
      open: (start, end) => p != null && File(p).existsSync() ? File(p).openRead(start, end) : sliceOf(whole(), start, end),
    );
  }
}

// ---------------------------------------------------------------- sending files

enum UploadState { waiting, sending, finishing, stopped }

/// One file on its way to a shelf.
class UploadJob {
  UploadJob(this.shelf, this.sectionId, this.file);
  final String shelf;
  final String sectionId;
  final PickedFile file;

  UploadState state = UploadState.waiting;

  /// Bytes the server has, or is being sent.
  int sent = 0;

  /// Why it stopped, in words for the row ("no signal"), and whether sending it again could help.
  String? problem;
  bool retryable = true;
  bool offline = false;
  bool cancelled = false;

  /// The server's id for the file once it has been told about it; kept so a try again carries on instead of starting over.
  String? fileId;
  _Plan? _plan;
  DateTime? _started;
  int _sentAtStart = 0;
  HttpClient? _client;

  double get fraction => file.size == 0 ? 0 : (sent / file.size).clamp(0, 1).toDouble();
  int get percent => (fraction * 100).floor();

  /// "about 2 min left", once there has been time to measure how fast it goes.
  String? get timeLeft {
    final s = _started;
    if (s == null || state != UploadState.sending) return null;
    final secs = DateTime.now().difference(s).inMilliseconds / 1000;
    final got = sent - _sentAtStart;
    if (secs < 4 || got <= 0) return null;
    final left = ((file.size - sent) / (got / secs)).ceil();
    return left < 10 ? 'a few seconds left' : 'about ${f.duration(left)} left';
  }
}

class _Part {
  _Part(this.n, this.size, this.done, this.url);
  final int n;
  final int size;
  bool done;
  final String? url;
}

class _Plan {
  _Plan(this.single, this.url, this.headers, this.partSize, this.parts);

  /// The links the server gave: one for the whole file, or one for each part still to send.
  factory _Plan.fromJson(Map<String, dynamic> j) {
    final single = j['mode'] == 'single';
    return _Plan(
      single,
      single ? '${j['url']}' : null,
      {for (final e in ((j['headers'] as Map?) ?? const {}).entries) '${e.key}': '${e.value}'},
      (j['part_size'] as num?)?.toInt() ?? 0,
      [
        for (final p in (j['parts'] as List? ?? const []))
          _Part((p['n'] as num).toInt(), (p['size'] as num).toInt(), p['done'] == true, p['url'] as String?),
      ],
    );
  }

  final bool single;
  final String? url;
  final Map<String, String> headers;
  final int partSize;
  final List<_Part> parts;
}

/// Sends bytes to a link and says what storage answered. Tests put their own in.
typedef Putter = Future<int> Function(UploadJob job, String url, int length, Stream<List<int>> body, Map<String, String> headers, void Function(int bytes) sent);

Future<int> _putOverHttp(UploadJob job, String url, int length, Stream<List<int>> body, Map<String, String> headers, void Function(int bytes) sent) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
  job._client = client;
  var last = DateTime.now();
  // A connection that stops moving for a while is a dead one: it is closed, and the part is sent again.
  final watch = Timer.periodic(const Duration(seconds: 5), (_) {
    if (DateTime.now().difference(last) > const Duration(seconds: 45)) client.close(force: true);
  });
  try {
    final req = await client.putUrl(Uri.parse(url));
    req.contentLength = length;
    headers.forEach(req.headers.set);
    await req.addStream(body.map((chunk) {
      last = DateTime.now();
      sent(chunk.length);
      return chunk;
    }));
    final res = await req.close();
    await res.drain<void>();
    return res.statusCode;
  } finally {
    watch.cancel();
    client.close(force: true);
    job._client = null;
  }
}

/// The files being sent to shelves. It outlives the screens: a tutor can go on using the app while a big file goes up, and the shelf's
/// page shows what is under way. Files go one at a time, so each gets the whole connection.
class LibraryUploads extends ChangeNotifier {
  final jobs = <UploadJob>[];

  /// How many files have finished, so a screen showing a shelf knows to load it again.
  int doneCount = 0;

  Putter put = _putOverHttp;
  bool _running = false;
  DateTime _lastTick = DateTime.fromMillisecondsSinceEpoch(0);

  List<UploadJob> forShelf(String shelf) => [for (final j in jobs) if (j.shelf == shelf) j];

  bool get busy => jobs.any((j) => j.state != UploadState.stopped);

  /// Queues files for a section and starts sending them.
  void add(String shelf, String sectionId, List<PickedFile> files) {
    for (final x in files) {
      jobs.add(UploadJob(shelf, sectionId, x));
    }
    notifyListeners();
    unawaited(_pump());
  }

  /// Sends a stopped file again, carrying on from where the server has it.
  void retry(UploadJob j) {
    if (j.state != UploadState.stopped) return;
    j.state = UploadState.waiting;
    j.problem = null;
    notifyListeners();
    unawaited(_pump());
  }

  /// Takes a file off the list, and off the server if it had begun.
  Future<void> cancel(UploadJob j) async {
    j.cancelled = true;
    j._client?.close(force: true);
    jobs.remove(j);
    notifyListeners();
    final id = j.fileId;
    if (id != null) {
      try {
        await api.delete('/teacher/library/files/$id');
      } on ApiException {
        // The server throws away what nobody finishes after a few hours.
      }
    }
  }

  /// Forgets everything (a different person signed in).
  void clear() {
    for (final j in jobs) {
      j.cancelled = true;
      j._client?.close(force: true);
    }
    jobs.clear();
    notifyListeners();
  }

  void _tick({bool force = false}) {
    final now = DateTime.now();
    if (!force && now.difference(_lastTick) < const Duration(milliseconds: 150)) return;
    _lastTick = now;
    notifyListeners();
  }

  Future<void> _pump() async {
    if (_running) return;
    _running = true;
    try {
      for (;;) {
        final next = jobs.where((j) => j.state == UploadState.waiting).firstOrNull;
        if (next == null) break;
        await _run(next);
      }
    } finally {
      _running = false;
    }
  }

  Future<void> _run(UploadJob j) async {
    j.state = UploadState.sending;
    j.problem = null;
    j._started = DateTime.now();
    j._sentAtStart = j.sent;
    _tick(force: true);
    try {
      if (j.fileId == null) {
        final r = await api.post('/teacher/library/sections/${j.sectionId}/files', {'name': j.file.name, 'content_type': j.file.contentType, 'size': j.file.size});
        j.fileId = '${r['file']['id']}';
        j._plan = _Plan.fromJson(Map<String, dynamic>.from(r['upload'] as Map));
      } else {
        final r = await api.post('/teacher/library/files/${j.fileId}/upload');
        j._plan = _Plan.fromJson(Map<String, dynamic>.from(r['upload'] as Map));
      }
      await _send(j);
      if (j.cancelled) return;
      j.state = UploadState.finishing;
      _tick(force: true);
      try {
        await api.post('/teacher/library/files/${j.fileId}/complete');
      } on ApiException catch (e) {
        if (e.code != 'incomplete') rethrow;
        // A part did not arrive: ask which, send those again, and finish.
        final r = await api.post('/teacher/library/files/${j.fileId}/upload');
        j._plan = _Plan.fromJson(Map<String, dynamic>.from(r['upload'] as Map));
        j.state = UploadState.sending;
        _tick(force: true);
        await _send(j);
        j.state = UploadState.finishing;
        _tick(force: true);
        await api.post('/teacher/library/files/${j.fileId}/complete');
      }
      jobs.remove(j);
      doneCount++;
      changes.reportAreas({Area.library});
      _tick(force: true);
    } on ApiException catch (e) {
      if (j.cancelled) return;
      _stop(j, e);
    } on SocketException {
      if (!j.cancelled) _stop(j, ApiException(0, 'offline', 'no signal'));
    } on HttpException {
      if (!j.cancelled) _stop(j, ApiException(0, 'offline', 'no signal'));
    } on TimeoutException {
      if (!j.cancelled) _stop(j, ApiException(0, 'offline', 'no signal'));
    }
  }

  /// Puts a file back on the list as stopped, saying why in the row's own words.
  void _stop(UploadJob j, ApiException e) {
    j.state = UploadState.stopped;
    j.offline = e.offline;
    j.retryable = !const {'too_big', 'unsupported_type', 'not_that_type', 'library_full', 'too_many_files', 'not_found', 'forbidden', 'signed_out'}.contains(e.code);
    // The server threw the file away (it did not arrive whole, or the upload was lost): the next try starts it again.
    if (const {'upload_failed', 'upload_lost'}.contains(e.code)) {
      j.fileId = null;
      j.sent = 0;
    }
    j.problem = e.offline ? 'no signal' : e.message;
    _tick(force: true);
  }

  /// Sends the file's bytes to the links: the whole file in one request, or each part not yet there.
  Future<void> _send(UploadJob j) async {
    final plan = j._plan!;
    if (plan.single) {
      j.sent = 0;
      final status = await put(j, plan.url!, j.file.size, j.file.open(0, j.file.size), plan.headers, (n) {
        j.sent += n;
        _tick();
      });
      if (status < 200 || status >= 300) throw ApiException(status, 'upload_failed', 'The file did not go up. Try again.');
      j.sent = j.file.size;
      return;
    }
    j.sent = plan.parts.where((p) => p.done).fold(0, (n, p) => n + p.size);
    for (final p in plan.parts) {
      if (p.done) continue;
      final start = (p.n - 1) * plan.partSize;
      for (var attempt = 1;; attempt++) {
        final base = j.sent;
        try {
          final status = await put(j, p.url!, p.size, j.file.open(start, start + p.size), const {}, (n) {
            j.sent += n;
            _tick();
          });
          if (status < 200 || status >= 300) throw ApiException(status, 'upload_failed', 'The file did not go up. Try again.');
          p.done = true;
          j.sent = base + p.size;
          break;
        } on ApiException catch (e) {
          j.sent = base;
          // A link that was refused (403) has run out; a new set comes with the next try.
          if (j.cancelled || attempt >= 3 || e.status == 403) rethrow;
          await Future<void>.delayed(Duration(seconds: 2 * attempt));
        } on SocketException {
          j.sent = base;
          if (j.cancelled || attempt >= 3) rethrow;
          await Future<void>.delayed(Duration(seconds: 2 * attempt));
        } on HttpException {
          j.sent = base;
          if (j.cancelled || attempt >= 3) rethrow;
          await Future<void>.delayed(Duration(seconds: 2 * attempt));
        }
      }
    }
  }
}

// ---------------------------------------------------------------- reading files

/// Brings a file onto the phone to read it, keeps it a while, and saves a copy where the person can find it. Tests put their own in.
class FileStore {
  FileStore();

  static const _channel = MethodChannel('core_academy/files');

  /// The most downloaded files kept on the phone; the oldest go first.
  static const _keep = 300 * 1024 * 1024;

  Future<Directory> _dir() async {
    final d = Directory('${(await getTemporaryDirectory()).path}/library');
    await d.create(recursive: true);
    return d;
  }

  /// The file on this phone, downloaded first unless it is already here whole. [progress] hears how far the download has got, 0 to 1.
  Future<File> fetch(LibFile file, {required bool teacher, void Function(double fraction)? progress}) async {
    final dir = await _dir();
    final ext = _extensionOf(file.contentType);
    final target = File('${dir.path}/${file.id}.$ext');
    if (await target.exists() && await target.length() == file.size) {
      await target.setLastModified(DateTime.now());
      progress?.call(1);
      return target;
    }
    final link = await api.get('${teacher ? '/teacher' : '/student'}/library/files/${file.id}/url') as Map;
    final part = File('${target.path}.part');
    final client = http.Client();
    try {
      final res = await client.send(http.Request('GET', Uri.parse('${link['url']}'))).timeout(const Duration(seconds: 30));
      if (res.statusCode != 200) throw ApiException(res.statusCode, 'download_failed', 'The file could not be opened. Try again.');
      final sink = part.openWrite();
      var got = 0;
      try {
        await for (final chunk in res.stream.timeout(const Duration(seconds: 45))) {
          sink.add(chunk);
          got += chunk.length;
          progress?.call(file.size == 0 ? 0 : (got / file.size).clamp(0, 1).toDouble());
        }
      } finally {
        await sink.close();
      }
      if (got != file.size) throw ApiException(0, 'offline', 'The download stopped half way. Check your internet and try again.');
      await part.rename(target.path);
    } on TimeoutException {
      throw ApiException(0, 'offline', 'The download is taking too long. Check your internet and try again.');
    } on SocketException {
      throw ApiException(0, 'offline', 'No internet connection. Check your connection and try again.');
    } on http.ClientException {
      throw ApiException(0, 'offline', 'No internet connection. Check your connection and try again.');
    } finally {
      client.close();
      if (await part.exists()) await part.delete().catchError((_) => part);
    }
    unawaited(_trim(dir));
    return target;
  }

  /// Deletes the oldest downloads while more than [_keep] bytes are kept.
  Future<void> _trim(Directory dir) async {
    try {
      final files = <(File, int, DateTime)>[];
      await for (final e in dir.list()) {
        if (e is File) files.add((e, await e.length(), await e.lastModified()));
      }
      var total = files.fold<int>(0, (n, x) => n + x.$2);
      files.sort((a, b) => a.$3.compareTo(b.$3));
      for (final x in files) {
        if (total <= _keep) break;
        await x.$1.delete();
        total -= x.$2;
      }
    } on FileSystemException {
      // A file that is in use stays; the next download tries again.
    }
  }

  /// Puts a copy in the phone's Downloads folder and says where ("Downloads/Core Academy"). Where the phone cannot do that, its share
  /// sheet opens with the file instead and this answers null.
  Future<String?> save(File file, LibFile info) async {
    try {
      final where = await _channel.invokeMethod<String>('saveToDownloads', {'path': file.path, 'name': info.saveName, 'mime': info.contentType});
      if (where != null) return where;
    } on PlatformException catch (e) {
      throw ApiException(0, 'save_failed', 'The file could not be saved${e.message == null ? '' : ': ${e.message}'}.');
    } on MissingPluginException {
      // Not on a phone that has the saving code: share it instead.
    }
    await SharePlus.instance.share(ShareParams(files: [XFile(file.path, mimeType: info.contentType, name: info.saveName)]));
    return null;
  }
}

/// What the Library reaches the phone and the network through. Tests put their own in.
class LibraryEnv {
  static LibrarySources sources = const LibrarySources();
  static FileStore store = FileStore();
  static final uploads = LibraryUploads();

  /// The bytes of a stand-in file, for tests that need a picked file.
  static PickedFile fake(String name, int size, {String? type}) => PickedFile(
        name: name,
        size: size,
        contentType: type ?? contentTypeOf(name) ?? 'application/pdf',
        open: (start, end) => Stream.value(Uint8List(end - start)),
      );
}
