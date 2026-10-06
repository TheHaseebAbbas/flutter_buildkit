import 'dart:io';
import 'package:flutter_buildkit/flutter_buildkit.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

void main() {
  group('gradle flavors', () {
    test('Groovy DSL', () {
      const gradle = '''
android {
  defaultConfig { applicationId "com.example.app" }
  flavorDimensions "env"
  productFlavors {
    dev { dimension "env"; applicationIdSuffix ".dev" }
    prod { dimension "env" }
  }
}''';
      final f = parseGradleFlavors(gradle);
      expect(f.map((x) => x.name), ['dev', 'prod']);
      expect(f[0].applicationId, 'com.example.app.dev');
      expect(f[1].applicationId, 'com.example.app');
    });

    test('Kotlin DSL with explicit ids and comments', () {
      const gradle = '''
android {
  defaultConfig { applicationId = "com.example.app" }
  productFlavors {
    // create("old") { }
    create("staging") { dimension = "env"; applicationId = "com.example.stg" }
    create("prod") { dimension = "env" }
  }
}''';
      final f = parseGradleFlavors(gradle);
      expect(f.map((x) => x.name), ['staging', 'prod']);
      expect(f[0].applicationId, 'com.example.stg');
    });

    test('no productFlavors block means no flavors', () {
      expect(parseGradleFlavors('android { defaultConfig { } }'), isEmpty);
    });
  });

  test('pubspec version parsing', () {
    expect(PubspecVersion.parse('1.2.3+45').code, 45);
    expect(PubspecVersion.parse('1.2.3').code, 1);
    expect(PubspecVersion.parse(null).name, '1.0.0');
  });

  test('firebase app id is matched by package name', () {
    const json = '''
{"client":[
 {"client_info":{"mobilesdk_app_id":"1:1:android:aaa","android_client_info":{"package_name":"com.a"}}},
 {"client_info":{"mobilesdk_app_id":"1:1:android:bbb","android_client_info":{"package_name":"com.b"}}}]}''';
    expect(parseFirebaseAppId(json, 'com.b'), '1:1:android:bbb');
    expect(parseFirebaseAppId('nope', 'com.b'), isNull);
  });

  group('flutter build args', () {
    const base = BuildRequest(
        type: ArtifactType.aab,
        mode: BuildMode.release,
        flavor: 'dev',
        target: 'lib/main_dev.dart',
        versionName: '1.2.0',
        versionCode: 42);

    test('release aab with flavor, obfuscation and version', () {
      expect(flutterBuildArgs(base, symbolsDir: '/s'), [
        'build',
        'appbundle',
        '--release',
        '--flavor',
        'dev',
        '--target',
        'lib/main_dev.dart',
        '--build-name=1.2.0',
        '--build-number=42',
        '--obfuscate',
        '--split-debug-info=/s',
      ]);
    });

    test('debug builds are never obfuscated', () {
      const r = BuildRequest(
          type: ArtifactType.apk,
          mode: BuildMode.debug,
          versionName: '1',
          versionCode: 1);
      expect(flutterBuildArgs(r, symbolsDir: '/s'),
          isNot(contains('--obfuscate')));
      expect(r.willObfuscate, isFalse);
    });
  });

  group('config', () {
    test('env vars override the config file for secrets', () {
      final c = AppConfig.fromYaml(
        '/proj',
        {
          'sentry': {'org': 'file-org', 'auth_token': 'file-token'}
        },
        env: {
          'SENTRY_AUTH_TOKEN': 'env-token',
          'PLAY_SERVICE_ACCOUNT_JSON': '/k.json'
        },
      );
      expect(c.sentry.authToken, 'env-token');
      expect(c.sentry.org, 'file-org');
      expect(c.play.serviceAccountJson, '/k.json');
    });

    test('defaults: app_builds/ledger.json inside the project', () {
      final c = AppConfig.fromYaml('/proj', const {});
      expect(c.ledgerPath, '/proj/app_builds/ledger.json');
      expect(c.flutter, ['flutter']);
    });

    test('a Play upload is a draft unless the config says otherwise', () {
      expect(AppConfig.fromYaml('/p', const {}).play.defaultReleaseStatus,
          'draft');
      final doc = loadYaml(AppConfig.template) as Map;
      expect(AppConfig.fromYaml('/p', doc.cast()).play.defaultReleaseStatus,
          'draft');
      final c = AppConfig.fromYaml('/p', {
        'play': {'default_release_status': 'completed'}
      });
      expect(c.play.defaultReleaseStatus, 'completed');
    });

    test('describe() does not reveal any part of a secret', () {
      final c = AppConfig.fromYaml('/p', {
        'sentry': {'auth_token': 'sntrys_abcdef123456'}
      });
      final text = c.describe();
      expect(text, matches(RegExp(r'sentry\.auth_token\s+set \(19 chars\)')));
      expect(text, isNot(contains('sntr')));
    });

    test('splitCommandLine keeps quoted paths together', () {
      expect(splitCommandLine('fvm flutter'), ['fvm', 'flutter']);
      expect(splitCommandLine(r'"C:\Program Files\flutter\bin\flutter.bat" -v'),
          [r'C:\Program Files\flutter\bin\flutter.bat', '-v']);
      expect(splitCommandLine("'~/My Tools/flutter'  x"),
          ['~/My Tools/flutter', 'x']);
      expect(splitCommandLine('  '), isEmpty);
      expect(splitCommandLine('a "" b'), ['a', '', 'b']);
    });

    test('a quoted flutter command with spaces survives the config', () {
      final c = AppConfig.fromYaml(
          '/p', {'flutter': '"/opt/My Tools/flutter" --suppress-analytics'});
      expect(c.flutter, ['/opt/My Tools/flutter', '--suppress-analytics']);
    });

    test('the local overlay wins over the shared file, key by key', () {
      final dir = Directory.systemTemp.createTempSync('fbk_overlay_');
      addTearDown(() => dir.deleteSync(recursive: true));
      File(p.join(dir.path, 'flutter_buildkit.yaml')).writeAsStringSync('''
output_dir: shared_out
play:
  default_track: beta
  default_release_status: draft
''');
      File(p.join(dir.path, 'flutter_buildkit.local.yaml'))
          .writeAsStringSync('''
play:
  default_track: internal
  service_account_json: /secret/key.json
''');
      final c = AppConfig.load(dir.path, env: const {});
      expect(c.play.defaultTrack, 'internal');
      expect(c.play.defaultReleaseStatus, 'draft');
      expect(c.play.serviceAccountJson, '/secret/key.json');
      expect(c.outputRoot, endsWith('shared_out'));
      expect(c.localConfigFile, endsWith('flutter_buildkit.local.yaml'));
      expect(c.describe(), contains('local overlay'));
    });

    test('the init template is valid config', () {
      final doc = loadYaml(AppConfig.template) as Map;
      expect(() => AppConfig.fromYaml('/p', doc.cast()), returnsNormally);
      expect(
          AppConfig.fromYaml('/p', doc.cast()).play.defaultTrack, 'internal');
    });
  });
}
