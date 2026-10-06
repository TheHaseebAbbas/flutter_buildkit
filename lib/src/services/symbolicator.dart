import 'dart:io';

import 'package:path/path.dart' as p;

import '../config.dart';
import '../ledger/ledger.dart';
import '../model/build_record.dart';
import 'process_runner.dart';

/// Kind of stack trace to de-obfuscate.
enum TraceKind {
  /// Obfuscated Dart stack trace: `flutter symbolize`.
  dart('Dart (flutter symbolize, from split-debug-info)'),

  /// Obfuscated Java/Kotlin trace: R8 `retrace` with mapping.txt.
  java('Android Java/Kotlin (R8 retrace, from mapping.txt)'),

  /// Native crash (tombstone): `ndk-stack` with unstripped libraries.
  native('Native C/C++ (ndk-stack, from unstripped libraries)');

  const TraceKind(this.label);

  /// Description shown to the user.
  final String label;
}

/// Thrown when a trace cannot be symbolicated, e.g. symbols are missing.
class TraceException implements Exception {
  /// Creates an exception carrying [message].
  TraceException(this.message);

  /// Human-readable description of what went wrong.
  final String message;
  @override
  String toString() => message;
}

/// Outcome of one symbolication run.
class TraceResult {
  /// Creates a result for [kind], the [command] that ran, its [output] and [exitCode].
  const TraceResult(this.kind, this.command, this.output, this.exitCode);

  /// Kind of trace that was processed.
  final TraceKind kind;

  /// Command line that was executed.
  final List<String> command;

  /// Combined output of the command.
  final String output;

  /// Exit code of the command; non-zero means failure.
  final int exitCode;
}

/// The Dart `build_id` a crash report names (`build_id: 'abc...'`), or null.
String? traceBuildId(String text) =>
    RegExp(r'''build_id:\s*['"]?([0-9a-fA-F]{8,})''')
        .firstMatch(text)
        ?.group(1)
        ?.toLowerCase();

/// The build that produced the crash in [text], by Dart build id first, then
/// by a `versionName+versionCode` that appears in the report. Null when
/// nothing matches or several builds share the version.
BuildRecord? matchBuild(Iterable<BuildRecord> records, String text) {
  final id = traceBuildId(text);
  if (id != null) {
    final byId = records.where((r) => r.buildIds.values.contains(id)).toList();
    if (byId.isNotEmpty) return byId.first;
  }
  final byVersion = records
      .where((r) =>
          !r.isFailed &&
          RegExp('\\b${RegExp.escape(r.versionName)}\\s*[+(]\\s*'
                  '${r.versionCode}\\b')
              .hasMatch(text))
      .toList();
  return byVersion.length == 1 ? byVersion.single : null;
}

/// A warning when the trace's build id is not one of [r]'s, or null when it
/// matches or the trace names none.
String? buildMismatchWarning(BuildRecord r, String text) {
  final id = traceBuildId(text);
  if (id == null || r.buildIds.values.contains(id)) return null;
  return r.buildIds.isEmpty
      ? 'The trace has build_id $id but build ${r.id} has no recorded build '
          'id, so the match cannot be checked.'
      : 'The trace has build_id $id, which is not one of build ${r.id}\'s '
          '(${r.buildIds.values.join(', ')}). The frames below may be wrong.';
}

/// Guesses what kind of stack trace [text] is.
TraceKind detectTraceKind(String text) {
  if (RegExp(r'\*\*\* \*\*\* \*\*\*|build_id:|isolate_dso_base|#\d+\s+abs ')
      .hasMatch(text)) {
    return TraceKind.dart;
  }
  if (RegExp(r'#\d+\s+pc [0-9a-fA-F]+\s+\S+\.so').hasMatch(text) ||
      text.contains('backtrace:')) {
    return TraceKind.native;
  }
  if (RegExp(r'^\s*at [\w.$<>]+\(', multiLine: true).hasMatch(text)) {
    return TraceKind.java;
  }
  return TraceKind.dart;
}

/// The Android ABI folder name for a crash's `ABI: 'arm64'` line, or null.
String? abiFromTrace(String text) {
  final m = RegExp(r'''ABI:\s*['"]?([\w-]+)''').firstMatch(text);
  if (m == null) return null;
  return switch (m.group(1)) {
    'arm64' || 'arm64-v8a' => 'arm64-v8a',
    'arm' || 'armeabi-v7a' => 'armeabi-v7a',
    'x86_64' => 'x86_64',
    'x86' => 'x86',
    _ => null,
  };
}

/// Picks the split-debug-info file for the trace's architecture, or the
/// folder itself when it can't tell (flutter symbolize accepts both).
String pickDartSymbols(String dartSymbolsDir, String traceText) {
  final files = Directory(dartSymbolsDir)
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.symbols'))
      .toList();
  if (files.length == 1) return files.first.path;
  final arch = switch (abiFromTrace(traceText)) {
    'arm64-v8a' => 'arm64',
    'armeabi-v7a' => 'arm',
    'x86_64' => 'x64',
    _ => null,
  };
  if (arch != null) {
    for (final f in files) {
      if (p.basename(f.path).contains(arch)) return f.path;
    }
  }
  return dartSymbolsDir;
}

/// De-obfuscates stack traces with the symbols stored for a build.
class Symbolicator {
  /// Creates a symbolicator for [config] and [ledger]; [runner] executes the tools and [env] defaults to the process environment.
  Symbolicator({
    required this.config,
    required this.ledger,
    this.runner = const ProcessRunner(),
    Map<String, String>? env,
  }) : env = env ?? Platform.environment;

