# flutter_buildkit

An interactive Dart console app that builds a Flutter project (APK, AAB, IPA),
files every build in a predictable folder tree, and keeps a **ledger** of what
was built, published, uploaded to Google Play, and symbolicated.

## Use it in your Flutter projects

[![pub package](https://img.shields.io/pub/v/flutter_buildkit.svg)](https://pub.dev/packages/flutter_buildkit)

Add it as a dev dependency in each Flutter project:

```sh
dart pub add --dev flutter_buildkit
```

or in `pubspec.yaml`:

```yaml
dev_dependencies:
  flutter_buildkit: ^0.1.0
```

Then, from the project root:

```sh
flutter pub get
dart run flutter_buildkit init   # optional: write flutter_buildkit.yaml
dart run flutter_buildkit        # open the menu
```

Add `app_builds/` and `flutter_buildkit.yaml` to that project's `.gitignore`.
To work on this repo itself, clone it and run `dart pub get`, then
`dart run bin/flutter_buildkit.dart -C /path/to/flutter/project`.

Options: `-C <project dir>`, `-c <config file>`, `--ledger <file>`, `--ui auto|keys|plain`.
Other commands: `init` (write a starter config), `list`, `export <csv|tsv|json> [file]`.

## Using the menu

Every list works two ways, so you are never stuck:

* **Numbers.** Type the number shown next to a row and press Enter. For
  several rows in a multi select type `1,3`, `1-3` or `1 3` and press Enter.
* **Keys.** On a terminal you can also use the arrows:

| Key | Does |
|---|---|
| Up / Down, `k` / `j`, PgUp / PgDn, Home / End | Move |
| Enter | Choose (single) or confirm (multi) |
| Space | Tick or untick a row (multi select) |
| `a` / `n` / `i` | Tick all, none, or invert the visible rows |
| `/` | Filter the list by typing (Esc clears) |
| Digits, `,` and `-` | Type row numbers, then Enter |
| Esc or `q` | Back / cancel; Ctrl-C quits |

Arrow keys are used automatically on macOS, Linux and Windows (PowerShell,
cmd, Windows Terminal; the app switches on the console's ANSI mode). If that
is not possible, or input is piped, or `TERM=dumb`, plain numbered questions
are used (numbers, ranges, or the start of an option's name). Force a mode with `--ui plain` or `--ui keys`
(or `FBK_UI=plain`). Colors follow the terminal and honour `NO_COLOR`. The
classic Windows console gets ASCII borders; Windows Terminal and the VS Code
terminal get box drawing.

| Item | What it does |
|---|---|
| Build app | Tick any flavors, outputs (APK / AAB / IPA on macOS) and modes; every combination is built. Optional steps run once first: **flutter clean** (followed by `pub get`), **build_runner** and **flutter gen-l10n** (offered only when the project uses them). |
| List builds | Table of all ledger rows, newest first, with status. |
| Build details | Everything stored for one build, including SHA-256 of each artifact. |
| Mark builds as published | Flags builds as released to users (or clears the mark). |
| Upload to Google Play | Really uploads the AAB through the Play Developer API when credentials are configured; otherwise (or by choice) only marks the ledger. |
| Upload debug symbols | Pick builds and Firebase Crashlytics (`firebase` CLI) and/or Sentry (`sentry-cli`). |
| Trace a crash | Paste or load a stack trace and get it de-obfuscated with the symbols stored for a build (see below). |
| Delete builds | Multi select; see the delete rules below. |
| Export ledger | CSV, TSV or JSON file. |

## Delete rules

* A build that was **never published and never uploaded to Play** is removed
  completely: its folder (files, symbols, mappings) and its ledger row.
* A **released** build (marked published or uploaded to Play) only loses its
  APK/AAB/IPA files. Its debug symbols, mappings and ledger row are kept
  forever, so crashes from the field can still be traced. The row shows
  `files deleted`.

## Tracing crashes

"Trace a crash" works on any build that still has symbols, including released
builds whose files were deleted. It detects the trace type and runs:

| Trace | Tool | Uses |
|---|---|---|
| Obfuscated Dart | `flutter symbolize` | `symbols/dart/` |
| Android Java/Kotlin | R8 `retrace` | `symbols/mapping/mapping.txt` |
| Native crash (tombstone) | `ndk-stack` | `symbols/native/<abi>/` |

`retrace` and `ndk-stack` are found on `PATH`, through `ANDROID_HOME` /
`ANDROID_NDK_HOME`, or via `android.retrace` / `android.ndk_stack` in the config.

### Several entry points (main files)

A project with more than one `main` (an admin app, a kiosk mode, a demo) can
build them all, with or without flavors. Without any config, extra
`lib/main_*.dart` files are found automatically (`main_admin.dart` becomes the
entry point `admin`; a `main_<flavor>.dart` stays that flavor's own main). To
choose the names and paths yourself:

```yaml
entry_points:                       # shared by all flavors
  main: lib/main_{flavor}.dart      # {flavor} is filled in per flavor
  admin: lib/main_admin.dart
flavors:
  prod:
    entry_points:                   # this flavor has its own list
      main: lib/main_prod.dart
      kiosk: lib/main_prod_kiosk.dart
```

The build menu then asks which entry points to build and builds every
combination of flavor, entry point, output and mode. A named entry point is
added to the folder and file names (`..._070509-admin.aab`) and stored in the
ledger (`entry_point` column), so builds never overwrite each other. Put
`{entry}` in `output_layout` or `file_name` to place the name yourself. The
default entry point keeps the plain names. Entry points can also be edited in
the settings screen.

### Set up from the project

`flutter_buildkit autoconfig` (or **Set up from this project** in the menu)
reads the project and writes `flutter_buildkit.yaml` from what it finds, then
reloads the app. It detects:

| Found | Becomes |
|---|---|
| Gradle product flavors, Xcode schemes, `flutter_flavorizr`, `--flavor` in `.vscode/launch.json` | the flavors, with a matching `main_<flavor>.dart` (anywhere in the project) as the entry point |
| the define file launch.json uses, or `config/<flavor>.json`, `env/<flavor>.json`, ... (matched loosely: `preprod` finds `pre_prod.json`) | `dart_define_file` |
| `applicationId` (and suffix) per flavor | `package_name` |
| `google-services.json` | `firebase_app_id` (when `firebase_crashlytics` is used) |
| other Dart files with a `main()`, anywhere in the project | `entry_points` |
| `build_runner`, `l10n.yaml` / `generate: true` | `pre_build.build_runner`, `pre_build.gen_l10n` |
| `firebase_crashlytics`, `sentry_flutter`, `sentry.properties` | `crashlytics.enabled`, `sentry.enabled`, org, project, url |
| `.fvmrc` / `.fvm/` | `flutter: fvm flutter` |
| `json_key_file` in `fastlane/Appfile` | `play.service_account_json` (the path only) |
| flavors or not | `output_layout`: `by-flavor`, or `{mode}/{version}-{datetime}` without flavors |

You tick what to apply, with the reason shown next to each value. Values you
already set in an existing file are not ticked, so they are never overwritten
by accident. It also offers to add the output folder and the config file to
`.gitignore`. Secrets are never read into the file: the Sentry auth token
stays out, and for Play only the key's path is used.

#### Entry points can be anywhere

Entry points are not limited to `lib/main_*.dart`. Every Dart file under
`lib/` that defines `main()` counts, and so do files named `main.dart`,
`main_x.dart` or `x_main.dart` in other folders (`apps/kiosk/main_kiosk.dart`),
plus the `program` of every launch.json configuration. The name comes from
the file: `main_admin.dart` and `admin_main.dart` give `admin`, a
`main.dart` inside `lib/admin/` gives `admin`, and two files that would get
the same name are told apart by their folder. A flavor finds its own main
loosely (`clientDb` matches `main_client_db.dart`). Platform folders
(`android`, `ios`, ...), `test`, `integration_test`, `tool`, hidden folders,
`build/` and generated code (`*.g.dart`, `*.freezed.dart`, ...) are skipped.

### VS Code run configurations

`flutter_buildkit vscode` (also **VS Code launch.json** in the menu, and an
offer at the end of **Set up from this project**) adds a run configuration for
every flavor × entry point × mode (debug, profile, release) to
`.vscode/launch.json`:

```jsonc
{
  "name": "CLIENT DB - RELEASE",
  "request": "launch",
  "type": "dart",
  "flutterMode": "release",
  "args": ["--flavor", "clientDb", "--dart-define-from-file=configs/client_db.json"]
}
```

`program` is only written for an entry point other than `lib/main.dart`
(`"program": "lib/main_legacy.dart"`). The file is edited in place: your
comments, formatting and other configurations stay, a configuration that
already runs the same thing (same flavor, mode, program and define file) is
not added again even under another name, the old file is kept once as
`launch.json.bak`, and a launch.json that is not valid JSON is never touched.
Without flavors you get one set of configurations per entry point.

### Editing the settings from the menu

Run `flutter_buildkit settings` (or pick **Settings** in the main menu) to
edit `flutter_buildkit.yaml` without opening the file. Every option shows its
current value and a preview of what it does: the folder and file name a build
would get, the exact `flutter build` command, the pre-build steps, and so on.
Choices list a preview next to each value, typed values are checked before
they are accepted, and nothing is written until you choose **Save and
reload**. The file is created from the documented template when the project
has none, comments in an existing file are kept, and the app reloads the new
settings straight after saving. Flavors are edited under **Flavors**. Secrets
such as the Sentry token are not stored by this screen: use the environment
variables.

### Options asked before each build

The build menu asks, per run: flavors, outputs, modes, version name and code,
the pre-build steps, **Build options** (obfuscate and keep Dart symbols; split
APKs per ABI when an APK is built) and extra `flutter build` arguments. The
answers start from your config, so you only change what differs this time.

## Output layout

Every build gets its own folder under `app_builds/` (set with `output_dir`):

```
app_builds/
  ledger.json                 the ledger (+ ledger.json.bak)
  exports/                    CSV / TSV / JSON exports
  dev/                        <flavor>   ("default" when there are no flavors)
    release/                  <mode>
      1.2.0-b42-20261001-070509/       <versionName>-b<versionCode>-<datetime>
        artifacts/
          my_app-dev-release-1.2.0-b42-20261001-070509.aab
        symbols/
          dart/             --split-debug-info output (obfuscated builds)
          mapping/          R8 mapping.txt, usage.txt, seeds.txt ...
          native/<abi>/     unstripped .so files
          dSYMs/            iOS
        build_info.json     this build's ledger row
```

Artifact file names are
`<app>-<flavor>-<mode>-<versionName>-b<versionCode>-<datetime>.<type>`, for
example `my_app-dev-release-1.2.0-b42-20261001-070509.aab`. Without a flavor
the flavor part is left out. Split-per-ABI APKs get the ABI at the end
(`...-070509-arm64-v8a.apk`). `<datetime>` is local time, `yyyyMMdd-HHmmss`.

### Choosing another folder structure

The `{app}/` folder of a preset only appears when `output_dir` is outside the
Flutter project. Inside the project (the default `app_builds/`) the project
folder already names the app, so `by-flavor` gives
`app_builds/dev/release/1.2.0-b42-.../`. With `output_dir: ~/builds` it gives
`~/builds/my_app/dev/release/1.2.0-b42-.../`. Custom templates are used
exactly as written. File names always contain the app name.

Set `output_layout` to a preset (or your own template). The presets, shown
for the same build:

| Preset | Template | Example folder | Good for |
|---|---|---|---|
| `by-flavor` (default) | `{app}/{flavor}/{mode}/{version}-{datetime}` | `my_app/dev/release/1.2.0-b42-20261001-070509/` | Browsing per environment (dev, staging, prod) |
| `by-version` | `{app}/{version}/{flavor}-{mode}-{datetime}` | `my_app/1.2.0-b42/dev-release-20261001-070509/` | Handing over or archiving a whole release: all flavors of a version sit together |
| `by-month` | `{year}-{month}/{app}-{flavor}-{mode}-{version}-{datetime}` | `2026-10/my_app-dev-release-1.2.0-b42-20261001-070509/` | Cleaning up by age; many apps in one output folder |
| `flat` | `{app}-{flavor}-{mode}-{version}-{datetime}` | `my_app-dev-release-1.2.0-b42-20261001-070509/` | Simple, one folder level |

Custom templates use these tokens: `{app}` `{flavor}` `{mode}` `{versionName}`
`{versionCode}` `{version}` (= `<versionName>-b<versionCode>`) `{datetime}`
`{date}` `{time}` `{year}` `{month}` `{type}`. Use `/` between folders. Values
are sanitised, and a layout must stay inside the output folder. Examples:

```yaml
output_layout: "{app}/{type}/{flavor}/{version}-{datetime}"   # split APKs and AABs
output_layout: "{year}/{month}/{app}/{flavor}-{mode}-{version}-{datetime}"
file_name: "{app}_{flavor}_{versionName}_{versionCode}"      # artifact name, no extension
```

Paths in the ledger are relative to the ledger folder, so the whole output
folder can be moved. Old builds keep working after you change the layout.

## Build status in the ledger

Every ledger entry carries a status, a condition and a history that the app
keeps up to date:

| Field | Values |
|---|---|
| `status` | `built` (stored, not released), `uploaded` (on Google Play, not published), `published` (marked public). The most advanced one wins; clearing the published mark steps back. |
| `condition` | `ready`, or `artifacts deleted, symbols kept` after the APK/AAB/IPA files were removed. |
| `symbols_status` | `stored, not uploaded`, `uploaded to crashlytics, sentry`, `missing` (an obfuscated build without symbols) or `none (not obfuscated)`. |
| history | what happened and when: built, uploaded to Google Play (track, release status), marked published, unmarked, debug symbols uploaded (tool), files deleted. |

The list shows Status, Files and Symbols columns, the build details show the
full history, and CSV/TSV/JSON exports carry `status`, `condition`,
`symbols_status` and `last_event_at`. Rows written by earlier versions get
their history rebuilt from their dates.

## Why the ledger is JSON

A build row is nested (several artifacts, Play status, per-tool symbol upload
times) and typed (numbers, booleans, timestamps). JSON keeps all of that
without loss and can be edited by hand. CSV and TSV flatten it to text, so they
are export formats: **CSV** (RFC 4180, opens in Excel/Sheets) and **TSV**
(tabs and newlines escaped as `\t` and `\n`). The ledger is rewritten
atomically and the previous copy is kept as `ledger.json.bak`. Paths inside it
are relative to the ledger folder, so the whole `app_builds/` folder can be moved.

## Configuration

Settings come from three places, later ones winning: built-in defaults, the
config file, then environment variables (for secrets and tool paths). Command
line options win for their own settings.

* **Config file:** `flutter_buildkit.yaml` in the Flutter project root (or
  `-c <file>`). Create a commented starter with
  `dart run flutter_buildkit init`. Keep it out of git if it holds anything
  private.
* **See what is in effect:** `dart run flutter_buildkit config` prints every
  setting (secrets masked).
* Everything is optional. With no config file the app works with defaults,
  detecting flavors from Gradle and Xcode.

### Config file reference

| Key | Default | What it does |
|---|---|---|
| `output_dir` | `app_builds` | Root of the build folders and the ledger, relative to the project. |
| `output_layout` | `by-flavor` | Folder layout: a preset id or a template (see Output layout). |
| `file_name` | `{app}-{flavor}-{mode}-{version}-{datetime}` | Artifact file name without extension. |
| `entry_points` | detected | Named Dart entry points shared by all flavors (`name: path`). `{flavor}` in a path is replaced by the flavor. |
| `flavors.<name>.entry_points` | none | Entry points of one flavor; replaces the shared list for it. |
| `ledger` | `<output_dir>/ledger.json` | Ledger file path. |
| `flutter` | `flutter` | Command that runs Flutter, e.g. `fvm flutter`. |
| `obfuscate` | `true` | Obfuscate profile/release builds and keep Dart symbols. |
| `split_per_abi` | `false` | Build one APK per ABI. |
| `extra_build_args` | `[]` | Extra arguments for every `flutter build`. |
| `pre_build.clean` | `false` | Pre-tick `flutter clean` (followed by `pub get`) in the menu. |
| `pre_build.build_runner` | `true` | Pre-tick `build_runner build` (shown only if the project uses it). |
| `pre_build.gen_l10n` | `true` | Pre-tick `flutter gen-l10n` (shown only if the project uses it). |
| `pre_build.build_runner_args` | `[--delete-conflicting-outputs]` | Arguments for build_runner. |
| `flavors.<name>.target` | `lib/main_<name>.dart` if it exists | Entry point (`-t`). |
| `flavors.<name>.dart_define_file` | none | File for `--dart-define-from-file`. |
| `flavors.<name>.package_name` | from Gradle | Android application id (used for Play). |
| `flavors.<name>.firebase_app_id` | from `google-services.json` | Crashlytics app id. |
| `flavors.<name>.sentry_project` | `sentry.project` | Sentry project for this flavor. |
| `flavors.<name>.extra_args` | `[]` | Extra `flutter build` arguments for this flavor. |
| `play.service_account_json` | none | Play service account key (path). |
| `play.default_track` | `internal` | `internal`, `alpha`, `beta` or `production`. |
| `play.default_release_status` | `completed` | `completed`, `draft` or `inProgress`. |
| `play.upload_mapping` | `true` | Attach the R8 mapping to the Play upload. |
| `crashlytics.enabled` | `true` | Offer Crashlytics for symbol upload. |
| `crashlytics.cli` | `firebase` | Firebase CLI command. |
| `sentry.enabled` | `true` | Offer Sentry for symbol upload. |
| `sentry.cli` | `sentry-cli` | sentry-cli command. |
| `sentry.org`, `sentry.project`, `sentry.url` | none | Sentry organisation, project, self-hosted URL. |
| `sentry.auth_token` | none | Prefer the `SENTRY_AUTH_TOKEN` variable. |
| `android.retrace`, `android.ndk_stack` | found on PATH / SDK | Tools for "Trace a crash". |

### Environment variables and options

| Name | Overrides / does |
|---|---|
| `PLAY_SERVICE_ACCOUNT_JSON` | `play.service_account_json` |
| `SENTRY_AUTH_TOKEN`, `SENTRY_ORG`, `SENTRY_PROJECT`, `SENTRY_URL` | the `sentry.*` settings |
| `FBK_FLUTTER` | `flutter` |
| `FBK_RETRACE`, `FBK_NDK_STACK` | `android.retrace`, `android.ndk_stack` |
| `ANDROID_HOME`, `ANDROID_NDK_HOME` | where to look for `retrace` and `ndk-stack` |
| `FBK_UI` | `--ui` |
| `NO_COLOR`, `FORCE_COLOR` | turn colors off / on |

| Option | Does |
|---|---|
| `-C, --project <dir>` | Flutter project folder (default `.`). |
| `-c, --config <file>` | Config file path. |
| `--ledger <file>` | Ledger file (overrides the config). |
| `--ui auto\|keys\|plain` | How prompts read input. |

### Example `flutter_buildkit.yaml`

```yaml
output_dir: app_builds
output_layout: by-version          # my_app/1.2.0-b42/dev-release-<datetime>/
file_name: "{app}-{flavor}-{mode}-{version}-{datetime}"

flutter: fvm flutter               # a pinned Flutter via FVM
obfuscate: true
split_per_abi: false

pre_build:
  clean: false
  build_runner: true
  gen_l10n: true

flavors:
  dev:
    target: lib/main_dev.dart
    dart_define_file: config/dev.json
    package_name: com.example.app.dev
    firebase_app_id: 1:1234567890:android:abc123dev
    sentry_project: my-app-dev
  prod:
    target: lib/main_prod.dart
    dart_define_file: config/prod.json
    package_name: com.example.app
    firebase_app_id: 1:1234567890:android:abc123prod
    sentry_project: my-app

play:
  # service_account_json: set PLAY_SERVICE_ACCOUNT_JSON instead
  default_track: internal
  default_release_status: draft

crashlytics:
  enabled: true
sentry:
  org: my-company                  # token: set SENTRY_AUTH_TOKEN in your shell
  project: my-app
```

Keep secrets in the environment, for example in PowerShell:

```powershell
$env:PLAY_SERVICE_ACCOUNT_JSON = "$HOME\.secrets\play-service-account.json"
$env:SENTRY_AUTH_TOKEN = "<token>"
dart run flutter_buildkit
```

or in bash/zsh: `export SENTRY_AUTH_TOKEN=...`.


### Google Play

Create a service account in Google Cloud, invite it in Play Console
(Users and permissions) with release permissions for the app, and point
`PLAY_SERVICE_ACCOUNT_JSON` at its key. Only **release AABs** are uploaded, to
the track you choose; R8 mapping is attached. Play requires the first upload
of a brand new app to be done in Play Console; use "only mark the ledger" for
that one and the API afterwards.

### Symbols

Every build stores its debug symbols next to the binaries: Dart symbols
(`--split-debug-info`), the full R8 mapping folder, unstripped native
libraries per ABI and, for iOS, dSYMs. Dart symbols exist only for obfuscated
profile/release builds (`obfuscate: true`, the default). Deleting an
unreleased build also deletes its symbols, so the delete menu warns when they
were never uploaded. Crashlytics gets the Dart and native symbols (and dSYMs
on iOS); Sentry gets the whole symbols folder plus the R8 mapping. Crashlytics
R8 mappings are normally uploaded by its Gradle plugin at build time.

## Development

```sh
dart analyze && dart test
```

The tests cover the ledger (persistence, atomic save, export, delete rules),
the folder layout, Gradle flavor parsing, build arguments, config, pre-build
planning, trace tooling and the keyboard/selection logic. Building,
the Play API, `firebase` and `sentry-cli` are thin wrappers and are not run in
tests; the build pipeline was smoke-tested against a fake `flutter` script.
