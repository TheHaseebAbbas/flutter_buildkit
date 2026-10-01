import 'dart:io';

import 'package:flutter_buildkit/flutter_buildkit.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'builder_test.dart' show FakeFlutter;

void main() {
  late Directory tmp;
  late FlutterProject project;

  void lib(String name) =>
      File(p.join(tmp.path, 'lib', name)).createSync(recursive: true);

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('fbk_entry_');
    File(p.join(tmp.path, 'pubspec.yaml'))
        .writeAsStringSync('name: demo\nversion: 1.2.0+5\n');
    project = FlutterProject(tmp.path);
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  group('entry point resolution', () {
    test('a plain project has one default entry point', () {
      lib('main.dart');
      final list =
          entryPointsFor(AppConfig.fromYaml(tmp.path, const {}), project, null);
      expect(list, [const EntryPoint(null, null)]);
    });

    test('extra lib/main_*.dart files are detected, flavor mains are not', () {
      lib('main.dart');
      lib('main_admin.dart');
      lib('main_kiosk.dart');
      final c = AppConfig.fromYaml(tmp.path, const {});
      expect(entryPointsFor(c, project, null), [
        const EntryPoint(null, null),
        const EntryPoint('admin', 'lib/main_admin.dart'),
        const EntryPoint('kiosk', 'lib/main_kiosk.dart'),
      ]);
    });

    test('configured entry points replace detection; {flavor} is filled in',
        () {
      lib('main_admin.dart');
      final c = AppConfig.fromYaml(tmp.path, const {
        'entry_points': {
          'main': 'lib/main_{flavor}.dart',
          'admin': 'lib/admin.dart',
        },
      });
      expect(entryPointsFor(c, project, 'dev'), [
        const EntryPoint(null, 'lib/main_dev.dart'),
        const EntryPoint('admin', 'lib/admin.dart'),
      ]);
      // Without a flavor, a path that needs one is left out.
      expect(entryPointsFor(c, project, null),
          [const EntryPoint('admin', 'lib/admin.dart')]);
    });

    test('a flavor list wins over the shared list', () {
      final c = AppConfig.fromYaml(tmp.path, const {
        'entry_points': {'main': 'lib/main.dart'},
        'flavors': {
          'dev': {
            'entry_points': {'kiosk': 'lib/kiosk_dev.dart'},
          },
        },
      });
      expect(entryPointsFor(c, project, 'dev'),
          [const EntryPoint('kiosk', 'lib/kiosk_dev.dart')]);
      expect(entryPointsFor(c, project, 'prod'),
          [const EntryPoint(null, 'lib/main.dart')]);
    });

    test('a flavor keeps its own main plus the detected extras', () {
      lib('main_dev.dart');
      lib('main_admin.dart');
      final c = AppConfig.fromYaml(tmp.path, const {});
      File(p.join(tmp.path, 'android', 'app', 'build.gradle'))
        ..createSync(recursive: true)
        ..writeAsStringSync('productFlavors { dev { } }');
      expect(entryPointsFor(c, project, 'dev'), [
        const EntryPoint(null, 'lib/main_dev.dart'),
        const EntryPoint('admin', 'lib/main_admin.dart'),
      ]);
    });

    test('bad entry point config is rejected', () {
      for (final bad in [
        {'1x': 'lib/a.dart'},
        {'a b': 'lib/a.dart'},
        {'ok': ''},
        'lib/main.dart',
      ]) {
        expect(() => AppConfig.fromYaml(tmp.path, {'entry_points': bad}),
            throwsA(isA<ConfigException>()),
            reason: '$bad');
      }
    });
  });

  group('names', () {
    final time = DateTime(2026, 10, 1, 7, 5, 9);
    BuildNaming naming({String? entry, String? flavor = 'dev'}) => BuildNaming(
        appName: 'my_app',
        flavor: flavor,
        mode: BuildMode.release,
        versionName: '1.2.0',
        versionCode: 42,
        time: time,
        type: ArtifactType.aab,
        entry: entry);

    test('the default entry point keeps the plain names', () {
      final paths = BuildPaths('/out');
      expect(paths.artifactFileName(naming()),
          'my_app-dev-release-1.2.0-b42-20261001-070509.aab');
    });

    test('a named entry point is appended to file and folder', () {
      final paths = BuildPaths('/out');
      expect(paths.artifactFileName(naming(entry: 'admin')),
          'my_app-dev-release-1.2.0-b42-20261001-070509-admin.aab');
      expect(p.basename(paths.buildDir(naming(entry: 'admin'))),
          '1.2.0-b42-20261001-070509-admin');
    });

    test('{entry} puts the name where you want it', () {
      final paths =
          BuildPaths('/out', fileName: '{app}-{entry}-{flavor}-{version}');
      expect(paths.artifactFileName(naming(entry: 'admin')),
          'my_app-admin-dev-1.2.0-b42.aab');
      expect(paths.artifactFileName(naming()), 'my_app-dev-1.2.0-b42.aab');
    });
  });

  test('a build records its entry point and is named after it', () async {
    final config = AppConfig.fromYaml(tmp.path, const {});
    final ledger = await Ledger.open(config.ledgerPath);
    final builder = FlutterBuilder(
        project: project,
        config: config,
        ledger: ledger,
        runner: FakeFlutter(tmp.path));
    final record = await builder.build(const BuildRequest(
      type: ArtifactType.aab,
      mode: BuildMode.release,
      flavor: 'dev',
      versionName: '1.2.0',
      versionCode: 5,
      target: 'lib/main_admin.dart',
      entryPoint: 'admin',
    ));
    expect(record.entryPoint, 'admin');
    expect(record.target, 'lib/main_admin.dart');
    expect(record.artifacts.single.path, endsWith('-admin.aab'));
    expect(record.outputDir, endsWith('-admin'));
    final back = BuildRecord.fromJson(record.toJson());
    expect(back.entryPoint, 'admin');
    expect(
        const LedgerExporter()
            .export([record], ExportFormat.csv)
            .split('\r\n')
            .first,
        contains('entry_point'));
  });

  test('settings screen adds and removes an entry point', () async {
    final out = StringBuffer();
    final lines = [
      '26', // Entry points (all flavors); rows: 25 settings + this one
      '1', // Add an entry point...
      'admin',
      'lib/main_admin.dart',
      'y',
      '0', // back
      '30', // Save and reload
      'y',
    ];
    final screen = SettingsScreen(
        console: Console(
            mode: UiMode.plain,
            readLine: () => lines.isEmpty ? null : lines.removeAt(0),
            write: out.write),
        project: project,
        env: const {});
    final saved = await screen.run();
    expect(saved, isNotNull);
    final c = AppConfig.load(tmp.path, env: const {});
    expect(c.entryPoints, {'admin': 'lib/main_admin.dart'});
    expect(out.toString(), contains('builds lib/main_admin.dart as "admin"'));
  });
}
