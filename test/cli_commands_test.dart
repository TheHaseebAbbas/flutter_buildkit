import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:flutter_buildkit/flutter_buildkit.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'builder_test.dart' show FakeFlutter;

BuildRecord rec(String id,
        {String flavor = 'dev',
        DateTime? at,
        ArtifactType type = ArtifactType.aab}) =>
    BuildRecord(
      id: id,
      appName: 'demo',
      packageName: 'com.demo',
      flavor: flavor,
      mode: BuildMode.release,
      type: type,
      versionName: '1.0.0',
      versionCode: 1,
      createdAt: at ?? DateTime.now().toUtc(),
      outputDir: 'demo/$id',
      artifacts: const [
        BuildArtifact(path: 'demo/a.aab', sizeBytes: 10, sha256: 'x')
      ],
    );

ArgResults parse(List<String> args) {
  final parser = ArgParser()..addOption('ledger');
  addCommandOptions(parser);
  return parser.parse(args);
}

void main() {
  late Directory tmp;
  late Ledger ledger;
  late StringBuffer out;
  late StringBuffer err;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('fbk_cli_cmds_');
    File(p.join(tmp.path, 'pubspec.yaml'))
        .writeAsStringSync('name: demo\nversion: 1.2.0+5\n');
    ledger = await Ledger.open(p.join(tmp.path, 'app_builds', 'ledger.json'));
    out = StringBuffer();
    err = StringBuffer();
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<int> run(List<String> args, {Cli? cli}) {
    final parsed = parse(args);
    return (cli ?? Cli(ledger: ledger, out: out, err: err))
        .run(parsed.rest.first, parsed);
  }

  Future<void> makeBuildFolder(BuildRecord r) async {
    final dir = Directory(ledger.resolve(r.outputDir))
      ..createSync(recursive: true);
    File(p.join(dir.path, 'build_info.json'))
        .writeAsStringSync(jsonEncode({'id': r.id}));
  }

  group('list and export', () {
    setUp(() async {
      await ledger.add(rec('20261001-a', flavor: 'dev'));
      await ledger.add(rec('20261002-b',
          flavor: 'prod',
          at: DateTime.now().toUtc().add(const Duration(hours: 1))));
      await ledger.add(
          rec('20250101-old', flavor: 'dev', at: DateTime.utc(2025, 1, 1)));
    });

    test('--json prints the rows, newest first', () async {
      expect(await run(['list', '--json']), 0);
      final rows = jsonDecode('$out') as List;
      expect(rows.map((r) => (r as Map)['id']),
          ['20261002-b', '20261001-a', '20250101-old']);
    });

    test('filters by flavor, status, since and limit', () async {
      await run(['list', '--json', '--flavor', 'dev', '--since', '30d']);
      expect((jsonDecode('$out') as List).single['id'], '20261001-a');

      out.clear();
      await run(['list', '--json', '--limit', '1']);
      expect(jsonDecode('$out') as List, hasLength(1));

      out.clear();
      expect(await run(['list', '--json', '--status', 'failed']), 0);
      expect(jsonDecode('$out') as List, isEmpty);
    });

    test('a bad status is a usage error', () async {
      expect(await run(['list', '--status', 'nope']), 64);
    });

    test('export creates the parent folder', () async {
      final target = p.join(tmp.path, 'x', 'y', 'ledger.csv');
      expect(await run(['export', 'csv', target]), 0);
      expect(File(target).readAsStringSync(), startsWith('id,'));
    });
  });

  group('mark and delete', () {
    test('ids can be a prefix or "latest"; unknown ids exit 64', () async {
      await ledger.add(rec('20261001-aaaa'));
      expect(await run(['mark', '20261001']), 0);
      expect(ledger.byId('20261001-aaaa')!.isPublished, isTrue);
      expect(await run(['mark', 'latest', '--clear']), 0);
      expect(ledger.byId('20261001-aaaa')!.isPublished, isFalse);
      expect(await run(['mark', 'zzz']), 64);
      expect(await run(['mark']), 64);
    });

    test('delete needs --yes or --dry-run', () async {
      final r = rec('a');
      await ledger.add(r);
      await makeBuildFolder(r);

      expect(await run(['delete', 'a']), 64);
      expect(ledger.byId('a'), isNotNull);

      expect(await run(['delete', 'a', '--dry-run']), 0);
      expect(Directory(ledger.resolve(r.outputDir)).existsSync(), isTrue);
      expect('$out', contains('Would delete'));

      expect(await run(['delete', 'a', '--yes']), 0);
      expect(Directory(ledger.resolve(r.outputDir)).existsSync(), isFalse);
      expect(ledger.records, isEmpty);
    });

    test('delete reports refused builds with exit code 72', () async {
      await ledger.add(rec('a')); // no folder and no build_info.json: fine
      final bad = BuildRecord.fromJson(
          {...rec('b').toJson(), 'outputDir': '../../outside'});
      await ledger.add(bad);
      expect(await run(['delete', 'b', '--yes', '--json']), 72);
      expect(jsonDecode('$out')['failed'], contains('b'));
    });

    test('"latest" is not accepted for delete', () async {
      await ledger.add(rec('a'));
      expect(await run(['delete', 'latest', '--yes']), 0 + 64);
    });
  });

  group('publish', () {
    test('--mark-only records the upload without credentials', () async {
      await ledger.add(rec('a'));
      final config = AppConfig.fromYaml(tmp.path, const {});
      final cli = Cli(
          ledger: ledger,
          project: FlutterProject(tmp.path),
          config: config,
          out: out,
          err: err);
      expect(
          await run(['publish', 'a', '--mark-only', '--track', 'beta'],
              cli: cli),
          0);
      expect(ledger.byId('a')!.play!.track, 'beta');
    });

    test('production needs --yes; missing credentials exit 69', () async {
      await ledger.add(rec('a'));
      final config = AppConfig.fromYaml(tmp.path, const {});
      final cli = Cli(
          ledger: ledger,
          project: FlutterProject(tmp.path),
          config: config,
          out: out,
          err: err);
      expect(
          await run(['publish', 'a', '--track', 'production'], cli: cli), 64);
      expect(
          await run(['publish', 'a', '--track', 'production', '--yes'],
              cli: cli),
          69);
      expect(err.toString(), contains('No Play credentials'));
    });
  });

  group('build', () {
    Cli cliWith(FakeFlutter flutter) => Cli(
        ledger: ledger,
        project: FlutterProject(tmp.path),
        config: AppConfig.fromYaml(tmp.path, const {}),
        runner: flutter,
        out: out,
        err: err);

    test('builds, prints JSON and exits 0', () async {
      File(p.join(tmp.path, 'android/app/build.gradle'))
        ..createSync(recursive: true)
        ..writeAsStringSync('productFlavors { dev { } }');
      final code = await run([
        'build',
        '--flavor',
        'dev',
        '--type',
        'aab',
        '--json',
        '--skip-pre-build',
        '--version-name',
        '2.0.0',
        '--build-number',
        '9'
      ], cli: cliWith(FakeFlutter(tmp.path)));
      expect(code, 0, reason: '$err');
      final json = jsonDecode('$out') as Map;
      expect((json['built'] as List).single['versionName'], '2.0.0');
      expect(json['failed'], isEmpty);
      expect(ledger.records.single.versionCode, 9);
    });

    test('a failing build exits 70 and is recorded', () async {
      final code = await run(
          ['build', '--flavor', 'none', '--type', 'aab', '--skip-pre-build'],
          cli: cliWith(FakeFlutter(tmp.path, exitCode: 1)));
      expect(code, 70);
      expect(ledger.records.single.status, BuildStatus.failed);
      expect('$err', contains('FAILED'));
    });

    test('flavors are required when the project has them', () async {
      File(p.join(tmp.path, 'android/app/build.gradle'))
        ..createSync(recursive: true)
        ..writeAsStringSync('productFlavors { dev { } }');
      final code = await run(['build', '--skip-pre-build'],
          cli: cliWith(FakeFlutter(tmp.path)));
      expect(code, 64);
      expect('$err', contains('--flavor'));
    });
  });
}
