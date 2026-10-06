import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../build_paths.dart';
import '../config.dart';
import '../dart_entries.dart';
import '../flutter_project.dart';
import '../ledger/ledger.dart';
import '../model/build_options.dart';
import '../model/build_record.dart';
import 'build_inspector.dart';
import 'process_runner.dart';

/// Everything the user chose for one build.
class BuildRequest {
  /// Creates a build request; [type], [mode], [versionName] and [versionCode] are required.
  const BuildRequest({
    required this.type,
    required this.mode,
    required this.versionName,
    required this.versionCode,
    this.flavor,
    this.target,
    this.entryPoint,
    this.dartDefineFile,
    this.obfuscate = true,
    this.splitPerAbi = false,
    this.extraArgs = const [],
    this.packageName,
    this.preBuild = const [],
    this.notes,
  });

  /// Artifact to build (apk, aab, ...), passed to `flutter build <type>`.
  final ArtifactType type;

  /// Build mode, passed as `--debug`, `--profile` or `--release`.
  final BuildMode mode;

  /// Flavor passed to `--flavor`, or null for none.
  final String? flavor;

  /// Dart entry file passed to `--target`, or null for the default.
  final String? target;

  /// Name of the entry point, when a named one is built.
  final String? entryPoint;

  /// File passed to `--dart-define-from-file`, or null.
  final String? dartDefineFile;

  /// Value for `--build-name`.
  final String versionName;

  /// Value for `--build-number`.
  final int versionCode;

  /// Whether to request `--obfuscate`; see [willObfuscate] for the effective value.
  final bool obfuscate;

  /// Whether to pass `--split-per-abi` (APK builds only).
  final bool splitPerAbi;

  /// Additional raw arguments appended to the `flutter build` command.
  final List<String> extraArgs;

  /// Application id of the built app, recorded in the ledger, or null.
  final String? packageName;

  /// Labels of the pre-build steps that ran, for the ledger.
  final List<String> preBuild;

  /// Free-form note stored with the build in the ledger.
  final String? notes;

  /// Obfuscation is only valid for profile and release builds.
  bool get willObfuscate => obfuscate && mode.supportsObfuscation;
}

/// Thrown when a build cannot be run or `flutter build` fails.
class BuildException implements Exception {
  /// Creates an exception carrying [message].
  BuildException(this.message);

  /// Human-readable description of what went wrong.
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

/// Name of the file in each build folder that holds the `flutter build` output.
const buildLogName = 'build.log';

/// Name of the file in each build folder that holds the ledger row.
const buildInfoName = 'build_info.json';

/// Runs `flutter build`, copies the outputs into the build folder tree and
/// records the build in the ledger.
class FlutterBuilder {
  /// Creates a builder for [project] using [config] and [ledger]; [runner] runs `flutter` and [log] receives output lines.
  FlutterBuilder({
    required this.project,
    required this.config,
    required this.ledger,
    this.runner = const ProcessRunner(),
    void Function(String)? log,
  }) : log = log ?? ((_) {});

  /// Project being built; its directory is the working directory for `flutter`.
  final FlutterProject project;

  /// Configuration (flutter command, output layout and root).
  final AppConfig config;

  /// Ledger that records each finished build.
  final Ledger ledger;

  /// Runs the `flutter build` process.
  final ProcessRunner runner;

  /// Receives progress and process output lines.
  final void Function(String) log;

  /// Builds [request] with `flutter build`, copies outputs into the build folder and records it in the ledger.
  ///
  /// Returns the stored [BuildRecord]. Throws [BuildException] if the build fails.
  Future<BuildRecord> build(BuildRequest request) async {
    final started = DateTime.now();
    final appName = project.appName;
    final paths = BuildPaths(config.outputRoot,
        layout: config.effectiveLayout, fileName: config.fileName);
    BuildNaming naming(ArtifactType type) => BuildNaming(
          appName: appName,
          flavor: request.flavor,
          mode: request.mode,
          versionName: request.versionName,
          versionCode: request.versionCode,
          time: started,
          type: type,
          entry: request.entryPoint,
        );
    // Pick the id first, so a collision cannot surface after the build.
    final id = _freshId(started);
    final outDir = paths.uniqueBuildDir(naming(request.type));
    await Directory(outDir).create(recursive: true);
    InterruptGuard.protect(outDir);
    try {
      return await _run(request, started, id, outDir, paths, naming);
    } finally {
      InterruptGuard.release(outDir);
    }
  }

