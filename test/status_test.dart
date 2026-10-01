import 'package:flutter_buildkit/flutter_buildkit.dart';
import 'package:test/test.dart';

BuildRecord base({bool obfuscated = true, String? symbolsDir = 'x/symbols'}) =>
    BuildRecord(
      id: 'a',
      appName: 'my_app',
      flavor: 'dev',
      mode: BuildMode.release,
      type: ArtifactType.aab,
      versionName: '1.0.0',
      versionCode: 1,
      createdAt: DateTime.utc(2026, 10, 1, 7),
      outputDir: 'x',
      artifacts: const [],
      obfuscated: obfuscated,
      symbolsDir: symbolsDir,
    );

void main() {
  test('a new build is built, ready, with stored symbols', () {
    final r = base();
    expect(r.status, BuildStatus.built);
    expect(r.statusLabel, 'built, not released');
    expect(r.condition, 'ready');
    expect(r.symbolsStatus, 'stored, not uploaded');
    expect(r.events.map((e) => e.kind), ['built']);
  });

  test('status follows upload, publish and unpublish, with history', () {
    var r = base().copyWith(
        play: PlayUpload(
            track: 'internal',
            uploadedAt: DateTime.utc(2026, 10, 2),
            viaApi: true,
            releaseStatus: 'draft'));
    expect(r.status, BuildStatus.uploaded);
    expect(r.statusLabel, 'uploaded to Play internal, draft');

    r = r.copyWith(publishedAt: DateTime.utc(2026, 10, 3));
    expect(r.status, BuildStatus.published);
    expect(r.statusLabel, 'published (Play internal, draft)');

    r = r.copyWith(clearPublished: true);
    expect(r.status, BuildStatus.uploaded);

    expect(r.events.map((e) => e.kind),
        ['built', 'uploaded', 'published', 'unpublished']);
    expect(r.events[1].text, 'uploaded to Google Play (internal, draft)');
  });

  test('symbol uploads and file deletion are recorded', () {
    var r = base().copyWith(symbolUploads: {
      'crashlytics': DateTime.utc(2026, 10, 2),
    });
    expect(r.symbolsStatus, 'uploaded to crashlytics');
    expect(r.symbolsShort, 'crashlytics');
    r = r.copyWith(symbolUploads: {
      'crashlytics': DateTime.utc(2026, 10, 2),
      'sentry': DateTime.utc(2026, 10, 3),
    });
    expect(r.symbolsShort, 'crashlytics+sentry');
    r = r.copyWith(artifactsDeletedAt: DateTime.utc(2026, 10, 4));
    expect(r.condition, 'artifacts deleted, symbols kept');
    expect(r.conditionShort, 'files deleted');
    expect(r.events.map((e) => e.kind), [
      'built',
      'symbols_uploaded',
      'symbols_uploaded',
      'artifacts_deleted',
    ]);
    expect(r.lastEventAt, DateTime.utc(2026, 10, 4));
  });

  test('symbols are reported missing for an obfuscated build without them', () {
    expect(base(symbolsDir: null).symbolsStatus, 'missing');
    expect(base(obfuscated: false, symbolsDir: null).symbolsStatus,
        'none (not obfuscated)');
  });

  test('history survives JSON, and old rows get one from their dates', () {
    final r = base()
        .copyWith(publishedAt: DateTime.utc(2026, 10, 3))
        .copyWith(artifactsDeletedAt: DateTime.utc(2026, 10, 5));
    final back = BuildRecord.fromJson(r.toJson());
    expect(back.events.map((e) => e.kind),
        ['built', 'published', 'artifacts_deleted']);
    expect((back.toJson()['status'] as Map)['current'], 'published');

    final old = r.toJson()..remove('history');
    final rebuilt = BuildRecord.fromJson(old);
    expect(rebuilt.history, isEmpty);
    expect(rebuilt.events.map((e) => e.kind),
        ['built', 'published', 'artifacts_deleted']);
  });

  test('exports carry status, condition and symbols', () {
    final r = base().copyWith(publishedAt: DateTime.utc(2026, 10, 3));
    final csv = const LedgerExporter().export([r], ExportFormat.csv);
    final lines = csv.split('\r\n');
    final header = lines[0].split(',');
    final row = lines[1].split(',');
    expect(row[header.indexOf('status')], 'published');
    expect(row[header.indexOf('condition')], 'ready');
    expect(header, contains('symbols_status'));
    expect(header, contains('last_event_at'));
  });
}
