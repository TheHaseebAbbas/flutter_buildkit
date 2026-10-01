import 'dart:io';

import 'package:path/path.dart' as p;

import 'config.dart';
import 'flutter_project.dart';
import 'ledger/exporter.dart';
import 'ledger/ledger.dart';
import 'model/build_options.dart';
import 'model/build_record.dart';
import 'services/build_manager.dart';
import 'services/flutter_builder.dart';
import 'services/play_publisher.dart';
import 'services/pre_build.dart';
import 'services/symbol_uploader.dart';
import 'services/symbolicator.dart';
import 'ui/console.dart';
import 'ui/table.dart';

/// The interactive main menu.
class App {
  App({
    required this.project,
    required this.config,
    required this.ledger,
    Console? console,
  }) : console = console ?? Console();

  final FlutterProject project;
  final AppConfig config;
  final Ledger ledger;
  final Console console;

  late final _manager = BuildManager(ledger);

  Future<void> run() async {
    console
      ..heading('Flutter Build Ledger')
      ..out('Project: ${project.appName} (${project.dir})')
      ..out('Ledger:  ${ledger.file.path}  (${ledger.records.length} builds)');
    while (true) {
      final choice = await console.choose(
        'Main menu',
        [
          'Build app',
          'List builds',
          'Build details',
          'Mark builds as published',
          'Upload to Google Play',
          'Upload debug symbols',
          'Trace a crash (de-obfuscate)',
          'Delete builds',
          'Export ledger',
        ],
        hints: [
          'APK / AAB / IPA, many flavors at once',
          'newest first',
          'artifacts, symbols, status',
          'release status in the ledger',
          'API upload or mark only',
          'Crashlytics, Sentry',
          'Dart, R8 and native stack traces',
          'released builds keep their symbols',
          'CSV, TSV, JSON',
        ],
        backLabel: 'Quit',
      );
      if (choice == null) return;
      try {
        switch (choice) {
          case 0:
            await _build();
          case 1:
            _list();
          case 2:
            await _details();
          case 3:
            await _markPublished();
          case 4:
            await _play();
          case 5:
            await _symbols();
          case 6:
            await _trace();
          case 7:
            await _delete();
          case 8:
            await _export();
        }
      } on Object catch (e) {
        if (e is! BuildException &&
            e is! PreBuildException &&
            e is! PlayException &&
            e is! SymbolUploadException &&
            e is! TraceException &&
            e is! LedgerException &&
            e is! FileSystemException) {
          rethrow;
        }
        console.out('\nError: $e');
      }
    }
  }

  // ---- build -------------------------------------------------------------

