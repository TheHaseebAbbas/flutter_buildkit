// Configuration: load the sample YAML files and see what they mean.
//
//   dart run example/configuration/load_config.dart
//
// Shows AppConfig.load, AppConfig.fromYaml (no file needed), per-flavor
// settings, entry points and how environment variables override the file.
import 'dart:io';

import 'package:flutter_buildkit/flutter_buildkit.dart';
import 'package:path/path.dart' as p;

import '../_support/demo.dart';

void main() {
  final here = p.dirname(Platform.script.toFilePath());

  for (final name in ['minimal', 'multi_flavor', 'entry_points']) {
    title('flutter_buildkit.$name.yaml');
    final config = AppConfig.load(
      '/work/my_app', // project folder; nothing is read from it here
      explicitPath: p.join(here, 'flutter_buildkit.$name.yaml'),
      env: const {}, // ignore this machine's environment variables
    );
    print('layout     : ${config.effectiveLayout}');
    print('ledger     : ${config.ledgerPath}');
    print('flavors    : ${config.flavors.keys.join(', ')}');
    print('entries    : ${config.entryPoints}');
    for (final e in config.flavors.entries) {
      final f = e.value;
      print('  ${e.key}: target=${f.target} package=${f.packageName} '
          'extraArgs=${f.extraArgs}');
    }
  }

  title('Environment variables override the file');
  final release = AppConfig.load(
    '/work/my_app',
    explicitPath: p.join(here, 'flutter_buildkit.release_pipeline.yaml'),
    env: const {
      'HOME': '/home/me',
      'FBK_FLUTTER': 'flutter', // wins over `flutter: fvm flutter`
      'SENTRY_AUTH_TOKEN': 'sntrys_0123456789', // secrets live in the env
      'PLAY_SERVICE_ACCOUNT_JSON': '~/.secrets/play.json',
    },
  );
  print('flutter command   : ${release.flutter}');
  print('output root       : ${release.outputRoot}');
  print('output in project : ${release.outputInsideProject}');
  print('layout used       : ${release.effectiveLayout}');
  print('play key          : ${release.play.serviceAccountJson}');

  title('Build a config from a map (no file)');
  final inline = AppConfig.fromYaml('/work/my_app', {
    'output_layout': 'flat',
    'flavors': {
      'dev': {'package_name': 'com.example.dev'},
    },
  });
  print('layout        : ${inline.outputLayout}');
  print('dev package   : ${inline.flavor('dev').packageName}');
  print(
      'unknown flavor: ${inline.flavor('nope').packageName}'); // empty defaults

  title('The commented starter file written by `init`');
  print(AppConfig.template.split('\n').take(8).join('\n'));
  print('  ...');

  title('Invalid values are reported');
  try {
    AppConfig.fromYaml('/work/my_app', {'output_layout': '../escape/{app}'});
  } on ConfigException catch (e) {
    print('ConfigException: $e');
  }

  title('Everything in effect (as `config` prints it)');
  print(release.describe());
}
