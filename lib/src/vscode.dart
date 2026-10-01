import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'config.dart';
import 'entry_points.dart';
import 'flutter_project.dart';
import 'jsonc.dart';
import 'launch_json.dart';

/// Thrown when launch.json cannot be read or changed safely.
class LaunchJsonException implements Exception {
  /// Creates an exception carrying a human-readable [message].
  LaunchJsonException(this.message);

  /// Explains what went wrong and that the file was left untouched.
  final String message;
  @override
  String toString() => message;
}

/// One run configuration to add to `.vscode/launch.json`.
class LaunchEntry {
  /// Creates an entry; [name] and [mode] are required.
  const LaunchEntry({
    required this.name,
    required this.mode,
    this.flavor,
    this.program,
    this.dartDefineFile,
  });

  /// Name shown in VS Code's run menu.
  final String name;

  /// debug, profile or release.
  final String mode;

  /// Value passed as `--flavor`, or null when the project has no flavors.
  final String? flavor;

  /// Entry point; null runs `lib/main.dart`.
  final String? program;

  /// Path to a `--dart-define-from-file` file, or null for none.
  final String? dartDefineFile;

  /// Command-line arguments: `--flavor` and `--dart-define-from-file` when set.
  List<String> get args => [
        if (flavor != null) ...['--flavor', flavor!],
        if (dartDefineFile != null) '--dart-define-from-file=$dartDefineFile',
      ];

  /// This entry as a [LaunchConfig], so it can be compared with existing ones.
  LaunchConfig get asConfig => LaunchConfig(
        name: name,
        program: program,
        mode: mode,
        flavor: flavor,
        dartDefineFile: dartDefineFile,
        args: args,
      );

  /// The configuration as JSON text, keys at [indent] spaces.
  String render(int indent, String nl) {
    final pad = ' ' * indent;
    final inner = ' ' * (indent + 2);
    String s(String v) => jsonEncode(v);
    final lines = [
      '$inner"name": ${s(name)}',
      '$inner"request": "launch"',
      '$inner"type": "dart"',
      if (program != null) '$inner"program": ${s(program!)}',
      '$inner"flutterMode": ${s(mode)}',
      '$inner"args": [${args.map(s).join(', ')}]',
    ];
    return '$pad{$nl${lines.join(',$nl')}$nl$pad}';
  }
}

/// Run modes written to launch.json, in order.
const launchModes = ['debug', 'profile', 'release'];

/// `clientDb` and `pre_prod` become `CLIENT DB` and `PRE PROD`.
String launchLabel(String s) => s
    .replaceAllMapped(RegExp(r'([a-z0-9])([A-Z])'), (m) => '${m[1]} ${m[2]}')
    .replaceAll(RegExp(r'[_\-\s]+'), ' ')
    .trim()
    .toUpperCase();

