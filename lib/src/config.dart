import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'build_paths.dart';
import 'services/process_runner.dart';

/// Per-flavor settings. Every field is optional.
class FlavorConfig {
  /// Creates a flavor configuration; all fields are optional.
  const FlavorConfig({
    this.target,
    this.dartDefineFile,
    this.packageName,
    this.firebaseAppId,
    this.sentryProject,
    this.extraArgs = const [],
    this.entryPoints = const {},
  });

  /// Entry point, e.g. `lib/main_dev.dart`.
  final String? target;

  /// File passed to `--dart-define-from-file`.
  final String? dartDefineFile;

  /// Android application id, used for Google Play uploads.
  final String? packageName;

  /// Firebase app id for Crashlytics (`1:123:android:abc`).
  final String? firebaseAppId;

  /// Overrides `sentry.project` for this flavor.
  final String? sentryProject;

  /// Extra arguments appended to the Flutter build command for this flavor.
  final List<String> extraArgs;

  /// Named entry points for this flavor (`name: path`). When set they
  /// replace [target] and the top-level `entry_points`.
  final Map<String, String> entryPoints;

  /// Reads a flavor from its YAML map, using the keys `target`,
  /// `dart_define_file`, `package_name`, `firebase_app_id`, `sentry_project`,
  /// `extra_args` and `entry_points`.
  factory FlavorConfig.fromYaml(Map<Object?, Object?> y) => FlavorConfig(
        entryPoints: AppConfig.parseEntryPoints(
            y['entry_points'], 'flavors.*.entry_points'),
        target: y['target'] as String?,
        dartDefineFile: y['dart_define_file'] as String?,
        packageName: y['package_name'] as String?,
        firebaseAppId: y['firebase_app_id'] as String?,
        sentryProject: y['sentry_project'] as String?,
        extraArgs: _stringList(y['extra_args']),
      );
}

/// Which pre-build steps are ticked by default in the build menu.
class PreBuildConfig {
  /// Creates the pre-build defaults: no clean, build_runner and gen-l10n on.
  const PreBuildConfig({
    this.clean = false,
    this.buildRunner = true,
    this.genL10n = true,
    this.buildRunnerArgs = const ['--delete-conflicting-outputs'],
  });

  /// Run `flutter clean` and `pub get` first (`pre_build.clean`, default false).
  final bool clean;

  /// Run `build_runner build` first (`pre_build.build_runner`, default true).
  final bool buildRunner;

  /// Run `flutter gen-l10n` first (`pre_build.gen_l10n`, default true).
  final bool genL10n;

  /// Arguments for `build_runner build` (`pre_build.build_runner_args`).
  final List<String> buildRunnerArgs;
}

/// Google Play upload settings, from the `play:` section.
class PlayConfig {
  /// Creates Play settings; uploads default to the internal track.
  const PlayConfig({
    this.serviceAccountJson,
    this.defaultTrack = 'internal',
    this.defaultReleaseStatus = 'draft',
    this.uploadMapping = true,
  });

  /// Path to the Google Play service account key (JSON).
  final String? serviceAccountJson;

  /// Track to upload to by default (`play.default_track`), e.g. `internal`.
  final String defaultTrack;

  /// Release status for uploads (`play.default_release_status`), `draft`
  /// unless set. A draft is finished in Play Console, so a wrong pick never
  /// rolls out to users.
  final String defaultReleaseStatus;

  /// Also upload R8 mapping.txt as the deobfuscation file.
  final bool uploadMapping;

  /// Whether a service account key path is configured.
  bool get hasCredentials => serviceAccountJson != null;
}

/// Firebase Crashlytics symbol upload settings, from the `crashlytics:` section.
class CrashlyticsConfig {
  /// Creates Crashlytics settings; enabled and using `firebase` by default.
  const CrashlyticsConfig({this.enabled = true, this.cli = const ['firebase']});

  /// Whether Crashlytics symbol upload is offered (`crashlytics.enabled`).
  final bool enabled;

  /// Command used to run the Firebase CLI (`crashlytics.cli`).
  final List<String> cli;
}

