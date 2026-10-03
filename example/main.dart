// A short tour of flutter_buildkit as a library. Run it with:
//
//   dart run example/main.dart
//
// flutter_buildkit is mostly used as a command line tool
// (`dart run flutter_buildkit` in a Flutter project), but everything the menu
// does is available from Dart. This file builds two flavors with a fake
// `flutter` (so no SDK is needed), lists the ledger and exports it. The other
// folders in this directory go deeper: see example/README.md.
import 'dart:io';

import 'package:flutter_buildkit/flutter_buildkit.dart';

import '_support/demo.dart';

Future<void> main() async {
  await withDemoProject((demo) async {
    final project = demo.project; // reads pubspec, Gradle flavors, main files
    final config =
        AppConfig.load(demo.dir); // flutter_buildkit.yaml or defaults
    final ledger = await Ledger.open(config.ledgerPath);
    final builder = FlutterBuilder(
      project: project,
      config: config,
      ledger: ledger,
      runner: FakeFlutter(demo.dir), // use the default ProcessRunner() for real
    );

    for (final flavor in project.flavors) {
      await builder.build(BuildRequest(
        type: ArtifactType.aab,
        mode: BuildMode.release,
        flavor: flavor,
        versionName: project.version.name,
        versionCode: project.version.code,
      ));
    }

    stdout.writeln(renderTable(
      ['Flavor', 'Version', 'Status', 'Folder'],
      [
        for (final r in ledger.records)
          [r.flavorLabel, r.version, r.status.code, r.outputDir],
      ],
    ));
    stdout.writeln(
        '\n${const LedgerExporter().toCsv(ledger.records).split('\n').first}');
  });
}
