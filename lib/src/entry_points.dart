import 'dart:io';

import 'package:path/path.dart' as p;

import 'config.dart';
import 'flutter_project.dart';

/// One Dart file to build. [name] is null for the default entry point, which
/// keeps the plain names.
class EntryPoint {
  const EntryPoint(this.name, this.path);

  final String? name;

  /// Passed to `flutter build -t`; null means Flutter's default
  /// (`lib/main.dart`).
  final String? path;

  String get label => name ?? '(default)';

  @override
  bool operator ==(Object other) =>
      other is EntryPoint && other.name == name && other.path == path;

  @override
  int get hashCode => Object.hash(name, path);
}

/// `lib/main_*.dart` files that are not the default or a flavor's own main:
/// `main_admin.dart` becomes the entry point `admin`.
Map<String, String> detectEntryPoints(
    FlutterProject project, Iterable<String> flavors) {
  final lib = Directory(p.join(project.dir, 'lib'));
  if (!lib.existsSync()) return const {};
  final flavorNames = {for (final f in flavors) f.toLowerCase()};
  final found = <String, String>{};
  final files = lib
      .listSync()
      .whereType<File>()
      .map((f) => p.basename(f.path))
      .where((n) => RegExp(r'^main_[A-Za-z0-9_-]+\.dart$').hasMatch(n))
      .toList()
    ..sort();
  for (final file in files) {
    final name = file.substring('main_'.length, file.length - '.dart'.length);
    if (flavorNames.contains(name.toLowerCase())) continue;
    found[name] = 'lib/$file';
  }
  return found;
}

/// The entry points to build for [flavor], in menu order.
///
/// 1. `flavors.<flavor>.entry_points`
/// 2. top-level `entry_points` (`{flavor}` in a path is substituted)
/// 3. the flavor's `target` (or `lib/main_<flavor>.dart`) as the default,
///    plus any extra `lib/main_*.dart` files found in the project
List<EntryPoint> entryPointsFor(
    AppConfig config, FlutterProject project, String? flavor) {
  final fc = config.flavor(flavor);
  if (fc.entryPoints.isNotEmpty) return _list(fc.entryPoints, flavor);
  if (config.entryPoints.isNotEmpty) {
    final all = _list(config.entryPoints, flavor);
    // A path that needs a flavor cannot be built without one.
    return flavor == null
        ? [
            for (final e in all)
              if (!(config.entryPoints[e.name]?.contains('{flavor}') ?? false))
                e,
          ]
        : all;
  }
  final defaultTarget = fc.target ?? project.defaultTarget(flavor);
  return [
    EntryPoint(null, defaultTarget),
    for (final e in detectEntryPoints(project, project.flavors).entries)
      EntryPoint(e.key, e.value),
  ];
}

List<EntryPoint> _list(Map<String, String> map, String? flavor) => [
      for (final e in map.entries)
        EntryPoint(e.key, e.value.replaceAll('{flavor}', flavor ?? 'default')),
    ];