/// Sentry symbol upload settings, from the `sentry:` section.
class SentryConfig {
  /// Creates Sentry settings; enabled and using `sentry-cli` by default.
  const SentryConfig({
    this.enabled = true,
    this.cli = const ['sentry-cli'],
    this.org,
    this.project,
    this.authToken,
    this.url,
  });

  /// Whether Sentry upload is offered (`sentry.enabled`).
  final bool enabled;

  /// Command used to run Sentry CLI (`sentry.cli`).
  final List<String> cli;

  /// Sentry organization slug (`sentry.org`, or SENTRY_ORG); null when unset.
  final String? org;

  /// Sentry project slug (`sentry.project`, or SENTRY_PROJECT); null when unset.
  final String? project;

  /// Prefer the SENTRY_AUTH_TOKEN environment variable over the config file.
  final String? authToken;

  /// Self-hosted Sentry URL; null for sentry.io.
  final String? url;
}

/// Settings for one Flutter project, read from `flutter_buildkit.yaml`
/// in the project root, with secrets taken from environment variables.
class AppConfig {
  /// Creates a config for [projectDir]; unset options take their defaults.
  const AppConfig({
    required this.projectDir,
    this.configFile,
    this.localConfigFile,
    this.outputDir = 'app_builds',
    this.outputLayout,
    this.fileName,
    this.entryPoints = const {},
    this.ledgerFile,
    this.flutter = const ['flutter'],
    this.obfuscate = true,
    this.splitPerAbi = false,
    this.extraBuildArgs = const [],
    this.preBuild = const PreBuildConfig(),
    this.androidRetrace,
    this.androidNdkStack,
    this.flavors = const {},
    this.play = const PlayConfig(),
    this.crashlytics = const CrashlyticsConfig(),
    this.sentry = const SentryConfig(),
  });

  /// Config file names looked for in the project root, in order.
  static const fileNames = ['flutter_buildkit.yaml', 'flutter_buildkit.yml'];

  /// Absolute or relative path of the Flutter project root.
  final String projectDir;

  /// The file this config was read from, or null when defaults are used.
  final String? configFile;

  /// The personal overlay (`flutter_buildkit.local.yaml`) merged over
  /// [configFile], or null when there is none.
  final String? localConfigFile;

  /// Root of the build folder tree, relative to [projectDir] unless absolute.
  final String outputDir;

  /// Folder layout inside [outputDir]: a preset id or a template (see
  /// [LayoutPreset], [PathTemplate]). Null means the default.
  final String? outputLayout;

  /// Artifact file name template, without extension.
  final String? fileName;

  /// Named entry points shared by all flavors (`name: path`). A path may use
  /// `{flavor}`, e.g. `lib/main_{flavor}.dart`.
  final Map<String, String> entryPoints;

  /// Ledger path; defaults to `<outputDir>/ledger.json`.
  final String? ledgerFile;

  /// Command used to run Flutter, e.g. `[fvm, flutter]`.
  final List<String> flutter;

  /// Obfuscate release and profile builds (`obfuscate`, default true).
  final bool obfuscate;

  /// Build one APK per ABI (`split_per_abi`, default false).
  final bool splitPerAbi;

  /// Extra arguments added to every build (`extra_build_args`).
  final List<String> extraBuildArgs;

  /// Default pre-build steps (`pre_build`).
  final PreBuildConfig preBuild;

  /// Paths to `retrace` and `ndk-stack` when they are not on PATH or found
  /// through ANDROID_HOME / ANDROID_NDK_HOME.
  final String? androidRetrace;

  /// Path to `ndk-stack` (`android.ndk_stack`, or FBK_NDK_STACK).
  final String? androidNdkStack;

  /// Per-flavor settings by flavor name (`flavors`).
  final Map<String, FlavorConfig> flavors;

  /// Google Play settings (`play`).
  final PlayConfig play;

  /// Crashlytics settings (`crashlytics`).
  final CrashlyticsConfig crashlytics;

  /// Sentry settings (`sentry`).
  final SentryConfig sentry;

  /// [outputDir] resolved to a normalized absolute path.
  String get outputRoot => _resolve(outputDir);

  /// True when [outputRoot] is inside the Flutter project, where the app
  /// name is already known from the project folder.
  bool get outputInsideProject => p.isWithin(projectDir, outputRoot);

