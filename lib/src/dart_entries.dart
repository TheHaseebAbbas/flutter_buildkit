import 'dart:io';

import 'package:path/path.dart' as p;

/// A Dart file that can be run as an app: it defines `main()`.
class DartEntry {
  const DartEntry(this.path, this.name);

  /// Relative to the project, with `/` separators.
  final String path;

  /// Short name derived from the file (`main_admin.dart` -> `admin`), or
  /// null for `lib/main.dart`, Flutter's default.
  final String? name;

  @override
  String toString() => 'DartEntry($path, $name)';
}

/// Lower case letters and digits only, so `clientDb`, `client_db` and
/// `Client-DB` compare equal.
String normalizeName(String s) =>
    s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

/// Folders that never hold the app's entry points.
const _skipDirs = {
  'build',
  'node_modules',
  'android',
  'ios',
  'web',
  'linux',
  'macos',
  'windows',
  'test',
  'tests',
  'integration_test',
  'test_driver',
  'tool',
  'docs',
  'doc',
  'coverage',
  'Pods',
};

final _generated = RegExp(
    r'\.(g|freezed|gr|config|mocks|chopper|reflectable|gen|part)\.dart$|_test\.dart$');

/// File names that look like an entry point even outside `lib/`.
final _mainish = RegExp(r'^(main(_.+)?|.+_main)\.dart$');

final _definesMain = RegExp(
    r'(?:^|\n)[ \t]*(?:(?:Future|FutureOr)<void>|void)?[ \t]*main[ \t]*\(');

/// Finds the entry points of the project at [dir], wherever they are:
/// every Dart file under `lib/` that defines `main()`, and files named like
/// `main.dart`, `main_x.dart` or `x_main.dart` elsewhere. Platform folders,
/// tests, generated code and hidden folders are skipped. [extra] adds files
/// (relative paths, e.g. a launch.json `program`) that exist even if they do
/// not look like entry points.
List<DartEntry> scanDartEntries(String dir,
    {Iterable<String> extra = const [], Iterable<String> skip = const []}) {
  final root = Directory(dir);
  if (!root.existsSync()) return const [];
  final skipSet = {..._skipDirs, ...skip};
  final found = <String>{};

  void walk(Directory d, String rel) {
    List<FileSystemEntity> children;
    try {
      children = d.listSync(followLinks: false);
    } on FileSystemException {
      return;
    }
    for (final e in children) {
      final base = p.basename(e.path);
      if (e is Directory) {
        if (base.startsWith('.') || skipSet.contains(base)) continue;
        walk(e, rel.isEmpty ? base : '$rel/$base');
      } else if (e is File && base.endsWith('.dart')) {
        if (_generated.hasMatch(base)) continue;
        final path = rel.isEmpty ? base : '$rel/$base';
        final inLib = path.startsWith('lib/');
        if (!inLib && !_mainish.hasMatch(base)) continue;
        try {
          if (e.lengthSync() > 512 * 1024) continue;
          if (_definesMain.hasMatch(e.readAsStringSync())) found.add(path);
        } on FileSystemException {
          continue;
        } on FormatException {
          continue; // not text
        }
      }
    }
  }

  walk(root, '');
  for (final x in extra) {
    final rel = x.replaceAll(r'\', '/');
    if (File(p.join(dir, rel)).existsSync()) found.add(rel);
  }

  final paths = found.toList()..sort();
  final names = <String, String?>{
    for (final path in paths) path: _nameOf(path),
  };
  // Two files with the same derived name: add their folder to tell them apart.
  final byName = <String, List<String>>{};
  for (final e in names.entries) {
    if (e.value != null) byName.putIfAbsent(e.value!, () => []).add(e.key);
  }
  for (final group in byName.values.where((g) => g.length > 1)) {
    for (final path in group) {
      final parent = p.posix.basename(p.posix.dirname(path));
      names[path] = _clean('${parent}_${names[path]}');
    }
  }
  final used = <String>{};
  final out = <DartEntry>[];
  for (final path in paths) {
    var name = names[path];
    if (name != null) {
      var unique = name;
      for (var i = 2; !used.add(unique); i++) {
        unique = '${name}_$i';
      }
      name = unique;
    }
    out.add(DartEntry(path, name));
  }
  // Default first, then by path.
  out.sort((a, b) => a.name == null
      ? -1
      : b.name == null
          ? 1
          : a.path.compareTo(b.path));
  return out;
}

String? _nameOf(String path) {
  if (path == 'lib/main.dart') return null;
  final file = p.posix.basename(path);
  var base = file.substring(0, file.length - '.dart'.length);
  if (base == 'main') {
    base = p.posix.basename(p.posix.dirname(path));
  } else if (base.startsWith('main_')) {
    base = base.substring('main_'.length);
  } else if (base.endsWith('_main')) {
    base = base.substring(0, base.length - '_main'.length);
  }
  return _clean(base);
}

/// A valid entry point name: letters, digits, `_` and `-`, starting with a
/// letter.
String _clean(String s) {
  var out = s.replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '_');
  out = out.replaceAll(RegExp(r'^[_-]+'), '');
  if (out.isEmpty) return 'entry';
  return RegExp(r'^[A-Za-z]').hasMatch(out) ? out : 'e_$out';
}
