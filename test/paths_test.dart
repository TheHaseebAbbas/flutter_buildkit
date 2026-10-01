import 'package:flutter_buildkit/flutter_buildkit.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

BuildNaming naming({
  String app = 'my_app',
  String? flavor = 'dev',
  BuildMode mode = BuildMode.release,
  String versionName = '1.2.0',
  int versionCode = 42,
  ArtifactType type = ArtifactType.aab,
  DateTime? time,
}) =>
    BuildNaming(
      appName: app,
      flavor: flavor,
      mode: mode,
      versionName: versionName,
      versionCode: versionCode,
      time: time ?? DateTime(2026, 10, 1, 7, 5, 9),
      type: type,
    );

void main() {
  final paths = BuildPaths('/out');

  group('default layout', () {
    test('app/flavor/mode/version-datetime', () {
      expect(
          paths.buildDir(naming()),
          p.join(
              '/out', 'my_app', 'dev', 'release', '1.2.0-b42-20261001-070509'));
    });

    test('uses "default" when there is no flavor', () {
      final dir = paths.buildDir(naming(flavor: null, mode: BuildMode.debug));
      expect(p.split(dir), containsAllInOrder(['my_app', 'default', 'debug']));
    });
  });

  group('artifact file names', () {
    test('<app>-<flavor>-<mode>-<versionName>-b<versionCode>-<datetime>.<type>',
        () {
      expect(paths.artifactFileName(naming()),
          'my_app-dev-release-1.2.0-b42-20261001-070509.aab');
      expect(paths.artifactFileName(naming(type: ArtifactType.apk)),
          'my_app-dev-release-1.2.0-b42-20261001-070509.apk');
      expect(paths.artifactFileName(naming(type: ArtifactType.ipa)),
          'my_app-dev-release-1.2.0-b42-20261001-070509.ipa');
    });

    test('the flavor part is dropped when there is no flavor', () {
      expect(paths.artifactFileName(naming(flavor: null)),
          'my_app-release-1.2.0-b42-20261001-070509.aab');
    });

    test('ABI suffix goes last', () {
      expect(
          paths.artifactFileName(naming(type: ArtifactType.apk),
              suffix: 'arm64-v8a'),
          'my_app-dev-release-1.2.0-b42-20261001-070509-arm64-v8a.apk');
    });

    test('a custom file name template', () {
      final custom = BuildPaths('/out',
          fileName: '{app}_{flavor}_{versionName}_{versionCode}_{type}');
      expect(custom.artifactFileName(naming()), 'my_app_dev_1.2.0_42_aab.aab');
    });
  });

  group('layout presets', () {
    String dir(LayoutPreset preset, {String? flavor = 'dev'}) => p.relative(
        BuildPaths('/out', layout: preset.template)
            .buildDir(naming(flavor: flavor)),
        from: '/out');

    test('by-flavor', () {
      expect(dir(LayoutPreset.byFlavor),
          p.join('my_app', 'dev', 'release', '1.2.0-b42-20261001-070509'));
    });

    test('by-version groups flavors and modes under the version', () {
      expect(dir(LayoutPreset.byVersion),
          p.join('my_app', '1.2.0-b42', 'dev-release-20261001-070509'));
    });

    test('by-month', () {
      expect(dir(LayoutPreset.byMonth),
          p.join('2026-10', 'my_app-dev-release-1.2.0-b42-20261001-070509'));
    });

    test('flat', () {
      expect(dir(LayoutPreset.flat),
          'my_app-dev-release-1.2.0-b42-20261001-070509');
    });

    test('presets resolve by id', () {
      expect(BuildPaths.resolveLayout('by-version'),
          LayoutPreset.byVersion.template);
      expect(BuildPaths.resolveLayout('{app}/{mode}'), '{app}/{mode}');
    });
  });

  group('custom templates', () {
    test('all tokens render', () {
      final t = PathTemplate.parse(
          '{app}|{flavor}|{mode}|{versionName}|{versionCode}|{version}|{datetime}|{date}|{time}|{year}|{month}|{type}',
          isFolder: false);
      expect(t.render(naming()),
          'my_app|dev|release|1.2.0|42|1.2.0-b42|20261001-070509|20261001|070509|2026|10|aab');
    });

    test('unknown tokens are rejected with the list of valid ones', () {
      expect(
          () => PathTemplate.parse('{app}/{nope}', isFolder: true),
          throwsA(isA<PathTemplateException>()
              .having((e) => e.message, 'message', contains('{versionCode}'))));
    });

    test('unsafe layouts are rejected', () {
      for (final bad in [
        '/abs/{app}',
        '../{app}',
        '{app}/../x',
        '{app}//x',
        'C:/x',
        ''
      ]) {
        expect(() => PathTemplate.parse(bad, isFolder: true),
            throwsA(isA<PathTemplateException>()),
            reason: bad);
      }
      expect(() => PathTemplate.parse('a/{app}', isFolder: false),
          throwsA(isA<PathTemplateException>()));
      expect(() => PathTemplate.parse('{app', isFolder: true),
          throwsA(isA<PathTemplateException>()));
    });

    test('a hostile flavor name cannot escape the root', () {
      final dir = paths.buildDir(naming(flavor: '../../x'));
      expect(p.isWithin('/out', dir), isTrue);
    });

    test('bad config values give a ConfigException', () {
      expect(() => AppConfig.fromYaml('/p', {'output_layout': '{wat}'}),
          throwsA(isA<ConfigException>()));
      expect(() => AppConfig.fromYaml('/p', {'file_name': 'a/b'}),
          throwsA(isA<ConfigException>()));
      final c = AppConfig.fromYaml('/p', {'output_layout': 'flat'});
      expect(c.outputLayout, LayoutPreset.flat.template);
    });

    test('presets drop {app}/ inside the project and keep it elsewhere', () {
      final inside = AppConfig.fromYaml('/p', const {});
      expect(inside.effectiveLayout, '{flavor}/{mode}/{version}-{datetime}');
      final outside = AppConfig.fromYaml('/p', const {'output_dir': '/builds'});
      expect(outside.effectiveLayout, LayoutPreset.byFlavor.template);
      final custom = AppConfig.fromYaml(
          '/p', const {'output_layout': '{app}/{flavor}-{datetime}'});
      expect(custom.effectiveLayout, '{app}/{flavor}-{datetime}');
      final flat = AppConfig.fromYaml('/p', const {'output_layout': 'flat'});
      expect(flat.effectiveLayout, LayoutPreset.flat.template);
      expect(inside.describe(), contains('{flavor}/{mode}'));
    });
  });

  test('timestamp is zero padded and sorts chronologically', () {
    expect(
        BuildPaths.timestamp(DateTime(2026, 1, 2, 3, 4, 5)), '20260102-030405');
    expect(
        BuildPaths.timestamp(DateTime(2026, 1, 2, 3, 4, 5))
            .compareTo(BuildPaths.timestamp(DateTime(2026, 11, 1))),
        lessThan(0));
  });

  test('sanitize strips path separators and unsafe characters', () {
    expect(BuildPaths.sanitize('a/b\\c:d'), 'a_b_c_d');
    expect(BuildPaths.sanitize('my app'), 'my_app');
    expect(BuildPaths.sanitize('1.0.0-beta.1'), '1.0.0-beta.1');
    expect(BuildPaths.sanitize('..'), '_');
    expect(BuildPaths.sanitize(''), '_');
    expect(BuildPaths.sanitize('../../etc'), '_.._etc');
  });
}
