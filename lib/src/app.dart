import 'dart:io';

import 'package:path/path.dart' as p;

import 'config.dart';
import 'entry_points.dart';
import 'flutter_project.dart';
import 'ledger/exporter.dart';
import 'ledger/ledger.dart';
import 'model/build_options.dart';
import 'model/build_record.dart';
import 'services/build_manager.dart';
import 'services/flutter_builder.dart';
import 'services/play_publisher.dart';
import 'services/pre_build.dart';
import 'services/process_runner.dart';
import 'services/symbol_uploader.dart';
import 'services/symbolicator.dart';
import 'ui/console.dart';
import 'ui/launch_screen.dart';
import 'ui/settings_screen.dart';
import 'ui/table.dart';

/// The interactive main menu.
class App {
  /// Creates the menu for [project], using [config] and [ledger].
  ///
  /// [console] defaults to a new [Console]; [ledgerOverride] is the ledger path from the command line.
  App({
    required this.project,
    required this.config,
    required this.ledger,
    Console? console,
    this.ledgerOverride,
  }) : console = console ?? Console();

  /// The Flutter project the menu operates on.
  final FlutterProject project;

  /// Replaced by [_reload] after the settings are saved.
  AppConfig config;

  /// The build ledger currently in use; reopened when the ledger path changes.
  Ledger ledger;

  /// Prompts and styled output for the menu.
  final Console console;

  /// Ledger path given on the command line; it wins over the config.
  final String? ledgerOverride;

  BuildManager get _manager => BuildManager(ledger);

  /// Opens the settings editor on its own (the `settings` command).
  Future<void> editSettings() async {
    if (await _settings()) {
      console.note('Settings reloaded.');
    }
  }

  /// Adds run configurations to `.vscode/launch.json`.
  Future<void> createLaunchJson() async {
    await runLaunchJsonFlow(console, project, config);
  }

  /// Reads the project and writes a config from what it finds.
  Future<void> setUpFromProject() async {
    final saved = await SettingsScreen(
            console: console, project: project, configFile: config.configFile)
        .autoConfigure();
    if (saved != null) await _reload(saved);
  }

  Future<void> _reload(String saved) async {
    config = AppConfig.load(project.dir, explicitPath: saved);
    final path = ledgerOverride ?? config.ledgerPath;
    if (p.normalize(path) != p.normalize(ledger.file.path)) {
      ledger = await Ledger.open(path);
    }
    console.success('Settings reloaded.');
    _banner();
  }

  /// Runs the settings editor; on save re-reads the config (and reopens the
  /// ledger if its path changed). True when something was saved.
  Future<bool> _settings() async {
    final saved = await SettingsScreen(
            console: console, project: project, configFile: config.configFile)
        .run();
    if (saved == null) return false;
    await _reload(saved);
    return true;
  }

  void _banner() => console.banner('Flutter Buildkit', [
        'Project  ${project.appName}  (${project.dir})',
        'Ledger   ${ledger.file.path}  (${ledger.records.length} builds)',
      ]);

