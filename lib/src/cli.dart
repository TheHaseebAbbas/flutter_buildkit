import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;

import 'config.dart';
import 'entry_points.dart';
import 'flutter_project.dart';
import 'ledger/exporter.dart';
import 'ledger/ledger.dart';
import 'model/build_options.dart';
import 'model/build_record.dart';
import 'services/build_manager.dart';
import 'services/flutter_builder.dart';
import 'services/play_publisher.dart';
import 'services/pre_build.dart';
import 'services/process_runner.dart';
import 'services/symbol_uploader.dart';
import 'services/symbolicator.dart';
import 'ui/table.dart';

/// Exit codes of the command line app. They follow `sysexits.h` where one
/// fits and are stable, so scripts and CI can rely on them.
abstract final class ExitCodes {
  /// Success.
  static const ok = 0;

  /// Wrong command, option or build id.
  static const usage = 64;

  /// No Flutter project (`pubspec.yaml`) found.
  static const noProject = 66;

  /// An upload to Google Play, Crashlytics or Sentry failed.
  static const uploadFailed = 69;

  /// At least one build failed.
  static const buildFailed = 70;

  /// A crash trace could not be symbolicated.
  static const traceFailed = 71;

  /// A build could not be deleted.
  static const deleteFailed = 72;

  /// The file to create already exists.
  static const cantCreate = 73;

  /// The ledger could not be read or written.
  static const ledger = 74;

  /// The configuration is invalid.
  static const config = 78;

  /// Interrupted with Ctrl-C.
  static const interrupted = 130;
}

/// Adds the options of the non-interactive commands to [parser].
void addCommandOptions(ArgParser parser) {
  parser
    ..addFlag('json', negatable: false, help: 'Print machine readable JSON.')
    ..addFlag('yes',
        abbr: 'y',
        negatable: false,
        help: 'Confirm destructive or production actions (delete, publish to '
            'the production track).')
    ..addFlag('dry-run',
        negatable: false, help: 'Show what delete would do; change nothing.')
    ..addMultiOption('flavor',
        help: 'build: flavors to build ("none" for no flavor). '
            'list/export: filter.')
    ..addMultiOption('type',
        help: 'build: apk, aab or ipa (default apk).', splitCommas: true)
    ..addMultiOption('mode',
        help: 'build: release, profile or debug (default release).',
        splitCommas: true)
    ..addOption('version-name', help: 'build: default from pubspec.yaml.')
    ..addOption('build-number', help: 'build: default from pubspec.yaml.')
    ..addMultiOption('entry',
        help: 'build: named entry points (default: the first one).')
    ..addFlag('obfuscate',
        defaultsTo: true,
        help: 'build: obfuscate and keep Dart symbols (default: the config).')
    ..addFlag('split-per-abi',
        negatable: false, help: 'build: one APK per ABI.')
    ..addMultiOption('arg',
        help: 'build: extra argument for flutter build (repeatable).')
    ..addFlag('skip-pre-build',
        negatable: false,
        help: 'build: skip the pre-build steps from the config.')
    ..addOption('notes', help: 'build/publish: free note or release notes.')
    ..addOption('notes-file', help: 'publish: read release notes from a file.')
    ..addOption('track', help: 'publish: Play track (default: the config).')
    ..addOption('release-status',
        help: 'publish: draft, completed, inProgress or halted '
            '(default: the config).')
    ..addOption('fraction', help: 'publish: rollout fraction for inProgress.')
    ..addFlag('mark-only',
        negatable: false,
        help: 'publish: only record in the ledger that it was uploaded.')
    ..addFlag('clear',
        negatable: false, help: 'mark: clear the published mark.')
    ..addMultiOption('to',
        help: 'symbols: crashlytics, sentry (default: the enabled ones).',
        splitCommas: true)
    ..addOption('file', help: 'trace: stack trace file (default: stdin).')
    ..addOption('kind', help: 'trace: dart, java or native (default: detect).')
    ..addOption('save', help: 'trace: also write the result to a file.')
    ..addOption('status',
        help: 'list/export: only builds with this status '
            '(failed, built, uploaded, published).')
    ..addOption('since',
        help: 'list/export: newer than 7d, 12h, 30m or a date (2026-10-01).')
    ..addOption('limit', help: 'list/export: newest N builds.');
}

