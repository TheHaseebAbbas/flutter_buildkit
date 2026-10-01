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
  Ledger(this.file);

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
  Future<void> add(BuildRecord record) async {
    if (byId(record.id) != null) {
      throw LedgerException('A build with id ${record.id} already exists.');
    }
    _records.add(record);
    await save();
  }

  /// Replaces the record with [id] by the result of [change] and saves.
  ///
  /// Returns the new record. Throws [LedgerException] if [id] is unknown.
  Future<BuildRecord> update(
      String id, BuildRecord Function(BuildRecord) change) async {
    final index = _records.indexWhere((r) => r.id == id);
    if (index < 0) throw LedgerException('No build with id $id.');
    final updated = change(_records[index]);
    _records[index] = updated;
    await save();
    return updated;
  }

  /// Removes the rows with [ids]; returns the removed records.
  Future<List<BuildRecord>> remove(Iterable<String> ids) async {
    final set = ids.toSet();
    final removed = _records.where((r) => set.contains(r.id)).toList();
    _records.removeWhere((r) => set.contains(r.id));
    if (removed.isNotEmpty) await save();
    return removed;
  }

  /// The ledger as pretty printed JSON text, with a trailing update time.
  String encode() => const JsonEncoder.withIndent('  ').convert({
        'schemaVersion': schemaVersion,
        'updatedAt': DateTime.now().toUtc().toIso8601String(),
        'builds': [for (final r in records) r.toJson()],
      });

  /// Writes the ledger to [file] atomically, keeping the old copy as `.bak`.
  Future<void> save() async {
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString('${encode()}\n', flush: true);
    if (await file.exists()) {
      await file.copy('${file.path}.bak');
    }
    await tmp.rename(file.path);
  }
}