  /// Shows the banner and runs the main menu loop until the user quits.
  Future<void> run() async {
    _banner();
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
          'Settings',
          'Set up from this project',
          'VS Code launch.json',
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
          'edit flutter_buildkit.yaml with previews',
          'detect flavors, entry points, tools; write the config',
          'run configs per flavor, entry point and mode',
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
          case 9:
            await _settings();
          case 10:
            await setUpFromProject();
          case 11:
            await createLaunchJson();
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
        console.error('$e');
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

    // Entry points (main files) per flavor. Asked only when there is more
    // than one to choose from.
    final entryOptions = {
      for (final f in chosenFlavors) f: entryPointsFor(config, project, f),
    };
    final names = <String?>[];
    for (final list in entryOptions.values) {
      for (final e in list) {
        if (!names.contains(e.name)) names.add(e.name);
      }
    }
    var chosenNames = names;
    if (names.length > 1) {
      final labels = [for (final n in names) n ?? '(default)'];
      final hints = [
        for (final n in names)
          {
            for (final f in chosenFlavors)
              if (entryOptions[f]!.where((e) => e.name == n).firstOrNull
                  case final e?)
                '${f ?? 'default'}: ${e.path ?? 'lib/main.dart'}',
          }.join('  '),
      ];
      final picks = await console.chooseMany(
          'Entry points', [for (final l in labels) l],
          ticked: {0}, hints: hints);
      if (picks == null || picks.isEmpty) return;
      chosenNames = [for (final i in picks) names[i]];
    }
    final entriesFor = {
      for (final f in chosenFlavors)
        f: [
          for (final e in entryOptions[f]!)
            if (chosenNames.contains(e.name)) e,
        ],
    };
    for (final f in chosenFlavors) {
      for (final e in entriesFor[f]!) {
        final path = e.path;
        if (path != null && !File(p.join(project.dir, path)).existsSync()) {
          console.warn('${f ?? 'default'} ${e.label}: $path not found; '
              'Flutter will report the error.');
        }
      }
      for (final n in chosenNames) {
        if (!entriesFor[f]!.any((e) => e.name == n)) {
          console
              .note('${f ?? 'default'} has no entry point "${n ?? 'default'}"; '
                  'skipped.');
        }
      }
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
    final highest = ledger.highestVersionCode(project.appName);
    if (highest != null && code <= highest) {
      console.warn('Version code $code is not higher than $highest, which the '
          'ledger already has for ${project.appName}. Google Play rejects a '
          'version code it has seen.');
    }

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

    // Build options, pre-set from the config for this one run.
    final hasApk = chosenTypes.contains(ArtifactType.apk);
    final canObfuscate = chosenModes.any((m) => m.supportsObfuscation);
    final optionLabels = [
      'Obfuscate and keep Dart symbols',
      if (hasApk) 'Split APKs per ABI',
    ];
    final optionHints = [
      canObfuscate
          ? 'release/profile only; needed to trace crashes later'
          : 'only release/profile builds can be obfuscated',
      if (hasApk) 'one APK per CPU architecture',
    ];
    final optionPicks = await console.chooseMany(
      'Build options',
      optionLabels,
      ticked: {
        if (config.obfuscate) 0,
        if (hasApk && config.splitPerAbi) 1,
      },
      hints: optionHints,
    );
    if (optionPicks == null) return;
    final obfuscate = optionPicks.contains(0);
    final splitPerAbi = hasApk && optionPicks.contains(1);
    final extraText = await console.ask(
        'Extra flutter build arguments (- for none)',
        defaultValue: config.extraBuildArgs.isEmpty
            ? '-'
            : config.extraBuildArgs.join(' '));
    if (extraText == null) return;
    final extraBuildArgs =
        extraText == '-' ? <String>[] : splitCommandLine(extraText);

    final requests = <BuildRequest>[
      for (final flavor in chosenFlavors)
        for (final entry in entriesFor[flavor] ?? const <EntryPoint>[])
          for (final type in chosenTypes)
            for (final mode in chosenModes)
              _request(flavor, entry, type, mode, name, code,
                  obfuscate: obfuscate,
                  splitPerAbi: splitPerAbi,
                  extraBuildArgs: extraBuildArgs),
    ];

    console
      ..heading('Plan')
      ..kv('App', project.appName)
      ..kv('Version', '$name+$code')
      ..kv('Obfuscate', obfuscate ? 'yes (release/profile)' : 'no')
      ..kv('Split ABI', splitPerAbi ? 'yes (APK)' : 'no')
      ..kv('Extra args',
          extraBuildArgs.isEmpty ? 'none' : extraBuildArgs.join(' '))
      ..kv(
          'Before',
          preSteps.isEmpty
              ? 'nothing'
              : preSteps.map((s) => s.label).join(', '))
      ..kv('Builds', '${requests.length}');
    for (final r in requests) {
      console.out('  ${console.style.cyan(console.style.bullet)} '
          '${(r.flavor ?? 'default').padRight(12)} ${r.mode.name.padRight(8)} '
          '${r.type.name}${r.entryPoint == null ? '' : '  [${r.entryPoint}]'}'
          '${r.willObfuscate ? '' : console.style.dim('  (not obfuscated: no Dart symbols)')}');
    }
    console.blank();
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
      final label = '${r.flavor ?? 'default'} ${r.mode.name} ${r.type.name}'
          '${r.entryPoint == null ? '' : ' ${r.entryPoint}'}';
      console.heading('Building $label');
      try {
        done.add(await builder.build(_withPreBuild(r, ran)));
      } on BuildException catch (e) {
        failed.add('$label: $e');
        console.error('$e');
      }
    }

    console.heading('Finished');
    if (done.isNotEmpty) {
      console.success('${done.length} built');
      for (final r in done) {
        console.out('    ${console.style.dim(ledger.resolve(r.outputDir))}');
      }
    }
    for (final f in failed) {
      console.error('FAILED $f');
    }
  }

