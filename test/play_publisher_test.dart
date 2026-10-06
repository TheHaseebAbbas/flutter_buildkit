import 'dart:convert';
import 'dart:io';

import 'package:flutter_buildkit/flutter_buildkit.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late Ledger ledger;
  late AppConfig config;
  late BuildRecord record;
  late List<http.Request> requests;
  late Map<String, Object?> track;
  var trackStatus = 200;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('fbk_play_');
    config = AppConfig.fromYaml(tmp.path, const {});
    ledger = await Ledger.open(config.ledgerPath);
    final aab = File(p.join(tmp.path, 'app_builds', 'a.aab'))
      ..createSync(recursive: true)
      ..writeAsStringSync('aab');
    record = BuildRecord(
      id: 'a',
      appName: 'demo',
      packageName: 'com.demo',
      mode: BuildMode.release,
      type: ArtifactType.aab,
      versionName: '1.0.0',
      versionCode: 3,
      createdAt: DateTime.utc(2026, 10, 1),
      outputDir: 'demo/a',
      artifacts: [
        BuildArtifact(
            path: ledger.relativize(aab.path), sizeBytes: 3, sha256: 'x')
      ],
    );
    await ledger.add(record);
    requests = [];
    track = {'track': 'internal'};
    trackStatus = 200;
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  MockClient client() => MockClient((request) async {
        requests.add(request);
        final path = request.url.path;
        http.Response json(Object body, [int status = 200]) =>
            http.Response(jsonEncode(body), status,
                headers: {'content-type': 'application/json; charset=utf-8'});
        if (path.endsWith('/edits') && request.method == 'POST') {
          return json({'id': 'edit1'});
        }
        if (path.contains('/bundles')) return json({'versionCode': 42});
        if (path.contains('/tracks/') && request.method == 'GET') {
          return trackStatus == 404
              ? json({
                  'error': {'code': 404, 'message': 'track not found'}
                }, 404)
              : json(track);
        }
        if (path.contains('/tracks/') && request.method == 'PUT') {
          return json(jsonDecode(request.body) as Object);
        }
        if (path.endsWith(':commit')) return json({'id': 'edit1'});
        if (request.method == 'DELETE') return http.Response('', 204);
        return json({
          'error': {
            'code': 500,
            'message': 'unexpected ${request.method} $path'
          }
        }, 500);
      });

  PlayPublisher publisher() => PlayPublisher(
      config: config, ledger: ledger, httpClient: client(), log: (_) {});

  Iterable<http.Request> where(String method, String part) =>
      requests.where((r) => r.method == method && r.url.path.contains(part));

  test('uploads, sets the release on the track and commits', () async {
    final updated = await publisher().publish(record,
        track: 'internal', releaseStatus: 'draft', releaseNotes: 'hello');

    final put = where('PUT', '/tracks/internal').single;
    final body = jsonDecode(put.body) as Map;
    final release = (body['releases'] as List).single as Map;
    expect(release['status'], 'draft');
    expect(release['versionCodes'], ['42']);
    expect(release['releaseNotes'], [
      {'language': 'en-US', 'text': 'hello'}
    ]);
    expect(where('POST', ':commit'), hasLength(1));
    expect(updated.play!.track, 'internal');
    expect(updated.play!.viaApi, isTrue);
    expect(ledger.byId('a')!.play!.releaseStatus, 'draft');
  });

  test('the track is read before it is changed', () async {
    await publisher()
        .publish(record, track: 'internal', releaseStatus: 'draft');
    final order = [for (final r in requests) '${r.method} ${r.url.path}'];
    expect(
        order.indexWhere((s) => s.startsWith('GET') && s.contains('/tracks/')),
        lessThan(order.indexWhere((s) => s.startsWith('PUT'))));
  });

  test('a staged rollout on the track is not dropped silently', () async {
    track = {
      'track': 'production',
      'releases': [
        {
          'name': '1.0.0',
          'status': 'inProgress',
          'userFraction': 0.1,
          'versionCodes': ['40']
        }
      ]
    };
    await expectLater(
        publisher()
            .publish(record, track: 'production', releaseStatus: 'draft'),
        throwsA(isA<PlayTrackInUseException>()
            .having((e) => e.message, 'message', contains('40'))));
    expect(where('PUT', '/tracks/'), isEmpty);
    expect(where('POST', ':commit'), isEmpty);
    expect(where('POST', '/bundles'), isEmpty, reason: 'nothing was uploaded');
    expect(ledger.byId('a')!.play, isNull);
  });

  test('replaceExisting goes ahead and a completed release is replaced',
      () async {
    track = {
      'track': 'internal',
      'releases': [
        {
          'status': 'inProgress',
          'versionCodes': ['40'],
          'userFraction': 0.5
        }
      ]
    };
    await publisher().publish(record,
        track: 'internal', releaseStatus: 'draft', replaceExisting: true);
    expect(where('POST', ':commit'), hasLength(1));

    requests.clear();
    track = {
      'track': 'internal',
      'releases': [
        {
          'status': 'completed',
          'versionCodes': ['40']
        }
      ]
    };
    final logs = <String>[];
    await PlayPublisher(
            config: config, ledger: ledger, httpClient: client(), log: logs.add)
        .publish(record, track: 'internal', releaseStatus: 'draft');
    expect(logs.join('\n'), contains('replaces it'));
  });

  test('a track that does not exist yet is fine', () async {
    trackStatus = 404;
    await publisher()
        .publish(record, track: 'internal', releaseStatus: 'draft');
    expect(where('POST', ':commit'), hasLength(1));
  });

  test('API errors become a PlayException with the status', () async {
    final failing = MockClient((request) async => http.Response(
        jsonEncode({
          'error': {'code': 403, 'message': 'The caller does not have access'}
        }),
        403,
        headers: {'content-type': 'application/json; charset=utf-8'}));
    await expectLater(
        PlayPublisher(config: config, ledger: ledger, httpClient: failing)
            .publish(record, track: 'internal', releaseStatus: 'draft'),
        throwsA(isA<PlayException>()
            .having((e) => e.message, 'message', contains('403'))));
  });

  test('staged rollouts need a fraction; failed builds cannot be uploaded',
      () async {
    await expectLater(
        publisher()
            .publish(record, track: 'internal', releaseStatus: 'inProgress'),
        throwsA(isA<PlayException>()));
    final failed = BuildRecord.fromJson({
      ...record.toJson(),
      'artifacts': [],
      'failure': {'exitCode': 1, 'message': 'x'}
    });
    await expectLater(
        publisher().publish(failed), throwsA(isA<PlayException>()));
  });
}
