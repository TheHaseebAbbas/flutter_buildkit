import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../model/build_record.dart';

/// Thrown when the ledger file cannot be read or a change is invalid.
class LedgerException implements Exception {
  /// Creates an exception with a human readable [message].
  LedgerException(this.message);

  /// What went wrong, phrased for showing to the user.
  final String message;
  @override
  String toString() => 'LedgerException: $message';
}

/// The build ledger, stored as a single JSON document.
///
/// JSON is the default because the ledger is nested (artifacts, Play status,
/// per-tool symbol uploads) and typed (numbers, booleans, timestamps). CSV and
/// TSV would flatten and stringify all of that, so they are export formats.
///
/// Every save writes a temporary file and renames it over the ledger, so a
/// crash mid-write never leaves a half-written ledger, and the previous
/// version is kept as `<ledger>.bak`.
class Ledger {
  /// Creates a ledger backed by [file]; call [reload] to read existing rows.
  Ledger(this.file, {this.lockWait = const Duration(seconds: 10)});

  /// Version of the JSON layout written by [save]; newer files are rejected.
  static const schemaVersion = 1;

  /// The JSON file the ledger is stored in.
  final File file;
  final List<BuildRecord> _records = [];

  /// Folder that every relative path in a record is resolved against.
  String get rootDir => p.dirname(p.absolute(file.path));

  /// Records, newest first.
  List<BuildRecord> get records {
    final sorted = List<BuildRecord>.of(_records)
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return List.unmodifiable(sorted);
  }

  /// Opens the ledger at [path], loading it if the file exists.
  ///
  /// A missing file gives an empty ledger. Throws [LedgerException] when the
  /// file is malformed.
  static Future<Ledger> open(String path) async {
    final ledger = Ledger(File(path));
    await ledger.reload();
    return ledger;
  }

  /// Discards in-memory rows and re-reads them from [file].
  ///
  /// Throws [LedgerException] for invalid JSON, an unexpected shape or a
  /// schema version newer than [schemaVersion].
  Future<void> reload() async {
    _records.clear();
    if (!await file.exists()) return;
    final text = await file.readAsString();
    if (text.trim().isEmpty) return;
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException catch (e) {
      throw LedgerException(
          'Ledger ${file.path} is not valid JSON (${e.message}). '
          'Fix it or restore ${file.path}.bak.');
    }
    final List<Object?> builds;
    if (decoded is Map && decoded['builds'] is List) {
      final version = (decoded['schemaVersion'] as num?)?.toInt() ?? 1;
      if (version > schemaVersion) {
        throw LedgerException('Ledger schema v$version is newer than this '
            'tool supports (v$schemaVersion). Update flutter_buildkit.');
      }
      builds = decoded['builds'] as List<Object?>;
    } else if (decoded is List) {
      builds = decoded;
    } else {
      throw LedgerException('Ledger ${file.path} has an unexpected shape.');
    }
    for (final b in builds) {
      _records.add(BuildRecord.fromJson((b! as Map).cast<String, Object?>()));
    }
  }

  /// The record with [id], or null if there is none.
  BuildRecord? byId(String id) {
    for (final r in _records) {
      if (r.id == id) return r;
    }
    return null;
  }

  /// Absolute path for a path stored relative to [rootDir].
  String resolve(String relative) => p
      .normalize(p.isAbsolute(relative) ? relative : p.join(rootDir, relative));