  String _freshId(DateTime started) {
    var id = newBuildId(started);
    while (ledger.byId(id) != null) {
      id = newBuildId(started);
    }
    return id;
  }

  Future<BuildRecord> _run(
    BuildRequest request,
    DateTime started,
    String id,
    String outDir,
    BuildPaths paths,
    BuildNaming Function(ArtifactType) naming,
  ) async {
    final symbolsDir = request.willObfuscate
        ? p.join(outDir, BuildPaths.symbolsFolder, 'dart')
        : null;

    final command = [
      ...config.flutter,
      ...flutterBuildArgs(request, symbolsDir: symbolsDir),
    ];
    final commandLine = describeCommand(command);
    log('\$ $commandLine\n');
    final logFile = p.join(outDir, buildLogName);
    await File(logFile).writeAsString('\$ $commandLine\n');
    final flutterInfo = await _flutterInfo();
    final flutterVersion = flutterInfo['frameworkVersion'] as String?;
    final before = _snapshot(request.type);
    final int exitCode;
    try {
      exitCode = await runner.stream(command,
          workingDirectory: project.dir, logFile: logFile);
    } on ProcessException catch (e) {
      await _discard(outDir);
      throw BuildException('Could not start "${config.flutter.join(' ')}": '
          '${e.message}. Is Flutter on your PATH? Set "flutter:" in the config '
          'or FBK_FLUTTER otherwise.');
    }
    Future<Never> fail(BuildFailure failure) async {
      await _recordFailure(
          request, id, started, outDir, commandLine, failure, flutterVersion);
      throw BuildException('${failure.message} The log is in '
          '${p.join(outDir, buildLogName)}.');
    }

    if (exitCode != 0) {
      await fail(BuildFailure(
          exitCode, 'flutter build failed with exit code $exitCode.'));
    }

    final List<File> outputs;
    try {
      outputs = _findOutputs(request, before: before, logFile: logFile);
    } on BuildException catch (e) {
      await fail(BuildFailure(0, e.message));
    }
    if (outputs.isEmpty) {
      await fail(BuildFailure(
          0,
          'flutter build succeeded but no new or changed '
          '.${request.type.extension} was found under '
          '${p.join(project.dir, 'build')}.'));
    }

    final artifacts = <BuildArtifact>[];
    for (final source in outputs) {
      final name = paths.artifactFileName(naming(request.type),
          suffix: outputs.length > 1 ? _abiSuffix(source.path) : null);
      final dest = File(p.join(outDir, BuildPaths.artifactsFolder, name));
      await dest.parent.create(recursive: true);
      await source.copy(dest.path);
      artifacts.add(BuildArtifact(
        path: ledger.relativize(dest.path),
        sizeBytes: await dest.length(),
        sha256: (await sha256.bind(dest.openRead()).first).toString(),
      ));
    }

    String? mappingFile;
    if (request.type.isAndroid) {
      mappingFile = await _storeAndroidSymbols(request, outDir, started);
    }
    if (request.type == ArtifactType.ipa) {
      final dsyms = Directory(p.join(
          project.dir, 'build', 'ios', 'archive', 'Runner.xcarchive', 'dSYMs'));
      if (dsyms.existsSync()) {
        await copyDirectory(dsyms,
            Directory(p.join(outDir, BuildPaths.symbolsFolder, 'dSYMs')));
      }
    }

    final (commit, branch) = await project.gitInfo();
    final signing = request.type.isAndroid
        ? await SigningInspector(runner)
            .inspect(File(ledger.resolve(artifacts.first.path)))
        : null;
    _checkSigning(request, signing);
    final buildIds = symbolsDir == null
        ? const <String, String>{}
        : dartBuildIds(Directory(symbolsDir));
    if (request.willObfuscate && buildIds.isEmpty) {
      log('Warning: no Dart build id could be read from the symbols; crash '
          'reports cannot be matched to this build automatically.');
    }
    final record = BuildRecord(
      id: id,
      appName: project.appName,
      packageName: request.packageName,
      flavor: request.flavor,
      mode: request.mode,
      type: request.type,
      versionName: request.versionName,
      versionCode: request.versionCode,
      createdAt: started.toUtc(),
      target: request.target,
      entryPoint: request.entryPoint,
      outputDir: ledger.relativize(outDir),
      artifacts: artifacts,
      signing: signing,
      buildIds: buildIds,
      environment: await _environment(request, flutterInfo),
      symbolsDir:
          Directory(p.join(outDir, BuildPaths.symbolsFolder)).existsSync()
              ? ledger.relativize(p.join(outDir, BuildPaths.symbolsFolder))
              : null,
      mappingFile: mappingFile,
      obfuscated: request.willObfuscate,
      gitCommit: commit,
      gitBranch: branch,
      flutterVersion: flutterVersion,
      durationMs: DateTime.now().difference(started).inMilliseconds,
      preBuild: request.preBuild,
      notes: request.notes,
      command: commandLine,
    );
    await File(p.join(outDir, buildInfoName)).writeAsString(
        const JsonEncoder.withIndent('  ').convert(record.toJson()));
    await ledger.add(record);
    return record;
  }

