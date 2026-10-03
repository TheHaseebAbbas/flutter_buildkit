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
}
