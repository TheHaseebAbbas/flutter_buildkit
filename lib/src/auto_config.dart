import 'dart:io';

import 'package:path/path.dart' as p;

import 'entry_points.dart';
import 'flutter_project.dart';

/// One value found by reading the project, and why it was chosen.
class Suggestion {
  /// Creates a suggestion for the key at [path] with [value] and [reason].
  const Suggestion(this.path, this.value, this.reason);

  /// Config key path, e.g. `['flavors', 'dev', 'target']`.
  final List<String> path;

  /// `bool`, `String` or `List<String>`.
  final Object value;

  /// Short explanation shown to the user for why this was suggested.
  final String reason;

  /// The key path joined with dots, e.g. `pre_build.clean`.
  String get key => path.join('.');
}

/// Reads the Flutter project and proposes config values: flavors with their
/// entry point, dart-define file, package name and Firebase app id, extra
/// entry points, whether build_runner / gen-l10n / Crashlytics / Sentry are
/// used, FVM, a layout that fits, and a Play key named in fastlane.
///
/// Only paths and identifiers are read. Secrets (the Sentry auth token, the
/// contents of a service account key) are never copied.
List<Suggestion> suggestConfig(FlutterProject project) {
  final out = <Suggestion>[];
  final flavors = project.flavors;

  bool exists(String rel) => File(p.join(project.dir, rel)).existsSync();

  // Flutter command.
  if (exists('.fvmrc') ||
      exists(p.join('.fvm', 'fvm_config.json')) ||
      Directory(p.join(project.dir, '.fvm', 'flutter_sdk')).existsSync()) {
    out.add(const Suggestion(['flutter'], 'fvm flutter',
        'the project pins a Flutter version with FVM'));
  }

  // Folder layout.
  out.add(flavors.isEmpty
      ? const Suggestion(['output_layout'], '{mode}/{version}-{datetime}',
          'no flavors, so a flavor folder would only say "default"')
      : Suggestion(
          ['output_layout'],
          'by-flavor',
          '${flavors.length} flavor${flavors.length == 1 ? '' : 's'} '
              '(${flavors.join(', ')}): one folder tree per flavor'));

  // Pre-build steps.
  out.add(Suggestion(
      ['pre_build', 'build_runner'],
      project.usesBuildRunner,
      project.usesBuildRunner
          ? 'build_runner is a dependency'
          : 'build_runner is not used'));
  out.add(Suggestion(
      ['pre_build', 'gen_l10n'],
      project.usesGenL10n,
      project.usesGenL10n
          ? 'l10n.yaml or flutter: generate: true found'
          : 'no localization generation found'));

  // Entry points.
  final extras = detectEntryPoints(project, flavors);
  if (extras.isNotEmpty) {
    void entries(List<String> base, String? mainPath, String why) {
      out.add(Suggestion([...base, 'main'], mainPath ?? 'lib/main.dart', why));
      for (final e in extras.entries) {
        out.add(Suggestion([...base, e.key], e.value, 'found ${e.value}'));
      }
    }

    if (flavors.isEmpty) {
      entries(['entry_points'], null,
          'the default entry point next to ${extras.length} more');
    } else {
      for (final f in flavors) {
        entries(['flavors', f, 'entry_points'], project.defaultTarget(f),
            '$f: its own main next to ${extras.length} more');
      }
    }
  }

  // Flavors.
  final crashlytics = project.hasDependency('firebase_crashlytics');
  for (final f in flavors) {
    final hasEntries = extras.isNotEmpty;
    final target = project.defaultTarget(f);
    if (target != null && !hasEntries) {
      out.add(Suggestion(['flavors', f, 'target'], target, 'found $target'));
    }
    final define = project.defineFileFor(f);
    if (define != null) {
      final fromLaunch = project.launchConfigs
          .any((c) => c.flavor == f && c.dartDefineFile == define);
      out.add(Suggestion(['flavors', f, 'dart_define_file'], define,
          fromLaunch ? 'used by launch.json for $f' : 'found $define'));
    }
    final package = project.packageName(f);
    if (package != null) {
      out.add(Suggestion(['flavors', f, 'package_name'], package,
          'applicationId from android/app/build.gradle'));
    }
    if (crashlytics) {
      final id = project.firebaseAppId(f, package);
      if (id != null) {
        out.add(Suggestion(
            ['flavors', f, 'firebase_app_id'], id, 'google-services.json'));
      }
    }
  }

  // Crash tools.
  out.add(Suggestion(
      ['crashlytics', 'enabled'],
      crashlytics,
      crashlytics
          ? 'firebase_crashlytics is a dependency'
          : 'firebase_crashlytics is not a dependency'));
  final sentryProps = _sentryProperties(project);
  final sentry = project.hasDependency('sentry_flutter') ||
      project.hasDependency('sentry') ||
      sentryProps.isNotEmpty;
  out.add(Suggestion(
      ['sentry', 'enabled'],
      sentry,
      sentry
          ? 'Sentry is used by the project'
          : 'no Sentry dependency or sentry.properties'));
  for (final e in {
    'org': sentryProps['defaults.org'],
    'project': sentryProps['defaults.project'],
    'url': sentryProps['defaults.url'],
  }.entries) {
    final v = e.value;
    if (v != null &&
        v.isNotEmpty &&
        !(e.key == 'url' && v.contains('sentry.io'))) {
      out.add(Suggestion(['sentry', e.key], v, 'sentry.properties'));
    }
  }

  // Google Play key named in fastlane.
  final key = _fastlaneJsonKey(project);
  if (key != null) {
    out.add(Suggestion(['play', 'service_account_json'], key,
        'json_key_file in fastlane/Appfile (path only; the key is not read)'));
  }
  return out;
}