class _Usage implements Exception {
  _Usage(this.message);
  final String message;
}

/// The commands that work without a menu: they take their input from
/// options and arguments, never prompt, and return an [ExitCodes] value.
class Cli {
  /// Creates the command set.
  ///
  /// [project] and [config] are only needed by `build`, `publish`, `symbols`
  /// and `trace`; `list`, `export`, `mark` and `delete` work on the [ledger]
  /// alone. Output goes to [out] and [err] (stdout and stderr by default).
  Cli({
    required this.ledger,
    this.project,
    this.config,
    StringSink? out,
    StringSink? err,
    this.runner = const ProcessRunner(),
  })  : out = out ?? stdout,
        err = err ?? stderr;

  /// The ledger the commands work on.
  final Ledger ledger;

  /// The project, for commands that run Flutter.
  final FlutterProject? project;

  /// The settings, for commands that run tools.
  final AppConfig? config;

  /// Where results go.
  final StringSink out;

  /// Where messages and errors go.
  final StringSink err;

  /// Runs `flutter` and other tools. Use `ProcessRunner(outputToStderr: true)`
  /// with `--json` so tool output cannot mix into the JSON on stdout.
  final ProcessRunner runner;

  /// Names of the commands [run] understands.
  static const commands = {
    'build',
    'publish',
    'mark',
    'symbols',
    'trace',
    'delete',
    'list',
    'export',
  };

  /// Commands that need the project and configuration.
  static const needsProject = {'build', 'publish', 'symbols', 'trace'};

  late bool _json;

  /// Runs [command] with the parsed [args] (the command's own arguments are
  /// `args.rest.skip(1)`). Returns the exit code.
  Future<int> run(String command, ArgResults args) async {
    _json = args['json'] as bool;
    final rest = args.rest.skip(1).toList();
    try {
      return switch (command) {
        'build' => await _build(args),
        'publish' => await _publish(args, rest),
        'mark' => await _mark(args, rest),
        'symbols' => await _symbols(args, rest),
        'trace' => await _trace(args, rest),
        'delete' => await _delete(args, rest),
        'list' => _list(args),
        'export' => await _export(args, rest),
        _ => throw _Usage('Unknown command "$command".'),
      };
    } on _Usage catch (e) {
      err.writeln(e.message);
      return ExitCodes.usage;
    } on FormatException catch (e) {
      err.writeln(e.message);
      return ExitCodes.usage;
    }
  }

  AppConfig get _config => config ?? (throw _Usage('This needs a project.'));
  FlutterProject get _project =>
      project ?? (throw _Usage('This needs a Flutter project.'));

  void _say(String text) {
    if (!_json) out.writeln(text);
  }

  void _emit(Object? json) =>
      out.writeln(const JsonEncoder.withIndent('  ').convert(json));

  // ---- helpers -----------------------------------------------------------

  List<BuildRecord> _pick(List<String> ids, {bool allowLatest = true}) {
    if (ids.isEmpty) {
      throw _Usage('Give a build id (see "list"), or "latest".');
    }
    final records = ledger.records;
    return [
      for (final id in ids)
        if (id == 'latest' && allowLatest)
          records.where((r) => !r.isFailed).firstOrNull ??
              (throw _Usage('The ledger has no finished build.'))
        else if (ledger.byId(id) case final exact?)
          exact
        else
          switch (records.where((r) => r.id.startsWith(id)).toList()) {
            [final only] => only,
            [] => throw _Usage('No build with id "$id".'),
            final many => throw _Usage('"$id" matches ${many.length} builds; '
                'use more of the id.'),
          },
    ];
  }

