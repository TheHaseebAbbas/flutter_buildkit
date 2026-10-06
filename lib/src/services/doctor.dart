import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../config.dart';
import '../flutter_project.dart';
import '../ledger/ledger.dart';
import 'play_publisher.dart';
import 'process_runner.dart';
import 'symbolicator.dart';

/// How a [DoctorCheck] came out.
enum CheckLevel {
  /// Works.
  ok,

  /// Missing or odd, but not needed for everything.
  warn,

  /// Something that will stop a command from working.
  fail,
}

/// One line of the `doctor` report.
class DoctorCheck {
  /// Creates a check result.
  const DoctorCheck(this.name, this.level, this.detail, {this.hint});

  /// What was checked, such as `flutter`.
  final String name;

  /// The outcome.
  final CheckLevel level;

  /// What was found (a version, a path, the error).
  final String detail;

  /// How to fix it, when it is not ok.
  final String? hint;

  /// JSON form for `--json`.
  Map<String, Object?> toJson() => {
        'name': name,
        'level': level.name,
        'detail': detail,
        if (hint != null) 'hint': hint,
      };
}

/// Checks that the tools and settings the other commands rely on are there.
class Doctor {
  /// Creates a doctor for [project] and [config]. [runner] starts the tools
  /// and [env] supplies the environment (both replaceable in tests).
  Doctor({
    required this.project,
    required this.config,
    required this.ledger,
    this.runner = const ProcessRunner(),
    Map<String, String>? env,
    this.publisher,
  }) : env = env ?? Platform.environment;

  /// The Flutter project.
  final FlutterProject project;

  /// Settings in effect.
  final AppConfig config;

  /// The ledger in use.
  final Ledger ledger;

  /// Starts the tools.
  final ProcessRunner runner;

  /// Environment variables.
  final Map<String, String> env;

  /// Used for the online Play check; defaults to one built from [config].
  final PlayPublisher? publisher;

  /// Runs every check. With [online] the Play key is also tried against the
  /// API (it opens and discards an edit; nothing is changed).
  Future<List<DoctorCheck>> run({bool online = false}) async {
    final checks = <DoctorCheck>[];
    checks.add(await _tool('flutter', config.flutter, ['--version'],
        hint:
            'Install Flutter, or set "flutter:" in the config or FBK_FLUTTER.',
        fail: true));
    checks.add(await _tool('git', ['git'], ['--version'],
        hint: 'Install git; builds record the commit and branch with it.'));
    checks.add(await _java());
    checks.add(_androidSdk());
    checks.add(_signingTool());
    if (config.crashlytics.enabled) {
      checks.add(await _tool('firebase', config.crashlytics.cli, ['--version'],
          hint: 'Install the Firebase CLI to upload symbols to Crashlytics '
              '(npm i -g firebase-tools), or set crashlytics.enabled: false.'));
    }
    if (config.sentry.enabled &&
        (config.sentry.org != null || config.sentry.project != null)) {
      checks.add(await _tool('sentry-cli', config.sentry.cli, ['--version'],
          hint: 'Install sentry-cli, or set sentry.enabled: false.'));
      checks.add(config.sentry.authToken == null
          ? const DoctorCheck(
              'sentry token',
              CheckLevel.warn,
              'SENTRY_AUTH_TOKEN is not set',
              hint: 'Export SENTRY_AUTH_TOKEN before uploading to Sentry.',
            )
          : const DoctorCheck('sentry token', CheckLevel.ok, 'set'));
    }
    checks.add(_androidTool('retrace', config.androidRetrace));
    checks.add(_androidTool('ndk-stack', config.androidNdkStack));
    checks.add(await _playKey(online));
    checks.add(_outputDir());
    checks.add(await _disk());
    checks.add(_ledger());
    for (final w in config.warnings) {
      checks.add(DoctorCheck('config', CheckLevel.warn, w));
    }
    return checks;
  }

