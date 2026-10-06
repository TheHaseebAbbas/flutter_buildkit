import 'dart:io';

import 'package:googleapis/androidpublisher/v3.dart' as ap;
import 'package:googleapis_auth/auth_io.dart';
import 'package:http/http.dart' as http;

import '../config.dart';
import '../ledger/ledger.dart';
import '../model/build_options.dart';
import '../model/build_record.dart';

/// Thrown when an upload to Google Play is rejected or cannot be attempted.
class PlayException implements Exception {
  /// Creates an exception carrying [message].
  PlayException(this.message);

  /// Human-readable description of what went wrong.
  final String message;
  @override
  String toString() => message;
}

/// Thrown when the track already carries a staged or halted rollout that an
/// upload would drop. Upload again with `replaceExisting` to go ahead.
class PlayTrackInUseException extends PlayException {
  /// Creates the exception for [track] and the [releases] in the way.
  PlayTrackInUseException(this.track, this.releases)
      : super(
            'The $track track has an unfinished release (${releases.join('; ')}'
            '). Uploading would replace it. Finish or halt it in Play '
            'Console, or upload with replaceExisting (--replace-existing).');

  /// The track that is in use.
  final String track;

  /// Short descriptions of the releases that would be dropped.
  final List<String> releases;
}

/// Uploads an AAB to Google Play through the Android Publisher API.
///
/// The service account key is read from `play.service_account_json` or the
/// PLAY_SERVICE_ACCOUNT_JSON environment variable. The account needs release
/// permissions for the app in Play Console. Google Play only accepts the
/// very first upload of a new app through the Play Console.
class PlayPublisher {
  /// Creates a publisher using [config] and [ledger]; [log] receives progress lines.
  ///
  /// By default the service account key is used. Pass [httpClient] to use
  /// your own authenticated client instead (other credential types, tests);
  /// it is not closed by the publisher.
  PlayPublisher({
    required this.config,
    required this.ledger,
    void Function(String)? log,
    this.httpClient,
  }) : log = log ?? ((_) {});

  /// Authenticated client used instead of the service account, or null.
  final http.Client? httpClient;

  /// Configuration holding the `play` settings and service account key path.
  final AppConfig config;

  /// Ledger updated with the upload result.
  final Ledger ledger;

  /// Receives progress lines.
  final void Function(String) log;

  /// Uploads the build's AAB to [track] and records it in the ledger.
  ///
  /// The track is read first. A staged or halted rollout on it would be
  /// dropped by the update, so that throws [PlayTrackInUseException] unless
  /// [replaceExisting] is true. Other existing releases (completed, draft)
  /// are replaced and mentioned in the log.
  Future<BuildRecord> publish(
    BuildRecord record, {
    String? track,
    String? releaseStatus,
    String? releaseNotes,
    double? userFraction,
    bool replaceExisting = false,
  }) async {
    if (record.type != ArtifactType.aab) {
      throw PlayException('Only AAB builds can be uploaded to Google Play '
          '(this build is ${record.type.name}).');
    }
    if (record.isFailed || record.artifacts.isEmpty) {
      throw PlayException('This build has no files to upload.');
    }
    if (record.mode != BuildMode.release) {
      throw PlayException('Google Play rejects debuggable builds; this build '
          'is ${record.mode.name}. Build with --release.');
    }
    if (record.signing?.debugKey ?? false) {
      throw PlayException('This build is signed with the Android debug key; '
          'Google Play rejects it. Set up release signing and build again.');
    }
    final keyPath = config.play.serviceAccountJson;
    if (keyPath == null && httpClient == null) {
      throw PlayException('No Play credentials. Set play.service_account_json '
          'in the config or PLAY_SERVICE_ACCOUNT_JSON in your environment. '
          'You can still mark the build as uploaded without the API.');
    }
    final packageName =
        record.packageName ?? config.flavor(record.flavor).packageName;
    if (packageName == null) {
      throw PlayException('Unknown Android package name for this build. Set '
          'flavors.<flavor>.package_name in the config.');
    }
    final aab = File(ledger.resolve(record.artifacts.first.path));
    if (!aab.existsSync()) {
      throw PlayException('${aab.path} no longer exists.');
    }
    final key = keyPath == null ? null : File(keyPath);
    if (key != null && httpClient == null && !key.existsSync()) {
      throw PlayException('Service account key not found: $keyPath');
    }

    track ??= config.play.defaultTrack;
    releaseStatus ??= config.play.defaultReleaseStatus;
    if (releaseStatus == 'inProgress' && userFraction == null) {
      throw PlayException('Staged rollouts need a user fraction, e.g. 0.1.');
    }

    final client = httpClient ??
        await clientViaServiceAccount(
            ServiceAccountCredentials.fromJson(key!.readAsStringSync()),
            [ap.AndroidPublisherApi.androidpublisherScope]);
    try {
      final api = ap.AndroidPublisherApi(client);
      log('Opening an edit for $packageName...');
      final edit = await api.edits.insert(ap.AppEdit(), packageName);
      final editId = edit.id!;

      await _checkVersionCode(api, record, packageName, editId);
      final existing = await _existingReleases(api, packageName, editId, track);
      final unfinished = [
        for (final r in existing)
          if (r.status == 'inProgress' || r.status == 'halted') _describe(r),
      ];
      if (unfinished.isNotEmpty && !replaceExisting) {
        await _discardEdit(api, packageName, editId);
        throw PlayTrackInUseException(track, unfinished);
      }
      for (final r in existing) {
        log('The $track track currently has ${_describe(r)}; '
            'this upload replaces it.');
      }

      log('Uploading ${aab.path} (${aab.lengthSync()} bytes)...');
      final bundle = await api.edits.bundles.upload(
        packageName,
        editId,
        uploadMedia: ap.Media(aab.openRead(), aab.lengthSync(),
            contentType: 'application/octet-stream'),
      );
      final code = bundle.versionCode!;

      final mapping = record.mappingFile == null
          ? null
          : File(ledger.resolve(record.mappingFile!));
      if (config.play.uploadMapping &&
          mapping != null &&
          mapping.existsSync()) {
        log('Uploading R8 mapping...');
        await api.edits.deobfuscationfiles.upload(
          packageName,
          editId,
          code,
          'proguard',
          uploadMedia: ap.Media(mapping.openRead(), mapping.lengthSync(),
              contentType: 'application/octet-stream'),
        );
      }

      log('Assigning version $code to the $track track ($releaseStatus)...');
      await api.edits.tracks.update(
        ap.Track(
          track: track,
          releases: [
            ap.TrackRelease(
              name: record.version,
              versionCodes: ['$code'],
              status: releaseStatus,
              userFraction: userFraction,
              releaseNotes: releaseNotes == null || releaseNotes.isEmpty
                  ? null
                  : [ap.LocalizedText(language: 'en-US', text: releaseNotes)],
            ),
          ],
        ),
        packageName,
        editId,
        track,
      );

      log('Committing the edit...');
      await api.edits.commit(packageName, editId);

      final upload = PlayUpload(
        track: track,
        uploadedAt: DateTime.now().toUtc(),
        viaApi: true,
        releaseStatus: releaseStatus,
        editId: editId,
      );
      return await ledger.update(record.id, (r) => r.copyWith(play: upload));
    } on ap.DetailedApiRequestError catch (e) {
      throw PlayException('Google Play API error ${e.status}: ${e.message}');
    } finally {
      if (httpClient == null) client.close();
    }
  }

