# flutter_buildkit examples

Runnable Dart programs that show every part of `flutter_buildkit`, grouped by
topic. They need **no Flutter SDK, no Android SDK and no network**: each one
creates a small demo Flutter project in a temporary folder (two Gradle
flavors, several `main` files, a `launch.json`), uses a fake `flutter` that
writes the files a real release build would, and deletes everything when it
ends.

Run the first one now to check your setup:

```sh
dart pub get
dart run example/main.dart
```

See [How to run and use the examples](#how-to-run-and-use-the-examples) for the
full steps.

## Contents

| Folder | Topic | Run |
|---|---|---|
| [`main.dart`](main.dart) | Short tour of the library | `dart run example/main.dart` |
| [`library_api/`](library_api) | Build, list, publish and delete from code | `dart run example/library_api/build_and_manage.dart` |
| [`configuration/`](configuration) | `flutter_buildkit.yaml`: samples and loading | `dart run example/configuration/load_config.dart` |
| [`layouts_and_naming/`](layouts_and_naming) | Output folders and file names | `dart run example/layouts_and_naming/layout_presets.dart` |
| [`ledger_and_exports/`](ledger_and_exports) | The ledger, CSV / TSV / JSON export | `dart run example/ledger_and_exports/ledger_and_exports.dart` |
| [`symbols_and_traces/`](symbols_and_traces) | Symbol uploads and crash traces | `dart run example/symbols_and_traces/symbols_and_traces.dart` |
| [`vscode_and_autoconfig/`](vscode_and_autoconfig) | Project detection, entry points, `launch.json` | `dart run example/vscode_and_autoconfig/autoconfig.dart` and `.../vscode_launch.dart` |
| [`cli_and_ui/`](cli_and_ui) | CLI commands and the prompt toolkit | `dart run example/cli_and_ui/cli_walkthrough.dart` and `.../scripted_console.dart` |

Every file starts with a comment saying what it shows and how to run it, and
prints titled sections, so the output reads like a walkthrough.

See [How to run and use the examples](#how-to-run-and-use-the-examples) for
setup, running everything at once, using the code in your own project and
troubleshooting.

**New here?** Read in this order: `main.dart`, `library_api`, `configuration`,
`ledger_and_exports`. Pick the rest as you need them.

## How to run and use the examples

### 1. Get the code

The examples live in the package repository and in the pub.dev archive. Clone
the repo, or open the package from your pub cache:

```sh
git clone https://github.com/TheHaseebAbbas/flutter_buildkit
cd flutter_buildkit
dart pub get
```

You need the [Dart SDK](https://dart.dev/get-dart) 3.5 or newer. Flutter is
**not** required.

### 2. Run an example

Always run from the package root (the folder with `pubspec.yaml`), using the
path of the file:

```sh
dart run example/library_api/build_and_manage.dart
```

Each example prints titled sections (`== Build every flavor ==`), so the output
reads top to bottom like a walkthrough. Pipe it to a pager for long ones:

```sh
dart run example/configuration/load_config.dart | less
```

Run everything at once to check that all examples work:

```sh
for f in $(find example -name '*.dart' -not -path '*/_support/*'); do
  dart run "$f" > /dev/null && echo "ok   $f" || echo "FAIL $f"
done
```

In PowerShell:

```powershell
Get-ChildItem example -Recurse -Filter *.dart |
  Where-Object { $_.FullName -notmatch '_support' } |
  ForEach-Object { dart run $_.FullName *> $null; "$LASTEXITCODE $($_.Name)" }
```

### 3. Read, then change

Open the file you ran, change a value and run it again. Good first edits:

| Example | Try |
|---|---|
| `layout_presets.dart` | Change the `layout:` template and see the new folder |
| `load_config.dart` | Edit a sample YAML in `configuration/` and re-run |
| `build_and_manage.dart` | Change `ArtifactType.aab` to `apk` or `BuildMode.release` to `debug` |
| `ledger_and_exports.dart` | Add a third row and compare the CSV and TSV |
| `autoconfig.dart` | Add `lib/main_kiosk.dart` in `_support/demo.dart` and watch the entry points change |

### 4. Use the pieces in your own project

You do not need this folder to use the package. The examples are patterns to
copy:

1. Add the package: `dart pub add --dev flutter_buildkit` (or a normal
   dependency if you build tooling on top of it).
2. Copy the code you need from an example. Imports are always
   `package:flutter_buildkit/flutter_buildkit.dart`.
3. Replace the demo parts, which live in `_support/demo.dart`:
   - `withDemoProject(...)` -> your real project folder, e.g.
     `FlutterProject('.')` and `AppConfig.load('.')`.
   - `FakeFlutter(...)` -> remove the `runner:` argument. `FlutterBuilder` then
     runs the real `flutter` (or `fvm flutter` via the `flutter:` config key).
4. Copy a sample from `configuration/` to your project root as
   `flutter_buildkit.yaml` and adjust it, or run
   `dart run flutter_buildkit autoconfig` to generate one.

A build in your own project then looks like this:

```dart
final project = FlutterProject('.');
final config = AppConfig.load(project.dir);
final ledger = await Ledger.open(config.ledgerPath);

final record = await FlutterBuilder(
  project: project,
  config: config,
  ledger: ledger,
  log: print, // show flutter's output
).build(BuildRequest(
  type: ArtifactType.aab,
  mode: BuildMode.release,
  flavor: 'prod',
  versionName: project.version.name,
  versionCode: project.version.code,
));
```

### Good to know

- **Nothing is left behind.** Examples work in a temporary folder
  (`fbk_example_*`) and delete it at the end. Your own files are never touched.
- **No network, no accounts.** Symbol uploads and Play uploads are shown as
  dry-run commands only. Use `SymbolUploader.upload` or the menu for real ones.
- **Command line, not code?** The `cli_and_ui/` examples show the same commands
  you would type; in a Flutter project run `dart run flutter_buildkit`.

### Troubleshooting

| Problem | Fix |
|---|---|
| `Could not find package` / unresolved imports | Run `dart pub get` in the package root. |
| `Could not find ... example/...dart` | Run from the package root, not from inside `example/`. |
| `cli_walkthrough.dart` cannot find `bin/` | Same: run it from the package root. |
| A real build says `Could not start "flutter"` | Put Flutter on `PATH`, or set `flutter:` in the config / `FBK_FLUTTER`. |
| Output shows no colors | Expected: the examples print plain text. The menu honours `NO_COLOR`. |

## main.dart

A 40-line tour: load the project and config, open the ledger, build every
flavor as an AAB, print a table and the CSV header.

```
Flavor  Version   Status  Folder
------  --------  ------  --------------------------------------
prod    1.2.0+42  built   prod/release/1.2.0-b42-20261003-101650
dev     1.2.0+42  built   dev/release/1.2.0-b42-20261003-101650
```

## library_api

**`build_and_manage.dart`** is the whole life of a build in one file.

1. `FlutterProject` reads flavors, version, package names, entry files and
   define files from the project.
2. `FlutterBuilder.build(BuildRequest(...))` runs `flutter build`, copies the
   output into the folder tree, stores symbols and adds a ledger row.
3. `ledger.records` is listed with `renderTable`.
4. `BuildManager.markPublished` flags a build as released.
5. `BuildManager.delete` applies the delete rules: the unreleased build is
   removed with its folder and row; the published one keeps its symbols and
   row, and only loses its files.

Key types: `FlutterProject`, `BuildRequest`, `FlutterBuilder`, `Ledger`,
`BuildManager`, `DeleteResult`.

## configuration

Four sample config files you can copy into a project, and a program that loads
them.

| File | For |
|---|---|
| [`flutter_buildkit.minimal.yaml`](configuration/flutter_buildkit.minimal.yaml) | Starting point; everything else is a default |
| [`flutter_buildkit.multi_flavor.yaml`](configuration/flutter_buildkit.multi_flavor.yaml) | dev / staging / prod with their own mains, define files and ids |
| [`flutter_buildkit.entry_points.yaml`](configuration/flutter_buildkit.entry_points.yaml) | One app with several `main` files, shared and per flavor |
| [`flutter_buildkit.release_pipeline.yaml`](configuration/flutter_buildkit.release_pipeline.yaml) | FVM, an output folder outside the project, Play, Crashlytics, Sentry |

**`load_config.dart`** shows `AppConfig.load` (from a file), `AppConfig.fromYaml`
(from a map), per-flavor lookups with `config.flavor(name)`, how environment
variables such as `FBK_FLUTTER`, `SENTRY_AUTH_TOKEN` and
`PLAY_SERVICE_ACCOUNT_JSON` override the file, how an invalid value raises
`ConfigException`, and what `config.describe()` prints. The full key reference
is in [doc/configuration.md](../doc/configuration.md).

## layouts_and_naming

**`layout_presets.dart`** prints where one build would be stored under each of
the four presets (`by-flavor`, `by-version`, `by-month`, `flat`), a custom
template, artifact file names (split-per-ABI APKs, no flavor), the extra
`-admin` suffix a named entry point gets, and what an invalid template does
(`PathTemplateException`). Nothing touches the disk.

```
by-flavor   app_builds/my_app/dev/release/1.2.0-b42-20261001-070509
by-version  app_builds/my_app/1.2.0-b42/dev-release-20261001-070509
by-month    app_builds/2026-10/my_app-dev-release-1.2.0-b42-20261001-070509
flat        app_builds/my_app-dev-release-1.2.0-b42-20261001-070509
```

Key types: `LayoutPreset`, `BuildPaths`, `BuildNaming`, `PathTemplate`.

## ledger_and_exports

**`ledger_and_exports.dart`** works on the ledger without any build.

- Open a missing file (empty ledger), `add` rows, `update` one with a Play
  upload and a symbol upload (the status and history follow), `remove` one.
- Export in all three formats with `LedgerExporter` and see why JSON is the
  ledger format while CSV and TSV are flat copies (`LedgerExporter.columns`).
- Rows hold paths relative to the ledger folder, so the folder can be moved.
- A ledger that is not valid JSON raises `LedgerException` and is never
  overwritten; the previous save is kept as `ledger.json.bak`.

## symbols_and_traces

**`symbols_and_traces.dart`** builds an obfuscated release, then, without
starting any external tool:

- `SymbolUploader.commandsFor` prints the exact `firebase` and `sentry-cli`
  commands that would upload the symbols;
- `Symbolicator.availableKinds` lists which traces the stored symbols can
  de-obfuscate (Dart, Java/Kotlin, native);
- `detectTraceKind` and `abiFromTrace` recognise a pasted trace;
- `Symbolicator.command` builds the `flutter symbolize` command for it.

To really upload or trace, use `SymbolUploader.upload` and the menu's **Trace
a crash**; they need `firebase`, `sentry-cli`, `retrace` or `ndk-stack`.

## vscode_and_autoconfig

**`autoconfig.dart`** reads the demo project the way **Set up from this
project** does: flavors from Gradle, package names, entry points found
anywhere (`main_admin.dart` becomes `admin`), what to build per flavor and the
config values `suggestConfig` proposes, each with its reason. Only paths and
identifiers are read, never secrets.

**`vscode_launch.dart`** plans and writes `.vscode/launch.json`: one run
configuration per flavor x entry point x mode, merged into your existing file.
Comments and your own configurations stay, running it again adds nothing, the
old file is kept once as `launch.json.bak`, and an invalid file is left alone.

## cli_and_ui

**`cli_walkthrough.dart`** runs the real command line (`bin/flutter_buildkit.dart`)
on the demo project: `list`, `export csv`, `init`, `config` and a failing
`export`. The interactive commands (menu, `autoconfig`, `vscode`, `settings`)
are listed at the end.

**`scripted_console.dart`** uses the prompt toolkit without a terminal.
`Console` accepts `readLine` and `write` callbacks, so `choose`, `chooseMany`,
`ask` and `confirm` can be answered from a list, which is also how the library
tests its menus. It also shows `parseNumberList`, `renderTable`, `formatBytes`
and `Style` (which honours `NO_COLOR`).

## Using the CLI in your own project

You do not need any of this code to use the package: in a Flutter project run

```sh
dart pub add --dev flutter_buildkit
dart run flutter_buildkit
```

See the [package README](../README.md) for the menu, and
[doc/](../doc) for configuration, project setup and the ledger.