  Future<DoctorCheck> _tool(
      String name, List<String> command, List<String> args,
      {String? hint, bool fail = false}) async {
    try {
      final r = await runner
          .run([...command, ...args], workingDirectory: project.dir);
      if (r.exitCode == 0) {
        final first = '${r.stdout}\n${r.stderr}'
            .split('\n')
            .map((l) => l.trim())
            .firstWhere((l) => l.isNotEmpty, orElse: () => 'found');
        return DoctorCheck(name, CheckLevel.ok, first);
      }
      return DoctorCheck(name, fail ? CheckLevel.fail : CheckLevel.warn,
          '${command.join(' ')} exited with ${r.exitCode}',
          hint: hint);
    } on ProcessException {
      return DoctorCheck(name, fail ? CheckLevel.fail : CheckLevel.warn,
          '${command.join(' ')} was not found',
          hint: hint);
    }
  }

  Future<DoctorCheck> _java() async {
    try {
      // `java -version` writes to stderr.
      final r = await runner.run(['java', '-version']);
      final text = '${r.stderr}\n${r.stdout}'
          .split('\n')
          .firstWhere((l) => l.trim().isNotEmpty, orElse: () => 'found');
      return r.exitCode == 0
          ? DoctorCheck('java', CheckLevel.ok, text.trim())
          : const DoctorCheck('java', CheckLevel.warn, 'java failed',
              hint: 'Android builds need a JDK (Flutter bundles one with '
                  'Android Studio).');
    } on ProcessException {
      return const DoctorCheck('java', CheckLevel.warn, 'java was not found',
          hint: 'Needed for Gradle, keytool and retrace. Install a JDK or '
              'set JAVA_HOME.');
    }
  }

  DoctorCheck _androidSdk() {
    final sdk = env['ANDROID_HOME'] ?? env['ANDROID_SDK_ROOT'];
    if (sdk == null) {
      return const DoctorCheck(
          'android sdk', CheckLevel.warn, 'ANDROID_HOME is not set',
          hint: 'Set ANDROID_HOME so apksigner, retrace and ndk-stack can be '
              'found.');
    }
    return Directory(sdk).existsSync()
        ? DoctorCheck('android sdk', CheckLevel.ok, sdk)
        : DoctorCheck('android sdk', CheckLevel.warn, '$sdk does not exist',
            hint: 'Fix ANDROID_HOME.');
  }

  DoctorCheck _signingTool() {
    final sdk = env['ANDROID_HOME'] ?? env['ANDROID_SDK_ROOT'];
    final tools = sdk == null ? null : Directory(p.join(sdk, 'build-tools'));
    final found = tools != null &&
        tools.existsSync() &&
        tools.listSync().whereType<Directory>().any((d) => File(p.join(
                d.path, Platform.isWindows ? 'apksigner.bat' : 'apksigner'))
            .existsSync());
    return found
        ? const DoctorCheck('apksigner', CheckLevel.ok, 'found in build-tools')
        : const DoctorCheck(
            'apksigner',
            CheckLevel.warn,
            'not found in the Android SDK; keytool is used instead',
            hint: 'Install Android SDK build-tools to read APK signatures.',
          );
  }

  DoctorCheck _androidTool(String name, String? override) {
    try {
      final path = Symbolicator(config: config, ledger: ledger, env: env)
          .findAndroidTool(name, override);
      if (override != null && !File(override).existsSync()) {
        return DoctorCheck(name, CheckLevel.warn, '$override does not exist',
            hint: 'Fix android.${name.replaceAll('-', '_')} in the config.');
      }
      return DoctorCheck(name, CheckLevel.ok, path);
    } on TraceException catch (e) {
      return DoctorCheck(name, CheckLevel.warn, 'not found',
          hint: e.toString());
    }
  }

