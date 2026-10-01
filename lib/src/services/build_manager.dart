import 'dart:io';

import 'package:path/path.dart' as p;

import '../ledger/ledger.dart';
import '../model/build_record.dart';

/// Ledger operations that also touch the build folders on disk.
class BuildManager {
  BuildManager(this.ledger);

  final Ledger ledger;

  /// Marks a build as published (released to users).
  Future<BuildRecord> markPublished(BuildRecord r, {DateTime? at}) =>
      ledger.update(
          r.id, (x) => x.copyWith(publishedAt: (at ?? DateTime.now()).toUtc()));

  Future<BuildRecord> unmarkPublished(BuildRecord r) =>
      ledger.update(r.id, (x) => x.copyWith(clearPublished: true));

  /// Deletes the build folder and removes the ledger row.
  ///
  /// The ledger row is removed even when the folder is already gone, so the
  /// ledger never keeps a row for a build that no longer exists. Returns the
  /// builds whose folder could not be deleted; their rows are kept.
  Future<DeleteResult> delete(Iterable<BuildRecord> records) async {
    final deleted = <BuildRecord>[];
    final failed = <BuildRecord, Object>{};
    for (final r in records) {
      try {
        final dir = Directory(_safeBuildDir(r));
        if (await dir.exists()) await dir.delete(recursive: true);
        await _pruneEmptyParents(dir.parent);
        deleted.add(r);
      } on FileSystemException catch (e) {
        failed[r] = e;
      } on StateError catch (e) {
        failed[r] = e;
      }
    }
    await ledger.remove(deleted.map((r) => r.id));
    return DeleteResult(deleted, failed);
  }

  /// Build folder for [r], refusing anything outside the ledger's root.
  String _safeBuildDir(BuildRecord r) {
    final dir = ledger.resolve(r.outputDir);
    if (!p.isWithin(ledger.rootDir, dir)) {
      throw StateError(
          'Refusing to delete $dir: it is outside ${ledger.rootDir}.');
    }
    return dir;
  }

  /// Removes `<mode>`, `<flavor>` and `<app>` folders left empty, never the
  /// root itself.
  Future<void> _pruneEmptyParents(Directory dir) async {
    var current = dir;
    while (p.isWithin(ledger.rootDir, current.path) &&
        await current.exists() &&
        await current.list().isEmpty) {
      await current.delete();
      current = current.parent;
    }
  }
}

class DeleteResult {
  DeleteResult(this.deleted, this.failed);
  final List<BuildRecord> deleted;
  final Map<BuildRecord, Object> failed;
}
