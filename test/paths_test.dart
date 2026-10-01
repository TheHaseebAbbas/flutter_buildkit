import 'package:flutter_buildkit/flutter_buildkit.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  const paths = BuildPaths('/out');
  final time = DateTime(2026, 10, 1, 7, 5, 9);

  test('lays out app/flavor/mode/version_timestamp', () {
    expect(
      paths.buildDir(
          appName: 'my_app',
          flavor: 'dev',
          mode: BuildMode.release,
          versionName: '1.2.0',
          versionCode: 42,
          time: time),
      p.join('/out', 'my_app', 'dev', 'release', '1.2.0+42_20261001-070509'),
    );
  });

  test('uses "default" when there is no flavor', () {
    final dir = paths.buildDir(
        appName: 'my_app',
        flavor: null,
        mode: BuildMode.debug,
        versionName: '1.0.0',
        versionCode: 1,
        time: time);
    expect(p.split(dir), containsAllInOrder(['my_app', 'default', 'debug']));
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

  test('a hostile flavor name cannot escape the root', () {
    final dir = paths.buildDir(
        appName: 'app',
        flavor: '../../x',
        mode: BuildMode.release,
        versionName: '1',
        versionCode: 1,
        time: time);
    expect(p.isWithin('/out', dir), isTrue);
  });

  test('artifact names include flavor, mode, version and abi suffix', () {
    expect(
      BuildPaths.artifactName(
          appName: 'my_app',
          flavor: 'dev',
          mode: BuildMode.release,
          versionName: '1.2.0',
          versionCode: 42,
          type: ArtifactType.aab),
      'my_app-dev-release-1.2.0+42.aab',
    );
    expect(
      BuildPaths.artifactName(
          appName: 'my_app',
          flavor: null,
          mode: BuildMode.debug,
          versionName: '1.0.0',
          versionCode: 1,
          type: ArtifactType.apk,
          suffix: 'arm64-v8a'),
      'my_app-debug-1.0.0+1-arm64-v8a.apk',
    );
  });
}
