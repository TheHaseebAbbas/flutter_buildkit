import 'dart:io';

import 'package:args/args.dart';
import 'package:flutter_buildkit/flutter_buildkit.dart';
import 'package:flutter_buildkit/src/app.dart';
import 'package:flutter_buildkit/src/ui/windows_console.dart';
import 'package:path/path.dart' as p;

const _usage = '''
flutter_buildkit: build Flutter apps and keep a ledger of the builds.

Usage: flutter_buildkit [options] [command]

Commands:
  (none)   Open the interactive menu.
  init     Write a starter flutter_buildkit.yaml in the project.
  autoconfig Read the project and write flutter_buildkit.yaml from it.
  vscode   Add run configurations to .vscode/launch.json.
  settings Edit flutter_buildkit.yaml interactively, with previews.
  config   Show the settings in effect (secrets masked).
  list     Print the ledger as a table (--flavor, --status, --since, --limit, --json).
  export   Write the ledger as csv, tsv or json: export <format> [file]

Commands for scripts and CI (no prompts; see "Exit codes"):
  build    Build: --flavor dev,prod --type aab --mode release [--version-name 1.2.0 --build-number 42]
  publish  Upload an AAB to Google Play: publish <id|latest> --track internal [--release-status draft]
  mark     Mark builds as published: mark <id...> [--clear]
  symbols  Upload debug symbols: symbols <id|latest> --to crashlytics,sentry
  trace    De-obfuscate a crash: trace <id|latest> [--file crash.txt]
  delete   Delete builds: delete <id...> --dry-run | --yes

Exit codes: 0 ok, 64 usage, 66 no project, 69 upload failed, 70 build failed,
71 trace failed, 72 delete failed, 73 file exists, 74 ledger, 78 config,
130 interrupted.

Options:
''';

// Dart ignores a value returned from main, so the code is set explicitly.
Future<void> main(List<String> arguments) async {
  exitCode = await _main(arguments);
}

Future<int> _main(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption('project',
        abbr: 'C', help: 'Flutter project folder.', defaultsTo: '.')
    ..addOption('config',
        abbr: 'c',
        help: 'Config file (default: <project>/flutter_buildkit.yaml).')
    ..addOption('ledger', help: 'Ledger file (overrides the config).')
    ..addOption('ui', help: 'How prompts read input (also FBK_UI).', allowed: [
      'auto',
      'keys',
      'plain'
    ], allowedHelp: {
      'auto': 'arrow keys on a terminal, numbers otherwise (default)',
      'keys': 'always arrow keys',
      'plain': 'always numbered questions: type 2, or 1,3 for several',
    })
    ..addFlag('help', abbr: 'h', negatable: false);
  addCommandOptions(parser);

  final ArgResults args;
  try {
    args = parser.parse(arguments);
  } on FormatException catch (e) {
    stderr.writeln('${e.message}\n\n$_usage${parser.usage}');
    return ExitCodes.usage;
  }
  if (args['help'] as bool) {
    stdout.writeln('$_usage${parser.usage}');
    return 0;
  }

  // Windows: switch on ANSI input/output so arrows and colors work in
  // PowerShell and cmd. Restored on exit.
  final windows = WindowsConsole.enable();
  Console.windowsKeysReady = windows.ready;
  // Ctrl-C raises SIGINT even in raw mode: put the terminal back first.
  final sigint = ProcessSignal.sigint.watch().listen((_) {
    try {
      stdout.write('\x1b[?25h\n');
      if (stdin.hasTerminal) {
        stdin.echoMode = true;
        stdin.lineMode = true;
      }
    } on Object {
      // Best effort while exiting.
    }
    InterruptGuard.interrupt();
    windows.restore();
    exit(ExitCodes.interrupted);
  });
  try {
    return await _run(args, parser);
  } finally {
    await sigint.cancel();
    windows.restore();
  }
}

Future<int> _run(ArgResults args, ArgParser parser) async {
  final projectDir = p.normalize(p.absolute(args['project'] as String));
  final project = FlutterProject(projectDir);
  final command = args.rest.isEmpty ? null : args.rest.first;

  if (command == 'init') {
    final target = File(p.join(projectDir, AppConfig.fileNames.first));
    if (target.existsSync()) {
      stderr.writeln('${target.path} already exists.');
      return ExitCodes.cantCreate;
    }
    target.writeAsStringSync(AppConfig.template);
    stdout.writeln(
        'Wrote ${target.path}. Add it to .gitignore if it holds secrets.');
    return 0;
  }

  if (!project.isFlutterProject) {
    // list, export, mark and delete only need the ledger.
    const ledgerOnly = {'list', 'export', 'mark', 'delete'};
    if (ledgerOnly.contains(command) && args['ledger'] != null) {
      try {
        final ledger = await Ledger.open(p.absolute(args['ledger'] as String));
        return await Cli(ledger: ledger).run(command!, args);
      } on LedgerException catch (e) {
        stderr.writeln('$e');
        return ExitCodes.ledger;
      }
    }
    stderr.writeln('No pubspec.yaml in $projectDir. Run this from a Flutter '
        'project or pass --project (list, export, mark and delete also work '
        'with just --ledger).');
    return ExitCodes.noProject;
  }

  try {
    final config =
        AppConfig.load(projectDir, explicitPath: args['config'] as String?);
    final ledgerPath = args['ledger'] != null
        ? p.absolute(args['ledger'] as String)
        : config.ledgerPath;
    final ledger = await Ledger.open(ledgerPath);

    switch (command) {
      case null:
        final ui = UiMode.parse(
            args['ui'] as String? ?? Platform.environment['FBK_UI']);
        await App(
                project: project,
                config: config,
                ledger: ledger,
                console: Console(mode: ui),
                ledgerOverride: args['ledger'] as String?)
            .run();
      case 'autoconfig':
        final ui = UiMode.parse(
            args['ui'] as String? ?? Platform.environment['FBK_UI']);
        await App(
                project: project,
                config: config,
                ledger: ledger,
                console: Console(mode: ui),
                ledgerOverride: args['ledger'] as String?)
            .setUpFromProject();
      case 'vscode':
        final ui = UiMode.parse(
            args['ui'] as String? ?? Platform.environment['FBK_UI']);
        await App(
                project: project,
                config: config,
                ledger: ledger,
                console: Console(mode: ui),
                ledgerOverride: args['ledger'] as String?)
            .createLaunchJson();
      case 'settings':
        final ui = UiMode.parse(
            args['ui'] as String? ?? Platform.environment['FBK_UI']);
        await App(
                project: project,
                config: config,
                ledger: ledger,
                console: Console(mode: ui),
                ledgerOverride: args['ledger'] as String?)
            .editSettings();
      case 'config':
        stdout.writeln(config.describe());
      case 'build' ||
            'publish' ||
            'mark' ||
            'symbols' ||
            'trace' ||
            'delete' ||
            'list' ||
            'export':
        return await Cli(
                ledger: ledger,
                project: project,
                config: config,
                runner: ProcessRunner(outputToStderr: args['json'] as bool))
            .run(command, args);
      default:
        stderr.writeln('Unknown command "$command".\n\n$_usage${parser.usage}');
        return ExitCodes.usage;
    }
    return 0;
  } on ConsoleAbort {
    stdout.writeln('\nAborted.');
    return ExitCodes.interrupted;
  } on ConfigException catch (e) {
    stderr.writeln('Config error: $e');
    return ExitCodes.config;
  } on LedgerException catch (e) {
    stderr.writeln('$e');
    return ExitCodes.ledger;
  }
}
