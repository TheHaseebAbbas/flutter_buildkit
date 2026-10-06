import 'dart:io';

/// Runs external tools (flutter, firebase, sentry-cli). Swappable in tests.
class ProcessRunner {
  /// Creates a runner. With [outputToStderr] the output of streamed commands
  /// goes to stderr, which keeps stdout clean for machine readable output.
  const ProcessRunner({this.outputToStderr = false});

  /// Whether streamed output goes to stderr instead of stdout.
  final bool outputToStderr;

  /// Runs [command] and returns its exit code.
  ///
  /// Without [logFile] the terminal is attached, so the tool keeps colors
  /// and progress bars. With [logFile] the output is copied to the console
  /// and appended to that file, so a build log survives the run.
  Future<int> stream(
    List<String> command, {
    String? workingDirectory,
    Map<String, String>? environment,
    String? logFile,
  }) async {
    if (logFile == null && !outputToStderr) {
      final process = await Process.start(
        command.first,
        command.sublist(1),
        workingDirectory: workingDirectory,
        environment: environment,
        mode: ProcessStartMode.inheritStdio,
        runInShell: Platform.isWindows,
      );
      InterruptGuard._running.add(process);
      try {
        return await process.exitCode;
      } finally {
        InterruptGuard._running.remove(process);
      }
    }
    final process = await Process.start(
      command.first,
      command.sublist(1),
      workingDirectory: workingDirectory,
      environment: environment,
      runInShell: Platform.isWindows,
    );
    InterruptGuard._running.add(process);
    final sink =
        logFile == null ? null : File(logFile).openWrite(mode: FileMode.append);
    Future<void> pump(Stream<List<int>> from, IOSink to) => from.forEach((d) {
          to.add(d);
          sink?.add(d);
        });
    try {
      final pumps = Future.wait(
          [pump(process.stdout, stdout), pump(process.stderr, stderr)]);
      final code = await process.exitCode;
      await pumps;
      return code;
    } finally {
      InterruptGuard._running.remove(process);
      await sink?.close();
    }
  }

  /// Runs [command] and captures its output.
  Future<ProcessResult> run(
    List<String> command, {
    String? workingDirectory,
    Map<String, String>? environment,
  }) =>
      Process.run(
        command.first,
        command.sublist(1),
        workingDirectory: workingDirectory,
        environment: environment,
        runInShell: Platform.isWindows,
      );

  /// Whether [executable] can be started at all.
  Future<bool> isAvailable(List<String> command) async {
    try {
      await run([...command, '--version']);
      return true;
    } on ProcessException {
      return false;
    }
  }
}

/// Cleans up when the user presses Ctrl-C during a build: stops the running
/// tool and removes folders of builds that have not finished.
class InterruptGuard {
  InterruptGuard._();

  static final Set<Process> _running = {};
  static final Set<String> _unfinished = {};

  /// Marks [dir] as the folder of a build in progress.
  static void protect(String dir) => _unfinished.add(dir);

  /// The build in [dir] finished (or cleaned up after itself).
  static void release(String dir) => _unfinished.remove(dir);

  /// Stops every tool started by a [ProcessRunner] and deletes the folders of
  /// unfinished builds. Call it from the SIGINT handler before exiting.
  static void interrupt() {
    for (final p in _running.toList()) {
      p.kill();
    }
    for (final dir in _unfinished.toList()) {
      try {
        final d = Directory(dir);
        if (d.existsSync()) d.deleteSync(recursive: true);
      } on FileSystemException {
        // Best effort while exiting.
      }
    }
    _unfinished.clear();
  }
}

/// Shell-style rendering of a command, for showing the user what runs.
String describeCommand(List<String> command) => command
    .map((a) =>
        a.contains(RegExp(r'[\s"]')) ? '"${a.replaceAll('"', r'\"')}"' : a)
    .join(' ');
