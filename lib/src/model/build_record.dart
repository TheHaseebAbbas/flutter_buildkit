import 'build_options.dart';

/// One file produced by a build (an APK per ABI, an AAB, an IPA...).
class BuildArtifact {
  /// Creates an artifact record.
  const BuildArtifact({
    required this.path,
    required this.sizeBytes,
    required this.sha256,
  });

  /// Path relative to the ledger's root folder.
  final String path;

  /// Size of the file in bytes.
  final int sizeBytes;

  /// Hex SHA-256 digest of the file; empty when unknown.
  final String sha256;

  /// Returns the JSON form stored in the ledger.
  Map<String, Object?> toJson() =>
      {'path': path, 'sizeBytes': sizeBytes, 'sha256': sha256};

  /// Reads an artifact from its ledger JSON; missing size and digest default to 0 and empty.
  factory BuildArtifact.fromJson(Map<String, Object?> json) => BuildArtifact(
        path: json['path']! as String,
        sizeBytes: (json['sizeBytes'] as num?)?.toInt() ?? 0,
        sha256: json['sha256'] as String? ?? '',
      );
}

/// Where and how a build reached Google Play.
class PlayUpload {
  /// Creates a record of a Play upload.
  const PlayUpload({
    required this.track,
    required this.uploadedAt,
    required this.viaApi,
    this.releaseStatus,
    this.editId,
  });

  /// internal, alpha, beta, production or a custom closed track.
  final String track;

  /// When the upload happened.
  final DateTime uploadedAt;

  /// `internal, completed`, for history lines.
  String get eventNote =>
      '$track${releaseStatus == null ? '' : ', $releaseStatus'}';

  /// True when this tool uploaded it through the Play Developer API,
  /// false when it was only marked in the ledger (uploaded by hand).
  final bool viaApi;

  /// draft, completed, inProgress or halted.
  final String? releaseStatus;

  /// Play Developer API edit id; null when not recorded.
  final String? editId;

  /// Returns the JSON form stored in the ledger.
  Map<String, Object?> toJson() => {
        'track': track,
        'uploadedAt': uploadedAt.toUtc().toIso8601String(),
        'viaApi': viaApi,
        if (releaseStatus != null) 'releaseStatus': releaseStatus,
        if (editId != null) 'editId': editId,
      };

  /// Reads a Play upload from its ledger JSON.
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
  /// Name of Firebase Crashlytics.
  static const crashlytics = 'crashlytics';

  /// Name of Sentry.
  static const sentry = 'sentry';

  /// Every supported target.
  static const all = [crashlytics, sentry];
}

/// Where a build is in its life, most advanced state wins.
enum BuildStatus {
  /// The build did not finish; only its log is kept.
  failed('failed'),

  /// Built and stored; not released anywhere.
  built('built'),

  /// Uploaded to Google Play but not marked published.
  uploaded('uploaded'),

  /// Marked public: released to users.
  published('published');

  const BuildStatus(this.code);

  /// Stable string stored in the ledger and exports.
  final String code;
}

/// Why a build did not finish; set on rows with status [BuildStatus.failed].
class BuildFailure {
  /// Creates a failure with the process [exitCode] and a [message].
  const BuildFailure(this.exitCode, this.message);

  /// Exit code of `flutter build`; 0 when it succeeded but produced no file.
  final int exitCode;

  /// What went wrong, phrased for the user.
  final String message;

  /// JSON form stored in the ledger.
  Map<String, Object?> toJson() => {'exitCode': exitCode, 'message': message};

  /// Reads the JSON form written by [toJson].
  factory BuildFailure.fromJson(Map<String, Object?> json) => BuildFailure(
      (json['exitCode'] as num?)?.toInt() ?? 1,
      json['message'] as String? ?? '');
}

/// Who signed an Android build, read back from the finished file.
class BuildSigning {
  /// Creates a signing record.
  const BuildSigning({
    required this.sha256,
    this.subject,
    this.debugKey = false,
    this.tool,
  });

  /// SHA-256 fingerprint of the signing certificate, lower case hex without
  /// separators.
  final String sha256;

  /// Certificate subject, such as `CN=Android Debug, O=Android, C=US`.
  final String? subject;

  /// True when the certificate is the Android debug key.
  final bool debugKey;

  /// The tool that read it (`apksigner` or `keytool`).
  final String? tool;

  /// JSON form stored in the ledger.
  Map<String, Object?> toJson() => {
        'sha256': sha256,
        if (subject != null) 'subject': subject,
        'debugKey': debugKey,
        if (tool != null) 'tool': tool,
      };

  /// Reads the JSON form written by [toJson].
  factory BuildSigning.fromJson(Map<String, Object?> json) => BuildSigning(
        sha256: json['sha256']! as String,
        subject: json['subject'] as String?,
        debugKey: json['debugKey'] as bool? ?? false,
        tool: json['tool'] as String?,
      );
}

