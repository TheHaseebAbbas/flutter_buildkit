import 'package:flutter_build_ledger/flutter_build_ledger.dart';
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

    test('the init template is valid config', () {
      final doc = loadYaml(AppConfig.template) as Map;
      expect(() => AppConfig.fromYaml('/p', doc.cast()), returnsNormally);
      expect(
          AppConfig.fromYaml('/p', doc.cast()).play.defaultTrack, 'internal');
    });
  });
}
