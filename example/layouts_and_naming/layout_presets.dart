// Folder layouts and file naming: see where a build would be stored.
//
//   dart run example/layouts_and_naming/layout_presets.dart
//
// No files are created; BuildPaths only works out names.
import 'package:flutter_buildkit/flutter_buildkit.dart';

import '../_support/demo.dart';

void main() {
  final naming = BuildNaming(
    appName: 'my_app',
    flavor: 'dev',
    mode: BuildMode.release,
    versionName: '1.2.0',
    versionCode: 42,
    time: DateTime(2026, 10, 1, 7, 5, 9),
    type: ArtifactType.aab,
  );

  title('The four presets');
  for (final preset in LayoutPreset.values) {
    final paths = BuildPaths('app_builds', layout: preset.template);
    print('${preset.id.padRight(11)} ${paths.buildDir(naming)}');
  }

  title('A custom template');
  final custom = BuildPaths(
    'app_builds',
    layout: '{year}/{month}/{app}/{type}/{flavor}/{version}-{datetime}',
    fileName: '{app}_{flavor}_{versionName}_{versionCode}',
  );
  print(custom.buildDir(naming));
  print(custom.artifactFileName(naming));

  title('File names');
  final paths = BuildPaths('app_builds');
  print(paths.artifactFileName(naming));
  print('split APK : ${paths.artifactFileName(
    BuildNaming(
      appName: 'my_app',
      flavor: 'dev',
      mode: BuildMode.release,
      versionName: '1.2.0',
      versionCode: 42,
      time: naming.time,
      type: ArtifactType.apk,
    ),
    suffix: 'arm64-v8a',
  )}');
  print('no flavor : ${paths.artifactFileName(BuildNaming(
    appName: 'my_app',
    flavor: null,
    mode: BuildMode.debug,
    versionName: '1.2.0',
    versionCode: 42,
    time: naming.time,
    type: ArtifactType.apk,
  ))}');

  title('A named entry point is added to the folder name');
  print(BuildPaths('app_builds').buildDir(BuildNaming(
    appName: 'my_app',
    flavor: 'dev',
    mode: BuildMode.release,
    versionName: '1.2.0',
    versionCode: 42,
    time: naming.time,
    type: ArtifactType.aab,
    entry: 'admin',
  )));

  title('Presets as config values and invalid templates');
  print(BuildPaths.resolveLayout('by-version'));
  try {
    BuildPaths('app_builds', layout: '{nope}/{app}');
  } on PathTemplateException catch (e) {
    print('PathTemplateException: $e');
  }
  print(BuildPaths.sanitize('Pro / Edition: 2?')); // safe on every OS
}
