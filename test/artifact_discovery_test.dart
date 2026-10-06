import 'dart:io';

import 'package:flutter_buildkit/flutter_buildkit.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// A fake `flutter` that runs [onBuild] instead of building.
class ScriptedFlutter extends ProcessRunner {
  ScriptedFlutter(this.onBuild);

  final void Function(String? logFile) onBuild;

  @override
  Future<int> stream(List<String> command,
      {String? workingDirectory,
      Map<String, String>? environment,
      String? logFile}) async {
    onBuild(logFile);
    return 0;
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
    tmp = Directory.systemTemp.createTempSync('fbk_discovery_');
    File(p.join(tmp.path, 'pubspec.yaml'))
        .writeAsStringSync('name: demo\nversion: 1.0.0+1\n');
    project = FlutterProject(tmp.path);
    config = AppConfig.fromYaml(tmp.path, const {});
    ledger = await Ledger.open(config.ledgerPath);
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  File write(String rel, [String content = 'x']) => File(p.join(tmp.path, rel))
    ..createSync(recursive: true)
    ..writeAsStringSync(content);

  Future<BuildRecord> build(
    void Function(String? logFile) onBuild, {
    String? flavor,
    bool split = false,
    ArtifactType type = ArtifactType.apk,
  }) =>
      FlutterBuilder(
              project: project,
              config: config,
              ledger: ledger,
              runner: ScriptedFlutter(onBuild))
          .build(BuildRequest(
              type: type,
              mode: BuildMode.release,
              flavor: flavor,
              versionName: '1.0.0',
              versionCode: 1,
              obfuscate: false,
              splitPerAbi: split));

  test('a flavor matches whole name parts, not substrings', () async {
    final record = await build((_) {
      write('build/app/outputs/flutter-apk/app-pro-release.apk', 'pro');
      write('build/app/outputs/flutter-apk/app-production-release.apk', 'prod');
    }, flavor: 'pro');
    expect(p.basename(record.artifacts.single.path), contains('pro-release'));
    expect(record.artifacts.single.sizeBytes, 3);
  });

  test('the Built line Flutter prints wins over guessing', () async {
    final record = await build((log) {
      write('build/app/outputs/flutter-apk/app-release.apk', 'a');
      write('build/app/outputs/flutter-apk/other-release.apk', 'bb');
      File(log!).writeAsStringSync(
          '✓ Built build/app/outputs/flutter-apk/other-release.apk '
          '(0.0MB)\n',
          mode: FileMode.append);
    });
    expect(record.artifacts.single.sizeBytes, 2);
  });

  test('several new files without split-per-abi fail instead of guessing',
      () async {
    await expectLater(build((_) {
      write('build/app/outputs/flutter-apk/app-release.apk');
      write('build/app/outputs/flutter-apk/stray-release.apk');
    }),
        throwsA(isA<BuildException>()
            .having((e) => e.message, 'message', contains('unclear'))));
    expect(ledger.records.single.status, BuildStatus.failed);
  });

  test('split-per-abi keeps every new APK', () async {
    final record = await build((_) {
      write('build/app/outputs/flutter-apk/app-arm64-v8a-release.apk');
      write('build/app/outputs/flutter-apk/app-x86_64-release.apk');
    }, split: true);
    expect(record.artifacts, hasLength(2));
  });

  test(
      'an unchanged file from an earlier build is ignored even if its time '
      'is recent', () async {
    write('build/app/outputs/flutter-apk/app-release.apk', 'old');
    await expectLater(build((_) {}), throwsA(isA<BuildException>()));
  });

  test('a file rewritten by the build is found even with the same size',
      () async {
    final old = write('build/app/outputs/flutter-apk/app-release.apk', 'old');
    old.setLastModifiedSync(DateTime.now().subtract(const Duration(days: 1)));
    final record = await build((_) {
      write('build/app/outputs/flutter-apk/app-release.apk', 'new');
    });
    expect(record.artifacts.single.sizeBytes, 3);
  });
}
