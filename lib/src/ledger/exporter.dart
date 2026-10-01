import 'dart:convert';

import '../model/build_record.dart';

enum ExportFormat {
  json('json'),
  csv('csv'),
  tsv('tsv');

  const ExportFormat(this.extension);
  final String extension;
}

/// Turns ledger rows into CSV, TSV or JSON text.
class LedgerExporter {
  const LedgerExporter();

  static const columns = [
    'id',
    'created_at',
    'app_name',
    'package_name',
    'flavor',
    'entry_point',
    'mode',
    'type',
    'status',
    'condition',
    'symbols_status',
    'last_event_at',
    'version_name',
    'version_code',
    'obfuscated',
    'published_at',
    'play_track',
    'play_release_status',
    'play_uploaded_at',
    'play_via_api',
    'crashlytics_uploaded_at',
    'sentry_uploaded_at',
    'artifacts_deleted_at',
    'output_dir',
    'artifacts',
    'total_size_bytes',
    'sha256',
    'symbols_dir',
    'mapping_file',
    'git_commit',
    'git_branch',
    'flutter_version',
    'duration_ms',
    'notes',
  ];

  String export(List<BuildRecord> records, ExportFormat format) =>
      switch (format) {
        ExportFormat.json => toJson(records),
        ExportFormat.csv => toCsv(records),
        ExportFormat.tsv => toTsv(records),
      };

  String toJson(List<BuildRecord> records) => const JsonEncoder.withIndent('  ')
      .convert([for (final r in records) r.toJson()]);

  /// RFC 4180 CSV with CRLF line endings, so Excel and Sheets open it as is.
  String toCsv(List<BuildRecord> records) {
    final buffer = StringBuffer();
    for (final row in [columns, ...records.map(row)]) {
      buffer
        ..write(row.map(_csvField).join(','))
        ..write('\r\n');
    }
    return buffer.toString();
  }

  /// Tab separated values. TSV has no quoting, so tabs, newlines and
  /// backslashes inside a value are written as `\t`, `\n` and `\\`.
  String toTsv(List<BuildRecord> records) {
    final buffer = StringBuffer();
    for (final row in [columns, ...records.map(row)]) {
      buffer
        ..write(row.map(_tsvField).join('\t'))
        ..write('\n');
    }
    return buffer.toString();
  }

  /// One flat row, in [columns] order.
  List<String> row(BuildRecord r) {
    String ts(DateTime? d) => d?.toUtc().toIso8601String() ?? '';
    return [
      r.id,
      ts(r.createdAt),
      r.appName,
      r.packageName ?? '',
      r.flavor ?? '',
      r.entryPoint ?? '',
      r.mode.name,
      r.type.name,
      r.status.code,
      r.condition,
      r.symbolsStatus,
      ts(r.lastEventAt),
      r.versionName,
      '${r.versionCode}',
      '${r.obfuscated}',
      ts(r.publishedAt),
      r.play?.track ?? '',
      r.play?.releaseStatus ?? '',
      ts(r.play?.uploadedAt),
      r.play == null ? '' : '${r.play!.viaApi}',
      ts(r.symbolUploads[SymbolTargets.crashlytics]),
      ts(r.symbolUploads[SymbolTargets.sentry]),
      ts(r.artifactsDeletedAt),
      r.outputDir,
      r.artifacts.map((a) => a.path).join(';'),
      '${r.totalSize}',
      r.artifacts.map((a) => a.sha256).join(';'),
      r.symbolsDir ?? '',
      r.mappingFile ?? '',
      r.gitCommit ?? '',
      r.gitBranch ?? '',
      r.flutterVersion ?? '',
      r.durationMs?.toString() ?? '',
      r.notes ?? '',
    ];
  }

  static String _csvField(String value) {
    final needsQuotes = value.contains(RegExp('[",\r\n]')) ||
        value.startsWith(' ') ||
        value.endsWith(' ');
    return needsQuotes ? '"${value.replaceAll('"', '""')}"' : value;
  }

  static String _tsvField(String value) => value
      .replaceAll(r'\', r'\\')
      .replaceAll('\t', r'\t')
      .replaceAll('\r', r'\r')
      .replaceAll('\n', r'\n');
}
