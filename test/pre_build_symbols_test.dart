import 'dart:io';

import 'package:flutter_buildkit/flutter_buildkit.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('fbl_pre_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  AppConfig cfg([Map<Object?, Object?> y = const {}]) =>
      AppConfig.fromYaml(tmp.path, y);

  group('pre-build plan', () {
    test('clean is always followed by pub get', () {
      final plan = planPreBuild(cfg(), [PreBuildStep.clean]);
      expect(plan.map((c) => c.label), ['flutter clean', 'flutter pub get']);
    });

    test('order: clean, pub get, build_runner, gen-l10n', () {
      final plan = planPreBuild(cfg(),
          [PreBuildStep.genL10n, PreBuildStep.buildRunner, PreBuildStep.clean]);
      expect(plan.map((c) => c.label), [
        'flutter clean',
        'flutter pub get',
        'build_runner build',
        'flutter gen-l10n',
      ]);
      expect(plan[2].command, [
        'dart',
        'run',
        'build_runner',
        'build',
      ]);
    });

    test('build_runner runs through dart, following the flutter command', () {
      List<String> cmd(String flutter) =>
          planPreBuild(cfg({'flutter': flutter}), [PreBuildStep.buildRunner])
              .single
              .command;
      expect(
          cmd('fvm flutter'), ['fvm', 'dart', 'run', 'build_runner', 'build']);
      expect(cmd('/sdk/bin/flutter'),
          ['/sdk/bin/dart', 'run', 'build_runner', 'build']);
    });

    test('uses the configured flutter command (fvm)', () {
      final plan =
          planPreBuild(cfg({'flutter': 'fvm flutter'}), [PreBuildStep.genL10n]);
      expect(plan.single.command, ['fvm', 'flutter', 'gen-l10n']);
    });

    test('no steps, no commands', () {
      expect(planPreBuild(cfg(), const []), isEmpty);
    });

    test('config sets which steps are ticked by default', () {
      final available = PreBuildStep.values;
      expect(defaultPreBuildSteps(cfg(), available),
          [PreBuildStep.buildRunner, PreBuildStep.genL10n]);
      expect(
          defaultPreBuildSteps(
              cfg({
                'pre_build': {'clean': true, 'build_runner': false}
              }),
              available),
          [PreBuildStep.clean, PreBuildStep.genL10n]);
    });

    test('build_runner and gen-l10n are offered only when used', () {
      File(p.join(tmp.path, 'pubspec.yaml')).writeAsStringSync(
          'name: a\ndev_dependencies:\n  build_runner: ^2.0.0\n');
      var project = FlutterProject(tmp.path);
      expect(availablePreBuildSteps(project),
          [PreBuildStep.clean, PreBuildStep.buildRunner]);

      File(p.join(tmp.path, 'l10n.yaml'))
          .writeAsStringSync('arb-dir: lib/l10n\n');
      expect(availablePreBuildSteps(project).last, PreBuildStep.genL10n);

      File(p.join(tmp.path, 'pubspec.yaml')).writeAsStringSync('name: a\n');
      File(p.join(tmp.path, 'l10n.yaml')).deleteSync();
      project = FlutterProject(tmp.path);
      expect(availablePreBuildSteps(project), [PreBuildStep.clean]);
    });

    test('flutter: generate: true counts as gen-l10n', () {
      File(p.join(tmp.path, 'pubspec.yaml'))
          .writeAsStringSync('name: a\nflutter:\n  generate: true\n');
      expect(FlutterProject(tmp.path).usesGenL10n, isTrue);
    });
  });

  group('trace detection', () {
    test('Dart AOT crash', () {
      expect(
          detectTraceKind(
              '*** *** *** *** *** ***\npid: 1, tid: 2\n#00 abs 000000 virt 0001 _kDartIsolateSnapshotInstructions+0x1'),
          TraceKind.dart);
    });

    test('Android Java stack', () {
      expect(
          detectTraceKind(
              'java.lang.NullPointerException\n\tat a.b.c(Unknown Source:3)'),
          TraceKind.java);
    });

    test('native tombstone', () {
      expect(
          detectTraceKind(
              'backtrace:\n  #00 pc 0000000000012345  /data/app/x/lib/arm64/libfoo.so (foo+4)'),
          TraceKind.native);
    });

    test('ABI line maps to the folder name', () {
      expect(abiFromTrace("ABI: 'arm64'"), 'arm64-v8a');
      expect(abiFromTrace("ABI: 'x86_64'"), 'x86_64');
      expect(abiFromTrace('nothing'), isNull);
    });
  });

  group('symbolicator commands', () {
    late Ledger ledger;
    late Symbolicator sym;
    late BuildRecord record;

    setUp(() async {
      ledger = Ledger(File(p.join(tmp.path, 'app_builds', 'ledger.json')));
      final dir =
          p.join(ledger.rootDir, 'a', 'dev', 'release', 'v1', 'symbols');
      for (final f in [
        'dart/app.android-arm64.symbols',
        'dart/app.android-arm.symbols',
        'mapping/mapping.txt',
        'native/arm64-v8a/libfoo.so',
        'native/armeabi-v7a/libfoo.so',
      ]) {
        File(p.join(dir, f)).createSync(recursive: true);
      }
      record = BuildRecord(
        id: 'a',
        appName: 'a',
        flavor: 'dev',
        mode: BuildMode.release,
        type: ArtifactType.aab,
        versionName: '1',
        versionCode: 1,
        createdAt: DateTime.utc(2026),
        outputDir: 'a/dev/release/v1',
        artifacts: const [],
        symbolsDir: 'a/dev/release/v1/symbols',
        mappingFile: 'a/dev/release/v1/symbols/mapping/mapping.txt',
        obfuscated: true,
      );
      sym = Symbolicator(config: cfg(), ledger: ledger, env: {'PATH': ''});
    });

    test('knows which traces the build can handle', () {
      expect(sym.availableKinds(record),
          [TraceKind.dart, TraceKind.java, TraceKind.native]);
    });

    test('Dart: picks the symbols file for the trace architecture', () {
      final cmd = sym.command(
          record, TraceKind.dart, '/t.txt', "ABI: 'arm64'\n#00 abs 1");
      expect(cmd.take(2), ['flutter', 'symbolize']);
      expect(cmd.last, endsWith('app.android-arm64.symbols'));
    });

    test('Dart: falls back to the folder when the architecture is unknown', () {
      final cmd = sym.command(record, TraceKind.dart, '/t.txt', '#00 abs 1');
      expect(cmd.last, endsWith(p.join('symbols', 'dart')));
    });

    test('native: picks the ABI folder named in the crash', () {
      final bin = Directory(p.join(tmp.path, 'bin'))..createSync();
      File(p.join(bin.path, 'ndk-stack')).createSync();
      final s =
          Symbolicator(config: cfg(), ledger: ledger, env: {'PATH': bin.path});
      final cmd = s.command(record, TraceKind.native, '/t.txt', "ABI: 'arm'");
      expect(cmd, contains('-sym'));
      expect(cmd[cmd.indexOf('-sym') + 1], endsWith('armeabi-v7a'));
    });

    test('java: finds retrace in the Android SDK', () {
      final tool =
          Directory(p.join(tmp.path, 'sdk', 'cmdline-tools', 'latest', 'bin'))
            ..createSync(recursive: true);
      File(p.join(tool.path, 'retrace')).createSync();
      final s = Symbolicator(
          config: cfg(),
          ledger: ledger,
          env: {'PATH': '', 'ANDROID_HOME': p.join(tmp.path, 'sdk')});
      final cmd = s.command(record, TraceKind.java, '/t.txt', 'at a.b(c)');
      expect(cmd.first, endsWith('retrace'));
      expect(cmd[1], endsWith('mapping.txt'));
    });

    test('a missing tool gives an actionable error', () {
      expect(() => sym.command(record, TraceKind.java, '/t.txt', 'x'),
          throwsA(isA<TraceException>()));
    });

    test('a build without symbols cannot be traced', () {
      final bare = BuildRecord(
        id: 'b',
        appName: 'a',
        mode: BuildMode.debug,
        type: ArtifactType.apk,
        versionName: '1',
        versionCode: 1,
        createdAt: DateTime.utc(2026),
        outputDir: 'b',
        artifacts: const [],
      );
      expect(sym.availableKinds(bare), isEmpty);
      expect(() => sym.command(bare, TraceKind.dart, '/t', 'x'),
          throwsA(isA<TraceException>()));
    });
  });
}
