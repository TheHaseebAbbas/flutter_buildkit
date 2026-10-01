import 'dart:io';

import 'package:path/path.dart' as p;

import 'model/build_options.dart';

/// Ready-made folder layouts for the build output. Pick one with
/// `output_layout:` in the config, or write your own template.
enum LayoutPreset {
  /// Everything for one flavor together; easy to browse per environment.
  byFlavor('by-flavor', '{app}/{flavor}/{mode}/{version}-{datetime}'),

  /// All flavors and modes of one version together; easy to hand over a
  /// release.
  byVersion('by-version', '{app}/{version}/{flavor}-{mode}-{datetime}'),

  /// One folder per month, builds side by side; easy to clean up by age.
  byMonth(
      'by-month', '{year}-{month}/{app}-{flavor}-{mode}-{version}-{datetime}'),

  /// One folder per build directly under the output folder.
  flat('flat', '{app}-{flavor}-{mode}-{version}-{datetime}');

  const LayoutPreset(this.id, this.template);

  final String id;
  final String template;

  static LayoutPreset? byId(String id) {
    for (final p in values) {
      if (p.id == id) return p;
    }
    return null;
  }
}

/// Everything a name template can use.
class BuildNaming {
  const BuildNaming({
    required this.appName,
    required this.flavor,
    required this.mode,
    required this.versionName,
    required this.versionCode,
    required this.time,
    required this.type,
  });

  final String appName;

  /// Null when the project has no flavors.
  final String? flavor;
  final BuildMode mode;
  final String versionName;
  final int versionCode;
  final DateTime time;
  final ArtifactType type;
}

class PathTemplateException implements Exception {
  PathTemplateException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// A name or folder template such as `{app}-{flavor}-{mode}-{version}`.
///
/// Tokens: `{app}`, `{flavor}`, `{mode}`, `{versionName}`, `{versionCode}`,
/// `{version}` (= `<versionName>-b<versionCode>`), `{datetime}`
/// (`yyyyMMdd-HHmmss`), `{date}`, `{time}`, `{year}`, `{month}` and `{type}`
/// (`apk`, `aab`, `ipa`).
class PathTemplate {
  PathTemplate._(this.source);

  static const tokens = [
    'app',
    'flavor',
    'mode',
    'versionName',
    'versionCode',
    'version',
    'datetime',
    'date',
    'time',
    'year',
    'month',
    'type',
  ];

  final String source;

  /// Parses [source], rejecting unknown tokens and unsafe paths.
  factory PathTemplate.parse(String source, {required bool isFolder}) {
    final text = source.trim().replaceAll(r'\', '/');
    if (text.isEmpty) throw PathTemplateException('The template is empty.');
    for (final m in RegExp(r'\{(\w*)\}').allMatches(text)) {
      if (!tokens.contains(m.group(1))) {
        throw PathTemplateException('Unknown token {${m.group(1)}} in '
            '"$source". Use: ${tokens.map((t) => '{$t}').join(' ')}.');
      }
    }
    if (RegExp(r'[{}]').hasMatch(text.replaceAll(RegExp(r'\{\w+\}'), ''))) {
      throw PathTemplateException('Unbalanced { } in "$source".');
    }
    if (!isFolder && text.contains('/')) {
      throw PathTemplateException(
          'A file name template cannot contain "/": "$source".');
    }
    if (isFolder) {
      if (text.startsWith('/') || RegExp(r'^[A-Za-z]:').hasMatch(text)) {
        throw PathTemplateException(
            'The layout must be relative to the output folder: "$source".');
      }
      final bare = text.replaceAll(RegExp(r'\{\w+\}'), 'x');
      if (bare.split('/').any((s) => s == '..' || s == '.' || s.isEmpty)) {
        throw PathTemplateException(
            'The layout has an empty, "." or ".." folder: "$source".');
      }
    }
    return PathTemplate._(text);
  }

  /// Substitutes the tokens. Values are made safe as file names first, so a
  /// flavor like `../x` cannot escape the output folder.
  String render(BuildNaming n, {bool dropEmptyFlavor = false}) {
    final t = n.time.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    final flavor = n.flavor == null
        ? (dropEmptyFlavor ? '' : BuildPaths.defaultFlavor)
        : BuildPaths.sanitize(n.flavor!);
    final values = {
      'app': BuildPaths.sanitize(n.appName),
      'flavor': flavor,
      'mode': n.mode.name,
      'versionName': BuildPaths.sanitize(n.versionName),
      'versionCode': '${n.versionCode}',
      'version': '${BuildPaths.sanitize(n.versionName)}-b${n.versionCode}',
      'datetime': BuildPaths.timestamp(n.time),
      'date':
          '${t.year.toString().padLeft(4, '0')}${two(t.month)}${two(t.day)}',
      'time': '${two(t.hour)}${two(t.minute)}${two(t.second)}',
      'year': t.year.toString().padLeft(4, '0'),
      'month': two(t.month),
      'type': n.type.extension,
    };
    var out = source.replaceAllMapped(
        RegExp(r'\{(\w+)\}'), (m) => values[m.group(1)] ?? '');
    if (dropEmptyFlavor && n.flavor == null) {
      // "app--release" becomes "app-release".
      out = out.replaceAllMapped(RegExp(r'([-_.])\1+'), (m) => m.group(1)!);
    }
    return out;
  }
}

/// Decides where a build and its files are stored.
///
/// ```
/// <root>/<layout>/                      e.g. my_app/dev/release/1.2.0-b42-20261001-070509/
///     artifacts/<file name>.<type>      my_app-dev-release-1.2.0-b42-20261001-070509.aab
///     symbols/{dart,native,mapping,dSYMs}/
///     build_info.json
/// ```
///
/// The default layout is [LayoutPreset.byFlavor]; the default file name is
/// `{app}-{flavor}-{mode}-{version}-{datetime}`. Without a flavor the
/// flavor part is dropped from file names and shown as `default` in folders.
class BuildPaths {
  BuildPaths(
    this.root, {
    String? layout,
    String? fileName,
  })  : layout = PathTemplate.parse(layout ?? LayoutPreset.byFlavor.template,
            isFolder: true),
        fileName =
            PathTemplate.parse(fileName ?? defaultFileName, isFolder: false);

