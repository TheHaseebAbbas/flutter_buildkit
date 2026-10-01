import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../build_paths.dart';
import '../config.dart';
import '../flutter_project.dart';
import '../ledger/ledger.dart';
import '../model/build_options.dart';
import '../model/build_record.dart';
import 'process_runner.dart';

/// Everything the user chose for one build.
class BuildRequest {
  const BuildRequest({
    required this.type,
    required this.mode,
    required this.versionName,
    required this.versionCode,
    this.flavor,
    this.target,
    this.dartDefineFile,
    this.obfuscate = true,
    this.splitPerAbi = false,
    this.extraArgs = const [],
    this.packageName,
    this.notes,
  });

  final ArtifactType type;
  final BuildMode mode;
  final String? flavor;
  final String? target;
  final String? dartDefineFile;
  final String versionName;
  final int versionCode;
  final bool obfuscate;
  final bool splitPerAbi;
  final List<String> extraArgs;
  final String? packageName;
  final String? notes;

  /// Obfuscation is only valid for profile and release builds.
  bool get willObfuscate => obfuscate && mode.supportsObfuscation;
}

class BuildException implements Exception {
  BuildException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Arguments after the flutter executable, e.g.
/// `build appbundle --release --flavor dev -t lib/main_dev.dart ...`.
List<String> flutterBuildArgs(BuildRequest r, {String? symbolsDir}) => [
      'build',
      r.type.flutterCommand,
      '--${r.mode.name}',
      if (r.flavor != null) ...['--flavor', r.flavor!],
      if (r.target != null) ...['--target', r.target!],
      '--build-name=${r.versionName}',
      '--build-number=${r.versionCode}',
      if (r.dartDefineFile != null)
        '--dart-define-from-file=${r.dartDefineFile}',
      if (r.willObfuscate && symbolsDir != null) ...[
        '--obfuscate',
        '--split-debug-info=$symbolsDir',
      ],
      if (r.splitPerAbi && r.type == ArtifactType.apk) '--split-per-abi',
      ...r.extraArgs,
    ];

/// Runs `flutter build`, copies the outputs into the build folder tree and
/// records the build in the ledger.
class FlutterBuilder {
  FlutterBuilder({
    required this.project,
    required this.config,
    required this.ledger,
    this.runner = const ProcessRunner(),
    void Function(String)? log,
  }) : log = log ?? ((_) {});

  final FlutterProject project;
  final AppConfig config;
  final Ledger ledger;
  final ProcessRunner runner;
  final void Function(String) log;

  Future<BuildRecord> build(BuildRequest request) async {
    final started = DateTime.now();
    final appName = project.appName;
    final paths = BuildPaths(config.outputRoot);
    final outDir = paths.uniqueBuildDir(
      appName: appName,
      flavor: request.flavor,
      mode: request.mode,
      versionName: request.versionName,
      versionCode: request.versionCode,
      time: started,
    );
    await Directory(outDir).create(recursive: true);
    final symbolsDir =
        request.willObfuscate ? p.join(outDir, 'symbols', 'dart') : null;

    final command = [
      ...config.flutter,
      ...flutterBuildArgs(request, symbolsDir: symbolsDir),
    ];
    log('\$ ${describeCommand(command)}\n');
    final flutterVersion = await _flutterVersion();
    final int exitCode;
    try {
      exitCode = await runner.stream(command, workingDirectory: project.dir);
    } on ProcessException catch (e) {
      await _discard(outDir);
      throw BuildException('Could not start "${config.flutter.join(' ')}": '
          '${e.message}. Is Flutter on your PATH? Set "flutter:" in the config '
          'or FBL_FLUTTER otherwise.');
    }
    if (exitCode != 0) {
      await _discard(outDir);
      throw BuildException('flutter build failed with exit code $exitCode. '
          'Nothing was added to the ledger.');
    }

    final outputs = _findOutputs(request, since: started);
    if (outputs.isEmpty) {
      await _discard(outDir);
      throw BuildException('flutter build succeeded but no '
          '.${request.type.extension} newer than the build start was found '
          'under ${p.join(project.dir, 'build')}.');
    }

    final artifacts = <BuildArtifact>[];
    for (final source in outputs) {
      final name = BuildPaths.artifactName(
        appName: appName,
        flavor: request.flavor,
        mode: request.mode,
        versionName: request.versionName,
        versionCode: request.versionCode,
        type: request.type,
        suffix: outputs.length > 1 ? _abiSuffix(source.path) : null,
      );
      final dest = File(p.join(outDir, name));
      await source.copy(dest.path);
      artifacts.add(BuildArtifact(
        path: ledger.relativize(dest.path),
        sizeBytes: await dest.length(),
        sha256: (await sha256.bind(dest.openRead()).first).toString(),
      ));
    }

    String? mappingFile;
    final mapping = _findMapping(request, since: started);
    if (mapping != null) {
      final dest = p.join(outDir, 'symbols', 'mapping.txt');
      await Directory(p.dirname(dest)).create(recursive: true);
      await mapping.copy(dest);
      mappingFile = ledger.relativize(dest);
    }
    if (request.type == ArtifactType.ipa) {
      final dsyms = Directory(p.join(
          project.dir, 'build', 'ios', 'archive', 'Runner.xcarchive', 'dSYMs'));
      if (dsyms.existsSync()) {
        await copyDirectory(
            dsyms, Directory(p.join(outDir, 'symbols', 'dSYMs')));
      }
    }

    final (commit, branch) = await project.gitInfo();
    final record = BuildRecord(
      id: newBuildId(started),
      appName: appName,
      packageName: request.packageName,
      flavor: request.flavor,
      mode: request.mode,
      type: request.type,
      versionName: request.versionName,
      versionCode: request.versionCode,
      createdAt: started.toUtc(),
      target: request.target,
      outputDir: ledger.relativize(outDir),
      artifacts: artifacts,
      symbolsDir: Directory(p.join(outDir, 'symbols')).existsSync()
          ? ledger.relativize(p.join(outDir, 'symbols'))
          : null,
      mappingFile: mappingFile,
      obfuscated: request.willObfuscate,
      gitCommit: commit,
      gitBranch: branch,
      flutterVersion: flutterVersion,
      durationMs: DateTime.now().difference(started).inMilliseconds,
      notes: request.notes,
    );
    await File(p.join(outDir, 'build_info.json')).writeAsString(
        const JsonEncoder.withIndent('  ').convert(record.toJson()));
    await ledger.add(record);
    return record;
  }

