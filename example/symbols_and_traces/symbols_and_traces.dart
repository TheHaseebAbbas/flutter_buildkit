// Debug symbols and crash traces.
//
//   dart run example/symbols_and_traces/symbols_and_traces.dart
//
// Builds an obfuscated release with a fake `flutter`, then shows which
// commands would upload its symbols to Crashlytics and Sentry, which crash
// traces it can de-obfuscate, and how trace types are recognised. Nothing is
// uploaded and no external tool is started.
import 'package:flutter_buildkit/flutter_buildkit.dart';

import '../_support/demo.dart';

const dartTrace = '''
*** *** *** *** *** *** *** *** *** *** *** *** *** *** *** ***
pid: 1, tid: 2, name: 1.ui
build_id: 'abc123'
isolate_dso_base: 7f0000000000, vm_dso_base: 7f0000000000
    #00 abs 00007f0000123456 virt 0000000000123456 _kDartIsolateSnapshotInstructions+0x1234
''';

const javaTrace = '''
java.lang.NullPointerException
    at a.a.b(Unknown Source:3)
    at com.example.Foo.run(Foo.java:10)
''';

const nativeTrace = '''
backtrace:
    #00 pc 000000000001a2b4  /data/app/lib/arm64/libfoo.so (BuildId: 1234)
''';

Future<void> main() async {
  await withDemoProject((demo) async {
    // A config with Sentry and a Firebase app id for the dev flavor.
    final config = AppConfig.fromYaml(demo.dir, {
      'flavors': {
        'dev': {'firebase_app_id': '1:1234567890:android:abc123dev'},
      },
      'sentry': {'org': 'my-company', 'project': 'my-app'},
    });
    final ledger = await Ledger.open(config.ledgerPath);
    final project = demo.project;
    final version = project.version;

    final record = await FlutterBuilder(
      project: project,
      config: config,
      ledger: ledger,
      runner: FakeFlutter(demo.dir),
    ).build(BuildRequest(
      type: ArtifactType.aab,
      mode: BuildMode.release, // obfuscation only applies to profile/release
      flavor: 'dev',
      versionName: version.name,
      versionCode: version.code,
    ));
    print('obfuscated: ${record.obfuscated}, '
        'symbols: ${record.symbolsDir}, mapping: ${record.mappingFile}');

    title('Where would the symbols go? (dry run)');
    final uploader =
        SymbolUploader(project: project, config: config, ledger: ledger);
    for (final target in SymbolTargets.all) {
      for (final command in uploader.commandsFor(record, target)) {
        print('[$target] ${describeCommand(command)}'
            .replaceAll(ledger.rootDir, '<ledger folder>'));
      }
    }
    print('Crashlytics app id: ${uploader.crashlyticsAppId(record)}');

    title('Which traces can this build de-obfuscate?');
    final symbolicator = Symbolicator(config: config, ledger: ledger);
    for (final kind in symbolicator.availableKinds(record)) {
      print('- ${kind.label}');
    }

    title('Recognising a trace');
    for (final (name, text) in [
      ('dart', dartTrace),
      ('java', javaTrace),
      ('native', nativeTrace),
    ]) {
      print('$name sample -> ${detectTraceKind(text).name}');
    }
    print('ABI in the native sample: ${abiFromTrace('ABI: \'arm64\'')}');

    title('The command that would run for the Dart trace');
    final command =
        symbolicator.command(record, TraceKind.dart, 'crash.txt', dartTrace);
    print(
        describeCommand(command).replaceAll(ledger.rootDir, '<ledger folder>'));
  });
}
