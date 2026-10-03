// Reading a project: flavors, entry points and suggested settings.
//
//   dart run example/vscode_and_autoconfig/autoconfig.dart
//
// Runs on a generated demo project (Gradle flavors, several main files).
import 'package:flutter_buildkit/flutter_buildkit.dart';

import '../_support/demo.dart';

void main() {
  final demo = DemoProject.create();
  try {
    final project = demo.project;

    title('What the project says about itself');
    print('app name       : ${project.appName}');
    print('version        : ${project.version.name}+${project.version.code}');
    print('flavors        : ${project.flavors}');
    print('application id : ${project.androidApplicationId}');
    print('dev package    : ${project.packageName('dev')}');
    print('dev main       : ${project.defaultTarget('dev')}');
    print('dev define file: ${project.defineFileFor('dev')}');

    title('Every Dart file with a main()');
    for (final entry in project.dartEntries) {
      print('${entry.path.padRight(22)} name: ${entry.name ?? '(default)'}');
    }

    title('Entry points that are not a flavor\'s own main');
    print(detectEntryPoints(project, project.flavors));

    title('What to build, per flavor');
    final config = AppConfig.load(demo.dir, env: const {});
    for (final flavor in project.flavors) {
      final labels = entryPointsFor(config, project, flavor)
          .map((e) => '${e.label} (${e.path})')
          .join(', ');
      print('$flavor -> $labels');
    }

    title('Suggested config (what `autoconfig` offers to write)');
    for (final s in suggestConfig(project)) {
      print('${s.key.padRight(26)} ${s.value}\n  ${s.reason}');
    }

    title('Name matching is loose');
    print(normalizeName('Client-DB') == normalizeName('client_db')); // true
  } finally {
    demo.dispose();
  }
}
