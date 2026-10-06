import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:args/args.dart';
import 'package:flutter_buildkit/flutter_buildkit.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// A tiny little-endian ELF64 file with one SHT_NOTE section holding a GNU
/// build id.
Uint8List elfWithBuildId(List<int> id) {
  final note = BytesBuilder()
    ..add(_u32(4)) // namesz
    ..add(_u32(id.length))
    ..add(_u32(3)) // NT_GNU_BUILD_ID
    ..add('GNU\u0000'.codeUnits)
    ..add(id);
  final noteBytes = note.toBytes();
  final bytes = BytesBuilder()
    ..add(List.filled(64, 0)) // header, patched below
    ..add(noteBytes);
  final shoff = bytes.length;
  final sh = ByteData(64)
    ..setUint32(4, 7, Endian.little) // SHT_NOTE
    ..setUint64(0x18, 64, Endian.little) // offset
    ..setUint64(0x20, noteBytes.length, Endian.little);
  bytes.add(sh.buffer.asUint8List());
  final out = bytes.toBytes();
  final h = ByteData.sublistView(out);
  out.setAll(0, [0x7f, 0x45, 0x4c, 0x46, 2, 1]);
  h
    ..setUint64(0x28, shoff, Endian.little)
    ..setUint16(0x3a, 64, Endian.little)
    ..setUint16(0x3c, 1, Endian.little);
  return out;
}

List<int> _u32(int v) =>
    (ByteData(4)..setUint32(0, v, Endian.little)).buffer.asUint8List();

BuildRecord rec(String id,
        {DateTime? at,
        int code = 1,
        String? flavor = 'dev',
        Map<String, String> buildIds = const {},
        BuildSigning? signing,
        bool failed = false,
        bool obfuscated = true,
        String? symbolsDir,
        Map<String, DateTime> uploads = const {},
        DateTime? publishedAt,
        PlayUpload? play,
        List<BuildArtifact> artifacts = const []}) =>
    BuildRecord(
      id: id,
      appName: 'demo',
      packageName: 'com.demo',
      flavor: flavor,
      mode: BuildMode.release,
      type: ArtifactType.aab,
      versionName: '1.0.0',
      versionCode: code,
      createdAt: at ?? DateTime.utc(2026, 10, 1),
      outputDir: 'demo/$id',
      artifacts: artifacts,
      obfuscated: obfuscated,
      symbolsDir: symbolsDir,
      buildIds: buildIds,
      signing: signing,
      symbolUploads: uploads,
      publishedAt: publishedAt,
      play: play,
      failure: failed ? const BuildFailure(1, 'boom') : null,
    );