  BuildRequest _request(String? flavor, EntryPoint entry, ArtifactType type,
      BuildMode mode, String name, int code,
      {required bool obfuscate,
      required bool splitPerAbi,
      required List<String> extraBuildArgs}) {
    final fc = config.flavor(flavor);
    return BuildRequest(
      type: type,
      mode: mode,
      flavor: flavor,
      target: entry.path,
      entryPoint: entry.name,
      dartDefineFile: fc.dartDefineFile,
      versionName: name,
      versionCode: code,
      obfuscate: obfuscate,
      splitPerAbi: splitPerAbi,
      extraArgs: [...extraBuildArgs, ...fc.extraArgs],
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
        entryPoint: r.entryPoint,
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

  static String _stamp(DateTime t) =>
      t.toLocal().toIso8601String().substring(0, 16).replaceFirst('T', ' ');

  String _colorStatus(BuildRecord r) => switch (r.status) {
        BuildStatus.published => console.style.green(r.statusLabel),
        BuildStatus.uploaded => console.style.blue(r.statusLabel),
        BuildStatus.built => r.statusLabel,
        BuildStatus.failed => console.style.red(r.statusLabel),
      };

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
    'Files',
    'Symbols',
  ];

  void _list() {
    console.heading('Builds');
    final records = ledger.records;
    if (records.isEmpty) {
      console.out('The ledger is empty.');
      return;
    }
    final rows = [
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
          records[i].status.code,
          records[i].conditionShort,
          records[i].symbolsShort,
        ],
    ];
    final st = console.style;
    console.out(renderTable(_header, rows, style: st, decorate: (col, cell) {
      switch (col) {
        case 0:
          return st.dim(cell);
        case 4:
          return cell.startsWith('release')
              ? st.green(cell)
              : cell.startsWith('profile')
                  ? st.yellow(cell)
                  : st.dim(cell);
        case 8:
          return switch (cell) {
            'published' => st.green(cell),
            'uploaded' => st.blue(cell),
            'failed' => st.red(cell),
            _ => st.dim(cell),
          };
        case 9:
          return cell == 'ready' ? st.green(cell) : st.yellow(cell);
        case 10:
          return cell == 'missing' ? st.red(cell) : st.magenta(cell);
      }
      return cell;
    }));
  }

  String _label(BuildRecord r) =>
      '${r.appName} ${r.flavorLabel} ${r.mode.name} ${r.type.name} ${r.version}';

