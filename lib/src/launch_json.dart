import 'jsonc.dart';

/// One Dart/Flutter configuration read from `.vscode/launch.json`.
class LaunchConfig {
  /// Creates a configuration; only [name] is required.
  const LaunchConfig({
    required this.name,
    this.program,
    this.mode,
    this.flavor,
    this.dartDefineFile,
    this.args = const [],
  });

  /// The configuration's `name` as shown in VS Code.
  final String name;

  /// `program`, or null when the configuration runs `lib/main.dart`.
  final String? program;

  /// `flutterMode`: debug, profile or release.
  final String? mode;

  /// Value of `--flavor` in the arguments.
  final String? flavor;

  /// Value of `--dart-define-from-file` in the arguments.
  final String? dartDefineFile;

  /// All `args` and `toolArgs` entries, as strings.
  final List<String> args;

  /// What makes two configurations run the same thing, whatever they are
  /// called.
  String get identity => [
        flavor ?? '',
        mode ?? 'debug',
        (program ?? 'lib/main.dart').replaceAll(r'\', '/'),
        dartDefineFile ?? '',
      ].join('|');
}

/// Reads the `dart` configurations of a launch.json text (JSONC: comments
/// and trailing commas are fine). Throws [FormatException] for invalid text.
List<LaunchConfig> parseLaunchConfigs(String text) {
  final doc = decodeJsonc(text);
  if (doc is! Map || doc['configurations'] is! List) return const [];
  final out = <LaunchConfig>[];
  for (final c in doc['configurations'] as List) {
    if (c is! Map || c['type'] != 'dart') continue;
    final args = [
      for (final key in ['args', 'toolArgs'])
        if (c[key] is List) ...[for (final a in c[key] as List) '$a'],
    ];
    String? flavor;
    String? define;
    for (var i = 0; i < args.length; i++) {
      final a = args[i];
      if (a == '--flavor' && i + 1 < args.length) flavor = args[i + 1];
      if (a.startsWith('--flavor=')) flavor = a.substring('--flavor='.length);
      if (a == '--dart-define-from-file' && i + 1 < args.length) {
        define = args[i + 1];
      }
      if (a.startsWith('--dart-define-from-file=')) {
        define = a.substring('--dart-define-from-file='.length);
      }
    }
    String? program = c['program'] as String?;
    if (program != null) {
      program =
          program.replaceAll(r'${workspaceFolder}/', '').replaceAll(r'\', '/');
      if (program == 'lib/main.dart') program = null;
    }
    out.add(LaunchConfig(
      name: '${c['name'] ?? ''}',
      program: program,
      mode: c['flutterMode'] as String?,
      flavor: flavor,
      dartDefineFile: define?.replaceAll(r'\', '/'),
      args: args,
    ));
  }
  return out;
}
