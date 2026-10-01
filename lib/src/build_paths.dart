import 'dart:io';

import 'package:path/path.dart' as p;

import 'model/build_options.dart';

/// Decides where a build is stored:
///
/// `<root>/<app>/<flavor>/<mode>/<versionName>+<versionCode>_<yyyyMMdd-HHmmss>/`
///
/// Projects without flavors use `default` as the flavor folder.
class BuildPaths {
  const BuildPaths(this.root);

  final String root;

  static const defaultFlavor = 'default';

  /// Folder for one build. Does not touch the file system.
  String buildDir({
    required String appName,
    required String? flavor,
    required BuildMode mode,
    required String versionName,
    required int versionCode,
    required DateTime time,
  }) =>
      p.join(
        root,
        sanitize(appName),
        sanitize(flavor ?? defaultFlavor),
        mode.name,
        '${sanitize(versionName)}+${versionCode}_${timestamp(time)}',
      );

  /// Like [buildDir], but appends `-2`, `-3`... if the folder already exists
  /// (two builds of the same version in the same second).
  String uniqueBuildDir({
    required String appName,
    required String? flavor,
    required BuildMode mode,
    required String versionName,
    required int versionCode,
    required DateTime time,
  }) {
    final base = buildDir(
      appName: appName,
      flavor: flavor,
      mode: mode,
      versionName: versionName,
      versionCode: versionCode,
      time: time,
    );
    var candidate = base;
    for (var i = 2; Directory(candidate).existsSync(); i++) {
      candidate = '$base-$i';
    }
    return candidate;
  }

  /// File name for an artifact, e.g. `my_app-dev-release-1.2.0+42.aab`.
  /// [suffix] separates several outputs of one build (split-per-abi APKs).
  static String artifactName({
    required String appName,
    required String? flavor,
    required BuildMode mode,
    required String versionName,
    required int versionCode,
    required ArtifactType type,
    String? suffix,
  }) {
    final parts = [
      sanitize(appName),
      if (flavor != null) sanitize(flavor),
      mode.name,
      '${sanitize(versionName)}+$versionCode',
      if (suffix != null && suffix.isNotEmpty) sanitize(suffix),
    ];
    return '${parts.join('-')}.${type.extension}';
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