  /// Keeps the folder (with `build.log`) and adds a `failed` row, so a
  /// failed build is not silently forgotten.
  Future<void> _recordFailure(
    BuildRequest request,
    String id,
    DateTime started,
    String outDir,
    String commandLine,
    BuildFailure failure,
    String? flutterVersion,
  ) async {
    final (commit, branch) = await project.gitInfo();
    final record = BuildRecord(
      id: id,
      appName: project.appName,
      packageName: request.packageName,
      flavor: request.flavor,
      mode: request.mode,
      type: request.type,
      versionName: request.versionName,
      versionCode: request.versionCode,
      createdAt: started.toUtc(),
      target: request.target,
      entryPoint: request.entryPoint,
      outputDir: ledger.relativize(outDir),
      artifacts: const [],
      obfuscated: request.willObfuscate,
      gitCommit: commit,
      gitBranch: branch,
      flutterVersion: flutterVersion,
      durationMs: DateTime.now().difference(started).inMilliseconds,
      preBuild: request.preBuild,
      notes: request.notes,
      failure: failure,
      command: commandLine,
    );
    await File(p.join(outDir, buildInfoName)).writeAsString(
        const JsonEncoder.withIndent('  ').convert(record.toJson()));
    await ledger.add(record);
  }

  List<String> _outputDirs(ArtifactType type) {
    final base = p.join(project.dir, 'build');
    return switch (type) {
      ArtifactType.apk => [p.join(base, 'app', 'outputs', 'flutter-apk')],
      ArtifactType.aab => [p.join(base, 'app', 'outputs', 'bundle')],
      ArtifactType.ipa => [p.join(base, 'ios', 'ipa')],
    };
  }

  /// Path, modification time and size of every output-type file now in the
  /// build output folders. Taken before `flutter build`, so afterwards the
  /// files this build wrote can be told from older ones by what changed, not
  /// by comparing clocks.
  Map<String, (int, int)> _snapshot(ArtifactType type) {
    final result = <String, (int, int)>{};
    for (final d in _outputDirs(type).map(Directory.new)) {
      if (!d.existsSync()) continue;
      for (final f in d.listSync(recursive: true).whereType<File>()) {
        if (p.extension(f.path) != '.${type.extension}') continue;
        final stat = f.statSync();
        result[p.normalize(f.path)] =
            (stat.modified.millisecondsSinceEpoch, stat.size);
      }
    }
    return result;
  }