/// Something that happened to a build, kept in [BuildRecord.events].
class BuildEvent {
  /// Creates an event at [at] of the given [kind] with an optional [note].
  const BuildEvent(this.at, this.kind, [this.note]);

  /// When the event happened.
  final DateTime at;

  /// `built`, `build_failed`, `uploaded`, `published`, `unpublished`, `symbols_uploaded`,
  /// `symbols_pruned` or `artifacts_deleted`.
  final String kind;

  /// Extra detail, such as the Play track or the symbol target; may be null.
  final String? note;

  /// Human readable description of the event, for history output.
  String get text {
    final n = note == null ? '' : ' ($note)';
    return switch (kind) {
      'built' => 'built',
      'build_failed' => 'build failed$n',
      'uploaded' => 'uploaded to Google Play$n',
      'published' => 'marked published',
      'unpublished' => 'unmarked as published',
      'symbols_uploaded' => 'debug symbols uploaded$n',
      'artifacts_deleted' => 'APK/AAB/IPA files deleted; symbols kept',
      'symbols_pruned' => 'local symbols removed (already uploaded)',
      _ => kind,
    };
  }

  /// Returns the JSON form stored in the ledger.
  Map<String, Object?> toJson() => {
        'at': at.toUtc().toIso8601String(),
        'event': kind,
        if (note != null) 'note': note,
      };

  /// Reads an event from its ledger JSON.
  factory BuildEvent.fromJson(Map<String, Object?> json) => BuildEvent(
        DateTime.parse(json['at']! as String),
        json['event']! as String,
        json['note'] as String?,
      );
}

