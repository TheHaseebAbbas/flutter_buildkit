// Helpers shared by the examples: a throw-away Flutter project on disk and a
// fake `flutter` so builds run without a Flutter SDK.
import 'dart:io';

import 'package:flutter_buildkit/flutter_buildkit.dart';
import 'package:path/path.dart' as p;

/// A small Flutter project in a temporary folder: two Gradle flavors
/// (`dev`, `prod`), an extra `main_admin.dart` and a `launch.json`.
class DemoProject {
  DemoProject._(this.dir);

  /// Root folder of the project.
  final String dir;

  /// The project as the library sees it.
  FlutterProject get project => FlutterProject(dir);

  /// Writes [content] to [relative] inside the project.
  void write(String relative, String content) {
    final file = File(p.join(dir, relative))..createSync(recursive: true);
    file.writeAsStringSync(content);
  }

  /// Creates the project in a new temporary folder.
  static DemoProject create() {
    final root = Directory.systemTemp.createTempSync('fbk_example_').path;
    final demo = DemoProject._(root);
    demo.write('pubspec.yaml', '''
name: demo_app
version: 1.2.0+42
dependencies:
  flutter:
    sdk: flutter
''');
    demo.write('android/app/build.gradle', '''
android {
  defaultConfig { applicationId "com.example.demo" }
  flavorDimensions "env"
  productFlavors {
    dev  { dimension "env"; applicationIdSuffix ".dev" }
    prod { dimension "env" }
  }
}
''');
    for (final f in ['main', 'main_dev', 'main_prod', 'main_admin']) {
      demo.write('lib/$f.dart', 'void main() {}\n');
    }
    demo.write('config/dev.json', '{"API_URL": "https://dev.example.com"}\n');
    demo.write('config/prod.json', '{"API_URL": "https://example.com"}\n');
    demo.write('.vscode/launch.json', '''
{
  // Your own configurations stay untouched.
  "version": "0.2.0",
  "configurations": [
    { "name": "Mine", "request": "launch", "type": "dart" }
  ]
}
''');
    return demo;
  }

  /// Deletes the project.
  void dispose() => Directory(dir).deleteSync(recursive: true);
}

/// Pretends to be `flutter`: instead of compiling, it writes the files a real
/// release build leaves behind (the AAB/APK, R8 mapping, Dart symbols).
class FakeFlutter extends ProcessRunner {
  /// Creates a fake for the project at [projectDir].
  FakeFlutter(this.projectDir);

  /// Project the fake "builds".
  final String projectDir;

  /// Every command that was "run", for printing.
  final List<List<String>> commands = [];

  void _write(String relative, String content) {
    File(p.join(projectDir, relative))
      ..createSync(recursive: true)
      ..writeAsStringSync(content);
  }

  @override
  Future<int> stream(List<String> command,
      {String? workingDirectory,
      Map<String, String>? environment,
      String? logFile}) async {
    commands.add(command);
    if (!command.contains('build')) return 0;
    final flavor = command.contains('--flavor')
        ? command[command.indexOf('--flavor') + 1]
        : null;
    final mode = command.firstWhere(
        (a) => a == '--release' || a == '--debug' || a == '--profile');
    final variant = flavor == null
        ? mode.substring(2)
        : '$flavor${mode[2].toUpperCase()}${mode.substring(3)}';
    final bundle = command.contains('appbundle');
    for (final a in command.where((a) => a.startsWith('--split-debug-info='))) {
      _write('${a.split('=').last}/app.android-arm64.symbols', 'symbols');
    }
    if (bundle) {
      _write('build/app/outputs/bundle/$variant/app-$variant.aab',
          'fake aab for $variant');
    } else {
      _write(
          'build/app/outputs/flutter-apk/app-${flavor ?? 'app'}-${mode.substring(2)}.apk',
          'fake apk for $variant');
    }
    if (mode == '--release') {
      _write('build/app/outputs/mapping/$variant/mapping.txt',
          'com.example.Foo -> a.a:\n');
    }
    return 0;
  }

  @override
  Future<ProcessResult> run(List<String> command,
          {String? workingDirectory, Map<String, String>? environment}) async =>
      ProcessResult(0, 0, '{"frameworkVersion":"3.99.0"}', '');
}

/// Runs [body] with a fresh demo project and removes it afterwards.
Future<T> withDemoProject<T>(Future<T> Function(DemoProject demo) body) async {
  final demo = DemoProject.create();
  try {
    return await body(demo);
  } finally {
    demo.dispose();
  }
}

/// Prints a section title.
void title(String text) => stdout.writeln('\n== $text ==');