  /// The layout actually used. A preset that starts with `{app}/` drops that
  /// folder while the output lives inside the project (it would only repeat
  /// the project's name) and keeps it when the output is somewhere else, so
  /// several apps can share one folder. Custom templates are used as written.
  String get effectiveLayout {
    final layout = outputLayout ?? LayoutPreset.byFlavor.template;
    final isPreset = LayoutPreset.values.any((x) => x.template == layout);
    const prefix = '{app}/';
    if (isPreset && layout.startsWith(prefix) && outputInsideProject) {
      return layout.substring(prefix.length);
    }
    return layout;
  }

  /// Resolved path of the ledger file, `<outputRoot>/ledger.json` by default.
  String get ledgerPath => ledgerFile == null
      ? p.join(outputRoot, 'ledger.json')
      : _resolve(ledgerFile!);

  /// Settings for the flavor [name]; empty defaults when null or unknown.
  FlavorConfig flavor(String? name) => name == null
      ? const FlavorConfig()
      : flavors[name] ?? const FlavorConfig();

  String _resolve(String path) =>
      p.normalize(p.isAbsolute(path) ? path : p.join(projectDir, path));

  /// Loads config for [projectDir]. [explicitPath] wins over the default
  /// file names; [env] overrides secrets (defaults to the process env).
  static AppConfig load(String projectDir,
      {String? explicitPath, Map<String, String>? env}) {
    env ??= Platform.environment;
    String? path = explicitPath;
    if (path == null) {
      for (final name in fileNames) {
        final candidate = p.join(projectDir, name);
        if (File(candidate).existsSync()) {
          path = candidate;
          break;
        }
      }
    }
    Map<Object?, Object?> y = const {};
    if (path != null) {
      final file = File(path);
      if (!file.existsSync()) {
        throw ConfigException('Config file not found: $path');
      }
      final doc = loadYaml(file.readAsStringSync());
      if (doc != null && doc is! Map) {
        throw ConfigException('$path must contain a YAML map.');
      }
      y = (doc as Map?) ?? const {};
    }
    // A personal overlay next to the config (`flutter_buildkit.local.yaml`)
    // wins over it: commit the shared file, keep secrets and machine paths
    // in the overlay and out of git.
    String? local;
    final base = path ?? p.join(projectDir, fileNames.first);
    for (final candidate in [
      '${p.withoutExtension(base)}.local${p.extension(base)}',
      if (path == null) p.join(projectDir, 'flutter_buildkit.local.yml'),
    ]) {
      if (File(candidate).existsSync()) {
        local = candidate;
        break;
      }
    }
    if (local != null) {
      final doc = loadYaml(File(local).readAsStringSync());
      if (doc != null && doc is! Map) {
        throw ConfigException('$local must contain a YAML map.');
      }
      y = _merge(y, (doc as Map?) ?? const {});
    }
    return fromYaml(projectDir, y,
        env: env, configFile: path, localConfigFile: local);
  }

