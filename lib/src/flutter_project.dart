import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'dart_entries.dart';
import 'launch_json.dart';

/// `version: 1.2.3+45` from pubspec.yaml.
class PubspecVersion {
  /// Creates a version from its [name] and build number [code].
  const PubspecVersion(this.name, this.code);

  /// Version name, the part before `+` (for example `1.2.3`).
  final String name;

  /// Build number, the part after `+`.
  final int code;

  /// Parses a pubspec `version` value, defaulting to `1.0.0+1` when [value] is null or blank.
  ///
  /// A missing or invalid build number becomes 1.
  static PubspecVersion parse(String? value) {
    if (value == null || value.trim().isEmpty) {
      return const PubspecVersion('1.0.0', 1);
    }
    final parts = value.trim().split('+');
    final code = parts.length > 1 ? int.tryParse(parts[1]) : null;
    return PubspecVersion(parts[0], code ?? 1);
  }

  @override
  String toString() => '$name+$code';
}

/// An Android product flavor found in Gradle.
class GradleFlavor {
  /// Creates a flavor called [name], with an optional [applicationId].
  const GradleFlavor(this.name, {this.applicationId});

  /// Flavor name as declared in Gradle.
  final String name;

  /// Full application id (defaultConfig id plus any suffix), when known.
  final String? applicationId;
}

/// What can be learned about a Flutter project from its files.
class FlutterProject {
  /// Creates a project rooted at the directory [dir].
  FlutterProject(this.dir);

  /// Root directory of the project.
  final String dir;

  /// The project's `pubspec.yaml`; it may not exist.
  File get pubspecFile => File(p.join(dir, 'pubspec.yaml'));

  /// Whether `pubspec.yaml` exists in [dir].
  bool get isFlutterProject => pubspecFile.existsSync();

  Map<Object?, Object?> _pubspec() {
    final doc = loadYaml(pubspecFile.readAsStringSync());
    return doc is Map ? doc.cast<Object?, Object?>() : const {};
  }

  bool _hasDependency(String name) {
    final y = _pubspec();
    for (final section in ['dependencies', 'dev_dependencies']) {
      final deps = y[section];
      if (deps is Map && deps.containsKey(name)) return true;
    }
    return false;
  }

  /// True when [name] is in `dependencies` or `dev_dependencies`.
  bool hasDependency(String name) => _hasDependency(name);

  /// `build_runner` is a dependency, so generated code may need refreshing.
  bool get usesBuildRunner => _hasDependency('build_runner');

  /// The project uses `flutter gen-l10n` (an l10n.yaml or `generate: true`).
  bool get usesGenL10n {
    if (File(p.join(dir, 'l10n.yaml')).existsSync()) return true;
    final flutter = _pubspec()['flutter'];
    return flutter is Map && flutter['generate'] == true;
  }

  /// The pubspec `name`, or the directory name when it has none.
  String get appName => (_pubspec()['name'] as String?) ?? p.basename(dir);

  /// The pubspec `version`, or `1.0.0+1` when missing.
  PubspecVersion get version =>
      PubspecVersion.parse('${_pubspec()['version'] ?? ''}');

  File? get _gradleFile {
    for (final name in ['build.gradle.kts', 'build.gradle']) {
      final f = File(p.join(dir, 'android', 'app', name));
      if (f.existsSync()) return f;
    }
    return null;
  }

  /// Product flavors from `android/app/build.gradle(.kts)`; empty when there is no Gradle file.
  List<GradleFlavor> get androidFlavors {
    final f = _gradleFile;
    return f == null ? const [] : parseGradleFlavors(f.readAsStringSync());
  }

  /// Default application id from the Gradle file, or null when it is not found.
  String? get androidApplicationId {
    final f = _gradleFile;
    return f == null ? null : parseDefaultApplicationId(f.readAsStringSync());
  }

  /// Shared Xcode schemes other than the default `Runner`.
  List<String> get iosSchemes {
    final d = Directory(
        p.join(dir, 'ios', 'Runner.xcodeproj', 'xcshareddata', 'xcschemes'));
    if (!d.existsSync()) return const [];
    return d
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.xcscheme'))
        .map((f) => p.basenameWithoutExtension(f.path))
        .where((s) => s != 'Runner')
        .toList()
      ..sort();
  }

  /// The Dart configurations in `.vscode/launch.json`, empty when there is
  /// none or it cannot be read.
  List<LaunchConfig> get launchConfigs {
    final f = File(p.join(dir, '.vscode', 'launch.json'));
    if (!f.existsSync()) return const [];
    try {
      return parseLaunchConfigs(f.readAsStringSync());
    } on Object {
      return const [];
    }
  }

