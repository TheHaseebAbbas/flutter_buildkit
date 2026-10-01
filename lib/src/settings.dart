import 'dart:io';

import 'package:path/path.dart' as p;

import 'build_paths.dart';
import 'config.dart';
import 'model/build_options.dart';
import 'services/flutter_builder.dart';

enum SettingKind {
  /// true / false.
  boolean,

  /// One of [SettingDef.choices] (or a custom value when [SettingDef.custom]).
  choice,

  /// Free text; an empty value removes the key.
  text,

  /// Space separated words, saved as a YAML list.
  list,
}

class SettingChoice {
  const SettingChoice(this.value, {this.note});
  final String value;
  final String? note;
}

/// What previews use as the example build.
class PreviewContext {
  PreviewContext({
    required this.appName,
    required this.versionName,
    required this.versionCode,
    this.flavor,
    DateTime? now,
  }) : now = now ?? DateTime.now();

  final String appName;
  final String versionName;
  final int versionCode;

  /// An example flavor, or null for a project without flavors.
  final String? flavor;
  final DateTime now;

  BuildNaming naming(BuildMode mode, ArtifactType type) => BuildNaming(
        appName: appName,
        flavor: flavor,
        mode: mode,
        versionName: versionName,
        versionCode: versionCode,
        time: now,
        type: type,
      );
}

/// One option in the settings screen: where it lives in the YAML file, how to
/// show and edit it, and what it will do (the preview).
class SettingDef {
  const SettingDef({
    required this.path,
    required this.summary,
    required this.kind,
    required this.current,
    required this.preview,
    this.choices = const [],
    this.custom = false,
    this.hint,
  });

  final List<String> path;
  final String summary;
  final SettingKind kind;
  final List<SettingChoice> choices;

  /// With [SettingKind.choice]: also accept a value typed by the user.
  final bool custom;

  /// Shown under the question, e.g. which tokens a template may use.
  final String? hint;

  /// The effective value, for display.
  final String Function(AppConfig c) current;

  /// Lines describing what the value does. The first line is a one line
  /// summary used next to each choice.
  final List<String> Function(AppConfig c, PreviewContext x) preview;

  String get key => path.join('.');
}

String _rel(AppConfig c, String path) => p.isWithin(c.projectDir, path)
    ? p.relative(path, from: c.projectDir)
    : path;

/// Example folder, artifact and symbol paths for the current layout.
List<String> _layoutPreview(AppConfig c, PreviewContext x) {
  final paths =
      BuildPaths(c.outputRoot, layout: c.effectiveLayout, fileName: c.fileName);
  final n = x.naming(BuildMode.release, ArtifactType.aab);
  final dir = paths.buildDir(n);
  final file = paths.artifactFileName(n);
  return [
    _rel(c, dir),
    'folder    ${_rel(c, dir)}/',
    'artifact  ${p.join(BuildPaths.artifactsFolder, file)}',
    'symbols   ${BuildPaths.symbolsFolder}/{dart,native,mapping}/',
    if (c.outputInsideProject)
      'output is inside the project, so presets leave out the app folder'
    else
      'output is outside the project, so presets include the app folder',
  ];
}

List<String> _commandPreview(AppConfig c, PreviewContext x,
    {String? flavor, String? note}) {
  final f = flavor ?? x.flavor;
  final flavorConfig = f == null ? const FlavorConfig() : c.flavor(f);
  final type = c.splitPerAbi ? ArtifactType.apk : ArtifactType.aab;
  final request = BuildRequest(
    type: type,
    mode: BuildMode.release,
    flavor: f,
    target: flavorConfig.target,
    dartDefineFile: flavorConfig.dartDefineFile,
    versionName: x.versionName,
    versionCode: x.versionCode,
    obfuscate: c.obfuscate,
    splitPerAbi: c.splitPerAbi,
    extraArgs: [...c.extraBuildArgs, ...flavorConfig.extraArgs],
  );
  final command = [
    ...c.flutter,
    ...flutterBuildArgs(request, symbolsDir: 'symbols/dart'),
  ];
  return [
    '\$ ${command.join(' ')}',
    if (note != null) note,
  ];
}

List<String> _preBuildPreview(AppConfig c, PreviewContext x) {
  final steps = [
    if (c.preBuild.clean) 'flutter clean + flutter pub get',
    if (c.preBuild.buildRunner)
      'build_runner build ${c.preBuild.buildRunnerArgs.join(' ')}'.trim(),
    if (c.preBuild.genL10n) 'flutter gen-l10n',
  ];
  return [
    steps.isEmpty
        ? 'no pre-build step is pre-ticked'
        : '${steps.length} step'
            '${steps.length == 1 ? '' : 's'} pre-ticked',
    for (final s in steps) '  - $s',
    'build_runner and gen-l10n only run when the project uses them',
    'You can still change the ticks for every build.',
  ];
}

