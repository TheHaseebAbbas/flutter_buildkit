import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../build_paths.dart';
import '../ledger/ledger.dart';
import '../model/build_record.dart';
import 'build_manager.dart';
import 'flutter_builder.dart';

/// One thing `verify` found wrong with the ledger or its folders.
class VerifyIssue {
  /// Creates an issue about build [id] (null for a folder with no row).
  const VerifyIssue(this.kind, this.message, {this.id, this.path});

  /// `missing_folder`, `missing_file`, `size_mismatch`, `hash_mismatch`,
  /// `missing_symbols` or `orphan_folder`.
  final String kind;

  /// What is wrong, in words.
  final String message;

  /// The ledger row concerned, if any.
  final String? id;

  /// The file or folder concerned, if any.
  final String? path;

  /// JSON form for `--json`.
  Map<String, Object?> toJson() => {
        'kind': kind,
        if (id != null) 'id': id,
        if (path != null) 'path': path,
        'message': message,
      };
}

/// Result of [verifyLedger].
class VerifyReport {
  /// Creates a report of [checked] rows and the [issues] found.
  const VerifyReport(this.checked, this.issues);

  /// How many ledger rows were looked at.
  final int checked;

  /// Everything that did not check out.
  final List<VerifyIssue> issues;

  /// True when nothing is wrong.
  bool get ok => issues.isEmpty;
}

/// Compares the ledger with the build folders on disk.
///
/// Reports rows whose folder or files are gone (unless their files were
/// deleted on purpose), files whose size or SHA-256 differs from the row,
/// obfuscated builds whose symbols are missing, and build folders under the
/// ledger's root that no row owns. With [hash] false only existence and size
/// are checked, which is quick for large AABs.
Future<VerifyReport> verifyLedger(Ledger ledger, {bool hash = true}) async {
  final issues = <VerifyIssue>[];
  final known = <String>{};
  for (final r in ledger.records) {
    final dir = ledger.resolve(r.outputDir);
    known.add(p.normalize(dir));
    if (!Directory(dir).existsSync()) {
      issues.add(VerifyIssue(
          'missing_folder', 'The folder of ${r.id} is gone: $dir',
          id: r.id, path: dir));
      continue;
    }
    if (!r.artifactsDeleted) {
      for (final a in r.artifacts) {
        final path = ledger.resolve(a.path);
        final file = File(path);
        if (!file.existsSync()) {
          issues.add(VerifyIssue('missing_file', '${r.id}: $path is gone',
              id: r.id, path: path));
          continue;
        }
        if (a.sizeBytes > 0 && file.lengthSync() != a.sizeBytes) {
          issues.add(VerifyIssue('size_mismatch',
              '${r.id}: $path is ${file.lengthSync()} bytes, the ledger says ${a.sizeBytes}',
              id: r.id, path: path));
        } else if (hash && a.sha256.isNotEmpty) {
          final actual = (await sha256.bind(file.openRead()).first).toString();
          if (actual != a.sha256) {
            issues.add(VerifyIssue(
                'hash_mismatch', '${r.id}: $path no longer matches its SHA-256',
                id: r.id, path: path));
          }
        }
      }
    }
    if (!r.isFailed && r.obfuscated && r.symbolUploads.isEmpty) {
      final symbols = r.symbolsDir == null
          ? null
          : Directory(ledger.resolve(r.symbolsDir!));
      if (symbols == null || !symbols.existsSync()) {
        issues.add(VerifyIssue(
            'missing_symbols',
            '${r.id} is obfuscated but its symbols are not on disk and were '
                'never uploaded; its crashes cannot be traced.',
            id: r.id));
      }
    }
  }
  // Build folders hold a build_info.json; one nobody owns is an orphan.
  final root = Directory(ledger.rootDir);
  if (root.existsSync()) {
    await for (final e in root.list(recursive: true, followLinks: false)) {
      if (e is File && p.basename(e.path) == buildInfoName) {
        final dir = p.normalize(p.dirname(e.path));
        if (!known.contains(dir)) {
          issues.add(VerifyIssue(
              'orphan_folder', '$dir is a build folder with no ledger row',
              path: dir));
        }
      }
    }
  }
  return VerifyReport(ledger.records.length, issues);
}