  List<BuildRecord> _filtered(ArgResults a) {
    var records = ledger.records.toList();
    final flavors = a['flavor'] as List<String>;
    if (flavors.isNotEmpty) {
      records = [
        for (final r in records)
          if (flavors.contains(r.flavor ?? 'none') ||
              flavors.contains(r.flavorLabel))
            r,
      ];
    }
    if (a['status'] case final String status) {
      if (!BuildStatus.values.any((s) => s.code == status)) {
        throw _Usage('Unknown status "$status". Use '
            '${BuildStatus.values.map((s) => s.code).join(', ')}.');
      }
      records = [
        for (final r in records)
          if (r.status.code == status) r,
      ];
    }
    if (a['since'] case final String since) {
      final cutoff = _since(since);
      records = [
        for (final r in records)
          if (!r.createdAt.isBefore(cutoff)) r,
      ];
    }
    if (a['limit'] case final String limit) {
      final n = int.tryParse(limit);
      if (n == null || n < 0) throw _Usage('--limit needs a number.');
      records = records.take(n).toList();
    }
    return records;
  }

  static DateTime _since(String value) {
    final m = RegExp(r'^(\d+)([dhm])$').firstMatch(value);
    if (m != null) {
      final n = int.parse(m.group(1)!);
      final d = switch (m.group(2)) {
        'd' => Duration(days: n),
        'h' => Duration(hours: n),
        _ => Duration(minutes: n),
      };
      return DateTime.now().subtract(d).toUtc();
    }
    return DateTime.tryParse(value)?.toUtc() ??
        (throw _Usage('--since needs 7d, 12h, 30m or a date like 2026-10-01.'));
  }

  // ---- list and export ---------------------------------------------------

  int _list(ArgResults a) {
    final records = _filtered(a);
    if (_json) {
      _emit([for (final r in records) r.toJson()]);
      return ExitCodes.ok;
    }
    out.writeln(records.isEmpty
        ? 'No builds.'
        : renderTable([
            'ID',
            'Created',
            'Flavor',
            'Mode',
            'Type',
            'Version',
            'Size',
            'Status',
          ], [
            for (final r in records)
              [
                r.id,
                r.createdAt.toLocal().toIso8601String().substring(0, 16),
                r.flavorLabel,
                r.mode.name,
                r.type.name,
                r.version,
                r.artifactsDeleted || r.isFailed
                    ? '-'
                    : formatBytes(r.totalSize),
                r.status.code,
              ]
          ]));
    return ExitCodes.ok;
  }

  Future<int> _export(ArgResults a, List<String> rest) async {
    if (rest.isEmpty) throw _Usage('Usage: export <csv|tsv|json> [file]');
    final format = ExportFormat.values
        .where((f) => f.extension == rest.first.toLowerCase())
        .firstOrNull;
    if (format == null) {
      throw _Usage('Unknown format "${rest.first}". Use csv, tsv or json.');
    }
    final text = const LedgerExporter().export(_filtered(a), format);
    if (rest.length > 1) {
      final file = File(rest[1]);
      await file.parent.create(recursive: true);
      await file.writeAsString(text);
    } else {
      out.write(text);
    }
    return ExitCodes.ok;
  }

  // ---- mark and delete ---------------------------------------------------

  Future<int> _mark(ArgResults a, List<String> rest) async {
    final clear = a['clear'] as bool;
    final manager = BuildManager(ledger);
    final changed = <BuildRecord>[];
    for (final r in _pick(rest)) {
      if (r.isFailed) throw _Usage('${r.id} failed; nothing to publish.');
      changed.add(clear
          ? await manager.unmarkPublished(r)
          : await manager.markPublished(r));
    }
    if (_json) {
      _emit([for (final r in changed) r.toJson()]);
    } else {
      for (final r in changed) {
        out.writeln('${r.id}: ${clear ? 'published mark cleared' : 'marked '
            'published'}');
      }
    }
    return ExitCodes.ok;
  }