void main() {
  late Directory tmp;
  late Ledger ledger;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('fbk_phase2_');
    File(p.join(tmp.path, 'pubspec.yaml'))
        .writeAsStringSync('name: demo\nversion: 1.2.0+5\n');
    ledger = await Ledger.open(p.join(tmp.path, 'app_builds', 'ledger.json'));
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<Directory> folder(BuildRecord r) async {
    final dir = Directory(ledger.resolve(r.outputDir))
      ..createSync(recursive: true);
    File(p.join(dir.path, buildInfoName))
        .writeAsStringSync(jsonEncode({'id': r.id}));
    return dir;
  }

  group('ledger JSON', () {
    test('raw state is written at the top level and status is derived', () {
      final r = rec('a')
          .copyWith(publishedAt: DateTime.utc(2026, 10, 2))
          .copyWith(symbolUploads: {'sentry': DateTime.utc(2026, 10, 3)});
      final json = r.toJson();
      expect(json['publishedAt'], '2026-10-02T00:00:00.000Z');
      expect((json['symbolUploads'] as Map).keys, ['sentry']);
      expect((json['status'] as Map).containsKey('publishedAt'), isFalse);
    });

    test('a hand-edited derived status is ignored on load', () {
      final json =
          jsonDecode(jsonEncode(rec('a').toJson())) as Map<String, Object?>;
      json['status'] = {
        'current': 'published',
        'publishedAt': '2026-01-01T00:00:00.000Z',
      };
      expect(BuildRecord.fromJson(json).isPublished, isFalse);
    });

    test('rows from 0.1.x keep their state inside status', () {
      final json =
          jsonDecode(jsonEncode(rec('a').toJson())) as Map<String, Object?>;
      json.remove('symbolUploads');
      json['status'] = {
        'publishedAt': '2026-01-01T00:00:00.000Z',
        'symbols': {'crashlytics': '2026-01-02T00:00:00.000Z'},
      };
      final back = BuildRecord.fromJson(json);
      expect(back.isPublished, isTrue);
      expect(back.symbolUploads.keys, ['crashlytics']);
    });

    test('signing, build ids and environment round-trip', () {
      final r = BuildRecord.fromJson(jsonDecode(jsonEncode(rec('a',
              buildIds: {'app.symbols': 'ab12'},
              signing: const BuildSigning(sha256: 'ff', debugKey: true))
          .toJson())) as Map<String, Object?>);
      expect(r.buildIds, {'app.symbols': 'ab12'});
      expect(r.signing!.debugKey, isTrue);
    });
  });

  group('ELF build ids', () {
    test('reads the GNU build id note', () {
      expect(elfBuildId(elfWithBuildId([0xde, 0xad, 0xbe, 0xef, 0x01])),
          'deadbeef01');
    });

    test('returns null for other files', () {
      expect(elfBuildId(Uint8List.fromList(List.filled(100, 1))), isNull);
      expect(elfBuildId(Uint8List(3)), isNull);
    });

    test('dartBuildIds reads every .symbols file', () {
      final dir = Directory(p.join(tmp.path, 'sym'))..createSync();
      File(p.join(dir.path, 'app.android-arm64.symbols'))
          .writeAsBytesSync(elfWithBuildId([1, 2, 3, 4]));
      File(p.join(dir.path, 'readme.txt')).writeAsStringSync('x');
      expect(dartBuildIds(dir), {'app.android-arm64.symbols': '01020304'});
    });
  });

  group('matching a crash to a build', () {
    const trace = "*** *** ***\nbuild_id: 'DEADBEEF01'\n#00 abs 0x1 virt 0x2";

    test('by build_id', () {
      final a = rec('a', buildIds: {'x': 'deadbeef01'});
      final b = rec('b', buildIds: {'x': 'other'});
      expect(matchBuild([b, a], trace)!.id, 'a');
      expect(traceBuildId(trace), 'deadbeef01');
    });

    test('by version when it is unique and the report has no id', () {
      final a = rec('a', code: 7);
      final b = rec('b', code: 8);
      expect(matchBuild([a, b], 'app 1.0.0+7 crashed')!.id, 'a');
      expect(matchBuild([a, a], 'app 1.0.0+7 crashed'), isNull);
    });

    test('warns when the build id belongs to another build', () {
      final a = rec('a', buildIds: {'x': 'aaaa1111'});
      expect(buildMismatchWarning(a, trace), contains('not one of'));
      expect(buildMismatchWarning(rec('b'), trace), contains('no recorded'));
      expect(
          buildMismatchWarning(rec('c', buildIds: {'x': 'deadbeef01'}), trace),
          isNull);
      expect(buildMismatchWarning(a, 'no id here'), isNull);
    });
  });

  group('signing', () {
    test('parses apksigner output', () {
      final s = SigningInspector.parseApksigner('''
Signer #1 certificate DN: CN=Android Debug, O=Android, C=US
Signer #1 certificate SHA-256 digest: AA:BB:cc
''')!;
      expect(s.sha256, 'aabbcc');
      expect(s.debugKey, isTrue);
      expect(s.tool, 'apksigner');
    });

    test('parses keytool output', () {
      final s = SigningInspector.parseKeytool('''
Owner: CN=Acme, O=Acme Inc
Certificate fingerprints:
\t SHA1: 11:22
\t SHA256: AB:CD:EF
''')!;
      expect(s.sha256, 'abcdef');
      expect(s.debugKey, isFalse);
    });

    test('junk output means unknown, not an error', () {
      expect(SigningInspector.parseKeytool('{"frameworkVersion":"1"}'), isNull);
      expect(SigningInspector.parseApksigner(''), isNull);
    });
  });

  group('verify', () {
    test('a consistent ledger is ok', () async {
      final dir = await folder(rec('a'));
      final aab = File(p.join(dir.path, 'a.aab'))..writeAsStringSync('hello');
      final r = rec('a',
          artifacts: [
            BuildArtifact(
                path: ledger.relativize(aab.path),
                sizeBytes: 5,
                // sha256 of "hello"
                sha256:
                    '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824')
          ],
          symbolsDir: 'demo/a/symbols');
      Directory(ledger.resolve('demo/a/symbols')).createSync();
      await ledger.add(r);
      final report = await verifyLedger(ledger);
      expect(report.issues, isEmpty);
    });

    test('finds missing and changed files, missing folders and orphans',
        () async {
      final changed = await folder(rec('changed'));
      final aab = File(p.join(changed.path, 'a.aab'))..writeAsStringSync('hi');
      await ledger.add(rec('changed', obfuscated: false, artifacts: [
        BuildArtifact(
            path: ledger.relativize(aab.path), sizeBytes: 2, sha256: 'wrong')
      ]));
      await folder(rec('gone-file'));
      await ledger.add(rec('gone-file', obfuscated: false, artifacts: const [
        BuildArtifact(path: 'demo/gone-file/x.aab', sizeBytes: 1, sha256: 'x')
      ]));
      await ledger.add(rec('no-folder', obfuscated: false));
      await folder(rec('orphan'));
      await folder(rec('nosymbols'));
      await ledger.add(rec('nosymbols'));

      final kinds = {
        for (final i in (await verifyLedger(ledger)).issues)
          '${i.kind}:${i.id ?? p.basename(i.path!)}'
      };
      expect(kinds, {
        'hash_mismatch:changed',
        'missing_file:gone-file',
        'missing_folder:no-folder',
        'orphan_folder:orphan',
        'missing_symbols:nosymbols',
      });
    });

    test('--quick skips the hash but still sees size changes', () async {
      final dir = await folder(rec('a'));
      final aab = File(p.join(dir.path, 'a.aab'))..writeAsStringSync('hi');
      await ledger.add(rec('a', obfuscated: false, artifacts: [
        BuildArtifact(
            path: ledger.relativize(aab.path), sizeBytes: 2, sha256: 'wrong')
      ]));
      expect((await verifyLedger(ledger, hash: false)).issues, isEmpty);
    });

    test('files deleted on purpose are not reported', () async {
      await folder(rec('a'));
      await ledger.add(rec('a', obfuscated: false, artifacts: const [
        BuildArtifact(path: 'demo/a/x.aab', sizeBytes: 1, sha256: 'x')
      ]).copyWith(artifactsDeletedAt: DateTime.utc(2026, 10, 2)));
      expect((await verifyLedger(ledger)).issues, isEmpty);
    });
  });

  group('prune', () {
    final now = DateTime.utc(2026, 10, 10);

    test('removes old logs and failed builds, keeps recent ones', () async {
      final old = rec('old', at: DateTime.utc(2026, 1, 1));
      final fresh = rec('fresh', at: DateTime.utc(2026, 10, 9));
      final oldFailed =
          rec('oldfail', at: DateTime.utc(2026, 1, 1), failed: true);
      for (final r in [old, fresh, oldFailed]) {
        final d = await folder(r);
        File(p.join(d.path, buildLogName)).writeAsStringSync('log');
        await ledger.add(r);
      }
      final manager = BuildManager(ledger);
      final dry = await pruneBuilds(ledger, manager,
          logDays: 30, dryRun: true, now: now);
      expect(dry.logs.map((r) => r.id), ['old']);
      expect(dry.failedBuilds.map((r) => r.id), ['oldfail']);
      expect(
          File(p.join(ledger.resolve(old.outputDir), buildLogName))
              .existsSync(),
          isTrue);

      final real = await pruneBuilds(ledger, manager, logDays: 30, now: now);
      expect(real.failed, isEmpty);
      expect(
          File(p.join(ledger.resolve(old.outputDir), buildLogName))
              .existsSync(),
          isFalse);
      expect(
          File(p.join(ledger.resolve(fresh.outputDir), buildLogName))
              .existsSync(),
          isTrue);
      expect(ledger.byId('oldfail'), isNull);
      expect(ledger.byId('old'), isNotNull);
    });

    test('symbols go only for old released builds already uploaded', () async {
      final uploads = {'sentry': DateTime.utc(2026, 9, 1)};
      final builds = [
        rec('r1',
            at: DateTime.utc(2026, 9, 1),
            publishedAt: DateTime.utc(2026, 9, 2),
            uploads: uploads,
            symbolsDir: 'demo/r1/symbols'),
        rec('r2',
            at: DateTime.utc(2026, 9, 2),
            publishedAt: DateTime.utc(2026, 9, 3),
            uploads: uploads,
            symbolsDir: 'demo/r2/symbols'),
        rec('r3-not-uploaded',
            at: DateTime.utc(2026, 8, 1),
            publishedAt: DateTime.utc(2026, 8, 2),
            symbolsDir: 'demo/r3-not-uploaded/symbols'),
        rec('r4-unreleased',
            at: DateTime.utc(2026, 7, 1),
            uploads: uploads,
            symbolsDir: 'demo/r4-unreleased/symbols'),
      ];
      for (final r in builds) {
        final d = await folder(r);
        Directory(p.join(d.path, 'symbols')).createSync();
        File(p.join(d.path, 'symbols', 's')).writeAsStringSync('x');
        await ledger.add(r);
      }
      final result = await pruneBuilds(ledger, BuildManager(ledger),
          symbolsKeepLast: 1, now: now);
      expect(result.symbols.map((r) => r.id), ['r1']);
      expect(
          Directory(ledger.resolve('demo/r1/symbols')).existsSync(), isFalse);
      expect(Directory(ledger.resolve('demo/r2/symbols')).existsSync(), isTrue);
      expect(
          Directory(ledger.resolve('demo/r3-not-uploaded/symbols'))
              .existsSync(),
          isTrue);
      final pruned = ledger.byId('r1')!;
      expect(pruned.symbolsDir, isNull);
      expect(pruned.symbolsShort, 'sentry');
      expect(pruned.events.last.kind, 'symbols_pruned');
    });

    test('refuses a folder that is not a build folder', () async {
      final r = rec('a', at: DateTime.utc(2026, 1, 1));
      Directory(ledger.resolve(r.outputDir)).createSync(recursive: true);
      await ledger.add(r);
      final result =
          await pruneBuilds(ledger, BuildManager(ledger), logDays: 1, now: now);
      expect(result.failed, hasLength(1));
    });
  });

  group('config', () {
    test('warns about a token in the YAML and a Play key inside the project',
        () {
      File(p.join(tmp.path, 'flutter_buildkit.yaml')).writeAsStringSync('''
sentry:
  auth_token: secret
play:
  service_account_json: key.json
''');
      final c = AppConfig.load(tmp.path, env: const {});
      expect(c.warnings.any((w) => w.contains('auth_token')), isTrue);
      final env =
          AppConfig.load(tmp.path, env: const {'SENTRY_AUTH_TOKEN': 'x'});
      expect(env.warnings.any((w) => w.contains('auth_token')), isFalse);
    });

    test('commands from the shared file need trust, overlay commands do not',
        () {
      File(p.join(tmp.path, 'flutter_buildkit.yaml')).writeAsStringSync(
          'flutter: fvm flutter\nsentry:\n  cli: /x/sentry\n');
      File(p.join(tmp.path, 'flutter_buildkit.local.yaml'))
          .writeAsStringSync('sentry:\n  cli: /mine/sentry\n');
      final c = AppConfig.load(tmp.path, env: const {});
      expect(c.sharedCommands, {'flutter': 'fvm flutter'});

      final trust = ConfigTrust(file: File(p.join(tmp.path, 'trust.json')));
      expect(trust.isTrusted(c), isFalse);
      trust.trust(c);
      expect(trust.isTrusted(c), isTrue);

      File(p.join(tmp.path, 'flutter_buildkit.yaml'))
          .writeAsStringSync('flutter: ./evil.sh\n');
      expect(trust.isTrusted(AppConfig.load(tmp.path, env: const {})), isFalse);
    });

    test('a config without commands is trusted; the environment wins', () {
      expect(
          ConfigTrust(file: File(p.join(tmp.path, 't.json')))
              .isTrusted(AppConfig.fromYaml(tmp.path, const {})),
          isTrue);
      File(p.join(tmp.path, 'flutter_buildkit.yaml'))
          .writeAsStringSync('flutter: fvm flutter\n');
      final c = AppConfig.load(tmp.path, env: const {'FBK_FLUTTER': 'flutter'});
      expect(c.sharedCommands, isEmpty);
    });

    test('retention and delete policy are read', () {
      final c = AppConfig.fromYaml(tmp.path, {
        'delete_policy': {
          'retain_on': ['published', 'internal']
        },
        'retention': {'log_days': 7, 'symbols_keep_last': 3},
      });
      expect(c.retainOn, {'published', 'internal'});
      expect(c.logRetentionDays, 7);
      expect(c.symbolsKeepLast, 3);
      final d = AppConfig.fromYaml(tmp.path, const {});
      expect(d.logRetentionDays, 90);
      expect(d.symbolsKeepLast, isNull);
      expect(
          () => AppConfig.fromYaml(tmp.path, {
                'retention': {'log_days': 0}
              }),
          throwsA(isA<ConfigException>()));
    });
  });

  group('CSV BOM', () {
    test('is added only on request', () {
      expect(const LedgerExporter().export([rec('a')], ExportFormat.csv),
          startsWith('id,'));
      expect(
          const LedgerExporter()
              .export([rec('a')], ExportFormat.csv, bom: true).codeUnitAt(0),
          0xFEFF);
    });
  });

  group('Doctor', () {
    test('flags a missing flutter and a bad Play key', () async {
      final key = File(p.join(tmp.path, 'key.json'))..writeAsStringSync('{}');
      final config = AppConfig.fromYaml(tmp.path, {
        'flutter': '/definitely/not/flutter',
        'play': {'service_account_json': key.path},
      });
      final checks = await Doctor(
        project: FlutterProject(tmp.path),
        config: config,
        ledger: ledger,
        env: const {},
      ).run();
      CheckLevel level(String n) => checks.firstWhere((c) => c.name == n).level;
      expect(level('flutter'), CheckLevel.fail);
      expect(level('play key'), CheckLevel.fail);
      expect(level('output folder'), CheckLevel.ok);
      expect(level('android sdk'), CheckLevel.warn);
    });
  });

  group('Google Play pre-flight', () {
    late AppConfig config;
    late BuildRecord record;
    late List<http.Request> requests;

    setUp(() async {
      config = AppConfig.fromYaml(tmp.path, const {});
      final aab = File(p.join(tmp.path, 'app_builds', 'a.aab'))
        ..createSync(recursive: true)
        ..writeAsStringSync('aab');
      record = rec('a', code: 3, artifacts: [
        BuildArtifact(
            path: ledger.relativize(aab.path), sizeBytes: 3, sha256: 'x')
      ]);
      await ledger.add(record);
      requests = [];
    });

    PlayPublisher publisher(List<int> usedCodes) => PlayPublisher(
        config: config,
        ledger: ledger,
        log: (_) {},
        httpClient: MockClient((request) async {
          requests.add(request);
          http.Response json(Object body, [int status = 200]) =>
              http.Response(jsonEncode(body), status,
                  headers: {'content-type': 'application/json; charset=utf-8'});
          final path = request.url.path;
          if (path.endsWith('/edits') && request.method == 'POST') {
            return json({'id': 'e1'});
          }
          if (path.endsWith('/tracks') && request.method == 'GET') {
            return json({
              'tracks': [
                {
                  'track': 'production',
                  'releases': [
                    {
                      'versionCodes': [for (final c in usedCodes) '$c'],
                      'status': 'completed'
                    }
                  ]
                }
              ]
            });
          }
          if (request.method == 'DELETE') return http.Response('', 204);
          return json({
            'error': {'code': 404, 'message': 'x'}
          }, 404);
        }));

    test('stops before uploading when the version code is already used',
        () async {
      await expectLater(
          publisher([1, 3]).publish(record, track: 'internal'),
          throwsA(isA<PlayException>()
              .having((e) => e.message, 'message', contains('already has'))));
      expect(requests.any((r) => r.url.path.contains('/bundles')), isFalse);
      expect(requests.any((r) => r.method == 'DELETE'), isTrue);
    });

    test('refuses a build signed with the debug key', () async {
      final debug = record.copyWith();
      final signed = BuildRecord.fromJson({
        ...debug.toJson(),
        'signing': {'sha256': 'ab', 'debugKey': true},
      });
      await expectLater(
          publisher(const []).publish(signed),
          throwsA(isA<PlayException>()
              .having((e) => e.message, 'message', contains('debug key'))));
    });

    test('checkAccess opens and discards an edit', () async {
      await publisher(const []).checkAccess('com.demo');
      expect(requests.map((r) => r.method), ['POST', 'DELETE']);
    });
  });

  group('commands', () {
    late StringBuffer out;
    late StringBuffer err;

    ArgResults parse(List<String> args) {
      final parser = ArgParser()..addOption('ledger');
      addCommandOptions(parser);
      return parser.parse(args);
    }

    Future<int> run(List<String> args) {
      final parsed = parse(args);
      return Cli(ledger: ledger, out: out, err: err)
          .run(parsed.rest.first, parsed);
    }

    setUp(() {
      out = StringBuffer();
      err = StringBuffer();
    });

    test('verify exits 76 on differences and 0 when clean', () async {
      await ledger.add(rec('a', obfuscated: false));
      expect(await run(['verify']), ExitCodes.verifyFailed);
      expect('$out', contains('missing_folder'));
      await folder(rec('a'));
      out.clear();
      expect(await run(['verify', '--json']), 0);
      expect((jsonDecode('$out') as Map)['ok'], isTrue);
    });

    test('prune needs --yes or --dry-run', () async {
      expect(await run(['prune']), ExitCodes.usage);
      expect(await run(['prune', '--dry-run', '--log-days', '1']), 0);
      expect(await run(['prune', '--yes', '--log-days', 'x']), ExitCodes.usage);
    });

    test('delete refuses a once-published build without --force', () async {
      final r = rec('a', obfuscated: false)
          .copyWith(publishedAt: DateTime.utc(2026, 10, 2));
      await folder(r);
      await ledger.add(r);
      await ledger.update('a', (x) => x.copyWith(clearPublished: true));
      expect(await run(['delete', 'a', '--yes']), ExitCodes.usage);
      expect(err.toString(), contains('--force'));
      expect(ledger.byId('a'), isNotNull);
      expect(await run(['delete', 'a', '--yes', '--force']), 0);
      expect(ledger.byId('a'), isNull);
    });

    test('export --bom writes the mark', () async {
      await ledger.add(rec('a'));
      expect(await run(['export', 'csv', '--bom']), 0);
      expect('$out'.codeUnitAt(0), 0xFEFF);
    });
  });
}
