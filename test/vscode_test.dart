import 'dart:io';

import 'package:flutter_buildkit/flutter_buildkit.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// A trimmed copy of a real launch.json: comments, flavors whose config file
/// is spelled differently (preprod / pre_prod.json), multi-line args and a
/// legacy entry point.
const sample = r'''
{
  "version": "0.2.0",
  "configurations": [
    {
      "name": "DEV - DEBUG",
      "request": "launch",
      "type": "dart",
      "flutterMode": "debug",
      "args": ["--flavor", "dev", "--dart-define-from-file=configs/dev.json"]
    },

    {
      "name": "PRE PROD - DEBUG",
      "request": "launch",
      "type": "dart",
      "flutterMode": "debug",
      "args": [
        "--flavor",
        "preprod",
        "--dart-define-from-file=configs/pre_prod.json"
      ]
    },
    {
      "name": "CLIENT DB - RELEASE",
      "request": "launch",
      "type": "dart",
      "flutterMode": "release",
      "args": [
        "--flavor",
        "clientDb",
        "--dart-define-from-file=configs/client_db.json"
      ]
    },

    // Pre-rewrite app. Every other configuration above omits "program" and so
    // defaults to lib/main.dart; these name the legacy entry point instead.
    {
      "name": "LEGACY DEV - DEBUG",
      "request": "launch",
      "type": "dart",
      "program": "lib/main_legacy.dart",
      "flutterMode": "debug",
      "args": ["--flavor", "dev", "--dart-define-from-file=configs/dev.json"]
    }
  ]
}
''';