  Future<int> _delete(ArgResults a, List<String> rest) async {
    final dryRun = a['dry-run'] as bool;
    if (!dryRun && !(a['yes'] as bool)) {
      throw _Usage('delete removes files. Add --dry-run to see what would '
          'happen, or --yes to do it.');
    }
    final picks = _pick(rest, allowLatest: false);
    final result = await BuildManager(ledger).delete(picks, dryRun: dryRun);
    if (_json) {
      _emit({
        'dryRun': dryRun,
        'deleted': [for (final r in result.deleted) r.id],
        'filesOnly': [for (final r in result.filesOnly) r.id],
        'failed': {
          for (final e in result.failed.entries) e.key.id: '${e.value}',
        },
      });
    } else {
      final verb = dryRun ? 'Would delete' : 'Deleted';
      for (final r in result.deleted) {
        out.writeln('$verb ${ledger.resolve(r.outputDir)} and its ledger row');
      }
      for (final r in result.filesOnly) {
        out.writeln('$verb the files of released build ${r.id} '
            '(symbols and row stay)');
      }
      for (final e in result.failed.entries) {
        err.writeln('Could not delete ${e.key.id}: ${e.value}');
      }
    }
    return result.failed.isEmpty ? ExitCodes.ok : ExitCodes.deleteFailed;
  }

  // ---- publish, symbols, trace -------------------------------------------

  Future<int> _publish(ArgResults a, List<String> rest) async {
    final r = _pick(rest).single;
    final config = _config;
    final track = (a['track'] as String?) ?? config.play.defaultTrack;
    final status =
        (a['release-status'] as String?) ?? config.play.defaultReleaseStatus;
    if (!const ['draft', 'completed', 'inProgress', 'halted']
        .contains(status)) {
      throw _Usage('Unknown release status "$status".');
    }
    final fraction = a['fraction'] == null
        ? null
        : (double.tryParse(a['fraction'] as String) ??
            (throw _Usage('--fraction needs a number like 0.1.')));
    if (a['mark-only'] as bool) {
      final updated =
          await PlayPublisher(config: config, ledger: ledger).markUploaded(
        r,
        track: track,
      );
      _json
          ? _emit(updated.toJson())
          : out.writeln('${r.id}: marked as uploaded to $track');
      return ExitCodes.ok;
    }
    if (track == 'production' && !(a['yes'] as bool)) {
      throw _Usage('Publishing to the production track needs --yes.');
    }
    var notes = a['notes'] as String?;
    if (a['notes-file'] case final String path) {
      final file = File(path);
      if (!file.existsSync()) throw _Usage('Notes file not found: $path');
      notes = file.readAsStringSync();
    }
    try {
      final updated = await PlayPublisher(
              config: config, ledger: ledger, log: (l) => _log(l))
          .publish(r,
              track: track,
              releaseStatus: status,
              releaseNotes: notes,
              userFraction: fraction);
      _json
          ? _emit(updated.toJson())
          : out.writeln('${r.id}: uploaded to the $track track ($status)');
      return ExitCodes.ok;
    } on PlayException catch (e) {
      err.writeln('Google Play: $e');
      return ExitCodes.uploadFailed;
    }
  }

  void _log(String line) => (_json ? err : out).writeln(line);

