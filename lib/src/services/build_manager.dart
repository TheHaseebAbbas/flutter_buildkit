import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../build_paths.dart';
import '../ledger/ledger.dart';
import '../model/build_record.dart';
import 'flutter_builder.dart';

/// Ledger operations that also touch the build folders on disk.
class BuildManager {
  /// Creates a manager that works on [ledger] and its folders.
  BuildManager(this.ledger, {this.retainOn = defaultRetainOn});

  /// Builds kept after a delete unless the config says otherwise: marked
  /// published, or uploaded to alpha, beta or production. A QA upload to the
  /// internal track does not make a build immortal.
  static const defaultRetainOn = {'published', 'alpha', 'beta', 'production'};

  /// What keeps a build's symbols and row; see [BuildRecord.isRetainedBy].
  final Set<String> retainOn;

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
  /// * Any other build is removed
  ///   completely: its folder (files, symbols, mappings) and its ledger row.
  /// * A build kept by [retainOn] only loses its APK/AAB/IPA files. Its
  ///   debug symbols, mappings and ledger row stay, so crashes from the field
  ///   can still be traced.
  ///
  /// The ledger file is hand-editable, so every path is checked before
  /// anything is removed: after resolving symlinks it must lie strictly
  /// inside the ledger's folder, must not contain another build, and a build
  /// folder must hold a `build_info.json` with the same id. A build that
  /// fails a check is reported in [DeleteResult.failed] and left alone.
  ///
  /// With [dryRun] the checks run and the result says what would happen, but
  /// nothing is changed.
  ///
  /// Builds whose files could not be deleted keep their row.
  Future<DeleteResult> delete(Iterable<BuildRecord> records,
      {bool dryRun = false}) async {
    final deleted = <BuildRecord>[];
    final filesOnly = <BuildRecord>[];
    final failed = <BuildRecord, Object>{};
    for (final r in records) {
      try {
        if (r.isRetainedBy(retainOn)) {
          if (r.artifactsDeleted) continue;
          final files = await _artifactFiles(r);
          if (!dryRun) {
            for (final f in files) {
              if (await f.exists()) await f.delete();
            }
            await ledger.update(r.id,
                (x) => x.copyWith(artifactsDeletedAt: DateTime.now().toUtc()));
          }
          filesOnly.add(r);
        } else {
          final dir = Directory(await safeBuildDir(r));
          if (!dryRun) {
            if (await dir.exists()) await dir.delete(recursive: true);
            await pruneEmptyParents(ledger.rootDir, dir.parent);
            await ledger.remove([r.id]);
          }
          deleted.add(r);
        }
      } on FileSystemException catch (e) {
        failed[r] = e;
      } on StateError catch (e) {
        failed[r] = e;
      }
    }
    return DeleteResult(deleted, filesOnly, failed, dryRun: dryRun);
  }

  Future<List<File>> _artifactFiles(BuildRecord r) async {
    await safeBuildDir(r);
    final files = <File>[];
    for (final a in r.artifacts) {
      final path = ledger.resolve(a.path);
      // Compare the real location of the folder holding the file, so a
      // symlinked folder cannot lead out of the ledger's root.
      final parent = await _canonical(p.dirname(path));
      final root = await _canonical(ledger.rootDir);
      if (!p.isWithin(root, parent)) {
        throw StateError(
            'Refusing to delete $path: it resolves outside $root.');
      }
      files.add(File(path));
    }
    return files;
  }

  /// [path] with symlinks resolved. For a path that does not exist (yet) the
  /// nearest existing parent is resolved and the rest appended, so it is
  /// comparable with other resolved paths (`/var` vs `/private/var` on macOS,
  /// short and long names on Windows).
  Future<String> _canonical(String path) async {
    var current = p.normalize(p.absolute(path));
    final rest = <String>[];
    while (await FileSystemEntity.type(current, followLinks: false) ==
        FileSystemEntityType.notFound) {
      final parent = p.dirname(current);
      if (parent == current) return p.normalize(p.absolute(path));
      rest.insert(0, p.basename(current));
      current = parent;
    }
    // A link or file is resolved through its parent folder; a folder itself.
    final isDir = await FileSystemEntity.isDirectory(current);
    final resolved = isDir
        ? await Directory(current).resolveSymbolicLinks()
        : p.join(await Directory(p.dirname(current)).resolveSymbolicLinks(),
            p.basename(current));
    return p.joinAll([resolved, ...rest]);
  }

  /// Build folder for [r]; throws [StateError] unless it is safe to remove
  /// (inside the ledger's folder, owned by [r] and holding no other build).
  Future<String> safeBuildDir(BuildRecord r) async {
    final dir = ledger.resolve(r.outputDir);
    final root = await _canonical(ledger.rootDir);
    final real = await _canonical(dir);
    if (!p.isWithin(root, real)) {
      throw StateError(
          'Refusing to delete $dir: it is not inside $root (the ledger\'s '
          'folder).');
    }
    for (final other in ledger.records) {
      if (other.id == r.id) continue;
      final otherDir = await _canonical(ledger.resolve(other.outputDir));
      if (p.isWithin(real, otherDir) || p.equals(real, otherDir)) {
        throw StateError('Refusing to delete $dir: it also holds build '
            '${other.id}.');
      }
    }
    if (await Directory(dir).exists()) {
      final info = File(p.join(dir, buildInfoName));
      if (!await info.exists()) {
        throw StateError('Refusing to delete $dir: it has no $buildInfoName, '
            'so it does not look like a build folder.');
      }
      Object? id;
      try {
        id = (jsonDecode(await info.readAsString()) as Map)['id'];
      } on Object {
        id = null;
      }
      if (id != r.id) {
        throw StateError('Refusing to delete $dir: $buildInfoName does not '
            'belong to build ${r.id}.');
      }
    }
    return dir;
  }
}

/// What [BuildManager.delete] did, per build.
class DeleteResult {
  /// Creates a result from the three outcome groups.
  DeleteResult(this.deleted, this.filesOnly, this.failed,
      {this.dryRun = false});

  /// True when nothing was changed; the lists say what would have happened.
  final bool dryRun;

  /// Folder and ledger row removed.
  final List<BuildRecord> deleted;

  /// Released builds: only the binaries were removed; symbols and row kept.
  final List<BuildRecord> filesOnly;

  /// Builds that could not be deleted, with the error that stopped each.
  final Map<BuildRecord, Object> failed;
}