  /// Builds a config from the parsed YAML map [y].
  ///
  /// [env] overrides some keys and supplies secrets; [configFile] is only
  /// recorded. Throws [ConfigException] for invalid values.
  static AppConfig fromYaml(String projectDir, Map<Object?, Object?> y,
      {Map<String, String> env = const {},
      String? configFile,
      String? localConfigFile}) {
    final playY = _map(y['play']);
    final crashY = _map(y['crashlytics']);
    final sentryY = _map(y['sentry']);
    final flavorsY = _map(y['flavors']);
    final preY = _map(y['pre_build']);
    final androidY = _map(y['android']);

    String? expand(String? path) {
      if (path == null || path.isEmpty) return null;
      final home = env['HOME'] ?? env['USERPROFILE'];
      if (path.startsWith('~') && home != null) {
        path = p.join(home, path.substring(path.startsWith('~/') ? 2 : 1));
      }
      return p.isAbsolute(path) ? path : p.join(projectDir, path);
    }

    return AppConfig(
      projectDir: projectDir,
      configFile: configFile,
      localConfigFile: localConfigFile,
      outputDir: y['output_dir'] as String? ?? 'app_builds',
      outputLayout: _layout(y['output_layout']),
      fileName: _fileName(y['file_name']),
      entryPoints: parseEntryPoints(y['entry_points'], 'entry_points'),
      ledgerFile: y['ledger'] as String?,
      flutter: _command(env['FBK_FLUTTER'] ?? y['flutter'], const ['flutter']),
      obfuscate: y['obfuscate'] as bool? ?? true,
      splitPerAbi: y['split_per_abi'] as bool? ?? false,
      extraBuildArgs: _stringList(y['extra_build_args']),
      androidRetrace: env['FBK_RETRACE'] ?? androidY['retrace'] as String?,
      androidNdkStack: env['FBK_NDK_STACK'] ?? androidY['ndk_stack'] as String?,
      preBuild: PreBuildConfig(
        clean: preY['clean'] as bool? ?? false,
        buildRunner: preY['build_runner'] as bool? ?? true,
        genL10n: preY['gen_l10n'] as bool? ?? true,
        buildRunnerArgs: preY['build_runner_args'] == null
            ? const ['--delete-conflicting-outputs']
            : _stringList(preY['build_runner_args']),
      ),
      flavors: {
        for (final e in flavorsY.entries)
          '${e.key}': FlavorConfig.fromYaml(_map(e.value)),
      },
      play: PlayConfig(
        serviceAccountJson: expand(env['PLAY_SERVICE_ACCOUNT_JSON'] ??
            playY['service_account_json'] as String?),
        defaultTrack: playY['default_track'] as String? ?? 'internal',
        defaultReleaseStatus:
            playY['default_release_status'] as String? ?? 'draft',
        uploadMapping: playY['upload_mapping'] as bool? ?? true,
      ),
      crashlytics: CrashlyticsConfig(
        enabled: crashY['enabled'] as bool? ?? true,
        cli: _command(crashY['cli'], const ['firebase']),
      ),
      sentry: SentryConfig(
        enabled: sentryY['enabled'] as bool? ?? true,
        cli: _command(sentryY['cli'], const ['sentry-cli']),
        org: env['SENTRY_ORG'] ?? sentryY['org'] as String?,
        project: env['SENTRY_PROJECT'] ?? sentryY['project'] as String?,
        authToken: env['SENTRY_AUTH_TOKEN'] ?? sentryY['auth_token'] as String?,
        url: env['SENTRY_URL'] ?? sentryY['url'] as String?,
      ),
    );
  }

  static String? _layout(Object? v) {
    if (v == null) return null;
    final resolved = BuildPaths.resolveLayout('$v');
    try {
      PathTemplate.parse(resolved, isFolder: true);
    } on PathTemplateException catch (e) {
      throw ConfigException('output_layout: $e Presets: '
          '${LayoutPreset.values.map((p) => p.id).join(', ')}.');
    }
    return resolved;
  }

  static String? _fileName(Object? v) {
    if (v == null) return null;
    try {
      PathTemplate.parse('$v', isFolder: false);
    } on PathTemplateException catch (e) {
      throw ConfigException('file_name: $e');
    }
    return '$v';
  }