  static const defaultFileName = '{app}-{flavor}-{mode}-{version}-{datetime}';
  static const defaultFlavor = 'default';
  static const artifactsFolder = 'artifacts';
  static const symbolsFolder = 'symbols';

  final String root;
  final PathTemplate layout;
  final PathTemplate fileName;

  /// Resolves a config value: a preset id (`by-version`) or a template.
  static String resolveLayout(String value) =>
      LayoutPreset.byId(value.trim())?.template ?? value;

  /// Folder for one build. Does not touch the file system.
  String buildDir(BuildNaming n) =>
      p.joinAll([root, ...layout.render(n).split('/')]);

  /// Like [buildDir], but appends `-2`, `-3`... if the folder already exists
  /// (two builds that map to the same name in the same second).
  String uniqueBuildDir(BuildNaming n) {
    final base = buildDir(n);
    var candidate = base;
    for (var i = 2; Directory(candidate).existsSync(); i++) {
      candidate = '$base-$i';
    }
    return candidate;
  }

  /// Artifact file name with its extension, e.g.
  /// `my_app-dev-release-1.2.0-b42-20261001-070509.aab`. [suffix] separates
  /// several outputs of one build (split-per-abi APKs).
  String artifactFileName(BuildNaming n, {String? suffix}) {
    final base = fileName.render(n, dropEmptyFlavor: true);
    final s = suffix == null || suffix.isEmpty ? '' : '-${sanitize(suffix)}';
    return '$base$s.${n.type.extension}';
  }

  /// `yyyyMMdd-HHmmss` in local time, so folders sort chronologically.
  static String timestamp(DateTime time) {
    final t = time.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year.toString().padLeft(4, '0')}${two(t.month)}${two(t.day)}'
        '-${two(t.hour)}${two(t.minute)}${two(t.second)}';
  }

  /// Makes a value safe as a single folder or file name on every OS.
  static String sanitize(String value) {
    var s = value.trim().replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F\s]+'), '_');
    s = s.replaceAll(RegExp(r'^\.+'), '').replaceAll(RegExp(r'[. ]+$'), '');
    return s.isEmpty ? '_' : s;
  }
}

/// Deletes [dir] and its parents while they are empty, stopping before
/// [root] itself.
Future<void> pruneEmptyParents(String root, Directory dir) async {
  var current = dir;
  while (p.isWithin(root, current.path) &&
      await current.exists() &&
      await current.list().isEmpty) {
    await current.delete();
    current = current.parent;
  }
}