void main() {
  late Directory tmp;
  late FlutterProject project;

  void write(String rel, String content) {
    File(p.join(tmp.path, rel))
      ..createSync(recursive: true)
      ..writeAsStringSync(content);
  }

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('fbk_vscode_');
    write('pubspec.yaml', 'name: demo\nversion: 1.0.0+1\n');
    project = FlutterProject(tmp.path);
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  group('jsonc', () {
    test('comments and trailing commas are read', () {
      expect(
          decodeJsonc(
              '{"a": [1, 2,], // c\n"b": "x // not a comment" /* y */}'),
          {
            'a': [1, 2],
            'b': 'x // not a comment',
          });
    });

    test('findArray ignores the key inside strings and comments', () {
      const t = '{ // "configurations": [\n"x": "\\"configurations\\": [",'
          ' "configurations": [1, [2]] }';
      final (open, close) = findArray(t, 'configurations')!;
      expect(t.substring(open, close + 1), '[1, [2]]');
    });
  });

  group('launch.json parsing', () {
    test('reads flavor, define file, mode and program', () {
      final c = parseLaunchConfigs(sample);
      expect(c.map((e) => e.name), [
        'DEV - DEBUG',
        'PRE PROD - DEBUG',
        'CLIENT DB - RELEASE',
        'LEGACY DEV - DEBUG'
      ]);
      expect(c[1].flavor, 'preprod');
      expect(c[1].dartDefineFile, 'configs/pre_prod.json');
      expect(c[2].mode, 'release');
      expect(c[0].program, isNull);
      expect(c[3].program, 'lib/main_legacy.dart');
    });
  });

  group('entry points anywhere', () {
    test('finds main files in any folder and names them', () {
      write('lib/main.dart', 'void main() {}');
      write('lib/flavors/main_dev.dart', 'Future<void> main() async {}');
      write('lib/admin/main.dart', 'void main() => runApp(A());');
      write('lib/legacy/legacy_main.dart', 'void main() {}');
      write('lib/util.dart', 'void helper() {}');
      write('lib/app.g.dart', 'void main() {}');
      write('test/main_test.dart', 'void main() {}');
      write('tool/main_tool.dart', 'void main() {}');
      write('android/main_x.dart', 'void main() {}');
      write('.dart_tool/main_y.dart', 'void main() {}');
      write('apps/kiosk/main_kiosk.dart', 'void main() {}');
      write('apps/not_main_named.dart', 'void main() {}');
      final found = {for (final e in scanDartEntries(tmp.path)) e.path: e.name};
      expect(found, {
        'lib/main.dart': null,
        'lib/flavors/main_dev.dart': 'dev',
        'lib/admin/main.dart': 'admin',
        'lib/legacy/legacy_main.dart': 'legacy',
        'apps/kiosk/main_kiosk.dart': 'kiosk',
      });
    });

    test('same names in different folders are told apart', () {
      write('lib/a/main_x.dart', 'void main() {}');
      write('lib/b/main_x.dart', 'void main() {}');
      final names = scanDartEntries(tmp.path).map((e) => e.name).toSet();
      expect(names, {'a_x', 'b_x'});
    });

    test('a launch.json program is an entry even if it is not named main', () {
      write('lib/boot/start.dart', 'void main() {}');
      final names = {
        for (final e
            in scanDartEntries(tmp.path, extra: ['lib/boot/start.dart']))
          e.path: e.name
      };
      expect(names['lib/boot/start.dart'], 'start');
    });

    test('a flavor finds its main loosely: clientDb ~ main_client_db.dart', () {
      write('lib/main.dart', 'void main() {}');
      write('lib/entry/main_client_db.dart', 'void main() {}');
      write('android/app/build.gradle',
          'android { productFlavors { clientDb { } } }');
      expect(
          project.defaultTarget('clientDb'), 'lib/entry/main_client_db.dart');
      // And it is not offered as an extra entry point.
      expect(detectEntryPoints(project, project.flavors), isEmpty);
    });
  });

  group('flavors and define files', () {
    test('launch.json supplies flavors, define files and entry points', () {
      write('.vscode/launch.json', sample);
      for (final f in ['dev', 'pre_prod', 'client_db']) {
        write('configs/$f.json', '{}');
      }
      write('lib/main.dart', 'void main() {}');
      write('lib/main_legacy.dart', 'void main() {}');
      expect(project.flavors, ['clientDb', 'dev', 'preprod']);
      expect(project.defineFileFor('preprod'), 'configs/pre_prod.json');
      expect(project.defineFileFor('clientDb'), 'configs/client_db.json');
      expect(project.defineFileFor('dev'), 'configs/dev.json');
      expect(detectEntryPoints(project, project.flavors),
          {'legacy': 'lib/main_legacy.dart'});
    });

    test('define files are matched by name without launch.json', () {
      write('env/pre-prod.json', '{}');
      write('env_dev.json', '{}');
      write('config/QA.json', '{}');
      write('config/notes.json', '{}');
      expect(project.defineFileFor('preprod'), 'env/pre-prod.json');
      expect(project.defineFileFor('dev'), 'env_dev.json');
      expect(project.defineFileFor('qa'), 'config/QA.json');
      expect(project.defineFileFor('uat'), isNull);
    });

    test('flavors from flutter_flavorizr count too', () {
      write('pubspec.yaml',
          'name: demo\nflavorizr:\n  flavors:\n    dev: {}\n    prod: {}\n');
      expect(project.flavors, ['dev', 'prod']);
    });

    test('names that differ only in case or punctuation count once', () {
      write('android/app/build.gradle',
          'android { productFlavors { preprod { } } }');
      write('.vscode/launch.json', sample);
      expect(project.flavors.where((f) => normalizeName(f) == 'preprod'),
          ['preprod']);
    });
  });

  group('generating launch configurations', () {
    test('names, args and program follow the project', () {
      write('android/app/build.gradle',
          'android { productFlavors { dev { } clientDb { } } }');
      write('configs/dev.json', '{}');
      write('configs/client_db.json', '{}');
      write('lib/main.dart', 'void main() {}');
      write('lib/main_dev.dart', 'void main() {}');
      final config = AppConfig.fromYaml(tmp.path, const {});
      final entries = launchEntriesFor(config, project);
      expect(entries, hasLength(6));
      final dev = entries.firstWhere((e) => e.name == 'DEV - PROFILE');
      expect(dev.program, 'lib/main_dev.dart');
      expect(dev.args,
          ['--flavor', 'dev', '--dart-define-from-file=configs/dev.json']);
      final db = entries.firstWhere((e) => e.name == 'CLIENT DB - RELEASE');
      expect(db.program, isNull); // lib/main.dart is the default
      expect(db.args.last, '--dart-define-from-file=configs/client_db.json');
    });

    test('extra entry points get their own names', () {
      write('lib/main.dart', 'void main() {}');
      write('lib/main_admin.dart', 'void main() {}');
      final config = AppConfig.fromYaml(tmp.path, const {});
      final names = launchEntriesFor(config, project).map((e) => e.name);
      expect(names, contains('DEMO - DEBUG'));
      expect(names, contains('DEMO ADMIN - RELEASE'));
    });
  });

  group('merging into an existing launch.json', () {
    setUp(() {
      write('.vscode/launch.json', sample);
      for (final f in ['dev', 'pre_prod', 'client_db']) {
        write('configs/$f.json', '{}');
      }
      write('lib/main.dart', 'void main() {}');
      write('lib/main_legacy.dart', 'void main() {}');
    });

    test('keeps what is there and adds only what is missing', () {
      final config = AppConfig.fromYaml(tmp.path, const {});
      final plan = planLaunchJson(config, project);
      final have = parseLaunchConfigs(sample);
      // Same flavor, mode, program and file under a different name: skipped.
      expect(
          plan.skipped.map((e) => e.asConfig.identity),
          containsAll([
            have[0].identity,
            have[1].identity,
            have[2].identity,
            have[3].identity
          ]));
      expect(plan.add, isNotEmpty);
      final merged = mergeLaunchJson(plan.existing, plan.add);

      // Everything old is still there, comments included.
      expect(merged,
          startsWith(sample.substring(0, sample.indexOf('    }\n  ]'))));
      expect(merged, contains('// Pre-rewrite app.'));
      final all = parseLaunchConfigs(merged);
      expect(all.length, have.length + plan.add.length);
      expect(all.map((c) => c.name), containsAll(have.map((c) => c.name)));
      expect(all.map((c) => c.name).toSet().length, all.length,
          reason: 'no duplicate names');

      // A second run has nothing left to add.
      write('.vscode/launch.json', merged);
      expect(planLaunchJson(config, project).add, isEmpty);
    });

    test('a trailing comma and an empty array are handled', () {
      final e = [
        const LaunchEntry(name: 'X - DEBUG', mode: 'debug', flavor: 'x')
      ];
      var out = mergeLaunchJson(
          '{"configurations": [\n    {"type": "dart", "name": "a"},\n  ]}', e);
      expect(parseLaunchConfigs(out).map((c) => c.name), ['a', 'X - DEBUG']);
      out = mergeLaunchJson('{"configurations": []}', e);
      expect(parseLaunchConfigs(out).map((c) => c.name), ['X - DEBUG']);
      out = mergeLaunchJson(
          '{"version": "0.2.0", "configurations": [ // none\n ]}', e);
      expect(parseLaunchConfigs(out).map((c) => c.name), ['X - DEBUG']);
    });

    test('invalid or unusable files are never touched', () {
      write('.vscode/launch.json', '{ "configurations": [ ');
      expect(
          () => planLaunchJson(AppConfig.fromYaml(tmp.path, const {}), project),
          throwsA(isA<LaunchJsonException>()));
      expect(
          () => mergeLaunchJson('{"version": "0.2.0"}',
              [const LaunchEntry(name: 'a', mode: 'debug')]),
          throwsA(isA<LaunchJsonException>()));
    });

    test('windows line endings are kept', () {
      final out = mergeLaunchJson(
          '{\r\n  "configurations": [\r\n    {"type": "dart", "name": "a"}\r\n  ]\r\n}\r\n',
          [const LaunchEntry(name: 'b', mode: 'debug')]);
      expect(out.replaceAll('\r\n', ''), isNot(contains('\n')));
      expect(parseLaunchConfigs(out), hasLength(2));
    });
  });

  test('a new launch.json is created and the old one backed up', () async {
    write('android/app/build.gradle', 'android { productFlavors { dev { } } }');
    write('lib/main.dart', 'void main() {}');
    final config = AppConfig.fromYaml(tmp.path, const {});
    final plan = planLaunchJson(config, project);
    expect(plan.existing, isNull);
    writeLaunchJson(project, mergeLaunchJson(plan.existing, plan.add));
    final f = File(p.join(tmp.path, '.vscode', 'launch.json'));
    expect(parseLaunchConfigs(f.readAsStringSync()).map((c) => c.name),
        ['DEV - DEBUG', 'DEV - PROFILE', 'DEV - RELEASE']);
    expect(File('${f.path}.bak').existsSync(), isFalse);
    writeLaunchJson(project, '{"configurations": []}');
    expect(File('${f.path}.bak').existsSync(), isTrue);
  });

  test('the launch.json step runs from the console', () async {
    write('android/app/build.gradle', 'android { productFlavors { dev { } } }');
    write('lib/main.dart', 'void main() {}');
    final lines = ['', 'y'];
    final out = StringBuffer();
    final ok = await runLaunchJsonFlow(
        Console(
            mode: UiMode.plain,
            readLine: () => lines.isEmpty ? null : lines.removeAt(0),
            write: out.write),
        project,
        AppConfig.fromYaml(tmp.path, const {}));
    expect(ok, isTrue);
    expect(out.toString(), contains('will be created'));
    expect(
        File(p.join(tmp.path, '.vscode', 'launch.json')).existsSync(), isTrue);
  });
}
