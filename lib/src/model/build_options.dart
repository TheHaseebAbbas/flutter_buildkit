/// The kind of artifact `flutter build` produces.
enum ArtifactType {
  /// Android APK.
  apk('apk', 'apk', 'APK (Android package)'),

  /// Android App Bundle.
  aab('appbundle', 'aab', 'AAB (Android App Bundle, for Google Play)'),

  /// iOS archive.
  ipa('ipa', 'ipa', 'IPA (iOS archive, macOS only)');

  const ArtifactType(this.flutterCommand, this.extension, this.label);

  /// Sub-command passed to `flutter build`.
  final String flutterCommand;

  /// File extension of the produced artifact.
  final String extension;

  /// Human readable description for menus.
  final String label;

  /// Whether this artifact is built for Android (everything but [ipa]).
  bool get isAndroid => this != ipa;

  /// Finds a type by enum name or [flutterCommand].
  ///
  /// Throws [FormatException] for an unknown [value].
  static ArtifactType parse(String value) => ArtifactType.values.firstWhere(
        (t) => t.name == value || t.flutterCommand == value,
        orElse: () => throw FormatException('Unknown artifact type: $value'),
      );
}

/// Flutter build mode.
enum BuildMode {
  /// Debug build; no obfuscation.
  debug,

  /// Profile build, for performance analysis.
  profile,

  /// Release build.
  release;

  /// Whether `--obfuscate` / `--split-debug-info` may be used.
  bool get supportsObfuscation => this != debug;

  /// `Release`, `Debug`, `Profile` as used in Gradle variant names.
  String get capitalized => name[0].toUpperCase() + name.substring(1);

  /// Finds a mode by enum name.
  ///
  /// Throws [FormatException] for an unknown [value].
  static BuildMode parse(String value) => BuildMode.values.firstWhere(
        (m) => m.name == value,
        orElse: () => throw FormatException('Unknown build mode: $value'),
      );
}