/// The run configurations for the project: every flavor × entry point ×
/// mode, with the flavor's dart-define file. `program` is only set for an
/// entry point other than `lib/main.dart`.
List<LaunchEntry> launchEntriesFor(AppConfig config, FlutterProject project) {
  final flavors = {...project.flavors, ...config.flavors.keys}.toList()..sort();
  final out = <LaunchEntry>[];
  final names = <String>{};

  void add(String base, String mode, String? flavor, EntryPoint entry,
      String? define) {
    final label =
        entry.name == null ? base : '$base ${launchLabel(entry.name!)}';
    var name = '$label - ${mode.toUpperCase()}';
    for (var i = 2; !names.add(name.toLowerCase()); i++) {
      name = '$label ($i) - ${mode.toUpperCase()}';
    }
    final path = entry.path?.replaceAll(r'\', '/');
    out.add(LaunchEntry(
      name: name,
      mode: mode,
      flavor: flavor,
      program: path == null || path == 'lib/main.dart' ? null : path,
      dartDefineFile: define,
    ));
  }

  if (flavors.isEmpty) {
    for (final entry in entryPointsFor(config, project, null)) {
      for (final mode in launchModes) {
        add(launchLabel(project.appName), mode, null, entry, null);
      }
    }
    return out;
  }
  for (final f in flavors) {
    final define = config.flavor(f).dartDefineFile ?? project.defineFileFor(f);
    for (final entry in entryPointsFor(config, project, f)) {
      for (final mode in launchModes) {
        add(launchLabel(f), mode, f, entry, define);
      }
    }
  }
  return out;
}

/// What writing launch.json would do.
class LaunchPlan {
  /// Creates a plan from the [existing] text and the [add] and [skipped] entries.
  LaunchPlan({
    required this.existing,
    required this.add,
    required this.skipped,
  });

  /// The current text, or null when the file does not exist.
  final String? existing;

  /// Entries that will be added to launch.json.
  final List<LaunchEntry> add;

  /// Entries left out because launch.json already has them (same name, or
  /// the same flavor, mode, program and define file).
  final List<LaunchEntry> skipped;
}

/// Works out which entries to add to the project's launch.json.
///
/// Throws [LaunchJsonException] when the existing file is not valid JSONC.
LaunchPlan planLaunchJson(AppConfig config, FlutterProject project) {
  final file = launchJsonFile(project);
  final existing = file.existsSync() ? file.readAsStringSync() : null;
  final wanted = launchEntriesFor(config, project);
  if (existing == null || existing.trim().isEmpty) {
    return LaunchPlan(existing: existing, add: wanted, skipped: const []);
  }
  final List<LaunchConfig> have;
  try {
    have = parseLaunchConfigs(existing);
  } on FormatException catch (e) {
    throw LaunchJsonException('${file.path} is not valid JSON ($e). Fix it '
        'first; it was left untouched.');
  }
  final names = {for (final c in have) c.name.toLowerCase()};
  final identities = {for (final c in have) c.identity};
  final add = <LaunchEntry>[];
  final skipped = <LaunchEntry>[];
  for (final e in wanted) {
    if (names.contains(e.name.toLowerCase()) ||
        identities.contains(e.asConfig.identity)) {
      skipped.add(e);
    } else {
      add.add(e);
    }
  }
  return LaunchPlan(existing: existing, add: add, skipped: skipped);
}

/// The `.vscode/launch.json` file of [project]; it may not exist.
File launchJsonFile(FlutterProject project) =>
    File(p.join(project.dir, '.vscode', 'launch.json'));

/// [existing] with [entries] added to its `configurations`, keeping
/// everything else (comments, formatting, other configurations). With no
/// existing text a new file is made.
String mergeLaunchJson(String? existing, List<LaunchEntry> entries) {
  if (existing == null || existing.trim().isEmpty) {
    final body = entries.map((e) => e.render(6, '\n')).join(',\n');
    return '{\n  "version": "0.2.0",\n  "configurations": [\n$body\n  ]\n}\n';
  }
  if (entries.isEmpty) return existing;
  final nl = existing.contains('\r\n') ? '\r\n' : '\n';
  final text = existing;
  final arr = findArray(text, 'configurations');
  if (arr == null) {
    throw LaunchJsonException('launch.json has no "configurations" array, so '
        'nothing was changed.');
  }
  final (open, close) = arr;
  final scan = JsoncScan(text);

  // Indent like the existing configurations, else 4 spaces.
  var indent = 4;
  for (var i = open + 1; i < close; i++) {
    if (scan.code[i] && text[i] == '{') {
      final lineStart = text.lastIndexOf('\n', i) + 1;
      indent = i - lineStart;
      break;
    }
  }
  final blocks = entries.map((e) => e.render(indent, nl)).join(',$nl');
  final last = scan.lastSignificant(open + 1, close);
  if (last < 0) {
    // Empty array.
    return '${text.substring(0, open + 1)}$nl$blocks$nl${' ' * (indent - 2).clamp(0, 99)}${text.substring(close)}';
  }
  final comma = text[last] == ',' ? '' : ',';
  return '${text.substring(0, last + 1)}$comma$nl$blocks${text.substring(last + 1)}';
}

/// Writes [text] to `.vscode/launch.json`, keeping the old file as
/// `launch.json.bak` once.
void writeLaunchJson(FlutterProject project, String text) {
  final f = launchJsonFile(project);
  f.parent.createSync(recursive: true);
  if (f.existsSync()) {
    final bak = File('${f.path}.bak');
    if (!bak.existsSync()) f.copySync(bak.path);
  }
  final tmp = File('${f.path}.tmp')..writeAsStringSync(text);
  tmp.renameSync(f.path);
}
