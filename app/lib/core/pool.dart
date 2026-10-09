import 'dart:async';

/// Runs [job] for every item, [width] at a time, starting them in order. The first job that throws
/// stops new ones from starting; the jobs already running finish, then that error is thrown.
Future<void> forEachLimited<T>(Iterable<T> items, int width, Future<void> Function(T item) job) async {
  final it = items.iterator;
  Object? error;
  StackTrace? trace;
  var failed = false;

  Future<void> worker() async {
    while (!failed && it.moveNext()) {
      final item = it.current;
      try {
        await job(item);
      } catch (e, s) {
        if (!failed) {
          failed = true;
          error = e;
          trace = s;
        }
      }
    }
  }

  await Future.wait([for (var i = 0; i < width; i++) worker()]);
  if (failed) Error.throwWithStackTrace(error!, trace!);
}

/// Like [forEachLimited], but a job that throws does not stop the others: every item gets its turn, and the
/// ones whose job threw come back with their error.
Future<Map<T, Object>> forEachSettled<T>(Iterable<T> items, int width, Future<void> Function(T item) job) async {
  final it = items.iterator;
  final failed = <T, Object>{};

  Future<void> worker() async {
    while (it.moveNext()) {
      final item = it.current;
      try {
        await job(item);
      } catch (e) {
        failed[item] = e;
      }
    }
  }

  await Future.wait([for (var i = 0; i < width; i++) worker()]);
  return failed;
}