  Future<void> _build() async {
    console.heading('Build');

    // Flavors (multi select, "a" ticks all).
    final flavors = project.flavors;
    List<String?> chosenFlavors;
    if (flavors.isNotEmpty) {
      final labels = [...flavors, '(no flavor)'];
      final picks = await console.chooseMany('Flavors to build', labels);
      if (picks == null || picks.isEmpty) return;
      chosenFlavors = [
        for (final i in picks) i < flavors.length ? flavors[i] : null,
      ];
    } else {
      console.out('No flavors detected; building the default variant.');
      chosenFlavors = [null];
    }

    final types = ArtifactType.values
        .where((t) => t != ArtifactType.ipa || Platform.isMacOS)
        .toList();
    final typePicks = await console.chooseMany(
      'Outputs',
      [for (final t in types) t.label],
      ticked: {0},
    );
    if (typePicks == null || typePicks.isEmpty) return;
    final chosenTypes = [for (final i in typePicks) types[i]];

    const modes = [BuildMode.release, BuildMode.profile, BuildMode.debug];
    final modePicks = await console.chooseMany(
      'Build modes',
      [for (final m in modes) m.name],
      ticked: {0},
    );
    if (modePicks == null || modePicks.isEmpty) return;
    final chosenModes = [for (final i in modePicks) modes[i]];

    final current = project.version;
    final name = await console.ask('Version name', defaultValue: current.name);
    if (name == null) return;
    final code =
        await console.askInt('Version code', defaultValue: current.code);
    if (code == null) return;

    // Pre-build steps.
    final available = availablePreBuildSteps(project);
    final defaults = defaultPreBuildSteps(config, available);
    final prePicks = await console.chooseMany(
      'Before building',
      [for (final s in available) s.label],
      ticked: {for (final s in defaults) available.indexOf(s)},
      hints: [
        for (final s in available)
          switch (s) {
            PreBuildStep.clean => 'wipes build/, then pub get',
            PreBuildStep.buildRunner => 'found in pubspec',
            PreBuildStep.genL10n => 'found in project',
          },
      ],
    );
    if (prePicks == null) return;
    final preSteps = [for (final i in prePicks) available[i]];

    final requests = <BuildRequest>[
      for (final flavor in chosenFlavors)
        for (final type in chosenTypes)
          for (final mode in chosenModes)
            _request(flavor, type, mode, name, code),
    ];

    console
      ..out('')
      ..out('  App:       ${project.appName}')
      ..out('  Version:   $name+$code')
      ..out(
          '  Before:    ${preSteps.isEmpty ? 'nothing' : preSteps.map((s) => s.label).join(', ')}')
      ..out('  Builds (${requests.length}):');
    for (final r in requests) {
      console.out('    ${r.flavor ?? 'default'}  ${r.mode.name}  ${r.type.name}'
          '${r.willObfuscate ? '' : '  (no symbols: not obfuscated)'}');
    }
    if (!await console.confirm('Start?', defaultValue: true)) return;

    List<String> ran = const [];
    if (preSteps.isNotEmpty) {
      ran = await PreBuildRunner(
              project: project, config: config, log: console.raw)
          .run(preSteps);
    }

    final builder = FlutterBuilder(
        project: project, config: config, ledger: ledger, log: console.raw);
    final done = <BuildRecord>[];
    final failed = <String>[];
    for (final r in requests) {
      final label = '${r.flavor ?? 'default'} ${r.mode.name} ${r.type.name}';
      console.out('\n--- $label ---');
      try {
        done.add(await builder.build(_withPreBuild(r, ran)));
      } on BuildException catch (e) {
        failed.add('$label: $e');
        console.out('Error: $e');
      }
    }

    console.out('\nFinished: ${done.length} built, ${failed.length} failed.');
    for (final r in done) {
      console.out('  ${ledger.resolve(r.outputDir)}');
    }
    for (final f in failed) {
      console.out('  FAILED $f');
    }
  }

  BuildRequest _request(String? flavor, ArtifactType type, BuildMode mode,
      String name, int code) {
    final fc = config.flavor(flavor);
    return BuildRequest(
      type: type,
      mode: mode,
      flavor: flavor,
      target: fc.target ?? project.defaultTarget(flavor),
      dartDefineFile: fc.dartDefineFile,
      versionName: name,
      versionCode: code,
      obfuscate: config.obfuscate,
      splitPerAbi: config.splitPerAbi,
      extraArgs: [...config.extraBuildArgs, ...fc.extraArgs],
      packageName: type.isAndroid
          ? (fc.packageName ?? project.packageName(flavor))
          : null,
    );
  }

  BuildRequest _withPreBuild(BuildRequest r, List<String> steps) =>
      BuildRequest(
        type: r.type,
        mode: r.mode,
        flavor: r.flavor,
        target: r.target,
        dartDefineFile: r.dartDefineFile,
        versionName: r.versionName,
        versionCode: r.versionCode,
        obfuscate: r.obfuscate,
        splitPerAbi: r.splitPerAbi,
        extraArgs: r.extraArgs,
        packageName: r.packageName,
        preBuild: steps,
        notes: r.notes,
      );

  // ---- list and details --------------------------------------------------

  static String _status(BuildRecord r) => [
        if (r.isPublished) 'published',
        if (r.play != null) 'play:${r.play!.track}',
        for (final t in r.symbolUploads.keys) 'sym:$t',
        if (r.artifactsDeleted) 'files deleted',
      ].join(' ');

  static String _when(BuildRecord r) => r.createdAt
      .toLocal()
      .toIso8601String()
      .substring(0, 16)
      .replaceFirst('T', ' ');

  static const _header = [
    '#',
    'Created',
    'App',
    'Flavor',
    'Mode',
    'Type',
    'Version',
    'Size',
    'Status',
  ];