Map<String, String> _sentryProperties(FlutterProject project) {
  for (final rel in ['sentry.properties', 'android/sentry.properties']) {
    final f = File(p.join(project.dir, rel));
    if (!f.existsSync()) continue;
    final map = <String, String>{};
    for (final line in f.readAsLinesSync()) {
      final t = line.trim();
      if (t.isEmpty || t.startsWith('#')) continue;
      final i = t.indexOf('=');
      if (i < 0) continue;
      final key = t.substring(0, i).trim();
      // auth.token is a secret and is left out on purpose.
      if (key.startsWith('auth')) continue;
      map[key] = t.substring(i + 1).trim();
    }
    return map;
  }
  return const {};
}

String? _fastlaneJsonKey(FlutterProject project) {
  for (final rel in ['fastlane/Appfile', 'android/fastlane/Appfile']) {
    final f = File(p.join(project.dir, rel));
    if (!f.existsSync()) continue;
    final m = RegExp(r'''json_key_file\(?\s*["']([^"']+)["']''')
        .firstMatch(f.readAsStringSync());
    if (m == null) continue;
    final path = m.group(1)!;
    final resolved = p.isAbsolute(path) || path.startsWith('~')
        ? path
        : p.normalize(p.join(p.dirname(f.path), path));
    final exists = resolved.startsWith('~') || File(resolved).existsSync();
    if (exists) {
      return p.isWithin(project.dir, resolved)
          ? p.relative(resolved, from: project.dir).replaceAll(r'\', '/')
          : resolved;
    }
  }
  return null;
}

/// Entries that should be in `.gitignore` but are not: the build output
/// folder and the config file (it can hold secrets).
List<String> missingGitignoreEntries(FlutterProject project,
    {required String outputDir, required String configFileName}) {
  final f = File(p.join(project.dir, '.gitignore'));
  final lines = f.existsSync()
      ? f.readAsLinesSync().map((l) => l.trim()).toSet()
      : <String>{};
  bool covered(String name) => lines.any((l) =>
      l == name ||
      l == '$name/' ||
      l == '/$name' ||
      l == '/$name/' ||
      l == '$name/*');
  final out = <String>[];
  final dir = p.isAbsolute(outputDir) ? null : outputDir;
  if (dir != null && !covered(dir.replaceAll(r'\', '/'))) out.add('$dir/');
  if (!covered(configFileName)) out.add(configFileName);
  return out;
}

/// Appends [entries] to the project's `.gitignore` (created if missing).
void addToGitignore(FlutterProject project, List<String> entries) {
  final f = File(p.join(project.dir, '.gitignore'));
  final existing = f.existsSync() ? f.readAsStringSync() : '';
  final sep = existing.isEmpty || existing.endsWith('\n') ? '' : '\n';
  f.writeAsStringSync(
      '$existing$sep\n# flutter_buildkit\n${entries.join('\n')}\n');
}