  String _hint(BuildRecord r) =>
      '${_when(r)}  ${r.status.code}  ${r.conditionShort}';

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
    final play = r.play;
    console
      ..heading('Build ${r.id}')
      ..kv('App',
          '${r.appName}${r.packageName == null ? '' : ' (${r.packageName})'}')
      ..kv('Flavor', r.flavorLabel)
      ..kv('Mode / type', '${r.mode.name} / ${r.type.name}')
      ..kv('Version', r.version)
      ..kv('Built', '${r.createdAt.toLocal()}')
      ..kv('Folder', ledger.resolve(r.outputDir))
      ..kv('Git', '${r.gitCommit ?? '-'} on ${r.gitBranch ?? '-'}')
      ..kv('Flutter', r.flutterVersion ?? '-')
      ..kv('Before build', r.preBuild.isEmpty ? '-' : r.preBuild.join(', '))
      ..kv('Obfuscated', '${r.obfuscated}')
      ..kv('Status', _colorStatus(r))
      ..kv('Condition', r.condition)
      ..kv('Crash symbols', r.symbolsStatus)
      ..kv(
          'Published',
          r.publishedAt == null
              ? 'no'
              : console.style.green('${r.publishedAt!.toLocal()}'))
      ..kv(
          'Google Play',
          play == null
              ? 'no'
              : console.style.blue(
                  '${play.track} at ${play.uploadedAt.toLocal()} (${play.viaApi ? 'via API' : 'marked manually'})'))
      ..kv('Symbols', symbols.isEmpty ? 'none stored' : 'stored for $symbols')
      ..kv(
          'Symbols sent',
          r.symbolUploads.isEmpty
              ? 'nowhere'
              : r.symbolUploads.entries
                  .map((e) => '${e.key} ${e.value.toLocal()}')
                  .join(', '));
    if (r.artifactsDeleted) {
      console.kv(
          'Files',
          console.style.yellow('deleted ${r.artifactsDeletedAt!.toLocal()}') +
              console.style.dim(' (symbols and this entry are kept)'));
    }
    console.out('');
    console.out(console.style.bold('History'));
    for (final e in r.events) {
      console.out('  ${console.style.dim(_stamp(e.at))}  ${e.text}');
    }
    console.out('');
    for (final a in r.artifacts) {
      console.kv('Artifact',
          '${a.path} (${formatBytes(a.sizeBytes)})\n${' ' * 14}${console.style.dim('sha256 ${a.sha256}')}');
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
      where: (r) => !r.isFailed && (marking ? !r.isPublished : r.isPublished),
    );
    if (picks == null) return;
    for (final r in picks) {
      if (marking) {
        await _manager.markPublished(r);
      } else {
        await _manager.unmarkPublished(r);
      }
    }
    console
        .success('${marking ? 'Marked' : 'Cleared'} ${picks.length} build(s).');
  }

  Future<void> _play() async {
    final r = await _pickOne('Upload which build to Google Play?',
        where: (r) => r.type == ArtifactType.aab && !r.isFailed);
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
              'draft (finish in Play Console)',
              'completed (rolls out now)',
            ],
            defaultIndex:
                config.play.defaultReleaseStatus == 'completed' ? 1 : 0,
            backLabel: 'Cancel');
        if (status == null) return;
        final releaseStatus = status == 0 ? 'draft' : 'completed';
        final notes = await console.ask('Release notes (en-US, optional)');
        if (notes == null) return;
        console
          ..heading('Upload to Google Play')
          ..kv('App', r.packageName ?? r.appName)
          ..kv('Version', r.version)
          ..kv('Track', track)
          ..kv('Status', releaseStatus);
        if (track == 'production') {
          console.warn('This is the production track.');
          final typed = await console.ask('Type "production" to continue');
          if (typed?.trim().toLowerCase() != 'production') {
            console.out('Cancelled.');
            return;
          }
        } else if (!await console.confirm('Upload?', defaultValue: true)) {
          return;
        }
        try {
          await publisher.publish(r,
              track: track, releaseStatus: releaseStatus, releaseNotes: notes);
        } on PlayTrackInUseException catch (e) {
          console.warn('$e');
          if (!await console.confirm('Replace it anyway?')) return;
          await publisher.publish(r,
              track: track,
              releaseStatus: releaseStatus,
              releaseNotes: notes,
              replaceExisting: true);
        }
        console.success(
            'Uploaded to the $track track and recorded in the ledger.');
        return;
      }
    } else {
      console.out('API upload is unavailable for this build (needs a release '
          'AAB file and Play credentials, see README). Marking the ledger only.');
    }
    await publisher.markUploaded(r, track: track);
    console.success('Marked as uploaded to the $track track.');
  }

  Future<void> _symbols() async {
    final picks = await _pickMany('Upload symbols for which builds?',
        where: (r) => !r.isFailed && r.symbolsDir != null);
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
          console.error('${r.version} (${r.flavorLabel}) ${targets[i]}: $e');
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
        console.error('File not found: $path');
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
      console.warn('The tool exited with code ${result.exitCode}.');
    }
    final save = await console.ask('Save to a file (Enter to skip)');
    if (save != null && save.isNotEmpty) {
      File(save).writeAsStringSync('${result.output}\n');
      console.success('Wrote $save');
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
      console.warn('Deleted completely (folder, symbols and ledger row):');
      for (final r in full) {
        console.out('  ${ledger.resolve(r.outputDir)}');
      }
      final lost = full.where((r) => r.obfuscated && r.symbolUploads.isEmpty);
      if (lost.isNotEmpty) {
        console.warn('${lost.length} obfuscated build(s) have no symbols '
            'uploaded; their only copy of the symbols goes too.');
      }
    }
    final unmarked = picks.where(
        (r) => !r.isReleased && r.events.any((e) => e.kind == 'unpublished'));
    if (unmarked.isNotEmpty) {
      console.warn('${unmarked.length} build(s) were published once and the '
          'mark was cleared, so they are deleted completely, symbols '
          'included.');
    }
    if (filesOnly.isNotEmpty) {
      console.note('Released builds: only the APK/AAB/IPA files are deleted. '
          'Symbols, mappings and the ledger row stay:');
      for (final r in filesOnly) {
        console.out('  ${r.artifacts.map((a) => a.path).join(', ')}');
      }
    }
    if (!await console.confirm('Delete ${picks.length} build(s)?')) return;

    final result = await _manager.delete(picks);
    console.success('Removed ${result.deleted.length} build(s) completely and '
        'the files of ${result.filesOnly.length} released build(s).');
    for (final e in result.failed.entries) {
      console
          .error('Could not delete ${e.key.id}: ${e.value} (ledger row kept)');
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
    console.success('Wrote ${records.length} builds to ${file.absolute.path}');
  }
}
