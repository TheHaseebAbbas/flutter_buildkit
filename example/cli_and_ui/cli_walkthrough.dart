// The command line, driven from code.
//
//   dart run example/cli_and_ui/cli_walkthrough.dart
//
// Creates a demo project with two builds in its ledger, then runs the real
// `bin/flutter_buildkit.dart` commands that need no interaction. The
// interactive menu itself is started with `dart run flutter_buildkit`.
import 'dart:io';

import 'package:flutter_buildkit/flutter_buildkit.dart';
import 'package:path/path.dart' as p;

import '../_support/demo.dart';

Future<void> main() async {
  final packageRoot =
      p.dirname(p.dirname(p.dirname(Platform.script.toFilePath())));
  final bin = p.join(packageRoot, 'bin', 'flutter_buildkit.dart');

  Future<void> cli(String project, List<String> args) async {
    print('\n\$ dart run flutter_buildkit ${args.join(' ')}');
    final result = await Process.run(
      Platform.resolvedExecutable,
      [bin, '-C', project, ...args],
      workingDirectory: packageRoot,
    );
    stdout.write('${result.stdout}');
    if ('${result.stderr}'.trim().isNotEmpty) stderr.write(result.stderr);
  }

  await withDemoProject((demo) async {
    final config = AppConfig.load(demo.dir, env: const {});
    final ledger = await Ledger.open(config.ledgerPath);
    final builder = FlutterBuilder(
        project: demo.project,
        config: config,
        ledger: ledger,
        runner: FakeFlutter(demo.dir));
    for (final (type, flavor) in [
      (ArtifactType.aab, 'prod'),
      (ArtifactType.apk, 'dev')
    ]) {
      await builder.build(BuildRequest(
        type: type,
        mode: BuildMode.release,
        flavor: flavor,
        versionName: '1.2.0',
        versionCode: 42,
      ));
    }

    title('Commands that need no interaction');
    await cli(demo.dir, ['list']);
    await cli(demo.dir, ['export', 'csv', p.join(demo.dir, 'ledger.csv')]);
    print('wrote ${File(p.join(demo.dir, 'ledger.csv')).lengthSync()} bytes');
    await cli(demo.dir, ['init']); // starter flutter_buildkit.yaml
    await cli(demo.dir, ['config']);

    title('Errors are written to stderr');
    final bad = await Process.run(
        Platform.resolvedExecutable, [bin, '-C', demo.dir, 'export', 'xml'],
        workingDirectory: packageRoot);
    print('export xml -> ${'${bad.stderr}'.trim()}');

    title('Interactive commands (run these in your terminal)');
    for (final line in [
      'dart run flutter_buildkit                  # the menu',
      'dart run flutter_buildkit autoconfig       # write config from the project',
      'dart run flutter_buildkit vscode           # add launch.json entries',
      'dart run flutter_buildkit settings         # edit the config with previews',
      'dart run flutter_buildkit --ui plain       # numbered questions only',
    ]) {
      print(line);
    }
  });
}
