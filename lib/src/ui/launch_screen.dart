import '../config.dart';
import '../flutter_project.dart';
import '../jsonc.dart';
import '../vscode.dart';
import 'console.dart';

/// Offers to add run configurations (flavor × entry point × mode) to
/// `.vscode/launch.json`. Existing configurations and comments are kept;
/// ones launch.json already has are not added again. True when the file was
/// written.
Future<bool> runLaunchJsonFlow(
    Console console, FlutterProject project, AppConfig config) async {
  console.heading('VS Code launch.json');
  final LaunchPlan plan;
  try {
    plan = planLaunchJson(config, project);
  } on LaunchJsonException catch (e) {
    console.error('$e');
    return false;
  }
  final path = launchJsonFile(project).path;
  if (plan.skipped.isNotEmpty) {
    console.note('${plan.skipped.length} configuration'
        '${plan.skipped.length == 1 ? '' : 's'} already in launch.json.');
  }
  if (plan.add.isEmpty) {
    console.out('Nothing to add: $path already has every configuration.');
    return false;
  }
  console.note(plan.existing == null
      ? '$path will be created.'
      : '$path will be updated; the old file is kept as launch.json.bak.');
  final picks = await console.chooseMany(
    'Run configurations to add',
    [for (final e in plan.add) e.name],
    ticked: {for (var i = 0; i < plan.add.length; i++) i},
    hints: [
      for (final e in plan.add)
        [
          if (e.flavor != null) 'flavor ${e.flavor}',
          e.program ?? 'lib/main.dart',
          if (e.dartDefineFile != null) e.dartDefineFile!,
        ].join('  '),
    ],
  );
  if (picks == null || picks.isEmpty) return false;
  final chosen = [for (final i in picks) plan.add[i]];
  try {
    final text = mergeLaunchJson(plan.existing, chosen);
    decodeJsonc(text); // never write something VS Code cannot read
    if (!await console.confirm(
        'Add ${chosen.length} configuration${chosen.length == 1 ? '' : 's'} '
        'to $path?',
        defaultValue: true)) {
      return false;
    }
    writeLaunchJson(project, text);
  } on LaunchJsonException catch (e) {
    console.error('$e');
    return false;
  } on FormatException catch (e) {
    console.error('The merged launch.json would be invalid ($e); nothing '
        'was written.');
    return false;
  }
  console.success('Added ${chosen.length} to $path');
  return true;
}