  Future<int> _symbols(ArgResults a, List<String> rest) async {
    final r = _pick(rest).single;
    final config = _config;
    var targets = a['to'] as List<String>;
    if (targets.isEmpty) {
      targets = [
        if (config.crashlytics.enabled) SymbolTargets.crashlytics,
        if (config.sentry.enabled) SymbolTargets.sentry,
      ];
    }
    for (final t in targets) {
      if (!SymbolTargets.all.contains(t)) {
        throw _Usage('Unknown target "$t". Use '
            '${SymbolTargets.all.join(', ')}.');
      }
    }
    if (targets.isEmpty) throw _Usage('Both crash tools are disabled.');
    final uploader = SymbolUploader(
        project: _project,
        config: config,
        ledger: ledger,
        runner: runner,
        log: _log);
    var current = r;
    final failed = <String, String>{};
    for (final t in targets) {
      try {
        current = await uploader.upload(current, t);
        _say('${r.id}: symbols uploaded to $t');
      } on SymbolUploadException catch (e) {
        failed[t] = '$e';
        err.writeln('$t: $e');
      }
    }
    if (_json) {
      _emit({
        'id': r.id,
        'uploaded': current.symbolUploads.keys.toList()..sort(),
        'failed': failed
      });
    }
    return failed.isEmpty ? ExitCodes.ok : ExitCodes.uploadFailed;
  }

  Future<int> _trace(ArgResults a, List<String> rest) async {
    final r = _pick(rest).single;
    final String text;
    if (a['file'] case final String path) {
      final file = File(path);
      if (!file.existsSync()) throw _Usage('File not found: $path');
      text = file.readAsStringSync();
    } else {
      text = await _readStdin();
    }
    if (text.trim().isEmpty) throw _Usage('The stack trace is empty.');
    final kind = switch (a['kind'] as String?) {
      null => null,
      final k => TraceKind.values.where((t) => t.name == k).firstOrNull ??
          (throw _Usage('Unknown kind "$k". Use dart, java or native.')),
    };
    final symbolicator = Symbolicator(config: _config, ledger: ledger);
    try {
      final result = await symbolicator.trace(r, text, kind: kind);
      if (a['save'] case final String path) {
        await File(path).writeAsString('${result.output}\n');
      }
      if (_json) {
        _emit({
          'id': r.id,
          'kind': result.kind.name,
          'exitCode': result.exitCode,
          'output': result.output,
        });
      } else {
        out.writeln(result.output);
      }
      return result.exitCode == 0 ? ExitCodes.ok : ExitCodes.traceFailed;
    } on TraceException catch (e) {
      err.writeln('$e');
      return ExitCodes.traceFailed;
    }
  }

  static Future<String> _readStdin() async {
    final buffer = StringBuffer();
    await for (final chunk in stdin.transform(utf8.decoder)) {
      buffer.write(chunk);
    }
    return buffer.toString();
  }

  // ---- build -------------------------------------------------------------

