import 'dart:convert';
import 'dart:io';

import 'package:flutter_buildkit/flutter_buildkit.dart';
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
  ledgerLockTests();
  ledgerFixtureTests();
  late Directory tmp;
  late Ledger ledger;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('fbl_ledger_');
    ledger = await Ledger.open(p.join(tmp.path, 'app_builds', 'ledger.json'));
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
      final lines = exporter.toTsv([r]).split('\n');
      expect(lines.removeLast(), isEmpty);
      expect(lines, hasLength(2));
      expect(lines[1], contains(r'a\tb\nc'));
      expect(lines[1].split('\t').length, LedgerExporter.columns.length);
    });

    test('cells that start like a formula are kept as text in CSV and TSV', () {
      for (final text in ['=1+1', '+SUM(A1)', '-2', '@cmd', '\tx']) {
        final r = record('a').copyWith(notes: text);
        final notes = LedgerExporter.columns.indexOf('notes');
        expect(exporter.row(r)[notes], text, reason: 'row() is unchanged');
        expect(exporter.toCsv([r]), contains("'$text"));
        expect(exporter.toTsv([r]), contains("'"));
      }
      expect(exporter.toJson([record('a').copyWith(notes: '=1+1')]),
          contains('"=1+1"'));
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
    Future<Directory> makeBuild(String id, String rel) async {
      final dir = Directory(p.join(ledger.rootDir, rel));
      await Directory(p.join(dir.path, 'symbols', 'dart'))
          .create(recursive: true);
      await File(p.join(dir.path, 'a.aab')).writeAsString('x');
      await File(p.join(dir.path, 'build_info.json'))
          .writeAsString(jsonEncode({'id': id}));
      await File(p.join(dir.path, 'symbols', 'dart', 'app.symbols'))
          .writeAsString('sym');
      return dir;
    }

    test('unreleased: removes folder, symbols, row and empty parents',
        () async {
      final dir = await makeBuild('a', 'my_app/dev/release/v1');
      final r = record('a', outputDir: 'my_app/dev/release/v1');
      await ledger.add(r);

      final result = await BuildManager(ledger).delete([r]);

      expect(result.deleted, hasLength(1));
      expect(dir.existsSync(), isFalse);
      expect(Directory(p.join(ledger.rootDir, 'my_app')).existsSync(), isFalse);
      expect(Directory(ledger.rootDir).existsSync(), isTrue);
      expect(ledger.records, isEmpty);
    });

    group('refuses unsafe paths', () {
      Future<DeleteResult> run(BuildRecord r, {bool dryRun = false}) =>
          BuildManager(ledger).delete([r], dryRun: dryRun);

      test('a folder outside the ledger root', () async {
        final outside = Directory(p.join(tmp.path, 'elsewhere'))..createSync();
        File(p.join(outside.path, 'keep.txt')).writeAsStringSync('x');
        final r = record('a', outputDir: '../../elsewhere');
        await ledger.add(r);

        final result = await run(r);

        expect(result.failed, hasLength(1));
        expect(File(p.join(outside.path, 'keep.txt')).existsSync(), isTrue);
        expect(ledger.byId('a'), isNotNull);
      });

      test('the ledger root itself, as "." or empty', () async {
        Directory(ledger.rootDir).createSync(recursive: true);
        File(p.join(ledger.rootDir, 'keep.txt')).writeAsStringSync('x');
        for (final dir in ['.', '', './']) {
          final r = record('a', outputDir: dir);
          await ledger.add(r);
          final result = await run(r);
          expect(result.failed, hasLength(1), reason: 'outputDir "$dir"');
          await ledger.remove(['a']);
        }
        expect(File(p.join(ledger.rootDir, 'keep.txt')).existsSync(), isTrue);
      });

      test('a symlink that leads out of the root', () async {
        final outside = Directory(p.join(tmp.path, 'precious'))..createSync();
        File(p.join(outside.path, 'build_info.json'))
            .writeAsStringSync(jsonEncode({'id': 'a'}));
        File(p.join(outside.path, 'keep.txt')).writeAsStringSync('x');
        Link(p.join(ledger.rootDir, 'link'))
            .createSync(outside.path, recursive: true);
        final r = record('a', outputDir: 'link');
        await ledger.add(r);

        final result = await run(r);

        expect(result.failed, hasLength(1));
        expect(File(p.join(outside.path, 'keep.txt')).existsSync(), isTrue);
        expect(ledger.byId('a'), isNotNull);
      }, skip: Platform.isWindows ? 'symlinks need admin rights' : null);

      test('a folder without build_info.json', () async {
        final dir = Directory(p.join(ledger.rootDir, 'notes'))
          ..createSync(recursive: true);
        File(p.join(dir.path, 'todo.txt')).writeAsStringSync('x');
        final r = record('a', outputDir: 'notes');
        await ledger.add(r);

        final result = await run(r);

        expect(result.failed, hasLength(1));
        expect(File(p.join(dir.path, 'todo.txt')).existsSync(), isTrue);
      });

      test('a build_info.json that belongs to another build', () async {
        final dir = await makeBuild('other', 'my_app/v1');
        final r = record('a', outputDir: 'my_app/v1');
        await ledger.add(r);

        final result = await run(r);

        expect(result.failed, hasLength(1));
        expect(dir.existsSync(), isTrue);
      });

      test('a folder that contains another build', () async {
        await makeBuild('a', 'my_app');
        await makeBuild('b', 'my_app/v2');
        final a = record('a', outputDir: 'my_app');
        await ledger.add(a);
        await ledger.add(record('b', outputDir: 'my_app/v2'));

        final result = await run(a);

        expect(result.failed, hasLength(1));
        expect(Directory(p.join(ledger.rootDir, 'my_app', 'v2')).existsSync(),
            isTrue);
      });

      test('a released build whose artifact path leaves the root', () async {
        await makeBuild('a', 'my_app/v1');
        final outsideFile = File(p.join(tmp.path, 'outside.aab'))
          ..writeAsStringSync('x');
        final r = BuildRecord.fromJson({
          ...record('a', outputDir: 'my_app/v1').toJson(),
          'artifacts': [
            {'path': '../../outside.aab', 'sizeBytes': 1, 'sha256': 'x'}
          ],
        }).copyWith(publishedAt: DateTime.utc(2026, 10, 2));
        await ledger.add(r);

        final result = await run(r);

        expect(result.failed, hasLength(1));
        expect(outsideFile.existsSync(), isTrue);
      });

      test('--dry-run changes nothing', () async {
        final dir = await makeBuild('a', 'my_app/v1');
        final r = record('a', outputDir: 'my_app/v1');
        await ledger.add(r);

        final result = await run(r, dryRun: true);

        expect(result.dryRun, isTrue);
        expect(result.deleted, hasLength(1));
        expect(dir.existsSync(), isTrue);
        expect(ledger.byId('a'), isNotNull);
      });
    });

    test('keeps sibling builds and their parents', () async {
      await makeBuild('a', 'my_app/dev/release/v1');
      await makeBuild('b', 'my_app/dev/release/v2');
      final a = record('a', outputDir: 'my_app/dev/release/v1');
      await ledger.add(a);
      await ledger.add(record('b', outputDir: 'my_app/dev/release/v2'));

      await BuildManager(ledger).delete([a]);

      expect(
          Directory(p.join(ledger.rootDir, 'my_app', 'dev', 'release', 'v2'))
              .existsSync(),
          isTrue);
      expect(ledger.records.map((r) => r.id), ['b']);
    });

    test('published AAB: files go, symbols and ledger row stay', () async {
      final dir = await makeBuild('a', 'my_app/dev/release/v1');
      await File(p.join(ledger.rootDir, 'app', 'dev', 'a.aab'))
          .create(recursive: true);
      final r = record('a', outputDir: 'my_app/dev/release/v1')
          .copyWith(publishedAt: DateTime.utc(2026, 10, 2));
      // The artifact path in the helper record is app/dev/a.aab.
      await ledger.add(r);

      final result = await BuildManager(ledger).delete([r]);

      expect(result.filesOnly, hasLength(1));
      expect(result.deleted, isEmpty);
      expect(File(p.join(ledger.rootDir, 'app', 'dev', 'a.aab')).existsSync(),
          isFalse);
      expect(
          File(p.join(dir.path, 'symbols', 'dart', 'app.symbols')).existsSync(),
          isTrue);
      final kept = ledger.byId('a')!;
      expect(kept.artifactsDeleted, isTrue);
      expect(kept.isPublished, isTrue);
    });

    PlayUpload upload(String track) =>
        PlayUpload(track: track, uploadedAt: DateTime.utc(2026), viaApi: false);

    test('an upload to a closed or production track keeps symbols and row',
        () async {
      await makeBuild('a', 'my_app/dev/release/v1');
      final r = record('a', outputDir: 'my_app/dev/release/v1')
          .copyWith(play: upload('beta'));
      await ledger.add(r);
      final result = await BuildManager(ledger).delete([r]);
      expect(result.filesOnly, hasLength(1));
      expect(ledger.byId('a'), isNotNull);
    });

    test('an internal-track upload does not keep a build by default', () async {
      await makeBuild('a', 'my_app/dev/release/v1');
      final r = record('a', outputDir: 'my_app/dev/release/v1')
          .copyWith(play: upload('internal'));
      await ledger.add(r);
      final result = await BuildManager(ledger).delete([r]);
      expect(result.deleted, hasLength(1));
      expect(ledger.byId('a'), isNull);
    });

    test('retain_on can bring the old behavior back', () async {
      await makeBuild('a', 'my_app/dev/release/v1');
      final r = record('a', outputDir: 'my_app/dev/release/v1')
          .copyWith(play: upload('internal'));
      await ledger.add(r);
      final result = await BuildManager(ledger, retainOn: {'play'}).delete([r]);
      expect(result.filesOnly, hasLength(1));
    });

    test('a build published once is still known after the mark is cleared', () {
      final r = record('a', outputDir: 'x')
          .copyWith(publishedAt: DateTime.utc(2026))
          .copyWith(clearPublished: true);
      expect(r.isPublished, isFalse);
      expect(r.everPublished, isTrue);
    });

    test('deleting a released build twice is a no-op', () async {
      await makeBuild('a', 'my_app/dev/release/v1');
      final r = record('a', outputDir: 'my_app/dev/release/v1')
          .copyWith(publishedAt: DateTime.utc(2026));
      await ledger.add(r);
      final manager = BuildManager(ledger);
      await manager.delete([r]);
      final again = await manager.delete([ledger.byId('a')!]);
      expect(again.filesOnly, isEmpty);
      expect(again.deleted, isEmpty);
    });

    test('artifactsDeletedAt survives a reload', () async {
      await makeBuild('a', 'my_app/dev/release/v1');
      final r = record('a', outputDir: 'my_app/dev/release/v1')
          .copyWith(publishedAt: DateTime.utc(2026));
      await ledger.add(r);
      await BuildManager(ledger).delete([r]);
      final reopened = await Ledger.open(ledger.file.path);
      expect(reopened.byId('a')!.artifactsDeleted, isTrue);
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

void ledgerLockTests() {
  late Directory tmp;
  late String path;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('fbk_lock_');
    path = p.join(tmp.path, 'out', 'ledger.json');
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  group('Ledger with several writers', () {
    test('a second instance does not overwrite the first one\'s rows',
        () async {
      final a = await Ledger.open(path);
      final b = await Ledger.open(path);
      await a.add(record('a'));
      await b.add(record('b')); // b never saw "a" in memory

      final reopened = await Ledger.open(path);
      expect(reopened.records.map((r) => r.id).toSet(), {'a', 'b'});
      expect(b.records, hasLength(2));
    });

    test('update works on the row as it is on disk', () async {
      final a = await Ledger.open(path);
      final b = await Ledger.open(path);
      await a.add(record('a'));
      await a.update(
          'a', (r) => r.copyWith(publishedAt: DateTime.utc(2026, 10, 2)));
      final updated = await b.update('a', (r) => r.copyWith(notes: 'n'));
      expect(updated.isPublished, isTrue);
      expect(updated.notes, 'n');
    });

    test('many concurrent adds all land', () async {
      final ledgers = [for (var i = 0; i < 4; i++) await Ledger.open(path)];
      await Future.wait([
        for (var i = 0; i < 20; i++) ledgers[i % 4].add(record('b$i')),
      ]);
      expect((await Ledger.open(path)).records, hasLength(20));
    });

    test('a held lock gives a clear error; a stale one is replaced', () async {
      final a = Ledger(File(path), lockWait: const Duration(milliseconds: 200));
      await a.reload();
      await a.add(record('a'));
      final lock = File('$path.lock')..writeAsStringSync('pid 1\n');
      await expectLater(
          a.add(record('b')),
          throwsA(isA<LedgerException>()
              .having((e) => e.message, 'message', contains('pid 1'))));
      expect(lock.existsSync(), isTrue, reason: 'not ours to delete');

      lock.setLastModifiedSync(DateTime.now()
          .subtract(Ledger.lockStale + const Duration(minutes: 1)));
      await a.add(record('c'));
      expect(lock.existsSync(), isFalse);
      expect((await Ledger.open(path)).records, hasLength(2));
    });

    test('a bad ledger file blocks a write instead of being replaced',
        () async {
      final a = await Ledger.open(path);
      await a.add(record('a'));
      File(path).writeAsStringSync('{ not json');
      await expectLater(a.add(record('b')), throwsA(isA<LedgerException>()));
      expect(File(path).readAsStringSync(), '{ not json');
    });

    test('the first save of a day keeps a snapshot; only 7 days are kept',
        () async {
      final a = await Ledger.open(path);
      await a.add(record('a'));
      final history = Directory(p.join(p.dirname(path), '.history'));
      expect(history.existsSync(), isFalse, reason: 'nothing to keep yet');
      await a.add(record('b'));
      final files = history.listSync().map((f) => p.basename(f.path)).toList();
      expect(files, hasLength(1));
      expect(files.single, matches(RegExp(r'^ledger-\d{8}\.json$')));
      // The snapshot is the ledger as it was before today's first change.
      final snap = jsonDecode(
          File(p.join(history.path, files.single)).readAsStringSync()) as Map;
      expect((snap['builds'] as List), hasLength(1));

      for (var d = 1; d <= 9; d++) {
        File(p.join(history.path, 'ledger-2020010$d.json'))
            .writeAsStringSync('{}');
      }
      File(p.join(history.path, 'ledger-20200110.json'))
          .writeAsStringSync('{}');
      await a.add(record('c')); // same day: no new snapshot, no pruning
      expect(history.listSync().length, 11);
      File(p.join(history.path, files.single)).deleteSync();
      await a.add(record('d')); // new snapshot triggers pruning
      expect(history.listSync().length, Ledger.historyDays);
    });
  });
}

void ledgerFixtureTests() {
  test('a ledger written by 0.1.2 still loads, saves and exports', () async {
    final tmp = Directory.systemTemp.createTempSync('fbk_fixture_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final path = p.join(tmp.path, 'ledger.json');
    File('test/fixtures/ledger_0_1_2.json').copySync(path);

    final ledger = await Ledger.open(path);

    expect(ledger.records, hasLength(2));
    final published = ledger.byId('20261001-071230-a1b2')!;
    expect(published.status, BuildStatus.published);
    expect(published.play!.editId, 'e1');
    expect(published.isFailed, isFalse);
    expect(published.command, isNull);
    final old = ledger.byId('20260920-100000-0000')!;
    expect(old.artifacts, isEmpty);
    expect(old.events.single.kind, 'built');

    await ledger.update(old.id, (r) => r.copyWith(notes: 'n'));
    expect((await Ledger.open(path)).records, hasLength(2));
    expect(const LedgerExporter().toCsv(ledger.records), contains('a1b2'));
  });
}
