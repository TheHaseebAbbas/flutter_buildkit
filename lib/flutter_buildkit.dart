/// Build Flutter apps (APK, AAB, IPA) from an interactive console menu or
/// from code, file every build in a predictable folder tree and keep a
/// ledger of what was built, published, uploaded to Google Play and
/// symbolicated.
///
/// Most people use the command line app:
///
/// ```sh
/// dart pub global activate flutter_buildkit
/// fbk            # inside a Flutter project
/// ```
///
/// The menu (`App`) and its settings screens are not part of the library API.
/// The commands that run without a menu are in [Cli].
///
/// The same pieces are available as a library:
///
/// * **Configuration**: [AppConfig] reads `flutter_buildkit.yaml`.
/// * **Projects**: [FlutterProject] finds flavors, entry points, version and
///   package names.
/// * **Building**: [FlutterBuilder] runs `flutter build` for a
///   [BuildRequest] and records the result.
/// * **Ledger**: [Ledger], [BuildRecord], [BuildManager] and
///   [LedgerExporter] store, change, delete and export builds.
/// * **Folders and names**: [BuildPaths], [LayoutPreset] and [PathTemplate].
/// * **Symbols**: [SymbolUploader] sends them to Crashlytics and Sentry,
///   [Symbolicator] de-obfuscates crash traces.
/// * **Editor and project setup**: [suggestConfig], [planLaunchJson] and
///   [mergeLaunchJson].
/// * **Commands without a menu**: [Cli] and [ExitCodes].
/// * **Terminal UI**: [Console], [SelectModel] and [renderTable].
///
/// Runnable examples for each area are in the package's `example/` folder.
library;

export 'src/cli.dart';
export 'src/build_paths.dart';
export 'src/config.dart';
export 'src/config_trust.dart';
export 'src/flutter_project.dart';
export 'src/ledger/exporter.dart';
export 'src/ledger/ledger.dart';
export 'src/model/build_options.dart';
export 'src/model/build_record.dart';
export 'src/services/build_inspector.dart';
export 'src/services/build_manager.dart';
export 'src/services/doctor.dart';
export 'src/services/maintenance.dart';
export 'src/services/flutter_builder.dart';
export 'src/services/play_publisher.dart';
export 'src/services/process_runner.dart';
export 'src/services/symbol_uploader.dart';
export 'src/ui/console.dart';
export 'src/ui/table.dart';
export 'src/ui/keys.dart';
export 'src/ui/select_model.dart';
export 'src/services/pre_build.dart';
export 'src/services/symbolicator.dart';
export 'src/ui/style.dart';
export 'src/config_editor.dart';
export 'src/settings.dart';
export 'src/entry_points.dart';
export 'src/auto_config.dart';
export 'src/dart_entries.dart';
export 'src/jsonc.dart';
export 'src/launch_json.dart';
export 'src/vscode.dart';
