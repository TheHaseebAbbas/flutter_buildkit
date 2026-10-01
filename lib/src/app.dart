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
import 'services/symbol_uploader.dart';
import 'ui/console.dart';
import 'ui/table.dart';

/// The interactive main menu.
class App {
  App(
      {required this.project,
      required this.config,
      required this.ledger,
      Console? console})
      : console = console ?? Console();

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
      final choice = console.choose(
        'Main menu',
        [
          'Build app (APK / AAB / IPA)',
          'List builds',
          'Build details',
          'Mark build as published',
          'Upload to Google Play',
          'Upload debug symbols (Crashlytics / Sentry)',
          'Delete builds',
          'Export ledger (CSV / TSV / JSON)',
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
            _details();
          case 3:
            await _markPublished();
          case 4:
            await _play();
          case 5:
            await _symbols();
          case 6:
            await _delete();
          case 7:
            await _export();
        }
      } on Object catch (e) {
        if (e is! BuildException &&
            e is! PlayException &&
            e is! SymbolUploadException &&
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
    final flavors = project.flavors;
    String? flavor;
    if (flavors.isNotEmpty) {
      final labels = [...flavors, '(no flavor)'];
      final i = console.choose('Flavor', labels, backLabel: 'Cancel');
      if (i == null) return;
      flavor = i < flavors.length ? flavors[i] : null;
    } else {
      console.out('No flavors detected; building the default variant.');
    }

    final types = ArtifactType.values
        .where((t) => t != ArtifactType.ipa || Platform.isMacOS)
        .toList();
    final t = console.choose('Output', [for (final t in types) t.label],
        defaultIndex: 0, backLabel: 'Cancel');
    if (t == null) return;
    final type = types[t];

    final m = console.choose('Build mode', ['release', 'profile', 'debug'],
        defaultIndex: 0, backLabel: 'Cancel');
    if (m == null) return;
    final mode = [BuildMode.release, BuildMode.profile, BuildMode.debug][m];

    final current = project.version;
    final name = console.ask('Version name', defaultValue: current.name);
    if (name == null) return;
    final code = console.askInt('Version code', defaultValue: current.code);
    if (code == null) return;

    final flavorConfig = config.flavor(flavor);
    final target = flavorConfig.target ?? project.defaultTarget(flavor);
    final packageName = flavorConfig.packageName ?? project.packageName(flavor);
    final request = BuildRequest(
      type: type,
      mode: mode,
      flavor: flavor,
      target: target,
      dartDefineFile: flavorConfig.dartDefineFile,
      versionName: name,
      versionCode: code,
      obfuscate: config.obfuscate,
      splitPerAbi: config.splitPerAbi,
      extraArgs: [...config.extraBuildArgs, ...flavorConfig.extraArgs],
      packageName: type.isAndroid ? packageName : null,
    );

    console
      ..out('')
      ..out('  App:      ${project.appName}')
      ..out('  Flavor:   ${flavor ?? 'default'}')
      ..out('  Type:     ${type.name}  Mode: ${mode.name}')
      ..out('  Version:  $name+$code')
      ..out('  Entry:    ${target ?? 'lib/main.dart'}')
      ..out(
          '  Symbols:  ${request.willObfuscate ? 'obfuscated, kept for upload' : 'none (not obfuscated)'}');
    if (!console.confirm('Start the build?', defaultValue: true)) return;

    final builder = FlutterBuilder(
        project: project, config: config, ledger: ledger, log: console.raw);
    final record = await builder.build(request);
    console
      ..out('\nBuild finished: ${record.id}')
      ..out('Stored in ${ledger.resolve(record.outputDir)}');
    for (final a in record.artifacts) {
      console.out('  ${a.path}  (${formatBytes(a.sizeBytes)})');
    }
  }

  // ---- list and details --------------------------------------------------

  static String _status(BuildRecord r) => [
        if (r.isPublished) 'published',
        if (r.play != null) 'play:${r.play!.track}',
        for (final t in r.symbolUploads.keys) 'sym:$t',
      ].join(' ');

  List<String> _row(int i, BuildRecord r) => [
        '${i + 1}',
        r.createdAt
            .toLocal()
            .toIso8601String()
            .substring(0, 16)
            .replaceFirst('T', ' '),
        r.appName,
        r.flavorLabel,
        r.mode.name,
        r.type.name,
        r.version,
        formatBytes(r.totalSize),
        _status(r),
      ];

  static const _header = [
    '#',
    'Created',
    'App',
    'Flavor',
    'Mode',
    'Type',
    'Version',
    'Size',
    'Status'
  ];

  void _list() {
    console.heading('Builds');
    final records = ledger.records;
    if (records.isEmpty) {
      console.out('The ledger is empty.');
      return;
    }
    console.out(renderTable(_header, [
      for (var i = 0; i < records.length; i++) _row(i, records[i]),
    ]));
  }

  /// Lets the user pick one build; null when cancelled or the ledger is empty.
  BuildRecord? _pick(String title) {
    final records = ledger.records;
    if (records.isEmpty) {
      console.out('The ledger is empty.');
      return null;
    }
    final i = console.choose(title, [for (final r in records) _label(r)],
        backLabel: 'Cancel');
    return i == null ? null : records[i];
  }

  String _label(BuildRecord r) =>
      '${r.appName} ${r.flavorLabel} ${r.mode.name} ${r.type.name} ${r.version} '
      '(${r.createdAt.toLocal().toIso8601String().substring(0, 16).replaceFirst('T', ' ')})'
      '${_status(r).isEmpty ? '' : '  [${_status(r)}]'}';

  void _details() {
    final r = _pick('Show which build?');
    if (r == null) return;
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
      ..out('Obfuscated:  ${r.obfuscated}')
      ..out('Published:   ${r.publishedAt?.toLocal() ?? 'no'}')
      ..out(
          'Google Play: ${r.play == null ? 'no' : '${r.play!.track} at ${r.play!.uploadedAt.toLocal()} (${r.play!.viaApi ? 'via API' : 'marked manually'})'}')
      ..out(
          'Symbols:     ${r.symbolUploads.isEmpty ? 'not uploaded' : r.symbolUploads.entries.map((e) => '${e.key} ${e.value.toLocal()}').join(', ')}');
    for (final a in r.artifacts) {
      console.out(
          'Artifact:    ${a.path} (${formatBytes(a.sizeBytes)}) sha256 ${a.sha256}');
    }
  }

  // ---- status ------------------------------------------------------------

  Future<void> _markPublished() async {
    final r = _pick('Mark which build?');
    if (r == null) return;
    if (r.isPublished) {
      if (console.confirm('Already published. Clear the published mark?')) {
        await _manager.unmarkPublished(r);
        console.out('Cleared.');
      }
      return;
    }
    await _manager.markPublished(r);
    console.out('Marked ${r.version} (${r.flavorLabel}) as published.');
  }

  Future<void> _play() async {
    final r = _pick('Upload which build to Google Play?');
    if (r == null) return;
    final tracks = ['internal', 'alpha', 'beta', 'production'];
    final defaultIndex = tracks.indexOf(config.play.defaultTrack);
    final t = console.choose('Track', tracks,
        defaultIndex: defaultIndex < 0 ? 0 : defaultIndex, backLabel: 'Cancel');
    if (t == null) return;
    final track = tracks[t];

    final publisher =
        PlayPublisher(config: config, ledger: ledger, log: console.out);
    final canUpload = config.play.hasCredentials &&
        r.type == ArtifactType.aab &&
        r.mode == BuildMode.release;
    if (canUpload) {
      final choice = console.choose(
        'How?',
        [
          'Upload through the Play API',
          'It is already uploaded; only mark the ledger'
        ],
        defaultIndex: 0,
        backLabel: 'Cancel',
      );
      if (choice == null) return;
      if (choice == 0) {
        final status = console.choose('Release status',
            ['completed (rolls out now)', 'draft (finish in Play Console)'],
            defaultIndex: config.play.defaultReleaseStatus == 'draft' ? 1 : 0,
            backLabel: 'Cancel');
        if (status == null) return;
        final notes = console.ask('Release notes (en-US, optional)');
        await publisher.publish(r,
            track: track,
            releaseStatus: status == 0 ? 'completed' : 'draft',
            releaseNotes: notes);
        console.out('Uploaded to the $track track and recorded in the ledger.');
        return;
      }
    } else {
      console.out('API upload is unavailable for this build '
          '(needs a release AAB and Play credentials, see README). '
          'Marking the ledger only.');
    }
    await publisher.markUploaded(r, track: track);
    console.out('Marked as uploaded to the $track track.');
  }

  Future<void> _symbols() async {
    final r = _pick('Upload symbols for which build?');
    if (r == null) return;
    final targets = [
      if (config.crashlytics.enabled) SymbolTargets.crashlytics,
      if (config.sentry.enabled) SymbolTargets.sentry,
    ];
    if (targets.isEmpty) {
      console.out('Both crash tools are disabled in the config.');
      return;
    }
    final picks = console.chooseMany('Upload to', [
      for (final t in targets)
        '$t${r.symbolUploads.containsKey(t) ? ' (already uploaded)' : ''}',
    ]);
    if (picks == null) return;
    final uploader = SymbolUploader(
        project: project, config: config, ledger: ledger, log: console.raw);
    var current = r;
    for (final i in picks) {
      try {
        current = await uploader.upload(current, targets[i]);
        console.out('Uploaded symbols to ${targets[i]}.');
      } on SymbolUploadException catch (e) {
        console.out('Error (${targets[i]}): $e');
      }
    }
  }

  // ---- delete and export -------------------------------------------------

  Future<void> _delete() async {
    final records = ledger.records;
    if (records.isEmpty) {
      console.out('The ledger is empty.');
      return;
    }
    final picks = console.chooseMany(
        'Delete which builds?', [for (final r in records) _label(r)]);
    if (picks == null) return;
    final chosen = [for (final i in picks) records[i]];
    console
        .out('\nThis permanently deletes these folders and their ledger rows:');
    for (final r in chosen) {
      console.out('  ${ledger.resolve(r.outputDir)}');
    }
    final warn = chosen.where(
        (r) => !r.isPublished && r.symbolUploads.isEmpty && r.obfuscated);
    if (warn.isNotEmpty) {
      console.out('\nNote: ${warn.length} obfuscated build(s) have no symbols '
          'uploaded; deleting them loses the only copy of their symbols.');
    }
    if (!console.confirm('Delete ${chosen.length} build(s)?')) return;
    final result = await _manager.delete(chosen);
    console.out(
        'Deleted ${result.deleted.length} build(s) and their ledger rows.');
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
    final f =
        console.choose('Format', ['CSV', 'TSV', 'JSON'], backLabel: 'Cancel');
    if (f == null) return;
    final format = ExportFormat.values[[1, 2, 0][f]];
    final stamp = DateTime.now()
        .toIso8601String()
        .substring(0, 19)
        .replaceAll(RegExp('[-:]'), '')
        .replaceFirst('T', '-');
    final defaultPath = p.join(
        config.outputRoot, 'exports', 'ledger-$stamp.${format.extension}');
    final path = console.ask('Write to', defaultValue: defaultPath);
    if (path == null) return;
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsString(const LedgerExporter().export(records, format));
    console.out('Wrote ${records.length} builds to ${file.absolute.path}');
  }
}