  Future<int> _build(ArgResults a) async {
    final project = _project;
    final config = _config;

    var flavors = <String?>[
      for (final f in a['flavor'] as List<String>) f == 'none' ? null : f,
    ];
    if (flavors.isEmpty) {
      if (project.flavors.isNotEmpty) {
        throw _Usage('Pass --flavor with one or more of '
            '${project.flavors.join(', ')} (or "none").');
      }
      flavors = [null];
    } else {
      for (final f in flavors.whereType<String>()) {
        if (project.flavors.isNotEmpty && !project.flavors.contains(f)) {
          err.writeln('Note: "$f" is not among the detected flavors '
              '(${project.flavors.join(', ')}).');
        }
      }
    }
    final types = [
      for (final t in (a['type'] as List<String>).isEmpty
          ? const ['apk']
          : a['type'] as List<String>)
        ArtifactType.parse(t),
    ];
    if (types.contains(ArtifactType.ipa) && !Platform.isMacOS) {
      throw _Usage('IPA builds need macOS.');
    }
    final modes = [
      for (final m in (a['mode'] as List<String>).isEmpty
          ? const ['release']
          : a['mode'] as List<String>)
        BuildMode.parse(m),
    ];
    final current = project.version;
    final versionName = (a['version-name'] as String?) ?? current.name;
    final versionCode = a['build-number'] == null
        ? current.code
        : (int.tryParse(a['build-number'] as String) ??
            (throw _Usage('--build-number needs a whole number.')));
    final obfuscate =
        a.wasParsed('obfuscate') ? a['obfuscate'] as bool : config.obfuscate;
    final splitPerAbi = (a['split-per-abi'] as bool) || config.splitPerAbi;
    final wantedEntries = a['entry'] as List<String>;

    final requests = <BuildRequest>[];
    for (final flavor in flavors) {
      var entries = entryPointsFor(config, project, flavor);
      if (wantedEntries.isEmpty) {
        entries = entries.take(1).toList();
      } else {
        entries = [
          for (final e in entries)
            if (wantedEntries.contains(e.name ?? 'default')) e,
        ];
        for (final w in wantedEntries) {
          if (!entries.any((e) => (e.name ?? 'default') == w)) {
            err.writeln('Note: ${flavor ?? 'default'} has no entry point '
                '"$w"; skipped.');
          }
        }
      }
      final fc = config.flavor(flavor);
      for (final entry in entries) {
        for (final type in types) {
          for (final mode in modes) {
            requests.add(BuildRequest(
              type: type,
              mode: mode,
              flavor: flavor,
              target: entry.path,
              entryPoint: entry.name,
              dartDefineFile: fc.dartDefineFile,
              versionName: versionName,
              versionCode: versionCode,
              obfuscate: obfuscate,
              splitPerAbi: splitPerAbi && type == ArtifactType.apk,
              extraArgs: [
                ...config.extraBuildArgs,
                ...(a['arg'] as List<String>),
                ...fc.extraArgs,
              ],
              packageName: type.isAndroid
                  ? (fc.packageName ?? project.packageName(flavor))
                  : null,
              notes: a['notes'] as String?,
            ));
          }
        }
      }
    }
    if (requests.isEmpty) throw _Usage('Nothing to build.');

    final streamRunner = runner;
    var ran = const <String>[];
    if (!(a['skip-pre-build'] as bool)) {
      final steps =
          defaultPreBuildSteps(config, availablePreBuildSteps(project));
      if (steps.isNotEmpty) {
        try {
          ran = await PreBuildRunner(
                  project: project,
                  config: config,
                  runner: streamRunner,
                  log: _log)
              .run(steps);
        } on PreBuildException catch (e) {
          err.writeln('$e');
          return ExitCodes.buildFailed;
        }
      }
    }

    final builder = FlutterBuilder(
        project: project,
        config: config,
        ledger: ledger,
        runner: streamRunner,
        log: _log);
    final done = <BuildRecord>[];
    final failed = <Map<String, String>>[];
    for (final r in requests) {
      final label = '${r.flavor ?? 'default'} ${r.mode.name} ${r.type.name}'
          '${r.entryPoint == null ? '' : ' ${r.entryPoint}'}';
      _log('\n== Building $label');
      try {
        done.add(await builder.build(BuildRequest(
          type: r.type,
          mode: r.mode,
          flavor: r.flavor,
          target: r.target,
          entryPoint: r.entryPoint,
          dartDefineFile: r.dartDefineFile,
          versionName: r.versionName,
          versionCode: r.versionCode,
          obfuscate: r.obfuscate,
          splitPerAbi: r.splitPerAbi,
          extraArgs: r.extraArgs,
          packageName: r.packageName,
          preBuild: ran,
          notes: r.notes,
        )));
      } on BuildException catch (e) {
        failed.add({'build': label, 'message': e.message});
        err.writeln('FAILED $label: ${e.message}');
      }
    }
    if (_json) {
      _emit({
        'built': [for (final r in done) r.toJson()],
        'failed': failed,
      });
    } else {
      out.writeln('\n${done.length} built, ${failed.length} failed');
      for (final r in done) {
        out.writeln('  ${r.id}  ${p.normalize(ledger.resolve(r.outputDir))}');
      }
    }
    return failed.isEmpty ? ExitCodes.ok : ExitCodes.buildFailed;
  }
}