  /// Path to store in a record for an absolute [path].
  String relativize(String path) =>
      p.relative(p.absolute(path), from: rootDir).replaceAll(r'\', '/');

  /// Appends [record] and saves.
  ///
  /// Throws [LedgerException] if a record with the same id already exists.
  Future<void> add(BuildRecord record) => _mutate(() {
        if (byId(record.id) != null) {
          throw LedgerException('A build with id ${record.id} already exists.');
        }
        _records.add(record);
        return true;
      });

  /// Replaces the record with [id] by the result of [change] and saves.
  ///
  /// Returns the new record. Throws [LedgerException] if [id] is unknown.
  Future<BuildRecord> update(
      String id, BuildRecord Function(BuildRecord) change) async {
    late BuildRecord updated;
    await _mutate(() {
      final index = _records.indexWhere((r) => r.id == id);
      if (index < 0) throw LedgerException('No build with id $id.');
      updated = change(_records[index]);
      _records[index] = updated;
      return true;
    });
    return updated;
  }

  /// Removes the rows with [ids]; returns the removed records.
  Future<List<BuildRecord>> remove(Iterable<String> ids) async {
    final set = ids.toSet();
    var removed = <BuildRecord>[];
    await _mutate(() {
      removed = _records.where((r) => set.contains(r.id)).toList();
      _records.removeWhere((r) => set.contains(r.id));
      return removed.isNotEmpty;
    });
    return removed;
  }

  /// Highest version code recorded for [appName] (failed builds ignored), or
  /// null when there is none. Used to warn before building a lower number.
  int? highestVersionCode(String appName) {
    int? best;
    for (final r in _records) {
      if (r.appName != appName || r.isFailed) continue;
      if (best == null || r.versionCode > best) best = r.versionCode;
    }
    return best;
  }

  /// Runs one read-modify-write cycle under the lock file.
  ///
  /// The ledger is re-read from disk first, so a change made by another
  /// process (a menu session and a CI job, two terminals) is not overwritten.
  /// [change] returns false when nothing changed, to skip saving.
  Future<void> _mutate(FutureOr<bool> Function() change) async {
    await file.parent.create(recursive: true);
    final lock = await _acquireLock();
    try {
      await reload();
      if (!await change()) return;
      await save();
    } finally {
      if (await lock.exists()) await lock.delete();
    }
  }

  /// How long a change waits for another process to release the lock.
  final Duration lockWait;

  /// A lock file older than this counts as left behind by a crashed process,
  /// and is ignored and replaced.
  static const lockStale = Duration(minutes: 2);

  Future<File> _acquireLock() async {
    final lock = File('${file.path}.lock');
    final deadline = DateTime.now().add(lockWait);
    while (true) {
      try {
        await lock.create(exclusive: true);
        await lock.writeAsString(
            'pid $pid\n${DateTime.now().toUtc().toIso8601String()}\n');
        return lock;
      } on FileSystemException {
        // Someone holds the lock, unless it is a leftover.
        try {
          final age = DateTime.now().difference(await lock.lastModified());
          if (age > lockStale) {
            await lock.delete();
            continue;
          }
        } on FileSystemException {
          continue; // released between the two calls
        }
        if (DateTime.now().isAfter(deadline)) {
          var holder = '';
          try {
            holder =
                ' (${(await lock.readAsString()).trim().split('\n').first})';
          } on FileSystemException {
            // Gone already.
          }
          throw LedgerException('The ledger is in use by another process'
              '$holder. Try again, or delete ${lock.path} if no other '
              'flutter_buildkit is running.');
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  }

  /// The ledger as pretty printed JSON text, with a trailing update time.
  String encode() => const JsonEncoder.withIndent('  ').convert({
        'schemaVersion': schemaVersion,
        'updatedAt': DateTime.now().toUtc().toIso8601String(),
        'builds': [for (final r in records) r.toJson()],
      });

  /// How many daily snapshots under `.history/` are kept.
  static const historyDays = 7;

  /// Writes the ledger to [file] atomically.
  ///
  /// The previous version is kept as `<ledger>.bak`. The first save of each
  /// day also copies the file as it was to `.history/ledger-<date>.json`
  /// (the last [historyDays] are kept), so one bad save or hand edit cannot
  /// replace the only good copy.
  Future<void> save() async {
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString('${encode()}\n', flush: true);
    if (await file.exists()) {
      await _snapshot();
      await file.copy('${file.path}.bak');
    }
    await tmp.rename(file.path);
  }

  Future<void> _snapshot() async {
    final dir = Directory(p.join(rootDir, '.history'));
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final day = '${now.year}${two(now.month)}${two(now.day)}';
    final today = File(p.join(dir.path, 'ledger-$day.json'));
    if (await today.exists()) return;
    await dir.create(recursive: true);
    await file.copy(today.path);
    final old = [
      for (final f in await dir.list().toList())
        if (f is File && RegExp(r'ledger-\d{8}\.json$').hasMatch(f.path)) f,
    ]..sort((a, b) => b.path.compareTo(a.path));
    for (final f in old.skip(historyDays)) {
      await f.delete();
    }
  }
}
