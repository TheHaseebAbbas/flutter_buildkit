import 'dart:io';

import 'package:flutter_buildkit/flutter_buildkit.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Pretends to be flutter: writes the files a release build would produce.
class FakeFlutter extends ProcessRunner {
  FakeFlutter(this.projectDir, {this.exitCode = 0});

  final String projectDir;
  final int exitCode;
  final List<List<String>> commands = [];

  void _write(String rel, [String content = 'x']) {
    final f = File(p.join(projectDir, rel))..createSync(recursive: true);
    f.writeAsStringSync(content);
  }

  @override
  Future<int> stream(List<String> command,
      {String? workingDirectory, Map<String, String>? environment}) async {
    commands.add(command);
    if (command.contains('build') && exitCode == 0) {
      final symbols = command
          .firstWhere((a) => a.startsWith('--split-debug-info='))
          .split('=')
          .last;
      File(p.join(symbols, 'app.android-arm64.symbols'))
          .createSync(recursive: true);
      _write('build/app/outputs/bundle/devRelease/app-dev-release.aab', 'aab');
      _write('build/app/outputs/mapping/devRelease/mapping.txt');
      _write('build/app/outputs/mapping/devRelease/usage.txt');
      _write(
          'build/app/intermediates/merged_native_libs/devRelease/mergeDevReleaseNativeLibs/out/lib/arm64-v8a/libfoo.so');
    }
    return exitCode;
  }

  @override
  Future<ProcessResult> run(List<String> command,
          {String? workingDirectory, Map<String, String>? environment}) async =>
      ProcessResult(0, 0, '{"frameworkVersion":"9.9.9"}', '');
}

void main() {
  late Directory tmp;
  late FlutterProject project;
  late AppConfig config;
  late Ledger ledger;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('fbl_builder_');
    File(p.join(tmp.path, 'pubspec.yaml'))
        .writeAsStringSync('name: demo\nversion: 1.2.0+5\n');
    project = FlutterProject(tmp.path);
    config = AppConfig.fromYaml(tmp.path, const {});
    ledger = await Ledger.open(config.ledgerPath);
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  const request = BuildRequest(
    type: ArtifactType.aab,
    mode: BuildMode.release,
    flavor: 'dev',
    versionName: '1.2.0',
    versionCode: 5,
    packageName: 'com.demo.dev',
    preBuild: ['flutter clean', 'flutter pub get'],
  );

  test('stores artifact, Dart, native and mapping symbols and the ledger row',
      () async {
    final builder = FlutterBuilder(
        project: project,
        config: config,
        ledger: ledger,
        runner: FakeFlutter(tmp.path));
    final record = await builder.build(request);

    final dir = ledger.resolve(record.outputDir);
    expect(p.split(record.outputDir), containsAllInOrder(['dev', 'release']));
    expect(p.split(record.outputDir), isNot(contains('demo')));
    final artifacts = Directory(p.join(dir, 'artifacts'))
        .listSync()
        .map((e) => p.basename(e.path))
        .toList();
    expect(artifacts, hasLength(1));
    expect(artifacts.single,
        matches(RegExp(r'^demo-dev-release-1\.2\.0-b5-\d{8}-\d{6}\.aab$')));
    expect(p.basename(dir), matches(RegExp(r'^1\.2\.0-b5-\d{8}-\d{6}$')));
    expect(
        File(p.join(dir, 'symbols', 'dart', 'app.android-arm64.symbols'))
            .existsSync(),
        isTrue);
    expect(File(p.join(dir, 'symbols', 'mapping', 'mapping.txt')).existsSync(),
        isTrue);
    expect(File(p.join(dir, 'symbols', 'mapping', 'usage.txt')).existsSync(),
        isTrue);
    expect(
        File(p.join(dir, 'symbols', 'native', 'arm64-v8a', 'libfoo.so'))
            .existsSync(),
        isTrue);
    expect(record.mappingFile, endsWith('symbols/mapping/mapping.txt'));
    expect(record.symbolsDir, endsWith('symbols'));
    expect(record.preBuild, ['flutter clean', 'flutter pub get']);
    expect(record.flutterVersion, '9.9.9');
    expect(record.artifacts.single.sha256, isNotEmpty);
    expect(ledger.records, hasLength(1));
  });

  test('a failed build leaves no folder and no ledger row', () async {
    final builder = FlutterBuilder(
        project: project,
        config: config,
        ledger: ledger,
        runner: FakeFlutter(tmp.path, exitCode: 1));
    await expectLater(builder.build(request), throwsA(isA<BuildException>()));
    expect(ledger.records, isEmpty);
    expect(Directory(p.join(config.outputRoot, 'demo')).existsSync(), isFalse);
  });

  test('outputs left over from an earlier build are not picked up', () async {
    final stale = File(p.join(
        tmp.path, 'build/app/outputs/bundle/devRelease/old-dev-release.aab'))
      ..createSync(recursive: true);
    stale
        .setLastModifiedSync(DateTime.now().subtract(const Duration(hours: 1)));
    final builder = FlutterBuilder(
        project: project,
        config: config,
        ledger: ledger,
        runner: FakeFlutter(tmp.path));
    final record = await builder.build(request);
    expect(record.artifacts, hasLength(1));
    expect(record.artifacts.single.path, isNot(contains('old')));
  });

  test('pre-build runner stops at the first failing command', () async {
    final fake = FakeFlutter(tmp.path, exitCode: 2);
    final runner =
        PreBuildRunner(project: project, config: config, runner: fake);
    await expectLater(runner.run([PreBuildStep.clean, PreBuildStep.genL10n]),
        throwsA(isA<PreBuildException>()));
    expect(fake.commands, hasLength(1));
  });

  test('pre-build runner returns the labels it ran', () async {
    final fake = FakeFlutter(tmp.path);
    final ran =
        await PreBuildRunner(project: project, config: config, runner: fake)
            .run([PreBuildStep.clean, PreBuildStep.genL10n]);
    expect(ran, ['flutter clean', 'flutter pub get', 'flutter gen-l10n']);
  });
}