  /// Reads `entry_points:` (`name: path`), checking names and paths.
  static Map<String, String> parseEntryPoints(Object? v, String where) {
    if (v == null) return const {};
    if (v is! Map) {
      throw ConfigException('$where must map a name to a Dart file, e.g. '
          'admin: lib/main_admin.dart.');
    }
    final out = <String, String>{};
    for (final e in v.entries) {
      final name = '${e.key}';
      if (!RegExp(r'^[A-Za-z][A-Za-z0-9_-]*$').hasMatch(name)) {
        throw ConfigException('$where: "$name" is not a valid name (letters, '
            'digits, "_" or "-", starting with a letter).');
      }
      final path = e.value;
      if (path is! String || path.trim().isEmpty) {
        throw ConfigException('$where.$name needs a path to a Dart file.');
      }
      out[name] = path.trim().replaceAll(r'\', '/');
    }
    return out;
  }

  /// [overlay] merged over [base]: maps are merged key by key, everything
  /// else (including lists) is replaced.
  static Map<Object?, Object?> _merge(
      Map<Object?, Object?> base, Map<Object?, Object?> overlay) {
    final result = Map<Object?, Object?>.of(base);
    for (final e in overlay.entries) {
      final old = result[e.key];
      result[e.key] = old is Map && e.value is Map
          ? _merge(old.cast<Object?, Object?>(),
              (e.value as Map).cast<Object?, Object?>())
          : e.value;
    }
    return result;
  }

  static Map<Object?, Object?> _map(Object? v) =>
      v is Map ? v.cast<Object?, Object?>() : const {};

  static List<String> _command(Object? v, List<String> fallback) {
    if (v is String && v.trim().isNotEmpty) {
      return splitCommandLine(v.trim());
    }
    if (v is List && v.isNotEmpty) return [for (final s in v) '$s'];
    return fallback;
  }

  /// The effective settings, one `key: value` per line, secrets masked.
  String describe() {
    String mask(String? v) =>
        v == null ? '(not set)' : 'set (${v.length} chars)';
    String list(List<String> v) => v.isEmpty ? '[]' : v.join(' ');
    final lines = <String, String>{
      'config file': configFile ?? '(none; defaults)',
      if (localConfigFile != null) 'local overlay': localConfigFile!,
      'project': projectDir,
      'output_dir': outputRoot,
      'output_layout': effectiveLayout,
      'file_name': fileName ?? BuildPaths.defaultFileName,
      'entry_points': entryPoints.isEmpty
          ? '(none; detected from lib/main*.dart)'
          : entryPoints.entries.map((e) => '${e.key}=${e.value}').join(' '),
      'ledger': ledgerPath,
      'flutter': flutter.join(' '),
      'obfuscate': '$obfuscate',
      'split_per_abi': '$splitPerAbi',
      'extra_build_args': list(extraBuildArgs),
      'pre_build.clean': '${preBuild.clean}',
      'pre_build.build_runner': '${preBuild.buildRunner}',
      'pre_build.gen_l10n': '${preBuild.genL10n}',
      'pre_build.build_runner_args': list(preBuild.buildRunnerArgs),
      'play.service_account_json': play.serviceAccountJson ?? '(not set)',
      'play.default_track': play.defaultTrack,
      'play.default_release_status': play.defaultReleaseStatus,
      'play.upload_mapping': '${play.uploadMapping}',
      'crashlytics.enabled': '${crashlytics.enabled}',
      'crashlytics.cli': crashlytics.cli.join(' '),
      'sentry.enabled': '${sentry.enabled}',
      'sentry.cli': sentry.cli.join(' '),
      'sentry.org': sentry.org ?? '(not set)',
      'sentry.project': sentry.project ?? '(not set)',
      'sentry.url': sentry.url ?? 'sentry.io',
      'sentry.auth_token': mask(sentry.authToken),
      'android.retrace': androidRetrace ?? '(PATH / ANDROID_HOME)',
      'android.ndk_stack': androidNdkStack ?? '(PATH / ANDROID_NDK_HOME)',
    };
    for (final e in flavors.entries) {
      final f = e.value;
      lines['flavors.${e.key}'] = [
        if (f.target != null) 'target=${f.target}',
        if (f.dartDefineFile != null) 'dart_define_file=${f.dartDefineFile}',
        if (f.packageName != null) 'package_name=${f.packageName}',
        if (f.firebaseAppId != null) 'firebase_app_id=${f.firebaseAppId}',
        if (f.sentryProject != null) 'sentry_project=${f.sentryProject}',
        if (f.extraArgs.isNotEmpty) 'extra_args=${f.extraArgs.join(' ')}',
        if (f.entryPoints.isNotEmpty)
          'entry_points=${f.entryPoints.entries.map((e) => '${e.key}:${e.value}').join(',')}',
      ].join(' ');
    }
    final width =
        lines.keys.map((k) => k.length).reduce((a, b) => a > b ? a : b);
    return lines.entries
        .map((e) => '${e.key.padRight(width)}  ${e.value}')
        .join('\n');
  }

  /// Commented starter config written for new projects.
  static const template = '''
# flutter_buildkit config. Commit this file so the team shares flavors and
# layout. Put secrets and machine paths in flutter_buildkit.local.yaml (same
# keys, wins over this file) and keep that one out of git. Prefer
# the environment variables noted below for credentials.

# Where builds and the ledger are stored (relative to the Flutter project).
output_dir: app_builds

# Folder layout inside output_dir. A preset or your own template.
#   by-flavor   {app}/{flavor}/{mode}/{version}-{datetime}            (default)
#   by-version  {app}/{version}/{flavor}-{mode}-{datetime}
#   by-month    {year}-{month}/{app}-{flavor}-{mode}-{version}-{datetime}
#   flat        {app}-{flavor}-{mode}-{version}-{datetime}
# A preset starting with {app}/ drops that folder while output_dir is inside
# the project, and keeps it when output_dir points elsewhere (e.g. ../builds).
# Tokens: {app} {flavor} {mode} {versionName} {versionCode} {version}
#         {datetime} {date} {time} {year} {month} {type}
output_layout: by-flavor

# Artifact file name (no extension). {version} = <versionName>-b<versionCode>.
file_name: "{app}-{flavor}-{mode}-{version}-{datetime}"
# ledger: app_builds/ledger.json

# Several Dart entry points (main files) to build. Leave out to build
# lib/main.dart (or lib/main_<flavor>.dart); extra lib/main_*.dart files are
# offered automatically. Each name is added to the artifact and folder names.
# {flavor} in a path is replaced by the flavor being built. A flavor can list
# its own under flavors.<name>.entry_points.
# entry_points:
#   main: lib/main.dart
#   admin: lib/main_admin.dart
#   kiosk: lib/main_{flavor}_kiosk.dart

# Command used to run Flutter ("fvm flutter" works too; quote a path with
# spaces: '"C:\\Program Files\\flutter\\bin\\flutter.bat"'). Env: FBK_FLUTTER
flutter: flutter

# Obfuscate release/profile builds and keep Dart symbols for crash tools.
obfuscate: true
split_per_abi: false
extra_build_args: []

# Steps pre-ticked in the build menu (you can change them per build).
# build_runner and gen-l10n only run when the project uses them.
pre_build:
  clean: false            # flutter clean + flutter pub get
  build_runner: true      # build_runner build
  gen_l10n: true          # flutter gen-l10n
  build_runner_args: [--delete-conflicting-outputs]

# Optional per-flavor settings. Flavors are also detected from Gradle and
# Xcode schemes; anything set here overrides what was detected.
flavors:
  # dev:
  #   target: lib/main_dev.dart
  #   dart_define_file: config/dev.json
  #   package_name: com.example.app.dev
  #   firebase_app_id: 1:1234567890:android:abc123
  #   sentry_project: my-app-dev
  #   entry_points: {main: lib/main_dev.dart, admin: lib/admin_dev.dart}
  # prod:
  #   target: lib/main_prod.dart
  #   package_name: com.example.app

# Tools used by the "Trace crash" menu when they are not on PATH.
# android:
#   retrace: /path/to/Android/Sdk/cmdline-tools/latest/bin/retrace
#   ndk_stack: /path/to/Android/Sdk/ndk/<version>/ndk-stack

play:
  # Service account key with access to the app in Play Console.
  # Env: PLAY_SERVICE_ACCOUNT_JSON (path to the key file)
  # service_account_json: ~/.secrets/play-service-account.json
  default_track: internal          # internal, alpha, beta, production
  default_release_status: draft    # draft, completed, inProgress
  upload_mapping: true

crashlytics:
  enabled: true
  cli: firebase                    # uses your `firebase login` session

sentry:
  enabled: true
  cli: sentry-cli
  # org: my-org                    # Env: SENTRY_ORG
  # project: my-app                # Env: SENTRY_PROJECT
  # url: https://sentry.example.com  # self-hosted only. Env: SENTRY_URL
  # Auth token: set SENTRY_AUTH_TOKEN in your environment.
''';
}

List<String> _stringList(Object? v) =>
    v is List ? [for (final s in v) '$s'] : const [];

/// Thrown when the config file or one of its values is invalid.
class ConfigException implements Exception {
  /// Creates an exception with [message].
  ConfigException(this.message);

  /// What is wrong, phrased for the user.
  final String message;
  @override
  String toString() => message;
}
