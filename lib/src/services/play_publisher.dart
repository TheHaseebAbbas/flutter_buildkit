import 'dart:io';

import 'package:googleapis/androidpublisher/v3.dart' as ap;
import 'package:googleapis_auth/auth_io.dart';

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

/// Uploads an AAB to Google Play through the Android Publisher API.
///
/// The service account key is read from `play.service_account_json` or the
/// PLAY_SERVICE_ACCOUNT_JSON environment variable. The account needs release
/// permissions for the app in Play Console. Google Play only accepts the
/// very first upload of a new app through the Play Console.
class PlayPublisher {
  /// Creates a publisher using [config] and [ledger]; [log] receives progress lines.
  PlayPublisher(
      {required this.config, required this.ledger, void Function(String)? log})
      : log = log ?? ((_) {});

  /// Configuration holding the `play` settings and service account key path.
  final AppConfig config;

  /// Ledger updated with the upload result.
  final Ledger ledger;

  /// Receives progress lines.
  final void Function(String) log;

  /// Uploads the build's AAB to [track] and records it in the ledger.
  Future<BuildRecord> publish(
    BuildRecord record, {
    String? track,
    String? releaseStatus,
    String? releaseNotes,
    double? userFraction,
  }) async {
    if (record.type != ArtifactType.aab) {
      throw PlayException('Only AAB builds can be uploaded to Google Play '
          '(this build is ${record.type.name}).');
    }
    if (record.mode != BuildMode.release) {
      throw PlayException('Google Play rejects debuggable builds; this build '
          'is ${record.mode.name}. Build with --release.');
    }
    final keyPath = config.play.serviceAccountJson;
    if (keyPath == null) {
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
    final key = File(keyPath);
    if (!key.existsSync()) {
      throw PlayException('Service account key not found: $keyPath');
    }

    track ??= config.play.defaultTrack;
    releaseStatus ??= config.play.defaultReleaseStatus;
    if (releaseStatus == 'inProgress' && userFraction == null) {
      throw PlayException('Staged rollouts need a user fraction, e.g. 0.1.');
    }

    final credentials =
        ServiceAccountCredentials.fromJson(key.readAsStringSync());
    final client = await clientViaServiceAccount(
        credentials, [ap.AndroidPublisherApi.androidpublisherScope]);
    try {
      final api = ap.AndroidPublisherApi(client);
      log('Opening an edit for $packageName...');
      final edit = await api.edits.insert(ap.AppEdit(), packageName);
      final editId = edit.id!;

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
      client.close();
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
