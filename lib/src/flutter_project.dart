import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

/// `version: 1.2.3+45` from pubspec.yaml.
class PubspecVersion {
  const PubspecVersion(this.name, this.code);
  final String name;
  final int code;

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
  const GradleFlavor(this.name, {this.applicationId});
  final String name;

  /// Full application id (defaultConfig id plus any suffix), when known.
  final String? applicationId;
}

/// What can be learned about a Flutter project from its files.
class FlutterProject {
  FlutterProject(this.dir);

  final String dir;

  File get pubspecFile => File(p.join(dir, 'pubspec.yaml'));
  bool get isFlutterProject => pubspecFile.existsSync();

  Map<Object?, Object?> _pubspec() {
    final doc = loadYaml(pubspecFile.readAsStringSync());
    return doc is Map ? doc.cast<Object?, Object?>() : const {};
  }

  String get appName => (_pubspec()['name'] as String?) ?? p.basename(dir);

  PubspecVersion get version =>
      PubspecVersion.parse('${_pubspec()['version'] ?? ''}');

  File? get _gradleFile {
    for (final name in ['build.gradle.kts', 'build.gradle']) {
      final f = File(p.join(dir, 'android', 'app', name));
      if (f.existsSync()) return f;
    }
    return null;
  }

  List<GradleFlavor> get androidFlavors {
    final f = _gradleFile;
    return f == null ? const [] : parseGradleFlavors(f.readAsStringSync());
  }

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

  /// Android flavors and iOS schemes together, sorted.
  List<String> get flavors =>
      {...androidFlavors.map((f) => f.name), ...iosSchemes}.toList()..sort();

  /// `lib/main_<flavor>.dart` when it exists.
  String? defaultTarget(String? flavor) {
    if (flavor == null) return null;
    for (final name in ['main_$flavor.dart', p.join(flavor, 'main.dart')]) {
      if (File(p.join(dir, 'lib', name)).existsSync()) {
        return p.join('lib', name).replaceAll(r'\', '/');
      }
    }
    return null;
  }

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
