import 'dart:convert';
import 'dart:io';

import 'package:flutter_build_ledger/flutter_build_ledger.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

BuildRecord record(String id,
        {String? flavor = 'dev',
        DateTime? at,
        ArtifactType type = ArtifactType.aab,
        String outputDir = 'app/dev/release/1.0.0+1_x'}) =>
    BuildRecord(
      id: id,
      appName: 'my_app',
      packageName: 'com.example.app',
      flavor: flavor,
      mode: BuildMode.release,
      type: type,
      versionName: '1.0.0',
      versionCode: 1,
      createdAt: at ?? DateTime.utc(2026, 10, 1, 7),
      outputDir: outputDir,
      artifacts: const [
        BuildArtifact(path: 'app/dev/a.aab', sizeBytes: 100, sha256: 'abc')
      ],
      obfuscated: true,
    );

void main() {
  late Directory tmp;
  late Ledger ledger;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('fbl_ledger_');
    ledger = await Ledger.open(p.join(tmp.path, 'builds', 'ledger.json'));
  });
  tearDown(() => tmp.delete(recursive: true));

  group('Ledger', () {
    test('starts empty when the file does not exist', () {
      expect(ledger.records, isEmpty);
    });

    test('persists and reloads records losslessly', () async {
      final r = record('a').copyWith(
        publishedAt: DateTime.utc(2026, 10, 2),
        symbolUploads: {SymbolTargets.sentry: DateTime.utc(2026, 10, 3)},
        play: PlayUpload(
            track: 'internal',
            uploadedAt: DateTime.utc(2026, 10, 2),
            viaApi: true,
            releaseStatus: 'completed'),
      );
      await ledger.add(r);

      final reopened = await Ledger.open(ledger.file.path);
      final back = reopened.records.single;
      expect(back.toJson(), r.toJson());
      expect(back.play!.viaApi, isTrue);
      expect(back.symbolUploads.keys, [SymbolTargets.sentry]);
      expect(back.versionCode, 1);
    });

    test('lists newest first', () async {
      await ledger.add(record('old', at: DateTime.utc(2026, 1, 1)));
      await ledger.add(record('new', at: DateTime.utc(2026, 6, 1)));
      expect(ledger.records.map((r) => r.id), ['new', 'old']);
    });

    test('rejects duplicate ids', () async {
      await ledger.add(record('a'));
      expect(() => ledger.add(record('a')), throwsA(isA<LedgerException>()));
    });

    test('remove deletes rows from the file', () async {
      await ledger.add(record('a'));
      await ledger.add(record('b'));
      final removed = await ledger.remove(['a']);
      expect(removed.single.id, 'a');

      final onDisk = jsonDecode(await ledger.file.readAsString()) as Map;
      expect((onDisk['builds'] as List).map((b) => (b as Map)['id']), ['b']);
    });

    test('update changes one row only', () async {
      await ledger.add(record('a'));
      await ledger.add(record('b'));
      await ledger.update(
          'a', (r) => r.copyWith(publishedAt: DateTime.utc(2026)));
      expect(ledger.byId('a')!.isPublished, isTrue);
      expect(ledger.byId('b')!.isPublished, isFalse);
    });

    test('keeps a .bak of the previous version and no stray .tmp', () async {
      await ledger.add(record('a'));
      await ledger.add(record('b'));
      expect(File('${ledger.file.path}.bak').existsSync(), isTrue);
      expect(File('${ledger.file.path}.tmp').existsSync(), isFalse);
    });

    test('reports corrupt JSON clearly', () async {
      await ledger.file.parent.create(recursive: true);
      await ledger.file.writeAsString('{not json');
      expect(Ledger.open(ledger.file.path), throwsA(isA<LedgerException>()));
    });

    test('refuses a newer schema', () async {
      await ledger.file.parent.create(recursive: true);
      await ledger.file.writeAsString('{"schemaVersion": 99, "builds": []}');
      expect(Ledger.open(ledger.file.path), throwsA(isA<LedgerException>()));
    });

    test('stores paths relative to the ledger folder', () {
      final abs = p.join(ledger.rootDir, 'app', 'x.aab');
      expect(ledger.relativize(abs), 'app/x.aab');
      expect(ledger.resolve('app/x.aab'), abs);
    });
  });

  group('LedgerExporter', () {
    const exporter = LedgerExporter();

    test('CSV has a header and one row per build', () {
      final lines =
          exporter.toCsv([record('a'), record('b')]).trimRight().split('\r\n');
      expect(lines, hasLength(3));
      expect(lines.first.split(',').length, LedgerExporter.columns.length);
    });

    test('CSV quotes commas, quotes and newlines', () {
      final r = record('a').copyWith(notes: 'fix, "bug"\nsecond line');
      final csv = exporter.toCsv([r]);
      expect(csv, contains('"fix, ""bug""\nsecond line"'));
    });

    test('TSV escapes tabs and newlines so each build stays on one line', () {
      final r = record('a').copyWith(notes: 'a\tb\nc');
      final lines = exporter.toTsv([r]).trimRight().split('\n');
      expect(lines, hasLength(2));
      expect(lines[1], contains(r'a\tb\nc'));
      expect(lines[1].split('\t').length, LedgerExporter.columns.length);
    });

    test('empty flavor and status columns are blank, not "null"', () {
      final row = exporter.row(record('a', flavor: null));
      expect(row, isNot(contains('null')));
      expect(row[LedgerExporter.columns.indexOf('flavor')], '');
      expect(row[LedgerExporter.columns.indexOf('published_at')], '');
    });

    test('JSON export round-trips', () {
      final json = jsonDecode(exporter.toJson([record('a')])) as List;
      expect(BuildRecord.fromJson((json.single as Map).cast()).id, 'a');
    });
  });

  group('BuildManager.delete', () {
    test('removes the folder, the row, and empty parent folders', () async {
      final dir =
          Directory(p.join(ledger.rootDir, 'my_app', 'dev', 'release', 'v1'));
      await dir.create(recursive: true);
      await File(p.join(dir.path, 'a.aab')).writeAsString('x');
      final r = record('a', outputDir: 'my_app/dev/release/v1');
      await ledger.add(r);

      final result = await BuildManager(ledger).delete([r]);

      expect(result.deleted, hasLength(1));
      expect(dir.existsSync(), isFalse);
      expect(Directory(p.join(ledger.rootDir, 'my_app')).existsSync(), isFalse);
      expect(Directory(ledger.rootDir).existsSync(), isTrue);
      expect(ledger.records, isEmpty);
    });

    test('keeps sibling builds and their parents', () async {
      for (final v in ['v1', 'v2']) {
        await Directory(p.join(ledger.rootDir, 'my_app', 'dev', 'release', v))
            .create(recursive: true);
      }
      final a = record('a', outputDir: 'my_app/dev/release/v1');
      final b = record('b', outputDir: 'my_app/dev/release/v2');
      await ledger.add(a);
      await ledger.add(b);

      await BuildManager(ledger).delete([a]);

      expect(
          Directory(p.join(ledger.rootDir, 'my_app', 'dev', 'release', 'v2'))
              .existsSync(),
          isTrue);
      expect(ledger.records.map((r) => r.id), ['b']);
    });

    test('still removes the row when the folder is already gone', () async {
      final r = record('a', outputDir: 'my_app/gone');
      await ledger.add(r);
      final result = await BuildManager(ledger).delete([r]);
      expect(result.deleted, hasLength(1));
      expect(ledger.records, isEmpty);
    });

    test('refuses to delete outside the ledger folder and keeps the row',
        () async {
      final outside = await Directory.systemTemp.createTemp('fbl_outside_');
      addTearDown(() => outside.delete(recursive: true));
      final r = record('evil', outputDir: '../../${p.basename(outside.path)}');
      await ledger.add(r);

      final result = await BuildManager(ledger).delete([r]);

      expect(result.deleted, isEmpty);
      expect(result.failed, hasLength(1));
      expect(outside.existsSync(), isTrue);
      expect(ledger.records, hasLength(1));
    });
  });
}
