import 'dart:io';

import 'package:args/args.dart';
import 'package:flutter_buildkit/flutter_buildkit.dart';
import 'package:path/path.dart' as p;

const _usage = '''
flutter_buildkit: build Flutter apps and keep a ledger of the builds.

Usage: flutter_buildkit [options] [command]

Commands:
  (none)   Open the interactive menu.
  init     Write a starter flutter_buildkit.yaml in the project.
  list     Print the ledger as a table.
  export   Write the ledger as csv, tsv or json: export <format> [file]

Options:
''';

Future<int> main(List<String> arguments) async {
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

  final ArgResults args;
  try {
    args = parser.parse(arguments);
  } on FormatException catch (e) {
    stderr.writeln('${e.message}\n\n$_usage${parser.usage}');
    return 64;
  }
  if (args['help'] as bool) {
    stdout.writeln('$_usage${parser.usage}');
    return 0;
  }

  final projectDir = p.normalize(p.absolute(args['project'] as String));
  final project = FlutterProject(projectDir);
  final command = args.rest.isEmpty ? null : args.rest.first;

  if (command == 'init') {
    final target = File(p.join(projectDir, AppConfig.fileNames.first));
    if (target.existsSync()) {
      stderr.writeln('${target.path} already exists.');
      return 1;
    }
    target.writeAsStringSync(AppConfig.template);
    stdout.writeln(
        'Wrote ${target.path}. Add it to .gitignore if it holds secrets.');
    return 0;
  }

  if (!project.isFlutterProject) {
    stderr.writeln('No pubspec.yaml in $projectDir. Run this from a Flutter '
        'project or pass --project.');
    return 66;
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
                console: Console(mode: ui))
            .run();
      case 'list':
        final records = ledger.records;
        stdout.writeln(records.isEmpty
            ? 'The ledger is empty.'
            : renderTable([
                'ID',
                'Created',
                'Flavor',
                'Mode',
                'Type',
                'Version',
                'Size'
              ], [
                for (final r in records)
                  [
                    r.id,
                    r.createdAt.toLocal().toIso8601String().substring(0, 16),
                    r.flavorLabel,
                    r.mode.name,
                    r.type.name,
                    r.version,
                    formatBytes(r.totalSize),
                  ]
              ]));
      case 'export':
        if (args.rest.length < 2) {
          stderr.writeln('Usage: export <csv|tsv|json> [file]');
          return 64;
        }
        final format = ExportFormat.values
            .where((f) => f.extension == args.rest[1].toLowerCase())
            .firstOrNull;
        if (format == null) {
          stderr.writeln(
              'Unknown format "${args.rest[1]}". Use csv, tsv or json.');
          return 64;
        }
        final text = const LedgerExporter().export(ledger.records, format);
        if (args.rest.length > 2) {
          await File(args.rest[2]).writeAsString(text);
        } else {
          stdout.write(text);
        }
      default:
        stderr.writeln('Unknown command "$command".\n\n$_usage${parser.usage}');
        return 64;
    }
    return 0;
  } on ConsoleAbort {
    stdout.writeln('\nAborted.');
    return 130;
  } on ConfigException catch (e) {
    stderr.writeln('Config error: $e');
    return 78;
  } on LedgerException catch (e) {
    stderr.writeln('$e');
    return 74;
  }
}
