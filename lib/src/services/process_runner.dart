import 'dart:io';

/// Runs external tools (flutter, firebase, sentry-cli). Swappable in tests.
class ProcessRunner {
  /// Creates a runner; it holds no state.
  const ProcessRunner();

  /// Runs [command] with the terminal attached so the user sees live output.
  /// Returns the exit code.
  Future<int> stream(
    List<String> command, {
    String? workingDirectory,
    Map<String, String>? environment,
  }) async {
    final process = await Process.start(
      command.first,
      command.sublist(1),
      workingDirectory: workingDirectory,
      environment: environment,
      mode: ProcessStartMode.inheritStdio,
      runInShell: Platform.isWindows,
    );
    return process.exitCode;
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

/// Shell-style rendering of a command, for showing the user what runs.
String describeCommand(List<String> command) => command
    .map((a) =>
        a.contains(RegExp(r'[\s"]')) ? '"${a.replaceAll('"', r'\"')}"' : a)
    .join(' ');
