import 'dart:io';

import 'package:flutter_buildkit/flutter_buildkit.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('ConfigEditor', () {
    test('changes a value in place and keeps comments', () {
      final e = ConfigEditor(
              '# top\nobfuscate: true   # keep\nsplit_per_abi: false\n')
          .set(['obfuscate'], false);
      expect(
          e.text, '# top\nobfuscate: false   # keep\nsplit_per_abi: false\n');
    });

    test('adds a missing top level key', () {
      final e = ConfigEditor('obfuscate: true\n').set(['output_dir'], 'out');
      expect(e.text, 'obfuscate: true\noutput_dir: out\n');
    });

    test('adds a nested key to an existing block and creates a new block', () {
      var e = ConfigEditor(
              'play:\n  default_track: internal\n\nsentry:\n  cli: x\n')
          .set(['play', 'upload_mapping'], false);
      expect(e.text,
          'play:\n  default_track: internal\n  upload_mapping: false\n\nsentry:\n  cli: x\n');
      e = e.set(['pre_build', 'clean'], true);
      expect(e.raw(['pre_build', 'clean']), true);
      expect(e.raw(['play', 'upload_mapping']), false);
    });

    test('fills an empty block that only has comments and a flavors: {}', () {
      var e = ConfigEditor('flavors:\n  # dev:\n\nplay:\n  x: 1\n')
          .set(['flavors', 'dev', 'target'], 'lib/main_dev.dart');
      expect(e.raw(['flavors', 'dev', 'target']), 'lib/main_dev.dart');
      expect(e.raw(['play', 'x']), 1);
      e = ConfigEditor('flavors: {}\n')
          .set(['flavors', 'dev', 'target'], 'lib/main_dev.dart');
      expect(e.raw(['flavors', 'dev', 'target']), 'lib/main_dev.dart');
    });

    test('removes a key and its nested lines', () {
      final e = ConfigEditor('a: 1\nflavors:\n  dev:\n    target: x\nb: 2\n')
          .set(['flavors'], null);
      expect(e.text, 'a: 1\nb: 2\n');
    });

    test('lists and awkward strings round-trip', () {
      var e = ConfigEditor('');
      e = e.set(['extra_build_args'], ['--no-tree-shake-icons', '--x=a b']);
      e = e.set(['file_name'], '{app}-{versionName}');
      e = e.set(['flavors', 'dev', 'firebase_app_id'], '1:123:android:abc');
      e = e.set(['sentry', 'org'], 'true');
      expect(e.raw(['extra_build_args']), ['--no-tree-shake-icons', '--x=a b']);
      expect(e.raw(['file_name']), '{app}-{versionName}');
      expect(e.raw(['flavors', 'dev', 'firebase_app_id']), '1:123:android:abc');
      expect(e.raw(['sentry', 'org']), 'true');
      expect(e.raw(['sentry', 'org']), isA<String>());
    });

    test('a comment inside quotes is not mistaken for a trailing comment', () {
      final e =
          ConfigEditor('file_name: "a # b"  # note\n').set(['file_name'], 'c');
      expect(e.text, 'file_name: c  # note\n');
    });

    test('the template can be edited and still builds a config', () {
      final e = ConfigEditor.template()
          .set(['output_layout'], 'by-version').set([
        'pre_build',
        'clean'
      ], true).set(['play', 'default_track'], 'beta').set(
              ['flavors', 'dev', 'target'], 'lib/main_dev.dart');
      final c = e.build('/proj');
      expect(c.outputLayout, LayoutPreset.byVersion.template);
      expect(c.preBuild.clean, isTrue);
      expect(c.play.defaultTrack, 'beta');
      expect(c.flavor('dev').target, 'lib/main_dev.dart');
      expect(e.text, contains('# flutter_buildkit config.'));
    });

    test('bad values are rejected when building', () {
      expect(() => ConfigEditor('output_layout: "{wat}"\n').build('/p'),
          throwsA(isA<ConfigException>()));
      expect(() => ConfigEditor('a: [\n').build('/p'),
          throwsA(isA<ConfigException>()));
    });
  });

  group('settings previews', () {
    final ctx = PreviewContext(
        appName: 'my_app',
        versionName: '1.2.0',
        versionCode: 42,
        flavor: 'dev',
        now: DateTime(2026, 10, 1, 7, 5, 9));
    SettingDef def(String key) =>
        globalSettings().firstWhere((d) => d.key == key);

    test('layout preview shows the folder, file and symbols', () {
      final c = AppConfig.fromYaml('/proj', const {});
      final lines = def('output_layout').preview(c, ctx);
      expect(lines.first,
          p.join('app_builds', 'dev', 'release', '1.2.0-b42-20261001-070509'));
      expect(lines.join('\n'),
          contains('my_app-dev-release-1.2.0-b42-20261001-070509.aab'));
    });

    test('layout preview keeps the app folder outside the project', () {
      final c = AppConfig.fromYaml('/proj', const {'output_dir': '/builds'});
      expect(def('output_layout').preview(c, ctx).first,
          startsWith(p.join('/builds', 'my_app')));
    });

    test('command preview follows obfuscate, split_per_abi and extra args', () {
      final c = AppConfig.fromYaml('/proj', const {
        'flutter': 'fvm flutter',
        'split_per_abi': true,
        'extra_build_args': ['--no-tree-shake-icons'],
      });
      final line = def('flutter').preview(c, ctx).first;
      expect(line, contains('fvm flutter build apk --release --flavor dev'));
      expect(line, contains('--obfuscate'));
      expect(line, contains('--split-per-abi'));
      expect(line, contains('--no-tree-shake-icons'));
    });

    test('every setting has a current value and a preview for defaults', () {
      final c = AppConfig.fromYaml('/proj', const {});
      for (final d in [...globalSettings(), ...flavorSettings('dev')]) {
        expect(d.current(c), isNotEmpty, reason: d.key);
        expect(d.preview(c, ctx), isNotEmpty, reason: d.key);
      }
    });

    test('settings keys all exist in the config template', () {
      final y = ConfigEditor.template();
      final c = y.build('/p');
      expect(c, isNotNull);
      for (final d in globalSettings()) {
        final edited =
            y.set(d.path, d.kind == SettingKind.boolean ? true : 'x');
        expect(edited.raw(d.path), isNotNull, reason: d.key);
      }
    });
  });

  group('SettingsScreen (plain console)', () {
    late Directory tmp;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('fbk_settings_');
      File(p.join(tmp.path, 'pubspec.yaml'))
          .writeAsStringSync('name: demo\nversion: 1.2.0+5\n');
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    Console scripted(List<String> input, StringBuffer out) {
      final lines = [...input];
      return Console(
          mode: UiMode.plain,
          readLine: () => lines.isEmpty ? null : lines.removeAt(0),
          write: out.write);
    }

    test('closing input with unsaved changes ends instead of looping',
        () async {
      final screen = SettingsScreen(
          console: scripted(['6', 'false'], StringBuffer()),
          project: FlutterProject(tmp.path),
          env: const {});
      expect(await screen.run().timeout(const Duration(seconds: 5)), isNull);
    });

    test('edits, previews and saves a new config file', () async {
      final out = StringBuffer();
      // Menu rows: 1 output_dir, 2 output_layout, ... 6 obfuscate.
      final project = FlutterProject(tmp.path);
      final defs = globalSettings();
      final save = defs.length + 3;
      final input = [
        '6',
        'false',
        '2',
        'by-version',
        '$save',
        'y',
      ];
      final screen = SettingsScreen(
          console: scripted(input, out), project: project, env: const {});
      final saved = await screen.run();
      expect(saved, p.join(tmp.path, 'flutter_buildkit.yaml'));
      final c = AppConfig.load(tmp.path, env: const {});
      expect(c.obfuscate, isFalse);
      expect(c.outputLayout, LayoutPreset.byVersion.template);
      expect(out.toString(), contains('Preview'));
      expect(File(saved!).readAsStringSync(),
          contains('# flutter_buildkit config.'));
    });
  });
}
