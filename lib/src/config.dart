import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

/// Per-flavor settings. Every field is optional.
class FlavorConfig {
  const FlavorConfig({
    this.target,
    this.dartDefineFile,
    this.packageName,
    this.firebaseAppId,
    this.sentryProject,
    this.extraArgs = const [],
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
  final List<String> extraArgs;

  factory FlavorConfig.fromYaml(Map<Object?, Object?> y) => FlavorConfig(
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
  const PreBuildConfig({
    this.clean = false,
    this.buildRunner = true,
    this.genL10n = true,
    this.buildRunnerArgs = const ['--delete-conflicting-outputs'],
  });

  final bool clean;
  final bool buildRunner;
  final bool genL10n;
  final List<String> buildRunnerArgs;
}

class PlayConfig {
  const PlayConfig({
    this.serviceAccountJson,
    this.defaultTrack = 'internal',
    this.defaultReleaseStatus = 'completed',
    this.uploadMapping = true,
  });

  /// Path to the Google Play service account key (JSON).
  final String? serviceAccountJson;
  final String defaultTrack;
  final String defaultReleaseStatus;

  /// Also upload R8 mapping.txt as the deobfuscation file.
  final bool uploadMapping;

  bool get hasCredentials => serviceAccountJson != null;
}

class CrashlyticsConfig {
  const CrashlyticsConfig({this.enabled = true, this.cli = const ['firebase']});
  final bool enabled;
  final List<String> cli;
}

class SentryConfig {
  const SentryConfig({
    this.enabled = true,
    this.cli = const ['sentry-cli'],
    this.org,
    this.project,
    this.authToken,
    this.url,
  });
  final bool enabled;
  final List<String> cli;
  final String? org;
  final String? project;

  /// Prefer the SENTRY_AUTH_TOKEN environment variable over the config file.
  final String? authToken;

  /// Self-hosted Sentry URL; null for sentry.io.
  final String? url;
}

/// Settings for one Flutter project, read from `flutter_buildkit.yaml`
/// in the project root, with secrets taken from environment variables.
class AppConfig {
  const AppConfig({
    required this.projectDir,
    this.configFile,
    this.outputDir = 'app_builds',
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

  static const fileNames = ['flutter_buildkit.yaml', 'flutter_buildkit.yml'];

  final String projectDir;

  /// The file this config was read from, or null when defaults are used.
  final String? configFile;

  /// Root of the build folder tree, relative to [projectDir] unless absolute.
  final String outputDir;

  /// Ledger path; defaults to `<outputDir>/ledger.json`.
  final String? ledgerFile;

  /// Command used to run Flutter, e.g. `[fvm, flutter]`.
  final List<String> flutter;
  final bool obfuscate;
  final bool splitPerAbi;
  final List<String> extraBuildArgs;
  final PreBuildConfig preBuild;

  /// Paths to `retrace` and `ndk-stack` when they are not on PATH or found
  /// through ANDROID_HOME / ANDROID_NDK_HOME.
  final String? androidRetrace;
  final String? androidNdkStack;
  final Map<String, FlavorConfig> flavors;
  final PlayConfig play;
  final CrashlyticsConfig crashlytics;
  final SentryConfig sentry;

  String get outputRoot => _resolve(outputDir);
  String get ledgerPath => ledgerFile == null
      ? p.join(outputRoot, 'ledger.json')
      : _resolve(ledgerFile!);

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
    return fromYaml(projectDir, y, env: env, configFile: path);
  }

  static AppConfig fromYaml(String projectDir, Map<Object?, Object?> y,
      {Map<String, String> env = const {}, String? configFile}) {
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
      outputDir: y['output_dir'] as String? ?? 'app_builds',
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
            playY['default_release_status'] as String? ?? 'completed',
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

  static Map<Object?, Object?> _map(Object? v) =>
      v is Map ? v.cast<Object?, Object?>() : const {};

  static List<String> _command(Object? v, List<String> fallback) {
    if (v is String && v.trim().isNotEmpty) {
      return v.trim().split(RegExp(r'\s+'));
    }
    if (v is List && v.isNotEmpty) return [for (final s in v) '$s'];
    return fallback;
  }

  static const template = '''
# flutter_buildkit config. Keep this file out of git if it holds secrets;
# prefer the environment variables noted below for credentials.

# Where builds and the ledger are stored (relative to the Flutter project).
output_dir: app_builds
# ledger: app_builds/ledger.json

# Command used to run Flutter ("fvm flutter" works too). Env: FBK_FLUTTER
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
  default_release_status: completed  # draft, completed, inProgress
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

class ConfigException implements Exception {
  ConfigException(this.message);
  final String message;
  @override
  String toString() => message;
}