  /// Flavors named under `flavorizr: flavors:` in pubspec.yaml.
  List<String> get flavorizrFlavors {
    final z = _pubspec()['flavorizr'];
    final f = z is Map ? z['flavors'] : null;
    return f is Map ? [for (final k in f.keys) '$k'] : const [];
  }

  /// Flavors from Gradle, Xcode schemes, flutter_flavorizr and the
  /// `--flavor` arguments of launch.json, sorted. Names that only differ in
  /// case or punctuation count once (Gradle's spelling wins).
  List<String> get flavors {
    final seen = <String, String>{};
    for (final name in [
      ...androidFlavors.map((f) => f.name),
      ...iosSchemes,
      ...flavorizrFlavors,
      ...launchConfigs.map((c) => c.flavor).whereType<String>(),
    ]) {
      seen.putIfAbsent(normalizeName(name), () => name);
    }
    return seen.values.toList()..sort();
  }

  List<DartEntry>? _entries;

  /// Every Dart file that can be run as an app, wherever it is in the
  /// project (see [scanDartEntries]), plus the `program`s of launch.json.
  List<DartEntry> get dartEntries => _entries ??= scanDartEntries(dir, extra: [
        for (final c in launchConfigs)
          if (c.program != null) c.program!,
      ]);

  /// The entry point of [flavor]: a `main_<flavor>.dart` (or `<flavor>/main.dart`)
  /// anywhere in the project, matching the name loosely (`clientDb` finds
  /// `main_client_db.dart`), or the `program` of a launch.json configuration
  /// for that flavor.
  String? defaultTarget(String? flavor) {
    if (flavor == null) return null;
    final key = normalizeName(flavor);
    final matches = [
      for (final e in dartEntries)
        if (e.name != null && normalizeName(e.name!) == key) e.path,
    ]..sort((a, b) => a.length.compareTo(b.length));
    if (matches.isNotEmpty) return matches.first;
    // launch.json: only when every configuration of the flavor names the
    // same program (one that also runs lib/main.dart means the flavor uses it).
    final programs = {
      for (final c in launchConfigs)
        if (c.flavor != null && normalizeName(c.flavor!) == key) c.program,
    };
    if (programs.length == 1 &&
        programs.single != null &&
        File(p.join(dir, programs.single!)).existsSync()) {
      return programs.single;
    }
    return null;
  }

  /// The `--dart-define-from-file` file of [flavor]: the one launch.json uses
  /// for it, else a JSON file named after it (`dev.json`, `pre_prod.json` for
  /// `preprod`, `env_dev.json`) in the usual config folders.
  String? defineFileFor(String flavor) {
    for (final c in launchConfigs) {
      final d = c.dartDefineFile;
      if (c.flavor == flavor &&
          d != null &&
          !d.contains(r'${') &&
          File(p.join(dir, d)).existsSync()) {
        return d;
      }
    }
    final key = normalizeName(flavor);
    final stems = {
      key,
      'env$key',
      '${key}env',
      'config$key',
      '${key}config',
      'dartdefine$key',
      'defines$key',
    };
    for (final folder in _defineDirs) {
      final d = Directory(folder.isEmpty ? dir : p.join(dir, folder));
      if (!d.existsSync()) continue;
      List<FileSystemEntity> files;
      try {
        files = d.listSync(followLinks: false);
      } on FileSystemException {
        continue;
      }
      final names = [
        for (final f in files)
          if (f is File && f.path.endsWith('.json')) p.basename(f.path),
      ]..sort();
      for (final n in names) {
        if (stems.contains(normalizeName(n.substring(0, n.length - 5)))) {
          return folder.isEmpty ? n : '$folder/$n';
        }
      }
    }
    return null;
  }

  static const _defineDirs = [
    'config',
    'configs',
    'env',
    'envs',
    '.env',
    'dart_defines',
    'dart-define',
    'defines',
    'environments',
    'flavors',
    'assets/config',
    'assets/env',
    'lib/config',
    '',
  ];

  /// Android application id for [flavor], or the default id when the flavor has none.
  ///
  /// Null when no id is found.
  String? packageName(String? flavor) {
    if (flavor != null) {
      for (final f in androidFlavors) {
        if (f.name == flavor && f.applicationId != null) return f.applicationId;
      }
    }
    return androidApplicationId;
  }

  /// Firebase app id from `google-services.json` for [packageName].
  String? firebaseAppId(String? flavor, String? packageName) {
    final candidates = [
      if (flavor != null)
        p.join(dir, 'android', 'app', 'src', flavor, 'google-services.json'),
      p.join(dir, 'android', 'app', 'google-services.json'),
    ];
    for (final path in candidates) {
      final f = File(path);
      if (!f.existsSync()) continue;
      final id = parseFirebaseAppId(f.readAsStringSync(), packageName);
      if (id != null) return id;
    }
    return null;
  }

