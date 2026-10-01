import 'build_options.dart';

/// One file produced by a build (an APK per ABI, an AAB, an IPA...).
class BuildArtifact {
  const BuildArtifact({
    required this.path,
    required this.sizeBytes,
    required this.sha256,
  });

  /// Path relative to the ledger's root folder.
  final String path;
  final int sizeBytes;
  final String sha256;

  Map<String, Object?> toJson() =>
      {'path': path, 'sizeBytes': sizeBytes, 'sha256': sha256};

  factory BuildArtifact.fromJson(Map<String, Object?> json) => BuildArtifact(
        path: json['path']! as String,
        sizeBytes: (json['sizeBytes'] as num?)?.toInt() ?? 0,
        sha256: json['sha256'] as String? ?? '',
      );
}

/// Where and how a build reached Google Play.
class PlayUpload {
  const PlayUpload({
    required this.track,
    required this.uploadedAt,
    required this.viaApi,
    this.releaseStatus,
    this.editId,
  });

  /// internal, alpha, beta, production or a custom closed track.
  final String track;
  final DateTime uploadedAt;

  /// True when this tool uploaded it through the Play Developer API,
  /// false when it was only marked in the ledger (uploaded by hand).
  final bool viaApi;

  /// draft, completed, inProgress or halted.
  final String? releaseStatus;
  final String? editId;

  Map<String, Object?> toJson() => {
        'track': track,
        'uploadedAt': uploadedAt.toUtc().toIso8601String(),
        'viaApi': viaApi,
        if (releaseStatus != null) 'releaseStatus': releaseStatus,
        if (editId != null) 'editId': editId,
      };

  factory PlayUpload.fromJson(Map<String, Object?> json) => PlayUpload(
        track: json['track']! as String,
        uploadedAt: DateTime.parse(json['uploadedAt']! as String),
        viaApi: json['viaApi'] as bool? ?? false,
        releaseStatus: json['releaseStatus'] as String?,
        editId: json['editId'] as String?,
      );
}

/// Names of crash reporting tools symbols can be uploaded to.
abstract final class SymbolTargets {
  static const crashlytics = 'crashlytics';
  static const sentry = 'sentry';
  static const all = [crashlytics, sentry];
}

/// A single row of the build ledger.
class BuildRecord {
  const BuildRecord({
    required this.id,
    required this.appName,
    this.flavor,
    required this.mode,
    required this.type,
    required this.versionName,
    required this.versionCode,
    required this.createdAt,
    required this.outputDir,
    required this.artifacts,
    this.packageName,
    this.target,
    this.entryPoint,
    this.symbolsDir,
    this.mappingFile,
    this.obfuscated = false,
    this.gitCommit,
    this.gitBranch,
    this.flutterVersion,
    this.durationMs,
    this.publishedAt,
    this.play,
    this.symbolUploads = const {},
    this.preBuild = const [],
    this.artifactsDeletedAt,
    this.notes,
  });

  final String id;
  final String appName;
  final String? packageName;

  /// Null when the project has no flavors.
  final String? flavor;
  final BuildMode mode;
  final ArtifactType type;
  final String versionName;
  final int versionCode;
  final DateTime createdAt;

  /// Entry point passed with `-t`, if any.
  final String? target;

  /// Name of the entry point (e.g. `admin`), when the build used a named one.
  final String? entryPoint;

  /// Folder holding this build, relative to the ledger's root folder.
  final String outputDir;
  final List<BuildArtifact> artifacts;

  /// Dart split-debug-info folder (relative), present for obfuscated builds.
  final String? symbolsDir;

  /// R8/ProGuard mapping.txt (relative), when minification produced one.
  final String? mappingFile;
  final bool obfuscated;

  final String? gitCommit;
  final String? gitBranch;
  final String? flutterVersion;
  final int? durationMs;

  /// When the build was marked public (released to users).
  final DateTime? publishedAt;
  final PlayUpload? play;

  /// Tool name ([SymbolTargets]) to upload time.
  final Map<String, DateTime> symbolUploads;

  /// Steps run before the build (clean, pub get, build_runner, gen-l10n).
  final List<String> preBuild;

  /// When the APK/AAB/IPA files were deleted (symbols are kept).
  final DateTime? artifactsDeletedAt;
  final String? notes;

  String get flavorLabel => flavor ?? 'default';
  String get version => '$versionName+$versionCode';
  bool get isPublished => publishedAt != null;
  bool get isOnPlay => play != null;

  /// Published or uploaded to Google Play. A released build keeps its
  /// ledger entry, debug symbols and mappings forever, so crashes from the
  /// field can still be traced; only its APK/AAB/IPA files may be deleted.
  bool get isReleased => isPublished || isOnPlay;

  bool get artifactsDeleted => artifactsDeletedAt != null;