  void _list() {
    console.heading('Builds');
    final records = ledger.records;
    if (records.isEmpty) {
      console.out('The ledger is empty.');
      return;
    }
    console.out(renderTable(_header, [
      for (var i = 0; i < records.length; i++)
        [
          '${i + 1}',
          _when(records[i]),
          records[i].appName,
          records[i].flavorLabel,
          records[i].mode.name,
          records[i].type.name,
          records[i].version,
          records[i].artifactsDeleted ? '-' : formatBytes(records[i].totalSize),
          _status(records[i]),
        ],
    ]));
  }

  String _label(BuildRecord r) =>
      '${r.appName} ${r.flavorLabel} ${r.mode.name} ${r.type.name} ${r.version}';

  String _hint(BuildRecord r) {
    final s = _status(r);
    return s.isEmpty ? _when(r) : '${_when(r)}  $s';
  }

  /// Lets the user pick one build; null when cancelled or the ledger is
  /// empty.
  Future<BuildRecord?> _pickOne(String title,
      {bool Function(BuildRecord)? where}) async {
    final records = [...ledger.records.where(where ?? (_) => true)];
    if (records.isEmpty) {
      console.out('No matching builds in the ledger.');
      return null;
    }
    final i = await console.choose(
      title,
      [for (final r in records) _label(r)],
      hints: [for (final r in records) _hint(r)],
      backLabel: 'Cancel',
    );
    return i == null ? null : records[i];
  }

  /// Multi-select of builds. [disabled] rows are shown but cannot be ticked.
  Future<List<BuildRecord>?> _pickMany(String title,
      {bool Function(BuildRecord)? where,
      bool Function(BuildRecord)? disabled}) async {
    final records = [...ledger.records.where(where ?? (_) => true)];
    if (records.isEmpty) {
      console.out('No matching builds in the ledger.');
      return null;
    }
    final picks = await console.chooseMany(
      title,
      [for (final r in records) _label(r)],
      hints: [for (final r in records) _hint(r)],
      disabled: {
        for (var i = 0; i < records.length; i++)
          if (disabled?.call(records[i]) ?? false) i,
      },
    );
    if (picks == null || picks.isEmpty) return null;
    return [for (final i in picks) records[i]];
  }

  Future<void> _details() async {
    final r = await _pickOne('Show which build?');
    if (r == null) return;
    final symbols = Symbolicator(config: config, ledger: ledger)
        .availableKinds(r)
        .map((k) => k.name)
        .join(', ');
    console
      ..heading('Build ${r.id}')
      ..out(
          'App:         ${r.appName}${r.packageName == null ? '' : ' (${r.packageName})'}')
      ..out('Flavor:      ${r.flavorLabel}')
      ..out('Mode / type: ${r.mode.name} / ${r.type.name}')
      ..out('Version:     ${r.version}')
      ..out('Built:       ${r.createdAt.toLocal()}')
      ..out('Folder:      ${ledger.resolve(r.outputDir)}')
      ..out('Git:         ${r.gitCommit ?? '-'} on ${r.gitBranch ?? '-'}')
      ..out('Flutter:     ${r.flutterVersion ?? '-'}')
      ..out('Before build: ${r.preBuild.isEmpty ? '-' : r.preBuild.join(', ')}')
      ..out('Obfuscated:  ${r.obfuscated}')
      ..out('Published:   ${r.publishedAt?.toLocal() ?? 'no'}')
      ..out(
          'Google Play: ${r.play == null ? 'no' : '${r.play!.track} at ${r.play!.uploadedAt.toLocal()} (${r.play!.viaApi ? 'via API' : 'marked manually'})'}')
      ..out(
          'Symbols:     ${symbols.isEmpty ? 'none stored' : 'stored for $symbols'}; uploaded: ${r.symbolUploads.isEmpty ? 'nowhere' : r.symbolUploads.entries.map((e) => '${e.key} ${e.value.toLocal()}').join(', ')}');
    if (r.artifactsDeleted) {
      console.out('Files:       deleted ${r.artifactsDeletedAt!.toLocal()} '
          '(symbols and this entry are kept)');
    }
    for (final a in r.artifacts) {
      console.out(
          'Artifact:    ${a.path} (${formatBytes(a.sizeBytes)}) sha256 ${a.sha256}');
    }
  }

