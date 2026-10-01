import 'dart:io';

import 'package:path/path.dart' as p;

import '../config.dart';
import '../flutter_project.dart';
import '../ledger/ledger.dart';
import '../model/build_record.dart';
import 'process_runner.dart';

/// Thrown when symbols cannot be uploaded, e.g. none exist or settings are missing.
class SymbolUploadException implements Exception {
  /// Creates an exception carrying [message].
  SymbolUploadException(this.message);

  /// Human-readable description of what went wrong.
  final String message;
  @override
  String toString() => message;
}

/// Uploads a build's debug symbols to Firebase Crashlytics and Sentry by
/// shelling out to the `firebase` and `sentry-cli` tools.
class SymbolUploader {
  /// Creates an uploader for [project] using [config] and [ledger]; [runner] executes the CLI tools and [log] receives output.
  SymbolUploader({
    required this.project,
    required this.config,
    required this.ledger,
    this.runner = const ProcessRunner(),
    void Function(String)? log,
  }) : log = log ?? ((_) {});

  /// Project, used to locate Firebase and iOS Pods files.
  final FlutterProject project;

  /// Configuration for Crashlytics and Sentry.
  final AppConfig config;

  /// Ledger used to resolve stored symbol paths.
  final Ledger ledger;

  /// Runs the `firebase` and `sentry-cli` processes.
  final ProcessRunner runner;

  /// Receives progress and process output lines.
  final void Function(String) log;

  String? _abs(String? relative) =>
      relative == null ? null : ledger.resolve(relative);

  /// Commands that would upload [record]'s symbols to [target].
  List<List<String>> commandsFor(BuildRecord record, String target) {
    final symbols = _abs(record.symbolsDir);
    if (symbols == null || !Directory(symbols).existsSync()) {
      throw SymbolUploadException('Build ${record.id} has no symbols folder. '
          'Only obfuscated profile/release builds (obfuscate: true) keep '
          'Dart symbols.');
    }
    switch (target) {
      case SymbolTargets.crashlytics:
        final appId = crashlyticsAppId(record);
        if (appId == null) {
          throw SymbolUploadException('No Firebase app id for flavor '
              '"${record.flavorLabel}". Add google-services.json / '
              'GoogleService-Info.plist or set flavors.<flavor>.firebase_app_id.');
        }
        final dart = p.join(symbols, 'dart');
        final commands = <List<String>>[];
        if (Directory(dart).existsSync()) {
          commands.add([
            ...config.crashlytics.cli,
            'crashlytics:symbols:upload',
            '--app=$appId',
            dart,
          ]);
        }
        final native = p.join(symbols, 'native');
        if (Directory(native).existsSync()) {
          commands.add([
            ...config.crashlytics.cli,
            'crashlytics:symbols:upload',
            '--app=$appId',
            native,
          ]);
        }
        final dsyms = p.join(symbols, 'dSYMs');
        final script = p.join(project.dir, 'ios', 'Pods', 'FirebaseCrashlytics',
            'upload-symbols');
        final plist = _googleServicePlist(record.flavor);
        if (Directory(dsyms).existsSync() &&
            File(script).existsSync() &&
            plist != null) {
          commands.add([script, '-gsp', plist, '-p', 'ios', dsyms]);
        }
        if (commands.isEmpty) {
          throw SymbolUploadException(
              'Nothing to upload to Crashlytics in $symbols.');
        }
        return commands;
      case SymbolTargets.sentry:
        final s = config.sentry;
        final project = config.flavor(record.flavor).sentryProject ?? s.project;
        if (s.org == null || project == null) {
          throw SymbolUploadException('Sentry org/project are not set. Set '
              'sentry.org and sentry.project in the config, or SENTRY_ORG and '
              'SENTRY_PROJECT.');
        }
        final base = [
          ...s.cli,
          if (s.url != null) ...['--url', s.url!],
        ];
        final scope = ['--org', s.org!, '--project', project];
        return [
          [...base, 'debug-files', 'upload', ...scope, '--wait', symbols],
          if (_abs(record.mappingFile) case final mapping?
              when File(mapping).existsSync())
            [...base, 'upload-proguard', ...scope, mapping],
        ];
      default:
        throw ArgumentError.value(target, 'target');
    }
  }

  /// Firebase app id for [record]'s flavor, or null if none is found.
  ///
  /// Uses the configured id first, then `google-services.json` (Android) or `GoogleService-Info.plist` (iOS).
  String? crashlyticsAppId(BuildRecord record) {
    final configured = config.flavor(record.flavor).firebaseAppId;
    if (configured != null) return configured;
    if (record.type.isAndroid) {
      return project.firebaseAppId(record.flavor, record.packageName);
    }
    final plist = _googleServicePlist(record.flavor);
    if (plist == null) return null;
    return RegExp(r'<key>GOOGLE_APP_ID</key>\s*<string>([^<]+)</string>')
        .firstMatch(File(plist).readAsStringSync())
        ?.group(1);
  }

  String? _googleServicePlist(String? flavor) {
    final ios = p.join(project.dir, 'ios');
    final candidates = [
      if (flavor != null) ...[
        p.join(ios, 'config', flavor, 'GoogleService-Info.plist'),
        p.join(ios, 'Runner', flavor, 'GoogleService-Info.plist'),
        p.join(ios, flavor, 'GoogleService-Info.plist'),
      ],
      p.join(ios, 'Runner', 'GoogleService-Info.plist'),
    ];
    for (final c in candidates) {
      if (File(c).existsSync()) return c;
    }
    return null;
  }

  /// Uploads to [target] and records the time in the ledger.
  Future<BuildRecord> upload(BuildRecord record, String target) async {
    final commands = commandsFor(record, target);
    final env = <String, String>{
      if (target == SymbolTargets.sentry && config.sentry.authToken != null)
        'SENTRY_AUTH_TOKEN': config.sentry.authToken!,
    };
    for (final command in commands) {
      log('\$ ${describeCommand(command)}\n');
      final int code;
      try {
        code = await runner.stream(command,
            workingDirectory: project.dir, environment: env);
      } on ProcessException catch (e) {
        throw SymbolUploadException(
            'Could not start ${command.first}: ${e.message}. Install it '
            '(${target == SymbolTargets.sentry ? 'https://docs.sentry.io/cli/installation/' : 'npm install -g firebase-tools'}) '
            'or set $target.cli in the config.');
      }
      if (code != 0) {
        throw SymbolUploadException('$target upload failed (exit code $code). '
            'The ledger was not changed.');
      }
    }
    return ledger.update(
      record.id,
      (r) => r.copyWith(
          symbolUploads: {...r.symbolUploads, target: DateTime.now().toUtc()}),
    );
  }
}
