// VS Code run configurations for every flavor x entry point x mode.
//
//   dart run example/vscode_and_autoconfig/vscode_launch.dart
//
// Plans the change to .vscode/launch.json, merges it into the demo project's
// existing file (comments and your own configurations stay) and runs it
// twice to show that nothing is added a second time.
import 'dart:io';

import 'package:flutter_buildkit/flutter_buildkit.dart';

import '../_support/demo.dart';

void main() {
  final demo = DemoProject.create();
  try {
    final project = demo.project;
    final config = AppConfig.load(demo.dir, env: const {});

    title('Entries that would be added');
    for (final e in launchEntriesFor(config, project).take(6)) {
      print('${e.name.padRight(24)} flavor=${e.flavor} program=${e.program} '
          'args=${e.args}');
    }
    print('... ${launchEntriesFor(config, project).length} in total');

    title('Plan, merge and write');
    var plan = planLaunchJson(config, project);
    print('add ${plan.add.length}, skip ${plan.skipped.length}');
    writeLaunchJson(project, mergeLaunchJson(plan.existing, plan.add));
    print(launchJsonFile(project)
        .readAsStringSync()
        .split('\n')
        .take(14)
        .join('\n'));
    print('  ...');
    print(
        'backup kept: ${File('${launchJsonFile(project).path}.bak').existsSync()}');

    title('Second run is a no-op');
    plan = planLaunchJson(config, project);
    print('add ${plan.add.length}, skip ${plan.skipped.length}');

    title('A broken launch.json is never touched');
    launchJsonFile(project).writeAsStringSync('{ "configurations": [ oops');
    try {
      planLaunchJson(config, project);
    } on LaunchJsonException catch (e) {
      print(e.toString().replaceAll(demo.dir, '<project>'));
    }
  } finally {
    demo.dispose();
  }
}
