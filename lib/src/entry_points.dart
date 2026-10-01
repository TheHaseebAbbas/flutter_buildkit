import 'config.dart';
import 'dart_entries.dart';
import 'flutter_project.dart';

/// One Dart file to build. [name] is null for the default entry point, which
/// keeps the plain names.
class EntryPoint {
  /// Creates an entry point called [name] built from the file at [path].
  const EntryPoint(this.name, this.path);

  /// Short name of the entry point, or null for the default one.
  final String? name;

  /// Passed to `flutter build -t`; null means Flutter's default
  /// (`lib/main.dart`).
  final String? path;

  /// The name shown in menus: [name], or `(default)` when it is null.
  String get label => name ?? '(default)';

  @override
  String toString() => 'EntryPoint($name, $path)';

  @override
  bool operator ==(Object other) =>
      other is EntryPoint && other.name == name && other.path == path;

  @override
  int get hashCode => Object.hash(name, path);
}

/// Dart files with a `main()` anywhere in the project that are not the
/// default (`lib/main.dart`) or a flavor's own main: `main_admin.dart`
/// becomes the entry point `admin`.
Map<String, String> detectEntryPoints(
    FlutterProject project, Iterable<String> flavors) {
  final flavorKeys = {for (final f in flavors) normalizeName(f)};
  return {
    for (final e in project.dartEntries)
      if (e.name != null && !flavorKeys.contains(normalizeName(e.name!)))
        e.name!: e.path,
  };
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
    // A path that needs a flavor cannot be built without one.
    final usable = flavor == null
        ? {
            for (final e in config.entryPoints.entries)
              if (!e.value.contains('{flavor}')) e.key: e.value,
          }
        : config.entryPoints;
    return _list(usable, flavor);
  }
  final defaultTarget = fc.target ?? project.defaultTarget(flavor);
  return [
    EntryPoint(null, defaultTarget),
    for (final e in detectEntryPoints(project, project.flavors).entries)
      EntryPoint(e.key, e.value),
  ];
}

/// An entry point named `main` or `default` is the default one: it keeps the
/// plain folder and file names.
List<EntryPoint> _list(Map<String, String> map, String? flavor) => [
      for (final e in map.entries)
        EntryPoint(e.key == 'main' || e.key == 'default' ? null : e.key,
            e.value.replaceAll('{flavor}', flavor ?? 'default')),
    ];