  /// Configuration for locating tools.
  final AppConfig config;

  /// Ledger used to resolve a build's stored symbol paths.
  final Ledger ledger;

  /// Runs `flutter symbolize`, `retrace` or `ndk-stack`.
  final ProcessRunner runner;

  /// Environment variables used to find the Android SDK/NDK.
  final Map<String, String> env;

  /// Kinds of trace this build has the symbols for.
  List<TraceKind> availableKinds(BuildRecord r) {
    String? sub(String name) {
      if (r.symbolsDir == null) return null;
      final d = p.join(ledger.resolve(r.symbolsDir!), name);
      return Directory(d).existsSync() ? d : null;
    }

    final mapping = r.mappingFile != null &&
        File(ledger.resolve(r.mappingFile!)).existsSync();
    return [
      if (sub('dart') != null) TraceKind.dart,
      if (mapping) TraceKind.java,
      if (sub('native') != null) TraceKind.native,
    ];
  }

  /// The command that symbolizes [traceFile] for [kind].
  List<String> command(
      BuildRecord r, TraceKind kind, String traceFile, String traceText) {
    final symbols = r.symbolsDir == null ? null : ledger.resolve(r.symbolsDir!);
    switch (kind) {
      case TraceKind.dart:
        final dir = symbols == null ? null : p.join(symbols, 'dart');
        if (dir == null || !Directory(dir).existsSync()) {
          throw TraceException('Build ${r.id} has no Dart symbols. Only '
              'obfuscated profile/release builds keep them.');
        }
        return [
          ...config.flutter,
          'symbolize',
          '-i',
          traceFile,
          '-d',
          pickDartSymbols(dir, traceText),
        ];
      case TraceKind.java:
        final mapping =
            r.mappingFile == null ? null : ledger.resolve(r.mappingFile!);
        if (mapping == null || !File(mapping).existsSync()) {
          throw TraceException('Build ${r.id} has no R8 mapping.txt '
              '(minification was off, or it was not a release build).');
        }
        final tool = findAndroidTool('retrace', config.androidRetrace);
        return [tool, mapping, traceFile];
      case TraceKind.native:
        final dir = symbols == null ? null : p.join(symbols, 'native');
        if (dir == null || !Directory(dir).existsSync()) {
          throw TraceException('Build ${r.id} has no native libraries stored.');
        }
        final abis = Directory(dir)
            .listSync()
            .whereType<Directory>()
            .map((d) => p.basename(d.path))
            .toList();
        final wanted = abiFromTrace(traceText);
        final abi = abis.contains(wanted)
            ? wanted!
            : (abis.isEmpty ? null : abis.first);
        final tool = findAndroidTool('ndk-stack', config.androidNdkStack);
        return [
          tool,
          '-sym',
          abi == null ? dir : p.join(dir, abi),
          '-dump',
          traceFile,
        ];
    }
  }

  /// Symbolizes [traceText] with the symbols of [record].
  Future<TraceResult> trace(BuildRecord record, String traceText,
      {TraceKind? kind}) async {
    kind ??= detectTraceKind(traceText);
    final tmp = await Directory.systemTemp.createTemp('fbl_trace_');
    try {
      final file = File(p.join(tmp.path, 'trace.txt'));
      await file.writeAsString(traceText);
      final cmd = command(record, kind, file.path, traceText);
      final ProcessResult result;
      try {
        result = await runner.run(cmd);
      } on ProcessException catch (e) {
        throw TraceException('Could not start ${cmd.first}: ${e.message}.');
      }
      final out = '${result.stdout}${result.stderr}'.trimRight();
      return TraceResult(kind, cmd, out, result.exitCode);
    } finally {
      await tmp.delete(recursive: true);
    }
  }

  /// Finds an Android SDK/NDK tool: [override], then PATH, then the SDK
  /// (`cmdline-tools/*/bin`, `ndk/*`).
  String findAndroidTool(String name, String? override) {
    if (override != null && override.isNotEmpty) return override;
    final exts = Platform.isWindows ? ['', '.bat', '.exe', '.cmd'] : [''];
    bool exists(String dir) =>
        exts.any((e) => File(p.join(dir, '$name$e')).existsSync());

    final sep = Platform.isWindows ? ';' : ':';
    for (final dir in (env['PATH'] ?? '').split(sep)) {
      if (dir.isNotEmpty && exists(dir)) return p.join(dir, name);
    }
    final sdk = env['ANDROID_HOME'] ?? env['ANDROID_SDK_ROOT'];
    final ndk = env['ANDROID_NDK_HOME'];
    final candidates = <String>[
      if (ndk != null) ndk,
      if (sdk != null) ...[
        ..._children(p.join(sdk, 'cmdline-tools')).map((d) => p.join(d, 'bin')),
        ..._children(p.join(sdk, 'ndk')),
      ],
    ];
    for (final dir in candidates.reversed) {
      if (exists(dir)) return p.join(dir, name);
    }
    throw TraceException('$name was not found. Install the Android '
        '${name == 'retrace' ? 'command-line tools' : 'NDK'}, set '
        'ANDROID_HOME, or set android.$name in the config.');
  }

  static List<String> _children(String dir) {
    final d = Directory(dir);
    if (!d.existsSync()) return const [];
    return d.listSync().whereType<Directory>().map((e) => e.path).toList()
      ..sort();
  }
}
