# flutter_buildkit

[![pub package](https://img.shields.io/pub/v/flutter_buildkit.svg)](https://pub.dev/packages/flutter_buildkit)

An interactive console app that builds your Flutter project (APK, AAB, IPA),
files every build in a predictable folder tree, and keeps a **ledger** of what
was built, published, uploaded to Google Play and symbolicated.

It is also a Dart library: everything the menu does can be called from code.

## Contents

- [What it does](#what-it-does)
- [Quick start](#quick-start)
- [Using the menu](#using-the-menu)
- [Where builds go](#where-builds-go)
- [The ledger](#the-ledger)
- [Configuration](#configuration)
- [Crash symbols and traces](#crash-symbols-and-traces)
- [Use it as a library](#use-it-as-a-library)
- [Examples](#examples)
- [More documentation](#more-documentation)
- [Development](#development)

## What it does

| You want to | Do this |
|---|---|
| Build any mix of flavors, outputs (APK / AAB / IPA) and modes in one go | **Build app** |
| See every build you made, with status and size | **List builds** |
| Know exactly what is in a build, including SHA-256 of each file | **Build details** |
| Record that a build is live, or upload it to Google Play | **Mark as published**, **Upload to Google Play** |
| Keep crash symbols and send them to Crashlytics or Sentry | **Upload debug symbols** |
| De-obfuscate a crash trace from the field | **Trace a crash** |
| Free disk space without losing what you need for crash tracing | **Delete builds** |
| Hand the build history to a spreadsheet or another tool | **Export ledger** (CSV, TSV, JSON) |
| Skip the setup work | **Set up from this project**, **VS Code launch.json**, **Settings** |

## Quick start

Add it as a dev dependency to your Flutter project, then run it from the
project root:

```sh
dart pub add --dev flutter_buildkit
flutter pub get
dart run flutter_buildkit init   # optional: write a commented flutter_buildkit.yaml
dart run flutter_buildkit        # open the menu
```

Add `app_builds/` and `flutter_buildkit.yaml` to the project's `.gitignore`.
Installed globally (`dart pub global activate flutter_buildkit`) it is on your
`PATH` as `flutter_buildkit` and the short `fbk`.

Other commands:

| Command | Does |
|---|---|
| `init` | Write a starter `flutter_buildkit.yaml`. |
| `autoconfig` | Read the project and write `flutter_buildkit.yaml` from it. |
| `vscode` | Add a run configuration per flavor, entry point and mode to `.vscode/launch.json`. |
| `settings` | Edit the config with live previews. |
| `config` | Show the settings in effect (secrets masked). |
| `list` | Print the ledger as a table. |
| `export <csv\|tsv\|json> [file]` | Write the ledger in another format. |

Options: `-C <project dir>`, `-c <config file>`, `--ledger <file>`,
`--ui auto|keys|plain`.

## Using the menu

Every list works two ways, so you are never stuck:

- **Numbers.** Type the number next to a row and press Enter. For several rows
  type `1,3`, `1-3` or `1 3`.
- **Keys.** On a terminal you can use the arrows:

| Key | Does |
|---|---|
| Up / Down, `k` / `j`, PgUp / PgDn, Home / End | Move |
| Enter | Choose (single) or confirm (multi) |
| Space | Tick or untick a row (multi select) |
| `a` / `n` / `i` | Tick all, none, or invert the visible rows |
| `/` | Filter the list by typing (Esc clears) |
| Esc or `q` | Back / cancel; Ctrl-C quits |

Arrow keys are used automatically on macOS, Linux and Windows (PowerShell,
cmd, Windows Terminal). Piped input or `TERM=dumb` falls back to numbered
questions; force a mode with `--ui plain|keys` or `FBK_UI`. Colors follow the
terminal and honour `NO_COLOR`.

Before each build the menu asks for flavors, outputs, modes, version name and
code, the pre-build steps (`flutter clean`, `build_runner`, `flutter gen-l10n`),
build options (obfuscation, split APKs) and extra arguments. The answers start
from your config, so you only change what differs this time. Details:
[Project setup](doc/project-setup.md).

## Where builds go

Every build gets its own folder under `app_builds/`:

```
app_builds/
  ledger.json                 the ledger (+ ledger.json.bak)
  exports/                    CSV / TSV / JSON exports
  dev/                        <flavor>   ("default" when there are no flavors)
    release/                  <mode>
      1.2.0-b42-20261001-070509/       <versionName>-b<versionCode>-<datetime>
        artifacts/my_app-dev-release-1.2.0-b42-20261001-070509.aab
        symbols/              dart/  mapping/  native/<abi>/  dSYMs/
        build_info.json       this build's ledger row
```

The structure is configurable. Pick a preset in `flutter_buildkit.yaml`, or
write your own template from tokens such as `{app}`, `{flavor}`, `{mode}`,
`{version}` and `{datetime}`:

| Preset | Example folder | Good for |
|---|---|---|
| `by-flavor` (default) | `dev/release/1.2.0-b42-20261001-070509/` | Browsing per environment |
| `by-version` | `1.2.0-b42/dev-release-20261001-070509/` | Archiving a whole release |
| `by-month` | `2026-10/my_app-dev-release-1.2.0-b42-...` | Cleaning up by age |
| `flat` | `my_app-dev-release-1.2.0-b42-...` | One folder level |

All tokens, naming rules and examples: [Builds, folders and the ledger](doc/builds-and-ledger.md).

## The ledger

The ledger is a **JSON** file. A build row is nested (several artifacts, Play
status, per-tool symbol uploads) and typed (numbers, booleans, timestamps).
JSON keeps all of that and can be edited by hand. CSV and TSV flatten it, so
they are export formats. Saves are atomic and the previous copy is kept as
`ledger.json.bak`. Paths inside are relative, so the whole `app_builds/`
folder can be moved.

Every row has a **status** (`built`, `uploaded` to Play, `published`), a
**condition** (`ready`, or files deleted with symbols kept), a **symbols
status** and a history of what happened and when.

**Delete rules.** A build that was never published or uploaded to Play is
removed completely, folder and row. A released build only loses its
APK/AAB/IPA files: its symbols, mappings and row stay forever, so crashes from
the field can still be traced.

## Configuration

Everything is optional. With no config file, flavors are detected from Gradle
and Xcode. Settings come from built-in defaults, then `flutter_buildkit.yaml`,
then environment variables (for secrets and tool paths).

```yaml
output_layout: by-version
flutter: fvm flutter
obfuscate: true

flavors:
  dev:
    target: lib/main_dev.dart
    dart_define_file: config/dev.json
    package_name: com.example.app.dev
  prod:
    target: lib/main_prod.dart
    package_name: com.example.app

play:
  default_track: internal
  default_release_status: draft

sentry:
  org: my-company          # token: set SENTRY_AUTH_TOKEN in your shell
  project: my-app
```

Keep secrets in the environment (`PLAY_SERVICE_ACCOUNT_JSON`,
`SENTRY_AUTH_TOKEN`), not in the file. The full key reference, environment
variables and Google Play setup are in [Configuration](doc/configuration.md).
Ready-to-copy files are in [`example/configuration`](example/configuration).

Not sure what to write? Run `dart run flutter_buildkit autoconfig`. It reads
flavors, entry points, define files, application ids, Firebase and Sentry usage
and FVM from the project, shows the reason for every value and lets you tick
what to apply. Several `main` files per app are supported; see
[Project setup](doc/project-setup.md).

## Crash symbols and traces

Every build stores its debug symbols next to the binaries: Dart symbols
(`--split-debug-info`), the R8 mapping, unstripped native libraries and iOS
dSYMs. **Upload debug symbols** sends them to Firebase Crashlytics (`firebase`
CLI) and/or Sentry (`sentry-cli`). **Trace a crash** de-obfuscates a pasted
trace, even for released builds whose files were deleted:

| Trace | Tool | Uses |
|---|---|---|
| Obfuscated Dart | `flutter symbolize` | `symbols/dart/` |
| Android Java/Kotlin | R8 `retrace` | `symbols/mapping/mapping.txt` |
| Native crash | `ndk-stack` | `symbols/native/<abi>/` |

## Use it as a library

```dart
import 'package:flutter_buildkit/flutter_buildkit.dart';

Future<void> main() async {
  final project = FlutterProject('.');
  final config = AppConfig.load(project.dir);
  final ledger = await Ledger.open(config.ledgerPath);

  final record = await FlutterBuilder(
    project: project,
    config: config,
    ledger: ledger,
  ).build(BuildRequest(
    type: ArtifactType.aab,
    mode: BuildMode.release,
    flavor: 'prod',
    versionName: project.version.name,
    versionCode: project.version.code,
  ));

  print('${record.id} -> ${record.outputDir}');
  print(const LedgerExporter().toCsv(ledger.records));
}
```

## Examples

The [`example/`](example) folder has runnable programs for every part of the
package, grouped by topic. They use a throw-away demo project and a fake
`flutter`, so they run without a Flutter SDK:

```sh
dart run example/main.dart                                    # the short tour
dart run example/library_api/build_and_manage.dart            # build, list, publish, delete
dart run example/ledger_and_exports/ledger_and_exports.dart   # ledger + CSV/TSV/JSON
```

| Folder | Shows |
|---|---|
| [`library_api`](example/library_api) | Building, listing, publishing and deleting from code |
| [`configuration`](example/configuration) | Sample `flutter_buildkit.yaml` files and loading them |
| [`layouts_and_naming`](example/layouts_and_naming) | Folder presets, templates, file names |
| [`ledger_and_exports`](example/ledger_and_exports) | The ledger and its exports |
| [`symbols_and_traces`](example/symbols_and_traces) | Symbol uploads and crash traces |
| [`vscode_and_autoconfig`](example/vscode_and_autoconfig) | Project detection and `launch.json` |
| [`cli_and_ui`](example/cli_and_ui) | CLI commands and the prompt toolkit |

Start with the [example guide](example/README.md).

## More documentation

- [Configuration](doc/configuration.md): every key, environment variables, Google Play, symbols
- [Project setup](doc/project-setup.md): entry points, auto-configuration, VS Code, settings editor
- [Builds, folders and the ledger](doc/builds-and-ledger.md): layouts, status, delete rules, crash tracing
- [API reference](https://pub.dev/documentation/flutter_buildkit/latest/)
- [Changelog](CHANGELOG.md) and [issue tracker](https://github.com/TheHaseebAbbas/flutter_buildkit/issues)

## Development

To work on this repo, clone it and run `dart pub get`, then
`dart run bin/flutter_buildkit.dart -C /path/to/flutter/project`.

```sh
dart format . && dart analyze && dart test
```

The tests cover the ledger (persistence, atomic save, export, delete rules),
the folder layout, Gradle flavor parsing, build arguments, config, pre-build
planning, trace tooling and the keyboard/selection logic. Building, the Play
API, `firebase` and `sentry-cli` are thin wrappers and are not run in tests;
the build pipeline is smoke-tested against a fake `flutter`.