  // ---- status ------------------------------------------------------------

  Future<void> _markPublished() async {
    final action = await console.choose(
        'Published status',
        [
          'Mark as published',
          'Clear the published mark',
        ],
        backLabel: 'Cancel');
    if (action == null) return;
    final marking = action == 0;
    final picks = await _pickMany(
      marking ? 'Mark which builds as published?' : 'Clear which builds?',
      where: (r) => marking ? !r.isPublished : r.isPublished,
    );
    if (picks == null) return;
    for (final r in picks) {
      if (marking) {
        await _manager.markPublished(r);
      } else {
        await _manager.unmarkPublished(r);
      }
    }
    console.out('${marking ? 'Marked' : 'Cleared'} ${picks.length} build(s).');
  }

  Future<void> _play() async {
    final r = await _pickOne('Upload which build to Google Play?',
        where: (r) => r.type == ArtifactType.aab);
    if (r == null) return;
    final tracks = ['internal', 'alpha', 'beta', 'production'];
    final defaultIndex = tracks.indexOf(config.play.defaultTrack);
    final t = await console.choose('Track', tracks,
        defaultIndex: defaultIndex < 0 ? 0 : defaultIndex, backLabel: 'Cancel');
    if (t == null) return;
    final track = tracks[t];

    final publisher =
        PlayPublisher(config: config, ledger: ledger, log: console.out);
    final canUpload = config.play.hasCredentials &&
        r.mode == BuildMode.release &&
        !r.artifactsDeleted;
    if (canUpload) {
      final choice = await console.choose(
        'How?',
        [
          'Upload through the Play API',
          'It is already uploaded; only mark the ledger',
        ],
        defaultIndex: 0,
        backLabel: 'Cancel',
      );
      if (choice == null) return;
      if (choice == 0) {
        final status = await console.choose(
            'Release status',
            [
              'completed (rolls out now)',
              'draft (finish in Play Console)',
            ],
            defaultIndex: config.play.defaultReleaseStatus == 'draft' ? 1 : 0,
            backLabel: 'Cancel');
        if (status == null) return;
        final notes = await console.ask('Release notes (en-US, optional)');
        await publisher.publish(r,
            track: track,
            releaseStatus: status == 0 ? 'completed' : 'draft',
            releaseNotes: notes);
        console.out('Uploaded to the $track track and recorded in the ledger.');
        return;
      }
    } else {
      console.out('API upload is unavailable for this build (needs a release '
          'AAB file and Play credentials, see README). Marking the ledger only.');
    }
    await publisher.markUploaded(r, track: track);
    console.out('Marked as uploaded to the $track track.');
  }

  Future<void> _symbols() async {
    final picks = await _pickMany('Upload symbols for which builds?',
        where: (r) => r.symbolsDir != null);
    if (picks == null) return;
    final targets = [
      if (config.crashlytics.enabled) SymbolTargets.crashlytics,
      if (config.sentry.enabled) SymbolTargets.sentry,
    ];
    if (targets.isEmpty) {
      console.out('Both crash tools are disabled in the config.');
      return;
    }
    final targetPicks = await console.chooseMany(
      'Upload to',
      targets,
      ticked: {for (var i = 0; i < targets.length; i++) i},
    );
    if (targetPicks == null || targetPicks.isEmpty) return;
    final uploader = SymbolUploader(
        project: project, config: config, ledger: ledger, log: console.raw);
    for (final r in picks) {
      var current = r;
      for (final i in targetPicks) {
        try {
          current = await uploader.upload(current, targets[i]);
          console.out(
              '${r.version} (${r.flavorLabel}): uploaded to ${targets[i]}.');
        } on SymbolUploadException catch (e) {
          console.out('${r.version} (${r.flavorLabel}) ${targets[i]}: $e');
        }
      }
    }
  }

  // ---- trace -------------------------------------------------------------

