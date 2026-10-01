import 'dart:io';

import '../config.dart';
import '../flutter_project.dart';
import 'process_runner.dart';

/// Steps that can run once before a batch of builds.
enum PreBuildStep {
  /// Runs `flutter clean`.
  clean('flutter clean'),

  /// Runs `flutter pub run build_runner build`.
  buildRunner('build_runner build'),

  /// Runs `flutter gen-l10n` to generate localization code.
  genL10n('flutter gen-l10n');

  const PreBuildStep(this.label);

  /// Creates a step with its display [label].
  final String label;
}

/// Thrown when a pre-build command cannot start or exits non-zero.
class PreBuildException implements Exception {
  /// Creates an exception carrying [message].
  PreBuildException(this.message);

  /// Human-readable description of what went wrong.
  final String message;
  @override
  String toString() => message;
}

/// One command of the pre-build plan.
class PreBuildCommand {
  /// Creates a command with display [label] and argv [command].
  const PreBuildCommand(this.label, this.command);

  /// Short name shown to the user.
  final String label;

  /// Executable and arguments to run.
  final List<String> command;
}

/// Steps that make sense for [project] (build_runner and gen-l10n only when
/// the project uses them).
List<PreBuildStep> availablePreBuildSteps(FlutterProject project) => [
      PreBuildStep.clean,
      if (project.usesBuildRunner) PreBuildStep.buildRunner,
      if (project.usesGenL10n) PreBuildStep.genL10n,
    ];

/// Which of [available] are ticked by default, from the config.
List<PreBuildStep> defaultPreBuildSteps(
        AppConfig config, List<PreBuildStep> available) =>
    [
      for (final s in available)
        if (switch (s) {
          PreBuildStep.clean => config.preBuild.clean,
          PreBuildStep.buildRunner => config.preBuild.buildRunner,
          PreBuildStep.genL10n => config.preBuild.genL10n,
        })
          s,
    ];

/// Commands for [steps], in the order that works: `flutter clean` wipes
/// `.dart_tool`, so it is always followed by `pub get` before code
/// generation.
List<PreBuildCommand> planPreBuild(
    AppConfig config, Iterable<PreBuildStep> steps) {
  final chosen = steps.toSet();
  final flutter = config.flutter;
  return [
    if (chosen.contains(PreBuildStep.clean)) ...[
      PreBuildCommand('flutter clean', [...flutter, 'clean']),
      PreBuildCommand('flutter pub get', [...flutter, 'pub', 'get']),
    ],
    if (chosen.contains(PreBuildStep.buildRunner))
      PreBuildCommand('build_runner build', [
        ...flutter,
        'pub',
        'run',
        'build_runner',
        'build',
        ...config.preBuild.buildRunnerArgs,
      ]),
    if (chosen.contains(PreBuildStep.genL10n))
      PreBuildCommand('flutter gen-l10n', [...flutter, 'gen-l10n']),
  ];
}

/// Runs the pre-build plan; stops at the first failing command.
class PreBuildRunner {
  /// Creates a runner for [project] using [config]; [runner] executes commands and [log] receives output.
  PreBuildRunner({
    required this.project,
    required this.config,
    this.runner = const ProcessRunner(),
    void Function(String)? log,
  }) : log = log ?? ((_) {});

  /// Project whose directory is the working directory for commands.
  final FlutterProject project;

  /// Configuration (flutter command, build_runner arguments).
  final AppConfig config;

  /// Executes the planned commands.
  final ProcessRunner runner;

  /// Receives progress and process output lines.
  final void Function(String) log;

  /// Returns the labels of the commands that ran.
  Future<List<String>> run(Iterable<PreBuildStep> steps) async {
    final done = <String>[];
    for (final c in planPreBuild(config, steps)) {
      log('\n> ${c.label}\n\$ ${describeCommand(c.command)}\n');
      final int code;
      try {
        code = await runner.stream(c.command, workingDirectory: project.dir);
      } on ProcessException catch (e) {
        throw PreBuildException('Could not start "${c.command.first}": '
            '${e.message}.');
      }
      if (code != 0) {
        throw PreBuildException(
            '${c.label} failed with exit code $code. No build was started.');
      }
      done.add(c.label);
    }
    return done;
  }
}
