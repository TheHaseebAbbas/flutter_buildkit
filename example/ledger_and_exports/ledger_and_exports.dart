// The ledger: add, update, remove, reload, and export to CSV / TSV / JSON.
//
//   dart run example/ledger_and_exports/ledger_and_exports.dart
//
// Rows are written by hand here, so no build (and no fake flutter) is needed.
import 'dart:io';

import 'package:flutter_buildkit/flutter_buildkit.dart';
import 'package:path/path.dart' as p;

import '../_support/demo.dart';

BuildRecord row(String id, String flavor, DateTime at, {int code = 42}) =>
    BuildRecord(
      id: id,
      appName: 'my_app',
      flavor: flavor,
      mode: BuildMode.release,
      type: ArtifactType.aab,
      versionName: '1.2.0',
      versionCode: code,
      createdAt: at.toUtc(),
      // Paths are relative to the ledger folder, so the folder can be moved.
      outputDir: '$flavor/release/1.2.0-b$code',
      artifacts: [
        BuildArtifact(
          path: '$flavor/release/1.2.0-b$code/artifacts/my_app-$flavor.aab',
          sizeBytes: 18 * 1024 * 1024,
          sha256: 'ab12' * 16,
        ),
      ],
      packageName: 'com.example.my_app',
    );

Future<void> main() async {
  final tmp = Directory.systemTemp.createTempSync('fbk_ledger_');
  try {
    final path = p.join(tmp.path, 'app_builds', 'ledger.json');

    title('Open (a missing file is an empty ledger) and add rows');
    final ledger = await Ledger.open(path);
    await ledger.add(row('a1', 'dev', DateTime(2026, 10, 1, 9)));
    await ledger.add(row('b2', 'prod', DateTime(2026, 10, 2, 9), code: 43));
    print('rows: ${ledger.records.map((r) => r.id).toList()} (newest first)');

    title('Update a row: Play upload, published mark, symbol upload');
    await ledger.update(
      'b2',
      (r) => r.copyWith(
        play: PlayUpload(
          track: 'internal',
          releaseStatus: 'completed',
          uploadedAt: DateTime.now().toUtc(),
          viaApi: true,
        ),
        symbolUploads: {SymbolTargets.sentry: DateTime.now().toUtc()},
      ),
    );
    final b2 = ledger.byId('b2')!;
    print('status=${b2.status.code}  symbols=${b2.symbolsStatus}');
    for (final e in b2.events) {
      print('  ${e.kind}${e.note == null ? '' : ' (${e.note})'}');
    }

    title('Exports: JSON is the ledger itself, CSV and TSV are flat copies');
    const exporter = LedgerExporter();
    for (final format in ExportFormat.values) {
      final text = exporter.export(ledger.records, format);
      final file = File(p.join(
          tmp.path, 'app_builds', 'exports', 'ledger.${format.extension}'))
        ..createSync(recursive: true)
        ..writeAsStringSync(text);
      print('${format.extension.padRight(4)} ${text.length} chars -> '
          '${p.relative(file.path, from: tmp.path)}');
    }
    print('\nCSV header:\n${LedgerExporter.columns.join(',')}');
    print('\nCSV rows:');
    print(exporter.toCsv(ledger.records).split('\n').skip(1).join('\n'));

    title('Reload from disk; remove a row');
    final again = await Ledger.open(path);
    print('reloaded ${again.records.length} rows, '
        'backup kept: ${File('$path.bak').existsSync()}');
    await again.remove(['a1']);
    print('after remove: ${again.records.map((r) => r.id).toList()}');

    title('Bad files are reported, never overwritten');
    File(path).writeAsStringSync('{ not json');
    try {
      await Ledger.open(path);
    } on LedgerException catch (e) {
      print(e);
    }
  } finally {
    tmp.deleteSync(recursive: true);
  }
}