  Future<void> _trace() async {
    final symbolicator = Symbolicator(config: config, ledger: ledger);
    final r = await _pickOne(
      'Trace a crash from which build?',
      where: (r) => symbolicator.availableKinds(r).isNotEmpty,
    );
    if (r == null) return;
    final kinds = symbolicator.availableKinds(r);

    final path = await console
        .ask('Path to a stack trace file (leave empty to paste it)');
    if (path == null) return;
    final String text;
    if (path.isEmpty) {
      text = await console.readLines(
          'Paste the stack trace, then a line with only "." to finish:');
    } else {
      final f = File(path);
      if (!f.existsSync()) {
        console.out('File not found: $path');
        return;
      }
      text = f.readAsStringSync();
    }
    if (text.trim().isEmpty) return;

    var kind = detectTraceKind(text);
    if (!kinds.contains(kind) || kinds.length > 1) {
      final detected = kinds.indexOf(kind);
      final i = await console.choose(
        kinds.contains(kind)
            ? 'Looks like a ${kind.name} trace. Use'
            : 'This build has no ${kind.name} symbols. Use',
        [for (final k in kinds) k.label],
        defaultIndex: detected < 0 ? 0 : detected,
        backLabel: 'Cancel',
      );
      if (i == null) return;
      kind = kinds[i];
    }

    final result = await symbolicator.trace(r, text, kind: kind);
    console
      ..heading('De-obfuscated trace (${kind.name})')
      ..out(result.output.isEmpty ? '(no output)' : result.output);
    if (result.exitCode != 0) {
      console.out('\nThe tool exited with code ${result.exitCode}.');
    }
    final save = await console.ask('Save to a file (Enter to skip)');
    if (save != null && save.isNotEmpty) {
      File(save).writeAsStringSync('${result.output}\n');
      console.out('Wrote $save');
    }
  }

  // ---- delete and export -------------------------------------------------

  Future<void> _delete() async {
    final picks = await _pickMany(
      'Delete which builds?',
      // Released builds whose files are already gone have nothing left to
      // delete.
      disabled: (r) => r.isReleased && r.artifactsDeleted,
    );
    if (picks == null) return;

    final full = picks.where((r) => !r.isReleased).toList();
    final filesOnly = picks.where((r) => r.isReleased).toList();
    if (full.isNotEmpty) {
      console.out('\nDeleted completely (folder, symbols and ledger row):');
      for (final r in full) {
        console.out('  ${ledger.resolve(r.outputDir)}');
      }
      final lost = full.where((r) => r.obfuscated && r.symbolUploads.isEmpty);
      if (lost.isNotEmpty) {
        console.out('  Note: ${lost.length} obfuscated build(s) have no '
            'symbols uploaded; their only copy of the symbols goes too.');
      }
    }
    if (filesOnly.isNotEmpty) {
      console.out('\nReleased builds: only the APK/AAB/IPA files are deleted. '
          'Symbols, mappings and the ledger row stay:');
      for (final r in filesOnly) {
        console.out('  ${r.artifacts.map((a) => a.path).join(', ')}');
      }
    }
    if (!await console.confirm('Delete ${picks.length} build(s)?')) return;

    final result = await _manager.delete(picks);
    console.out('Removed ${result.deleted.length} build(s) completely and '
        'the files of ${result.filesOnly.length} released build(s).');
    for (final e in result.failed.entries) {
      console.out('Could not delete ${e.key.id}: ${e.value} (ledger row kept)');
    }
  }

  Future<void> _export() async {
    final records = ledger.records;
    if (records.isEmpty) {
      console.out('The ledger is empty.');
      return;
    }
    final f = await console.choose('Format', ['CSV', 'TSV', 'JSON'],
        backLabel: 'Cancel');
    if (f == null) return;
    final format = ExportFormat.values[[1, 2, 0][f]];
    final stamp = DateTime.now()
        .toIso8601String()
        .substring(0, 19)
        .replaceAll(RegExp('[-:]'), '')
        .replaceFirst('T', '-');
    final defaultPath = p.join(
        config.outputRoot, 'exports', 'ledger-$stamp.${format.extension}');
    final path = await console.ask('Write to', defaultValue: defaultPath);
    if (path == null) return;
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsString(const LedgerExporter().export(records, format));
    console.out('Wrote ${records.length} builds to ${file.absolute.path}');
  }
}