/// What [pruneBuilds] removed, or would remove with `dryRun`.
class PruneResult {
  /// Creates a result.
  PruneResult(this.dryRun,
      {required this.logs,
      required this.failedBuilds,
      required this.symbols,
      required this.failed});

  /// True when nothing was changed.
  final bool dryRun;

  /// Builds whose `build.log` was removed.
  final List<BuildRecord> logs;

  /// Failed builds removed with their folders.
  final List<BuildRecord> failedBuilds;

  /// Released builds whose local symbols were removed.
  final List<BuildRecord> symbols;

  /// Builds that could not be pruned, with the error.
  final Map<BuildRecord, Object> failed;
}

/// Applies the retention settings.
///
/// * Failed builds older than [logDays] days are removed with their folder.
/// * `build.log` of other builds older than [logDays] is removed.
/// * With [symbolsKeepLast] N, the local symbols and mapping of the released
///   builds beyond the newest N of each app and flavor are removed, but only
///   when they were uploaded to a crash tool first; the row stays.
///
/// Every path goes through the same checks as [BuildManager.delete].
Future<PruneResult> pruneBuilds(
  Ledger ledger,
  BuildManager manager, {
  int? logDays,
  int? symbolsKeepLast,
  bool dryRun = false,
  DateTime? now,
}) async {
  now ??= DateTime.now();
  final logs = <BuildRecord>[];
  final failedBuilds = <BuildRecord>[];
  final symbols = <BuildRecord>[];
  final failed = <BuildRecord, Object>{};

  if (logDays != null) {
    final cutoff = now.subtract(Duration(days: logDays));
    for (final r in ledger.records.toList()) {
      if (!r.createdAt.isBefore(cutoff)) continue;
      try {
        if (r.isFailed) {
          final result = await manager.delete([r], dryRun: dryRun);
          if (result.failed.isNotEmpty) {
            failed[r] = result.failed.values.first;
          } else {
            failedBuilds.add(r);
          }
          continue;
        }
        final dir = await manager.safeBuildDir(r);
        final log = File(p.join(dir, buildLogName));
        if (await log.exists()) {
          if (!dryRun) await log.delete();
          logs.add(r);
        }
      } on FileSystemException catch (e) {
        failed[r] = e;
      } on StateError catch (e) {
        failed[r] = e;
      }
    }
  }

  if (symbolsKeepLast != null) {
    final groups = <String, List<BuildRecord>>{};
    for (final r in ledger.records) {
      if (r.isFailed || !r.isRetainedBy(manager.retainOn)) continue;
      groups.putIfAbsent('${r.appName}/${r.flavorLabel}', () => []).add(r);
    }
    for (final group in groups.values) {
      group.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      for (final r in group.skip(symbolsKeepLast)) {
        if (r.symbolsDir == null && r.mappingFile == null) continue;
        if (r.symbolUploads.isEmpty) continue; // the only copy; keep it
        try {
          final dir = await manager.safeBuildDir(r);
          final target = Directory(p.join(dir, BuildPaths.symbolsFolder));
          if (!dryRun) {
            if (await target.exists()) await target.delete(recursive: true);
            await ledger.update(r.id, (x) => x.copyWith(clearSymbols: true));
          }
          symbols.add(r);
        } on FileSystemException catch (e) {
          failed[r] = e;
        } on StateError catch (e) {
          failed[r] = e;
        }
      }
    }
  }
  return PruneResult(dryRun,
      logs: logs, failedBuilds: failedBuilds, symbols: symbols, failed: failed);
}

/// Pretty JSON for reports.
String jsonText(Object? value) =>
    const JsonEncoder.withIndent('  ').convert(value);
