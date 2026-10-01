/// The kind of artifact `flutter build` produces.
enum ArtifactType {
  apk('apk', 'apk', 'APK (Android package)'),
  aab('appbundle', 'aab', 'AAB (Android App Bundle, for Google Play)'),
  ipa('ipa', 'ipa', 'IPA (iOS archive, macOS only)');

  const ArtifactType(this.flutterCommand, this.extension, this.label);

  /// Sub-command passed to `flutter build`.
  final String flutterCommand;

  /// File extension of the produced artifact.
  final String extension;

  /// Human readable description for menus.
  final String label;

  bool get isAndroid => this != ipa;

  static ArtifactType parse(String value) => ArtifactType.values.firstWhere(
        (t) => t.name == value || t.flutterCommand == value,
        orElse: () => throw FormatException('Unknown artifact type: $value'),
      );
}

/// Flutter build mode.
enum BuildMode {
  debug,
  profile,
  release;

  /// Whether `--obfuscate` / `--split-debug-info` may be used.
  bool get supportsObfuscation => this != debug;

  /// `Release`, `Debug`, `Profile` as used in Gradle variant names.
  String get capitalized => name[0].toUpperCase() + name.substring(1);

  static BuildMode parse(String value) => BuildMode.values.firstWhere(
        (m) => m.name == value,
        orElse: () => throw FormatException('Unknown build mode: $value'),
      );
}
