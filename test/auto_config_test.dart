import 'dart:io';

import 'package:flutter_buildkit/flutter_buildkit.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late FlutterProject project;

  void write(String rel, String content) {
    final f = File(p.join(tmp.path, rel))..createSync(recursive: true);
    f.writeAsStringSync(content);
  }

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('fbk_auto_');
    project = FlutterProject(tmp.path);
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  Map<String, Object> found() =>
      {for (final s in suggestConfig(project)) s.key: s.value};

  test('a bare project gets a layout without a flavor folder', () {
    write('pubspec.yaml', 'name: demo\nversion: 1.0.0+1\n');
    final f = found();
    expect(f['output_layout'], '{mode}/{version}-{datetime}');
    expect(f['pre_build.build_runner'], false);
    expect(f['pre_build.gen_l10n'], false);
    expect(f['crashlytics.enabled'], false);
    expect(f['sentry.enabled'], false);
    expect(f.containsKey('flutter'), isFalse);
    expect(f.keys.where((k) => k.startsWith('flavors')), isEmpty);
  });

  group('a flavored project', () {
    setUp(() {
      write('pubspec.yaml', '''
name: demo
version: 1.2.0+5
dependencies:
  firebase_crashlytics: ^4.0.0
  sentry_flutter: ^8.0.0
dev_dependencies:
  build_runner: ^2.4.0
flutter:
  generate: true
''');
      write('android/app/build.gradle', '''
android {
  defaultConfig { applicationId "com.demo.app" }
  flavorDimensions "env"
  productFlavors {
    dev { applicationIdSuffix ".dev" }
    prod { }
  }
}
''');
      write('lib/main_dev.dart', '');
      write('lib/main_prod.dart', '');
      write('config/dev.json', '{}');
      write('android/app/src/dev/google-services.json', '''
{"client":[{"client_info":{"mobilesdk_app_id":"1:123:android:abc",
 "android_client_info":{"package_name":"com.demo.app.dev"}}}]}''');
      write('.fvmrc', '{"flutter":"3.24.0"}');
      write('sentry.properties',
          'defaults.org=acme\ndefaults.project=demo\nauth.token=SECRET123\n');
      write('fastlane/Appfile', 'json_key_file("play.json")\n');
      write('fastlane/play.json', '{}');
    });

    test('reads flavors, tools and files', () {
      final f = found();
      expect(f['flutter'], 'fvm flutter');
      expect(f['output_layout'], 'by-flavor');
      expect(f['pre_build.build_runner'], true);
      expect(f['pre_build.gen_l10n'], true);
      expect(f['flavors.dev.target'], 'lib/main_dev.dart');
      expect(f['flavors.prod.target'], 'lib/main_prod.dart');
      expect(f['flavors.dev.dart_define_file'], 'config/dev.json');
      expect(f.containsKey('flavors.prod.dart_define_file'), isFalse);
      expect(f['flavors.dev.package_name'], 'com.demo.app.dev');
      expect(f['flavors.prod.package_name'], 'com.demo.app');
      expect(f['flavors.dev.firebase_app_id'], '1:123:android:abc');
      expect(f['crashlytics.enabled'], true);
      expect(f['sentry.enabled'], true);
      expect(f['sentry.org'], 'acme');
      expect(f['sentry.project'], 'demo');
      expect(f['play.service_account_json'], 'fastlane/play.json');
    });

    test('never copies the Sentry auth token', () {
      for (final s in suggestConfig(project)) {
        expect('${s.value}', isNot(contains('SECRET123')), reason: s.key);
        expect(s.key, isNot(contains('auth')));
      }
    });

    test('suggestions build into a valid config', () {
      var e = ConfigEditor.template();
      for (final s in suggestConfig(project)) {
        e = e.set(s.path, s.value);
      }
      final c = e.build(tmp.path);
      expect(c.flutter, ['fvm', 'flutter']);
      expect(c.flavor('dev').packageName, 'com.demo.app.dev');
      expect(c.flavor('dev').target, 'lib/main_dev.dart');
      expect(c.sentry.org, 'acme');
    });

    test('extra main files become entry points per flavor', () {
      write('lib/main_admin.dart', '');
      final f = found();
      expect(f['flavors.dev.entry_points.main'], 'lib/main_dev.dart');
      expect(f['flavors.dev.entry_points.admin'], 'lib/main_admin.dart');
      expect(f['flavors.prod.entry_points.main'], 'lib/main_prod.dart');
      // The flavor target is replaced by the list, not repeated.
      expect(f.containsKey('flavors.dev.target'), isFalse);
      var e = ConfigEditor.template();
      for (final s in suggestConfig(project)) {
        e = e.set(s.path, s.value);
      }
      final c = e.build(tmp.path);
      expect(entryPointsFor(c, project, 'dev'), [
        const EntryPoint(null, 'lib/main_dev.dart'),
        const EntryPoint('admin', 'lib/main_admin.dart'),
      ]);
    });
  });

  test('gitignore gaps are found and filled', () {
    write('pubspec.yaml', 'name: demo\n');
    write('.gitignore', 'build/\napp_builds/\n');
    final missing = missingGitignoreEntries(project,
        outputDir: 'app_builds', configFileName: 'flutter_buildkit.yaml');
    expect(missing, ['flutter_buildkit.yaml']);
    addToGitignore(project, missing);
    expect(
        missingGitignoreEntries(project,
            outputDir: 'app_builds', configFileName: 'flutter_buildkit.yaml'),
        isEmpty);
    expect(File(p.join(tmp.path, '.gitignore')).readAsStringSync(),
        startsWith('build/\napp_builds/\n'));
  });

  test('autoconfigure writes the file, reports and offers .gitignore',
      () async {
    write('pubspec.yaml',
        'name: demo\nversion: 1.2.0+5\ndev_dependencies:\n  build_runner: ^2.0.0\n');
    write('android/app/build.gradle',
        'android { productFlavors { dev { } prod { } } }');
    write('lib/main_dev.dart', '');
    final out = StringBuffer();
    final lines = [
      '', // Enter keeps the ticked suggestions
      'y', // write and reload
      'y', // add to .gitignore
    ];
    final screen = SettingsScreen(
        console: Console(
            mode: UiMode.plain,
            readLine: () => lines.isEmpty ? null : lines.removeAt(0),
            write: out.write),
        project: FlutterProject(tmp.path),
        env: const {});
    final saved = await screen.autoConfigure();
    expect(saved, p.join(tmp.path, 'flutter_buildkit.yaml'));
    final c = AppConfig.load(tmp.path, env: const {});
    expect(c.flavor('dev').target, 'lib/main_dev.dart');
    expect(c.preBuild.buildRunner, isTrue);
    expect(out.toString(), contains('Detected settings'));
    expect(File(p.join(tmp.path, '.gitignore')).readAsStringSync(),
        allOf(contains('app_builds/'), contains('flutter_buildkit.yaml')));
  });

  test('an existing value is not overwritten unless ticked', () async {
    write('pubspec.yaml', 'name: demo\nversion: 1.0.0+1\n');
    write('flutter_buildkit.yaml', 'output_layout: flat\n');
    final lines = ['', 'y'];
    final screen = SettingsScreen(
        console: Console(
            mode: UiMode.plain,
            readLine: () => lines.isEmpty ? null : lines.removeAt(0),
            write: (_) {}),
        project: FlutterProject(tmp.path),
        configFile: p.join(tmp.path, 'flutter_buildkit.yaml'),
        env: const {});
    await screen.autoConfigure();
    expect(AppConfig.load(tmp.path, env: const {}).outputLayout,
        LayoutPreset.flat.template);
  });
}
