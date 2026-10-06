import 'dart:io';

import 'package:flutter_buildkit/flutter_buildkit.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('stream with a log file appends the output and returns the exit code',
      () async {
    final tmp = Directory.systemTemp.createTempSync('fbk_runner_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final log = p.join(tmp.path, 'out.log');
    File(log).writeAsStringSync('header\n');

    final code = await const ProcessRunner()
        .stream([Platform.resolvedExecutable, '--version'], logFile: log);

    expect(code, 0);
    final text = File(log).readAsStringSync();
    expect(text, startsWith('header\n'));
    expect(text, contains('Dart SDK'));
  });

  test('InterruptGuard removes the folders of unfinished builds', () {
    final tmp = Directory.systemTemp.createTempSync('fbk_guard_');
    addTearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });
    final done = Directory(p.join(tmp.path, 'done'))..createSync();
    final open = Directory(p.join(tmp.path, 'open'))..createSync();
    InterruptGuard.protect(done.path);
    InterruptGuard.protect(open.path);
    InterruptGuard.release(done.path);

    InterruptGuard.interrupt();

    expect(open.existsSync(), isFalse);
    expect(done.existsSync(), isTrue);
  });
}
