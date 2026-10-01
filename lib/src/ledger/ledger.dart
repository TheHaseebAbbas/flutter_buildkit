import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../model/build_record.dart';

class LedgerException implements Exception {
  LedgerException(this.message);
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
  Ledger(this.file);

  static const schemaVersion = 1;

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

  static Future<Ledger> open(String path) async {
    final ledger = Ledger(File(path));
    await ledger.reload();
    return ledger;
  }

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

  Future<void> add(BuildRecord record) async {
    if (byId(record.id) != null) {
      throw LedgerException('A build with id ${record.id} already exists.');
    }
    _records.add(record);
    await save();
  }

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

  String encode() => const JsonEncoder.withIndent('  ').convert({
        'schemaVersion': schemaVersion,
        'updatedAt': DateTime.now().toUtc().toIso8601String(),
        'builds': [for (final r in records) r.toJson()],
      });

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