  Future<DoctorCheck> _playKey(bool online) async {
    final path = config.play.serviceAccountJson;
    if (path == null) {
      return const DoctorCheck('play key', CheckLevel.warn, 'not configured',
          hint: 'Needed only for "publish". Set play.service_account_json or '
              'PLAY_SERVICE_ACCOUNT_JSON.');
    }
    final file = File(path);
    if (!file.existsSync()) {
      return DoctorCheck('play key', CheckLevel.fail, '$path does not exist',
          hint: 'Fix the path, or remove it if you do not publish from here.');
    }
    try {
      final json = jsonDecode(file.readAsStringSync()) as Map;
      if (json['client_email'] == null || json['private_key'] == null) {
        return const DoctorCheck(
            'play key', CheckLevel.fail, 'not a service account key',
            hint: 'Create a JSON key for a service account in Google Cloud.');
      }
    } on Object {
      return const DoctorCheck('play key', CheckLevel.fail, 'not valid JSON',
          hint: 'Download the key again from Google Cloud.');
    }
    if (!online) {
      return DoctorCheck('play key', CheckLevel.ok,
          '$path (run with --online to try it against Google Play)');
    }
    final package = config.flavors.values
            .map((f) => f.packageName)
            .whereType<String>()
            .firstOrNull ??
        ledger.records
            .map((r) => r.packageName)
            .whereType<String>()
            .firstOrNull;
    if (package == null) {
      return const DoctorCheck('play key', CheckLevel.warn,
          'key is valid; no package name known to try it with',
          hint: 'Set flavors.<flavor>.package_name in the config.');
    }
    try {
      await (publisher ?? PlayPublisher(config: config, ledger: ledger))
          .checkAccess(package);
      return DoctorCheck('play key', CheckLevel.ok, 'can edit $package');
    } on PlayException catch (e) {
      return DoctorCheck('play key', CheckLevel.fail, e.message,
          hint: 'Grant the service account release access to the app in '
              'Play Console (Users and permissions).');
    } on Object catch (e) {
      return DoctorCheck('play key', CheckLevel.fail, '$e');
    }
  }

  DoctorCheck _outputDir() {
    final dir = Directory(config.outputRoot);
    try {
      dir.createSync(recursive: true);
      final probe = File(p.join(dir.path, '.fbk_write_test'))
        ..writeAsStringSync('x');
      probe.deleteSync();
      return DoctorCheck('output folder', CheckLevel.ok, dir.path);
    } on FileSystemException catch (e) {
      return DoctorCheck(
          'output folder', CheckLevel.fail, '${dir.path} is not writable',
          hint: e.message);
    }
  }

  Future<DoctorCheck> _disk() async {
    if (Platform.isWindows) {
      return const DoctorCheck(
          'free disk space', CheckLevel.ok, 'not checked on Windows');
    }
    try {
      final dir = Directory(config.outputRoot);
      final path = dir.existsSync() ? dir.path : project.dir;
      final r = await runner.run(['df', '-k', path]);
      final lines = '${r.stdout}'.trim().split('\n');
      if (r.exitCode != 0 || lines.length < 2) {
        return const DoctorCheck('free disk space', CheckLevel.ok, 'unknown');
      }
      final cols = lines.last.trim().split(RegExp(r'\s+'));
      final freeKb = int.tryParse(cols[3]);
      if (freeKb == null) {
        return const DoctorCheck('free disk space', CheckLevel.ok, 'unknown');
      }
      final gb = freeKb / (1024 * 1024);
      final text = '${gb.toStringAsFixed(1)} GB free';
      return gb < 5
          ? DoctorCheck('free disk space', CheckLevel.warn, text,
              hint: 'Release builds need a few GB; try "prune" or delete old '
                  'builds.')
          : DoctorCheck('free disk space', CheckLevel.ok, text);
    } on Object {
      return const DoctorCheck('free disk space', CheckLevel.ok, 'unknown');
    }
  }

  DoctorCheck _ledger() => DoctorCheck('ledger', CheckLevel.ok,
      '${ledger.file.path} (${ledger.records.length} builds)');
}