String _list(List<String> v) => v.isEmpty ? '(none)' : v.join(' ');
String _opt(String? v) => v ?? '(not set)';

/// All project wide settings, in the order shown in the menu.
List<SettingDef> globalSettings() => [
      SettingDef(
        path: const ['output_dir'],
        summary: 'Folder for builds and the ledger',
        kind: SettingKind.text,
        hint: 'Relative to the project, or absolute (e.g. ~/builds).',
        current: (c) => c.outputDir,
        preview: (c, x) => [
          'builds go to ${c.outputRoot}',
          ..._layoutPreview(c, x).skip(1),
        ],
      ),
      SettingDef(
        path: const ['output_layout'],
        summary: 'Folder structure inside the output folder',
        kind: SettingKind.choice,
        custom: true,
        hint: 'Tokens: ${PathTemplate.tokens.map((t) => '{$t}').join(' ')}',
        choices: [
          for (final l in LayoutPreset.values)
            SettingChoice(l.id, note: l.template),
        ],
        current: (c) => c.outputLayout ?? 'by-flavor',
        preview: (c, x) => _layoutPreview(c, x),
      ),
      SettingDef(
        path: const ['file_name'],
        summary: 'Artifact file name (without extension)',
        kind: SettingKind.choice,
        custom: true,
        hint: 'Same tokens as the layout; no "/" allowed.',
        choices: const [
          SettingChoice(BuildPaths.defaultFileName),
          SettingChoice('{app}_{flavor}_{versionName}_{versionCode}'),
          SettingChoice('{app}-{flavor}-{mode}-{version}'),
        ],
        current: (c) => c.fileName ?? BuildPaths.defaultFileName,
        preview: (c, x) {
          final paths = BuildPaths(c.outputRoot,
              layout: c.effectiveLayout, fileName: c.fileName);
          final name = paths
              .artifactFileName(x.naming(BuildMode.release, ArtifactType.aab));
          return [name, 'artifact  $name'];
        },
      ),
      SettingDef(
        path: const ['ledger'],
        summary: 'Ledger file',
        kind: SettingKind.text,
        hint: 'Empty keeps the default: <output folder>/ledger.json.',
        current: (c) => _opt(c.ledgerFile),
        preview: (c, x) => [_rel(c, c.ledgerPath), 'ledger  ${c.ledgerPath}'],
      ),
      SettingDef(
        path: const ['flutter'],
        summary: 'Command that runs Flutter',
        kind: SettingKind.text,
        hint: 'e.g. flutter, fvm flutter, /opt/flutter/bin/flutter',
        current: (c) => c.flutter.join(' '),
        preview: (c, x) => _commandPreview(c, x),
      ),
      SettingDef(
        path: const ['obfuscate'],
        summary: 'Obfuscate release builds and keep Dart symbols',
        kind: SettingKind.boolean,
        current: (c) => '${c.obfuscate}',
        preview: (c, x) => [
          c.obfuscate
              ? 'adds --obfuscate; Dart symbols are stored'
              : 'no obfuscation; no Dart symbols to store',
          ..._commandPreview(c, x),
        ],
      ),
      SettingDef(
        path: const ['split_per_abi'],
        summary: 'Split APKs per CPU architecture',
        kind: SettingKind.boolean,
        current: (c) => '${c.splitPerAbi}',
        preview: (c, x) => [
          c.splitPerAbi
              ? 'APK builds make one file per ABI'
              : 'APK builds make one universal file',
          ..._commandPreview(c, x),
        ],
      ),
      SettingDef(
        path: const ['extra_build_args'],
        summary: 'Extra arguments for every flutter build',
        kind: SettingKind.list,
        hint: 'Space separated, e.g. --no-tree-shake-icons',
        current: (c) => _list(c.extraBuildArgs),
        preview: (c, x) => _commandPreview(c, x),
      ),
      SettingDef(
        path: const ['pre_build', 'clean'],
        summary: 'Pre-tick "flutter clean" in the build menu',
        kind: SettingKind.boolean,
        current: (c) => '${c.preBuild.clean}',
        preview: _preBuildPreview,
      ),
      SettingDef(
        path: const ['pre_build', 'build_runner'],
        summary: 'Pre-tick build_runner in the build menu',
        kind: SettingKind.boolean,
        current: (c) => '${c.preBuild.buildRunner}',
        preview: _preBuildPreview,
      ),
      SettingDef(
        path: const ['pre_build', 'gen_l10n'],
        summary: 'Pre-tick "flutter gen-l10n" in the build menu',
        kind: SettingKind.boolean,
        current: (c) => '${c.preBuild.genL10n}',
        preview: _preBuildPreview,
      ),
      SettingDef(
        path: const ['pre_build', 'build_runner_args'],
        summary: 'Arguments for build_runner build',
        kind: SettingKind.list,
        hint: 'Space separated, e.g. --delete-conflicting-outputs',
        current: (c) => _list(c.preBuild.buildRunnerArgs),
        preview: _preBuildPreview,
      ),
      SettingDef(
        path: const ['play', 'default_track'],
        summary: 'Google Play track used by default',
        kind: SettingKind.choice,
        choices: const [
          SettingChoice('internal'),
          SettingChoice('alpha'),
          SettingChoice('beta'),
          SettingChoice('production'),
        ],
        custom: true,
        current: (c) => c.play.defaultTrack,
        preview: (c, x) => [
          'uploads go to the "${c.play.defaultTrack}" track',
          'release status ${c.play.defaultReleaseStatus}',
        ],
      ),
      SettingDef(
        path: const ['play', 'default_release_status'],
        summary: 'Release status of a Play upload',
        kind: SettingKind.choice,
        choices: const [
          SettingChoice('draft', note: 'saved in Play Console, not rolled out'),
          SettingChoice('completed', note: 'rolled out to the whole track'),
          SettingChoice('inProgress', note: 'staged rollout'),
        ],
        current: (c) => c.play.defaultReleaseStatus,
        preview: (c, x) => [
          switch (c.play.defaultReleaseStatus) {
            'draft' => 'a draft: you roll it out in Play Console',
            'completed' => 'rolled out to everyone on the track',
            'inProgress' => 'staged rollout (needs a user fraction)',
            _ => 'custom status "${c.play.defaultReleaseStatus}"',
          },
        ],
      ),
      SettingDef(
        path: const ['play', 'upload_mapping'],
        summary: 'Upload R8 mapping.txt with the AAB',
        kind: SettingKind.boolean,
        current: (c) => '${c.play.uploadMapping}',
        preview: (c, x) => [
          c.play.uploadMapping
              ? 'mapping.txt is sent so Play de-obfuscates crashes'
              : 'only the AAB is sent',
        ],
      ),
      SettingDef(
        path: const ['play', 'service_account_json'],
        summary: 'Play service account key (JSON file)',
        kind: SettingKind.text,
        hint: 'A path, not the key itself. Env PLAY_SERVICE_ACCOUNT_JSON wins.',
        current: (c) => _opt(c.play.serviceAccountJson),
        preview: (c, x) {
          final f = c.play.serviceAccountJson;
          if (f == null) {
            return ['no key: uploads only mark the ledger'];
          }
          return [
            File(f).existsSync() ? 'key file found' : 'key file NOT found',
            f,
          ];
        },
      ),
      SettingDef(
        path: const ['crashlytics', 'enabled'],
        summary: 'Offer Crashlytics in symbol uploads',
        kind: SettingKind.boolean,
        current: (c) => '${c.crashlytics.enabled}',
        preview: (c, x) => [
          c.crashlytics.enabled
              ? 'Crashlytics is offered, using "${c.crashlytics.cli.join(' ')}"'
              : 'Crashlytics is hidden',
        ],
      ),
      SettingDef(
        path: const ['crashlytics', 'cli'],
        summary: 'Firebase CLI command',
        kind: SettingKind.text,
        hint: 'e.g. firebase, npx firebase-tools',
        current: (c) => c.crashlytics.cli.join(' '),
        preview: (c, x) => [
          'runs "${c.crashlytics.cli.join(' ')} '
              'crashlytics:symbols:upload ..."'
        ],
      ),
      SettingDef(
        path: const ['sentry', 'enabled'],
        summary: 'Offer Sentry in symbol uploads',
        kind: SettingKind.boolean,
        current: (c) => '${c.sentry.enabled}',
        preview: (c, x) => [
          c.sentry.enabled
              ? 'Sentry is offered, using "${c.sentry.cli.join(' ')}"'
              : 'Sentry is hidden',
        ],
      ),
      SettingDef(
        path: const ['sentry', 'cli'],
        summary: 'sentry-cli command',
        kind: SettingKind.text,
        current: (c) => c.sentry.cli.join(' '),
        preview: (c, x) => ['runs "${c.sentry.cli.join(' ')} debug-files ..."'],
      ),
      SettingDef(
        path: const ['sentry', 'org'],
        summary: 'Sentry organization',
        kind: SettingKind.text,
        hint: 'Env SENTRY_ORG wins.',
        current: (c) => _opt(c.sentry.org),
        preview: (c, x) => ['org ${_opt(c.sentry.org)}'],
      ),
      SettingDef(
        path: const ['sentry', 'project'],
        summary: 'Sentry project',
        kind: SettingKind.text,
        hint: 'Env SENTRY_PROJECT wins; flavors can override it.',
        current: (c) => _opt(c.sentry.project),
        preview: (c, x) => ['project ${_opt(c.sentry.project)}'],
      ),
      SettingDef(
        path: const ['sentry', 'url'],
        summary: 'Self-hosted Sentry URL',
        kind: SettingKind.text,
        hint: 'Leave empty for sentry.io. The auth token is never stored here: '
            'set SENTRY_AUTH_TOKEN.',
        current: (c) => c.sentry.url ?? 'sentry.io',
        preview: (c, x) => ['server ${c.sentry.url ?? 'https://sentry.io'}'],
      ),
      SettingDef(
        path: const ['android', 'retrace'],
        summary: 'Path to R8 retrace (Trace a crash)',
        kind: SettingKind.text,
        hint: 'Empty searches PATH and ANDROID_HOME.',
        current: (c) => _opt(c.androidRetrace),
        preview: (c, x) => [
          c.androidRetrace == null
              ? 'found through PATH / ANDROID_HOME'
              : (File(c.androidRetrace!).existsSync()
                  ? 'file found'
                  : 'file NOT found'),
        ],
      ),
      SettingDef(
        path: const ['android', 'ndk_stack'],
        summary: 'Path to ndk-stack (Trace a crash)',
        kind: SettingKind.text,
        hint: 'Empty searches PATH and ANDROID_NDK_HOME.',
        current: (c) => _opt(c.androidNdkStack),
        preview: (c, x) => [
          c.androidNdkStack == null
              ? 'found through PATH / ANDROID_NDK_HOME'
              : (File(c.androidNdkStack!).existsSync()
                  ? 'file found'
                  : 'file NOT found'),
        ],
      ),
    ];

/// Settings of one flavor (`flavors.<name>.*`).
List<SettingDef> flavorSettings(String flavor) {
  List<String> command(AppConfig c, PreviewContext x) =>
      _commandPreview(c, x, flavor: flavor);
  return [
    SettingDef(
      path: ['flavors', flavor, 'target'],
      summary: 'Entry point (-t)',
      kind: SettingKind.text,
      hint: 'e.g. lib/main_$flavor.dart',
      current: (c) => _opt(c.flavor(flavor).target),
      preview: command,
    ),
    SettingDef(
      path: ['flavors', flavor, 'dart_define_file'],
      summary: 'File for --dart-define-from-file',
      kind: SettingKind.text,
      hint: 'e.g. config/$flavor.json',
      current: (c) => _opt(c.flavor(flavor).dartDefineFile),
      preview: command,
    ),
    SettingDef(
      path: ['flavors', flavor, 'package_name'],
      summary: 'Android application id (Play uploads)',
      kind: SettingKind.text,
      current: (c) => _opt(c.flavor(flavor).packageName),
      preview: (c, x) =>
          ['Play uploads use ${_opt(c.flavor(flavor).packageName)}'],
    ),
    SettingDef(
      path: ['flavors', flavor, 'firebase_app_id'],
      summary: 'Firebase app id (Crashlytics)',
      kind: SettingKind.text,
      hint: 'looks like 1:1234567890:android:abc123',
      current: (c) => _opt(c.flavor(flavor).firebaseAppId),
      preview: (c, x) =>
          ['Crashlytics uses ${_opt(c.flavor(flavor).firebaseAppId)}'],
    ),
    SettingDef(
      path: ['flavors', flavor, 'sentry_project'],
      summary: 'Sentry project for this flavor',
      kind: SettingKind.text,
      current: (c) => _opt(c.flavor(flavor).sentryProject),
      preview: (c, x) => [
        'Sentry project ${c.flavor(flavor).sentryProject ?? c.sentry.project ?? '(not set)'}',
      ],
    ),
    SettingDef(
      path: ['flavors', flavor, 'extra_args'],
      summary: 'Extra flutter build arguments',
      kind: SettingKind.list,
      hint: 'Space separated.',
      current: (c) => _list(c.flavor(flavor).extraArgs),
      preview: command,
    ),
  ];
}