  int get totalSize => artifacts.fold(0, (sum, a) => sum + a.sizeBytes);

  BuildRecord copyWith({
    DateTime? publishedAt,
    bool clearPublished = false,
    PlayUpload? play,
    bool clearPlay = false,
    Map<String, DateTime>? symbolUploads,
    DateTime? artifactsDeletedAt,
    String? notes,
  }) =>
      BuildRecord(
        id: id,
        appName: appName,
        packageName: packageName,
        flavor: flavor,
        mode: mode,
        type: type,
        versionName: versionName,
        versionCode: versionCode,
        createdAt: createdAt,
        target: target,
        entryPoint: entryPoint,
        outputDir: outputDir,
        artifacts: artifacts,
        symbolsDir: symbolsDir,
        mappingFile: mappingFile,
        obfuscated: obfuscated,
        gitCommit: gitCommit,
        gitBranch: gitBranch,
        flutterVersion: flutterVersion,
        durationMs: durationMs,
        publishedAt: clearPublished ? null : (publishedAt ?? this.publishedAt),
        play: clearPlay ? null : (play ?? this.play),
        symbolUploads: symbolUploads ?? this.symbolUploads,
        preBuild: preBuild,
        artifactsDeletedAt: artifactsDeletedAt ?? this.artifactsDeletedAt,
        notes: notes ?? this.notes,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'appName': appName,
        if (packageName != null) 'packageName': packageName,
        'flavor': flavor,
        'mode': mode.name,
        'type': type.name,
        'versionName': versionName,
        'versionCode': versionCode,
        'createdAt': createdAt.toUtc().toIso8601String(),
        if (target != null) 'target': target,
        if (entryPoint != null) 'entryPoint': entryPoint,
        'outputDir': outputDir,
        'artifacts': [for (final a in artifacts) a.toJson()],
        if (symbolsDir != null) 'symbolsDir': symbolsDir,
        if (mappingFile != null) 'mappingFile': mappingFile,
        'obfuscated': obfuscated,
        if (gitCommit != null) 'gitCommit': gitCommit,
        if (gitBranch != null) 'gitBranch': gitBranch,
        if (flutterVersion != null) 'flutterVersion': flutterVersion,
        if (durationMs != null) 'durationMs': durationMs,
        'status': {
          'publishedAt': publishedAt?.toUtc().toIso8601String(),
          'play': play?.toJson(),
          'symbols': {
            for (final e in symbolUploads.entries)
              e.key: e.value.toUtc().toIso8601String(),
          },
        },
        if (preBuild.isNotEmpty) 'preBuild': preBuild,
        if (artifactsDeletedAt != null)
          'artifactsDeletedAt': artifactsDeletedAt!.toUtc().toIso8601String(),
        if (notes != null) 'notes': notes,
      };

  factory BuildRecord.fromJson(Map<String, Object?> json) {
    final status = (json['status'] as Map?)?.cast<String, Object?>() ?? {};
    final symbols = (status['symbols'] as Map?)?.cast<String, Object?>() ?? {};
    final play = status['play'] as Map?;
    final published = status['publishedAt'] as String?;
    return BuildRecord(
      id: json['id']! as String,
      appName: json['appName']! as String,
      packageName: json['packageName'] as String?,
      flavor: json['flavor'] as String?,
      mode: BuildMode.parse(json['mode']! as String),
      type: ArtifactType.parse(json['type']! as String),
      versionName: json['versionName']! as String,
      versionCode: (json['versionCode']! as num).toInt(),
      createdAt: DateTime.parse(json['createdAt']! as String),
      target: json['target'] as String?,
      entryPoint: json['entryPoint'] as String?,
      outputDir: json['outputDir']! as String,
      artifacts: [
        for (final a in (json['artifacts'] as List?) ?? const [])
          BuildArtifact.fromJson((a as Map).cast<String, Object?>()),
      ],
      symbolsDir: json['symbolsDir'] as String?,
      mappingFile: json['mappingFile'] as String?,
      obfuscated: json['obfuscated'] as bool? ?? false,
      gitCommit: json['gitCommit'] as String?,
      gitBranch: json['gitBranch'] as String?,
      flutterVersion: json['flutterVersion'] as String?,
      durationMs: (json['durationMs'] as num?)?.toInt(),
      publishedAt: published == null ? null : DateTime.parse(published),
      play: play == null
          ? null
          : PlayUpload.fromJson(play.cast<String, Object?>()),
      symbolUploads: {
        for (final e in symbols.entries)
          e.key: DateTime.parse(e.value! as String),
      },
      preBuild: [
        for (final p in (json['preBuild'] as List?) ?? const []) '$p',
      ],
      artifactsDeletedAt: json['artifactsDeletedAt'] == null
          ? null
          : DateTime.parse(json['artifactsDeletedAt']! as String),
      notes: json['notes'] as String?,
    );
  }
}
