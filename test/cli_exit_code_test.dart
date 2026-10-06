import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('fbk_cli_');
    File(p.join(tmp.path, 'pubspec.yaml'))
        .writeAsStringSync('name: demo\nversion: 1.0.0+1\n');
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<int> run(List<String> args) async => (await Process.run(
          Platform.resolvedExecutable,
          ['bin/flutter_buildkit.dart', '-C', tmp.path, ...args]))
      .exitCode;

  test('success exits 0', () async => expect(await run(['list']), 0));
  test('unknown format exits 64',
      () async => expect(await run(['export', 'xml']), 64));
  test('unknown command exits 64', () async => expect(await run(['nope']), 64));
  test('missing project exits 66', () async {
    File(p.join(tmp.path, 'pubspec.yaml')).deleteSync();
    expect(await run(['list']), 66);
  });

  test('init over an existing config exits 73', () async {
    expect(await run(['init']), 0);
    expect(await run(['init']), 73);
  });

  test('delete without --yes exits 64', () async {
    expect(await run(['delete', 'abc']), 64);
  });

  test('list works with only --ledger outside a project', () async {
    File(p.join(tmp.path, 'pubspec.yaml')).deleteSync();
    final ledger = p.join(tmp.path, 'l.json');
    expect(await run(['--ledger', ledger, 'list']), 0);
    expect(await run(['--ledger', ledger, 'delete', 'x', '--dry-run']), 64);
    expect(await run(['build']), 66);
  });
}
