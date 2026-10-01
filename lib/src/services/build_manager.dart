import 'dart:io';

import 'package:path/path.dart' as p;

import '../build_paths.dart';
import '../ledger/ledger.dart';
import '../model/build_record.dart';

/// Ledger operations that also touch the build folders on disk.
class BuildManager {
  /// Creates a manager that works on [ledger] and its folders.
  BuildManager(this.ledger);

  /// The ledger whose records this manager changes.
  final Ledger ledger;

  /// Marks a build as published (released to users).
  Future<BuildRecord> markPublished(BuildRecord r, {DateTime? at}) =>
      ledger.update(
          r.id, (x) => x.copyWith(publishedAt: (at ?? DateTime.now()).toUtc()));

  /// Clears the published mark from [r]; this is recorded as an `unpublished` event.
  Future<BuildRecord> unmarkPublished(BuildRecord r) =>
      ledger.update(r.id, (x) => x.copyWith(clearPublished: true));

  /// Deletes builds.
  ///
  /// * A build that was never published or uploaded to Play is removed
  ///   completely: its folder (files, symbols, mappings) and its ledger row.
  /// * A [BuildRecord.isReleased] build only loses its APK/AAB/IPA files. Its
  ///   debug symbols, mappings and ledger row stay, so crashes from the field
  ///   can still be traced.
  ///
  /// Builds whose files could not be deleted keep their row.
  Future<DeleteResult> delete(Iterable<BuildRecord> records) async {
    final deleted = <BuildRecord>[];
    final filesOnly = <BuildRecord>[];
    final failed = <BuildRecord, Object>{};
    for (final r in records) {
      try {
        if (r.isReleased) {
          if (r.artifactsDeleted) continue;
          await _deleteArtifacts(r);
          await ledger.update(r.id,
              (x) => x.copyWith(artifactsDeletedAt: DateTime.now().toUtc()));
          filesOnly.add(r);
        } else {
          final dir = Directory(_safeBuildDir(r));
          if (await dir.exists()) await dir.delete(recursive: true);
          await pruneEmptyParents(ledger.rootDir, dir.parent);
          await ledger.remove([r.id]);
          deleted.add(r);
        }
      } on FileSystemException catch (e) {
        failed[r] = e;
      } on StateError catch (e) {
        failed[r] = e;
      }
    }
    return DeleteResult(deleted, filesOnly, failed);
  }

  Future<void> _deleteArtifacts(BuildRecord r) async {
    _safeBuildDir(r);
    for (final a in r.artifacts) {
      final path = ledger.resolve(a.path);
      if (!p.isWithin(ledger.rootDir, path)) {
        throw StateError(
            'Refusing to delete $path: outside ${ledger.rootDir}.');
      }
      final f = File(path);
      if (await f.exists()) await f.delete();
    }
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
}

/// What [BuildManager.delete] did, per build.
class DeleteResult {
  /// Creates a result from the three outcome groups.
  DeleteResult(this.deleted, this.filesOnly, this.failed);

  /// Folder and ledger row removed.
  final List<BuildRecord> deleted;

  /// Released builds: only the binaries were removed; symbols and row kept.
  final List<BuildRecord> filesOnly;

  /// Builds that could not be deleted, with the error that stopped each.
  final Map<BuildRecord, Object> failed;
}
