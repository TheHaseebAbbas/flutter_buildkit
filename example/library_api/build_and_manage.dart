// Library API: the whole life of a build, from code.
//
//   dart run example/library_api/build_and_manage.dart
//
// Builds two flavors with a fake `flutter` (no SDK needed), lists the ledger,
// marks one build as published, then deletes both and shows what is kept.
import 'package:flutter_buildkit/flutter_buildkit.dart';

import '../_support/demo.dart';

Future<void> main() async {
  await withDemoProject((demo) async {
    final project = demo.project;
    final config = AppConfig.load(demo.dir);
    final ledger = await Ledger.open(config.ledgerPath);
    final fake = FakeFlutter(demo.dir);
    final builder = FlutterBuilder(
      project: project,
      config: config,
      ledger: ledger,
      runner: fake, // swap in the default ProcessRunner() for real builds
      log: (line) => print('  $line'.trimRight()),
    );

    title('Build every flavor as a release AAB');
    final version = project.version; // from pubspec.yaml: 1.2.0+42
    for (final flavor in project.flavors) {
      final record = await builder.build(BuildRequest(
        type: ArtifactType.aab,
        mode: BuildMode.release,
        flavor: flavor,
        target: project.defaultTarget(flavor),
        dartDefineFile: project.defineFileFor(flavor),
        versionName: version.name,
        versionCode: version.code,
        packageName: project.packageName(flavor),
      ));
      print('built ${record.id}  ->  ${record.outputDir}');
    }

    title('List the ledger (newest first)');
    print(renderTable(
      ['Flavor', 'Mode', 'Type', 'Version', 'Status', 'Size'],
      [
        for (final r in ledger.records)
          [
            r.flavorLabel,
            r.mode.name,
            r.type.name,
            r.version,
            r.status.code,
            formatBytes(r.totalSize),
          ],
      ],
    ));

    title('Mark the prod build as published');
    final manager = BuildManager(ledger);
    final prod = ledger.records.firstWhere((r) => r.flavor == 'prod');
    final published = await manager.markPublished(prod);
    print('${published.flavorLabel}: ${published.statusLabel}');

    title('Delete both builds');
    final result = await manager.delete(ledger.records);
    print('removed completely : ${result.deleted.map((r) => r.flavorLabel)}');
    print('files only (kept)  : ${result.filesOnly.map((r) => r.flavorLabel)}');
    print('rows left          : ${ledger.records.length}');
    print('A released build keeps its symbols and ledger row, so crashes from '
        'the field can still be traced.');
  });
}