  /// The files this build produced.
  ///
  /// First choice is what Flutter itself reported (`Built <path>` lines in
  /// [logFile]). Otherwise the files that are new or changed since [before]
  /// are used, narrowed to the requested flavor by matching whole name parts
  /// (`dev` matches `app-dev-release.apk`, not `app-device-release.apk`).
  /// Throws [BuildException] when more than one candidate is left and the
  /// build was not split per ABI, instead of guessing.
  List<File> _findOutputs(BuildRequest r,
      {required Map<String, (int, int)> before, String? logFile}) {
    final ext = '.${r.type.extension}';
    final reported = <File>[];
    if (logFile != null && File(logFile).existsSync()) {
      final built = RegExp(r'Built\s+(\S.*?\.' + r.type.extension + r')\b');
      for (final line in File(logFile).readAsLinesSync()) {
        final m = built.firstMatch(line);
        if (m == null) continue;
        final file = File(p.normalize(p.absolute(project.dir, m.group(1))));
        if (file.existsSync() && !reported.any((f) => f.path == file.path)) {
          reported.add(file);
        }
      }
    }
    if (reported.isNotEmpty) return reported;

    final found = <File>[];
    for (final d in _outputDirs(r.type).map(Directory.new)) {
      if (!d.existsSync()) continue;
      for (final f in d.listSync(recursive: true).whereType<File>()) {
        if (p.extension(f.path) != ext) continue;
        final stat = f.statSync();
        final old = before[p.normalize(f.path)];
        if (old != null &&
            old.$1 == stat.modified.millisecondsSinceEpoch &&
            old.$2 == stat.size) {
          continue;
        }
        // flutter build apk also refreshes app.apk as a copy of the last
        // variant; skip it when the variant-named file is there too.
        if (p.basename(f.path) == 'app.apk' && r.flavor != null) continue;
        found.add(f);
      }
    }
    var candidates = found;
    if (r.flavor != null) {
      final flavor = r.flavor!.toLowerCase();
      final matching = found
          .where((f) => p
              .basenameWithoutExtension(f.path)
              .toLowerCase()
              .split(RegExp(r'[-_.]'))
              .contains(flavor))
          .toList();
      if (matching.isNotEmpty) candidates = matching;
    }
    if (candidates.length > 1 &&
        !(r.splitPerAbi && r.type == ArtifactType.apk)) {
      throw BuildException('flutter build succeeded but more than one '
          '$ext file is new, so the right one is unclear: '
          '${candidates.map((f) => p.basename(f.path)).join(', ')}.');
    }
    return candidates;
  }

  /// [t] cut to whole seconds, so file systems with 1 s timestamps still see
  /// this build's outputs as new, while earlier builds' files stay old.
  static DateTime _wholeSecond(DateTime t) =>
      DateTime.fromMillisecondsSinceEpoch(
          t.millisecondsSinceEpoch ~/ 1000 * 1000);

  /// Gradle variant name: `release`, or `devRelease` for flavor `dev`.
  static String variantName(BuildRequest r) =>
      r.flavor == null ? r.mode.name : '${r.flavor}${r.mode.capitalized}';

  /// The folder under [parent] whose name is [variant], matched ignoring case
  /// and punctuation (Gradle spells multi-dimension variants its own way,
  /// such as `devFreeRelease`). Falls back to [variant] itself.
  static String _existingVariant(String parent, String variant) {
    final dir = Directory(parent);
    if (!dir.existsSync()) return variant;
    final want = normalizeName(variant);
    for (final e in dir.listSync()) {
      final name = p.basename(e.path);
      if (e is Directory && (name == variant || normalizeName(name) == want)) {
        return name;
      }
    }
    return variant;
  }