  List<File> _findOutputs(BuildRequest r, {required DateTime since}) {
    final base = p.join(project.dir, 'build');
    final dirs = switch (r.type) {
      ArtifactType.apk => [p.join(base, 'app', 'outputs', 'flutter-apk')],
      ArtifactType.aab => [p.join(base, 'app', 'outputs', 'bundle')],
      ArtifactType.ipa => [p.join(base, 'ios', 'ipa')],
    };
    final cutoff = since.subtract(const Duration(seconds: 2));
    final found = <File>[];
    for (final d in dirs.map(Directory.new)) {
      if (!d.existsSync()) continue;
      for (final f in d.listSync(recursive: true).whereType<File>()) {
        if (p.extension(f.path) != '.${r.type.extension}') continue;
        if (f.lastModifiedSync().isBefore(cutoff)) continue;
        // flutter build apk also refreshes app.apk as a copy of the last
        // variant; skip it when the variant-named file is there too.
        if (p.basename(f.path) == 'app.apk' && r.flavor != null) continue;
        found.add(f);
      }
    }
    if (r.flavor != null) {
      final matching = found
          .where((f) => p
              .basename(f.path)
              .toLowerCase()
              .contains(r.flavor!.toLowerCase()))
          .toList();
      if (matching.isNotEmpty) return matching;
    }
    return found;
  }

  File? _findMapping(BuildRequest r, {required DateTime since}) {
    if (!r.type.isAndroid) return null;
    final variant =
        r.flavor == null ? r.mode.name : '${r.flavor}${r.mode.capitalized}';
    final f = File(p.join(project.dir, 'build', 'app', 'outputs', 'mapping',
        variant, 'mapping.txt'));
    if (!f.existsSync()) return null;
    return f
            .lastModifiedSync()
            .isBefore(since.subtract(const Duration(seconds: 2)))
        ? null
        : f;
  }

  Future<String?> _flutterVersion() async {
    try {
      final r = await runner.run([...config.flutter, '--version', '--machine'],
          workingDirectory: project.dir);
      final out = '${r.stdout}';
      final start = out.indexOf('{');
      if (r.exitCode != 0 || start < 0) return null;
      final json = jsonDecode(out.substring(start)) as Map<String, Object?>;
      return json['frameworkVersion'] as String?;
    } on Object {
      return null;
    }
  }

  Future<void> _discard(String outDir) async {
    final d = Directory(outDir);
    if (await d.exists()) await d.delete(recursive: true);
  }

  static String? _abiSuffix(String path) {
    final m = RegExp(r'(armeabi-v7a|arm64-v8a|x86_64|x86|universal)')
        .firstMatch(p.basename(path));
    return m?.group(1) ?? p.basenameWithoutExtension(path);
  }
}

/// `20261001-071230-a1b2`: sortable and unique enough for a local ledger.
String newBuildId(DateTime time) {
  final rand =
      Random.secure().nextInt(0x10000).toRadixString(16).padLeft(4, '0');
  return '${BuildPaths.timestamp(time)}-$rand';
}

Future<void> copyDirectory(Directory from, Directory to) async {
  await to.create(recursive: true);
  await for (final entity in from.list(recursive: true, followLinks: false)) {
    final target = p.join(to.path, p.relative(entity.path, from: from.path));
    if (entity is Directory) {
      await Directory(target).create(recursive: true);
    } else if (entity is File) {
      await Directory(p.dirname(target)).create(recursive: true);
      await entity.copy(target);
    }
  }
}