  /// Short commit hash and branch, when the project is a git checkout.
  Future<(String?, String?)> gitInfo() async {
    Future<String?> git(List<String> args) async {
      try {
        final r = await Process.run('git', args, workingDirectory: dir);
        final out = '${r.stdout}'.trim();
        return r.exitCode == 0 && out.isNotEmpty ? out : null;
      } on ProcessException {
        return null;
      }
    }

    final commit = await git(['rev-parse', '--short', 'HEAD']);
    final dirty = await git(['status', '--porcelain']);
    return (
      commit == null ? null : (dirty == null ? commit : '$commit-dirty'),
      await git(['rev-parse', '--abbrev-ref', 'HEAD']),
    );
  }
}

/// Flavor names (and application ids) declared in `productFlavors { }`,
/// for both Groovy (`dev { }`) and Kotlin DSL (`create("dev") { }`).
List<GradleFlavor> parseGradleFlavors(String gradle) {
  final source = _stripComments(gradle);
  final block = _block(source, 'productFlavors');
  if (block == null) return const [];
  final defaultId = parseDefaultApplicationId(source);
  final entry = RegExp(
      r'''(?:(?:create|register|maybeCreate)\s*\(\s*["']([\w-]+)["']\s*\)|\b(\w+))\s*\{''');
  final flavors = <GradleFlavor>[];
  var searchFrom = 0;
  while (true) {
    final m = entry.firstMatch(block.substring(searchFrom));
    if (m == null) break;
    final start = searchFrom + m.start;
    if (_depthAt(block, start) != 0) {
      searchFrom = start + 1;
      continue;
    }
    final name = m.group(1) ?? m.group(2)!;
    final open = searchFrom + m.end - 1;
    final close = _matchingBrace(block, open);
    final body = block.substring(open + 1, close < 0 ? block.length : close);
    searchFrom = close < 0 ? block.length : close + 1;
    if (const {'all', 'configureEach', 'named', 'getByName'}.contains(name)) {
      continue;
    }
    final id = _stringProp(body, 'applicationId');
    final suffix = _stringProp(body, 'applicationIdSuffix');
    flavors.add(GradleFlavor(name,
        applicationId: id ??
            (defaultId != null && suffix != null
                ? '$defaultId$suffix'
                : defaultId)));
  }
  return flavors;
}

/// `applicationId` inside `defaultConfig { }`.
String? parseDefaultApplicationId(String gradle) {
  final block = _block(_stripComments(gradle), 'defaultConfig');
  return block == null ? null : _stringProp(block, 'applicationId');
}

/// `mobilesdk_app_id` of the client matching [packageName] (or the first).
String? parseFirebaseAppId(String googleServicesJson, String? packageName) {
  try {
    final json = jsonDecode(googleServicesJson) as Map<String, Object?>;
    final clients = (json['client'] as List?) ?? const [];
    Map<Object?, Object?>? pick;
    for (final c in clients) {
      final info = (c as Map)['client_info'] as Map?;
      final pkg =
          ((info?['android_client_info'] as Map?)?['package_name']) as String?;
      if (packageName == null || pkg == packageName) {
        pick = info;
        break;
      }
    }
    return pick?['mobilesdk_app_id'] as String?;
  } on Object {
    return null;
  }
}

String? _stringProp(String body, String name) =>
    RegExp('\\b$name\\s*=?\\s*\\(?\\s*["\']([^"\']+)["\']')
        .firstMatch(body)
        ?.group(1);

String _stripComments(String s) =>
    s.replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '').replaceAllMapped(
        RegExp(r'(^|[^:"])//.*$', multiLine: true), (m) => m.group(1)!);

String? _block(String source, String name) {
  final m = RegExp('\\b$name\\s*\\{').firstMatch(source);
  if (m == null) return null;
  final open = m.end - 1;
  final close = _matchingBrace(source, open);
  return source.substring(open + 1, close < 0 ? source.length : close);
}

int _matchingBrace(String s, int open) {
  var depth = 0;
  for (var i = open; i < s.length; i++) {
    if (s[i] == '{') depth++;
    if (s[i] == '}' && --depth == 0) return i;
  }
  return -1;
}

int _depthAt(String s, int index) {
  var depth = 0;
  for (var i = 0; i < index; i++) {
    if (s[i] == '{') depth++;
    if (s[i] == '}') depth--;
  }
  return depth;
}