/// A single row of the build ledger.
class BuildRecord {
  /// Creates a ledger row; only the required fields must be known at build time.
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
    this.history = const [],
    this.notes,
    this.failure,
    this.command,
    this.signing,
    this.buildIds = const {},
    this.environment = const {},
  });

  /// Unique id of the build.
  final String id;

  /// Name of the app that was built.
  final String appName;

  /// Android application id, when known; null otherwise.
  final String? packageName;

  /// Null when the project has no flavors.
  final String? flavor;

  /// Build mode used.
  final BuildMode mode;

  /// Kind of artifact produced.
  final ArtifactType type;

  /// User facing version, the part before `+` in `pubspec.yaml`.
  final String versionName;

  /// Build number (Android versionCode / iOS build number).
  final int versionCode;

  /// When the build was made.
  final DateTime createdAt;

  /// Entry point passed with `-t`, if any.
  final String? target;

  /// Name of the entry point (e.g. `admin`), when the build used a named one.
  final String? entryPoint;

  /// Folder holding this build, relative to the ledger's root folder.
  final String outputDir;

  /// Files the build produced.
  final List<BuildArtifact> artifacts;

  /// Dart split-debug-info folder (relative), present for obfuscated builds.
  final String? symbolsDir;

  /// R8/ProGuard mapping.txt (relative), when minification produced one.
  final String? mappingFile;

  /// Whether the build was obfuscated (`--obfuscate`).
  final bool obfuscated;

  /// Git commit hash at build time, if available.
  final String? gitCommit;

  /// Git branch at build time, if available.
  final String? gitBranch;

  /// Flutter SDK version used, if known.
  final String? flutterVersion;

  /// Build duration in milliseconds; null when not measured.
  final int? durationMs;

  /// When the build was marked public (released to users).
  final DateTime? publishedAt;

  /// Google Play upload details; null if never uploaded.
  final PlayUpload? play;

  /// Tool name ([SymbolTargets]) to upload time.
  final Map<String, DateTime> symbolUploads;

  /// Steps run before the build (clean, pub get, build_runner, gen-l10n).
  final List<String> preBuild;

  /// When the APK/AAB/IPA files were deleted (symbols are kept).
  final DateTime? artifactsDeletedAt;

  /// Recorded events, oldest first. Empty for a build nothing has happened
  /// to yet and for rows written before events existed; use [events].
  final List<BuildEvent> history;

  /// Free form note; null if none.
  final String? notes;

  /// The certificate the Android build is signed with; null when it could
  /// not be read (no `apksigner`/`keytool`) or for other platforms.
  final BuildSigning? signing;

  /// ELF build ids of the Dart snapshots, by symbols file name (for example
  /// `app.android-arm64.symbols`). A crash report's `build_id` matches one.
  final Map<String, String> buildIds;

  /// Where the build ran: Dart and OS versions, Flutter channel and
  /// revision, hash of the `--dart-define-from-file`, and so on.
  final Map<String, String> environment;

  /// Set when the build did not finish; such a row has no [artifacts] and
  /// keeps only its `build.log`.
  final BuildFailure? failure;

  /// The `flutter build` command line that was run, when known.
  final String? command;

  /// [flavor], or `default` when there is none.
  String get flavorLabel => flavor ?? 'default';

  /// Version as `name+code`, for example `1.2.0+14`.
  String get version => '$versionName+$versionCode';

  /// Whether the build did not finish; see [failure].
  bool get isFailed => failure != null;

  /// Whether the build was marked published.
  bool get isPublished => publishedAt != null;

  /// Whether the build was uploaded to Google Play.
  bool get isOnPlay => play != null;

  /// Published or uploaded to Google Play. A released build keeps its
  /// ledger entry, debug symbols and mappings forever, so crashes from the
  /// field can still be traced; only its APK/AAB/IPA files may be deleted.
  bool get isReleased => isPublished || isOnPlay;

  /// Whether a delete keeps this build's symbols and row, by the rules in
  /// [retainOn]: `published` (marked published), `play` (any Play upload) or
  /// the name of a Play track the build was uploaded to.
  bool isRetainedBy(Set<String> retainOn) =>
      (isPublished && retainOn.contains('published')) ||
      (isOnPlay &&
          (retainOn.contains('play') || retainOn.contains(play!.track)));

  /// Whether the build was ever marked published, even if the mark was
  /// cleared later.
  bool get everPublished =>
      isPublished || events.any((e) => e.kind == 'published');

  /// Whether the APK/AAB/IPA files have been deleted.
  bool get artifactsDeleted => artifactsDeletedAt != null;

  /// The most advanced state: published, else uploaded to Play, else built.
  BuildStatus get status => isFailed
      ? BuildStatus.failed
      : isPublished
          ? BuildStatus.published
          : (isOnPlay ? BuildStatus.uploaded : BuildStatus.built);

  /// [status] in words, e.g. `published (Play internal, completed)`.
  String get statusLabel {
    final onPlay = play == null
        ? ''
        : 'Play ${play!.track}${play!.releaseStatus == null ? '' : ', ${play!.releaseStatus}'}';
    return switch (status) {
      BuildStatus.failed => 'failed (exit code ${failure!.exitCode})',
      BuildStatus.published =>
        onPlay.isEmpty ? 'published' : 'published ($onPlay)',
      BuildStatus.uploaded => 'uploaded to $onPlay',
      BuildStatus.built => 'built, not released',
    };
  }

  /// Whether the build's files are still there.
  String get condition => isFailed
      ? 'failed, log kept'
      : artifactsDeleted
          ? 'artifacts deleted, symbols kept'
          : 'ready';

  /// State of the debug symbols and mappings: stored on disk and uploaded
  /// to which crash tools.
  String get symbolsStatus {
    if (isFailed) return 'none (build failed)';
    final stored = symbolsDir != null || mappingFile != null;
    if (!stored) {
      if (symbolUploads.isNotEmpty) {
        return 'uploaded to ${(symbolUploads.keys.toList()..sort()).join(', ')}'
            ' (local copy removed)';
      }
      return obfuscated ? 'missing' : 'none (not obfuscated)';
    }
    if (symbolUploads.isEmpty) return 'stored, not uploaded';
    return 'uploaded to ${(symbolUploads.keys.toList()..sort()).join(', ')}';
  }

  /// Short [condition] for tables: `ready` or `files deleted`.
  String get conditionShort =>
      isFailed ? 'failed' : (artifactsDeleted ? 'files deleted' : 'ready');

  /// Short [symbolsStatus] for tables: `-`, `stored` or the tools sent to.
  String get symbolsShort {
    if (isFailed) return '-';
    if (symbolsDir == null && mappingFile == null) {
      if (symbolUploads.isNotEmpty) {
        return (symbolUploads.keys.toList()..sort()).join('+');
      }
      return obfuscated ? 'missing' : '-';
    }
    if (symbolUploads.isEmpty) return 'stored';
    return (symbolUploads.keys.toList()..sort()).join('+');
  }

  /// What happened to the build, oldest first. Rows without recorded history
  /// get one rebuilt from their dates.
  List<BuildEvent> get events {
    if (history.isNotEmpty) return history;
    return ([
      BuildEvent(
          createdAt, isFailed ? 'build_failed' : 'built', failure?.message),
      if (play != null)
        BuildEvent(play!.uploadedAt, 'uploaded', play!.eventNote),
      if (publishedAt != null) BuildEvent(publishedAt!, 'published'),
      for (final e in symbolUploads.entries)
        BuildEvent(e.value, 'symbols_uploaded', e.key),
      if (artifactsDeletedAt != null)
        BuildEvent(artifactsDeletedAt!, 'artifacts_deleted'),
    ]..sort((a, b) => a.at.compareTo(b.at)));
  }

  /// Time of the newest entry in [events].
  DateTime get lastEventAt => events.last.at;

  /// Combined size of all [artifacts] in bytes.
  int get totalSize => artifacts.fold(0, (sum, a) => sum + a.sizeBytes);

  /// Returns a copy with the given changes and matching history events appended.
  ///
  /// Null arguments keep the current value; [clearPublished] and [clearPlay]
  /// reset those fields instead.
  BuildRecord copyWith({
    DateTime? publishedAt,
    bool clearPublished = false,
    PlayUpload? play,
    bool clearPlay = false,
    Map<String, DateTime>? symbolUploads,
    DateTime? artifactsDeletedAt,
    bool clearSymbols = false,
    String? notes,
  }) {
    final now = DateTime.now().toUtc();
    final added = <BuildEvent>[
      if (clearPublished && publishedAt == null && this.publishedAt != null)
        BuildEvent(now, 'unpublished'),
      if (publishedAt != null && this.publishedAt == null)
        BuildEvent(publishedAt, 'published'),
      if (play != null) BuildEvent(play.uploadedAt, 'uploaded', play.eventNote),
      if (symbolUploads != null)
        for (final e in symbolUploads.entries)
          if (!this.symbolUploads.containsKey(e.key) ||
              this.symbolUploads[e.key] != e.value)
            BuildEvent(e.value, 'symbols_uploaded', e.key),
      if (artifactsDeletedAt != null && this.artifactsDeletedAt == null)
        BuildEvent(artifactsDeletedAt, 'artifacts_deleted'),
      if (clearSymbols && (symbolsDir != null || mappingFile != null))
        BuildEvent(now, 'symbols_pruned'),
    ];
    return BuildRecord(
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
      symbolsDir: clearSymbols ? null : symbolsDir,
      mappingFile: clearSymbols ? null : mappingFile,
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
      history: added.isEmpty ? history : [...events, ...added],
      notes: notes ?? this.notes,
      failure: failure,
      command: command,
      signing: signing,
      buildIds: buildIds,
      environment: environment,
    );
  }

  /// Returns the JSON form stored in the ledger, including derived status fields.
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
          'current': status.code,
          'label': statusLabel,
          'condition': condition,
          'symbolsStatus': symbolsStatus,
        },
        // Raw state; `status` above is derived and ignored on load.
        if (publishedAt != null)
          'publishedAt': publishedAt!.toUtc().toIso8601String(),
        if (play != null) 'play': play!.toJson(),
        // Always written: its presence marks the newer format.
        'symbolUploads': {
          for (final e in symbolUploads.entries)
            e.key: e.value.toUtc().toIso8601String(),
        },
        if (preBuild.isNotEmpty) 'preBuild': preBuild,
        'history': [for (final e in events) e.toJson()],
        if (artifactsDeletedAt != null)
          'artifactsDeletedAt': artifactsDeletedAt!.toUtc().toIso8601String(),
        if (notes != null) 'notes': notes,
        if (failure != null) 'failure': failure!.toJson(),
        if (command != null) 'command': command,
        if (signing != null) 'signing': signing!.toJson(),
        if (buildIds.isNotEmpty) 'buildIds': buildIds,
        if (environment.isNotEmpty) 'environment': environment,
      };

  /// Reads a record from its ledger JSON; older rows without optional fields are accepted.
  factory BuildRecord.fromJson(Map<String, Object?> json) {
    // Raw fields are the source of truth; files written by 0.1.x kept them
    // inside the derived `status` object, so fall back to that.
    final legacy = json.containsKey('symbolUploads')
        ? const <String, Object?>{}
        : (json['status'] as Map?)?.cast<String, Object?>() ?? {};
    final symbols = ((json['symbolUploads'] ?? legacy['symbols']) as Map?)
            ?.cast<String, Object?>() ??
        {};
    final play = (json['play'] ?? legacy['play']) as Map?;
    final published = (json['publishedAt'] ?? legacy['publishedAt']) as String?;
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
      history: [
        for (final h in (json['history'] as List?) ?? const [])
          BuildEvent.fromJson((h as Map).cast<String, Object?>()),
      ],
      notes: json['notes'] as String?,
      failure: json['failure'] == null
          ? null
          : BuildFailure.fromJson(
              (json['failure']! as Map).cast<String, Object?>()),
      command: json['command'] as String?,
      signing: json['signing'] == null
          ? null
          : BuildSigning.fromJson(
              (json['signing']! as Map).cast<String, Object?>()),
      buildIds: {
        for (final e in ((json['buildIds'] as Map?) ?? const {}).entries)
          '${e.key}': '${e.value}',
      },
      environment: {
        for (final e in ((json['environment'] as Map?) ?? const {}).entries)
          '${e.key}': '${e.value}',
      },
    );
  }
}