  /// Copies the R8/ProGuard output (`mapping.txt`, `usage.txt`, `seeds.txt`,
  /// ...) to `symbols/mapping/` and the unstripped native libraries to
  /// `symbols/native/`. Returns the ledger path of `mapping.txt`, if any.
  Future<String?> _storeAndroidSymbols(
      BuildRequest r, String outDir, DateTime since) async {
    final cutoff = _wholeSecond(since);
    final intermediates = p.join(project.dir, 'build', 'app');
    final variant = _existingVariant(
        p.join(intermediates, 'outputs', 'mapping'), variantName(r));

    String? mappingFile;
    final mappingDir =
        Directory(p.join(intermediates, 'outputs', 'mapping', variant));
    final mappingTxt = File(p.join(mappingDir.path, 'mapping.txt'));
    if (mappingTxt.existsSync() &&
        !mappingTxt.lastModifiedSync().isBefore(cutoff)) {
      final dest =
          Directory(p.join(outDir, BuildPaths.symbolsFolder, 'mapping'));
      await copyDirectory(mappingDir, dest);
      mappingFile = ledger.relativize(p.join(dest.path, 'mapping.txt'));
    }

    // AGP 7/8 write native libraries to .../out/lib/<abi>/*.so.
    final native = Directory(
        p.join(intermediates, 'intermediates', 'merged_native_libs', variant));
    if (native.existsSync()) {
      for (final entity in native.listSync(recursive: true)) {
        if (entity is Directory &&
            p.split(entity.path).reversed.take(2).toList().join('/') ==
                'lib/out') {
          await copyDirectory(entity,
              Directory(p.join(outDir, BuildPaths.symbolsFolder, 'native')));
        }
      }
    }
    return mappingFile;
  }

  /// `flutter --version --machine` as a map; empty when it cannot be read.
  Future<Map<String, Object?>> _flutterInfo() async {
    try {
      final r = await runner.run([...config.flutter, '--version', '--machine'],
          workingDirectory: project.dir);
      final out = '${r.stdout}';
      final start = out.indexOf('{');
      if (r.exitCode != 0 || start < 0) return const {};
      return (jsonDecode(out.substring(start)) as Map).cast<String, Object?>();
    } on Object {
      return const {};
    }
  }

  /// Where the build ran, for reproducing it later.
  Future<Map<String, String>> _environment(
      BuildRequest request, Map<String, Object?> info) async {
    String? defineHash;
    final defineFile = request.dartDefineFile;
    if (defineFile != null) {
      final f = File(p.isAbsolute(defineFile)
          ? defineFile
          : p.join(project.dir, defineFile));
      if (f.existsSync()) {
        defineHash = (await sha256.bind(f.openRead()).first).toString();
      }
    }
    final values = <String, String?>{
      'os': '${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
      'host': Platform.localHostname,
      'flutterChannel': info['channel'] as String?,
      'flutterRevision': info['frameworkRevisionShort'] as String? ??
          info['frameworkRevision'] as String?,
      'dartSdk': info['dartSdkVersion'] as String?,
      'engineRevision': info['engineRevision'] as String?,
      'dartDefineFileSha256': defineHash,
    };
    return {
      for (final e in values.entries)
        if (e.value != null && e.value!.isNotEmpty) e.key: e.value!,
    };
  }

  /// Warns about a debug-signed release build, or a certificate that
  /// differs from the app's earlier release builds.
  void _checkSigning(BuildRequest request, BuildSigning? signing) {
    if (signing == null) return;
    if (request.mode == BuildMode.release && signing.debugKey) {
      log('Warning: this release build is signed with the Android DEBUG key. '
          'Google Play will reject it; check the release signing config.');
    }
    final earlier = ledger.records
        .where((r) =>
            !r.isFailed &&
            r.mode == BuildMode.release &&
            r.packageName != null &&
            r.packageName == request.packageName &&
            r.signing != null)
        .toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    if (earlier.isNotEmpty &&
        request.mode == BuildMode.release &&
        earlier.first.signing!.sha256 != signing.sha256) {
      log('Warning: the signing certificate (${signing.sha256.substring(0, 16)}...) '
          'differs from build ${earlier.first.id} '
          '(${earlier.first.signing!.sha256.substring(0, 16)}...).');
    }
  }

  Future<void> _discard(String outDir) async {
    final d = Directory(outDir);
    if (await d.exists()) await d.delete(recursive: true);
    await pruneEmptyParents(config.outputRoot, d.parent);
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

/// Recursively copies the contents of [from] into [to], creating [to] if needed.
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