  /// Fails early when Play already has this version code, instead of after
  /// the upload. Skipped quietly when the tracks cannot be read.
  Future<void> _checkVersionCode(ap.AndroidPublisherApi api, BuildRecord record,
      String packageName, String editId) async {
    final used = <int>{};
    try {
      final tracks = await api.edits.tracks.list(packageName, editId);
      for (final t in tracks.tracks ?? const <ap.Track>[]) {
        for (final r in t.releases ?? const <ap.TrackRelease>[]) {
          for (final c in r.versionCodes ?? const <String>[]) {
            final n = int.tryParse(c);
            if (n != null) used.add(n);
          }
        }
      }
    } on Object {
      log('Could not read the existing version codes; skipping that check.');
      return;
    }
    if (used.contains(record.versionCode)) {
      await _discardEdit(api, packageName, editId);
      throw PlayException('Google Play already has version code '
          '${record.versionCode}. Build again with a higher --build-number '
          '(highest on Play: ${used.reduce((a, b) => a > b ? a : b)}).');
    }
    final highest = used.isEmpty ? 0 : used.reduce((a, b) => a > b ? a : b);
    if (record.versionCode < highest) {
      log('Warning: version code ${record.versionCode} is lower than '
          '$highest already on Play.');
    }
  }

  /// Checks that the service account can open an edit for [packageName] (and
  /// discards it). Throws [PlayException] with the reason when it cannot.
  Future<void> checkAccess(String packageName) async {
    final keyPath = config.play.serviceAccountJson;
    if (keyPath == null && httpClient == null) {
      throw PlayException('No Play credentials are configured.');
    }
    final client = httpClient ??
        await clientViaServiceAccount(
            ServiceAccountCredentials.fromJson(
                File(keyPath!).readAsStringSync()),
            [ap.AndroidPublisherApi.androidpublisherScope]);
    try {
      final api = ap.AndroidPublisherApi(client);
      final edit = await api.edits.insert(ap.AppEdit(), packageName);
      await _discardEdit(api, packageName, edit.id!);
    } on ap.DetailedApiRequestError catch (e) {
      throw PlayException('Google Play API error ${e.status}: ${e.message}');
    } finally {
      if (httpClient == null) client.close();
    }
  }

  Future<List<ap.TrackRelease>> _existingReleases(ap.AndroidPublisherApi api,
      String packageName, String editId, String track) async {
    try {
      final current = await api.edits.tracks.get(packageName, editId, track);
      return current.releases ?? const [];
    } on ap.DetailedApiRequestError catch (e) {
      if (e.status == 404) return const [];
      rethrow;
    }
  }

  static String _describe(ap.TrackRelease r) =>
      '${r.status ?? 'unknown'} release ${r.name ?? ''} '
              '(version codes ${(r.versionCodes ?? const []).join(', ')}'
              '${r.userFraction == null ? '' : ', ${r.userFraction}'})'
          .replaceAll('  ', ' ');

  /// Best effort: an unused edit expires on its own.
  Future<void> _discardEdit(
      ap.AndroidPublisherApi api, String packageName, String editId) async {
    try {
      await api.edits.delete(packageName, editId);
    } on Object {
      // Ignored.
    }
  }

  /// Records that the build was uploaded to Play by hand.
  Future<BuildRecord> markUploaded(BuildRecord record,
          {required String track, DateTime? at}) =>
      ledger.update(
        record.id,
        (r) => r.copyWith(
          play: PlayUpload(
              track: track,
              uploadedAt: (at ?? DateTime.now()).toUtc(),
              viaApi: false),
        ),
      );
}
