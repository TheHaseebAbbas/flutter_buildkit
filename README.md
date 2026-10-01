# flutter_build_ledger

An interactive Dart console app that builds a Flutter project (APK, AAB, IPA),
files every build in a predictable folder tree, and keeps a **ledger** of what
was built, published, uploaded to Google Play, and symbolicated.

## Use it in your Flutter projects

Add it as a dev dependency straight from GitHub, in each Flutter project's
`pubspec.yaml`:

```yaml
dev_dependencies:
  flutter_build_ledger:
    git:
      url: https://github.com/TheHaseebAbbas/flutter_build_ledger.git
      # ref: v0.1.0   # pin a tag or commit when you want reproducible tooling
```

Then, from the project root:

```sh
flutter pub get
dart run flutter_build_ledger init   # optional: write flutter_build_ledger.yaml
dart run flutter_build_ledger        # open the menu
```

Add `app_builds/` and `flutter_build_ledger.yaml` to that project's `.gitignore`.
To work on this repo itself, clone it and run `dart pub get`, then
`dart run bin/flutter_build_ledger.dart -C /path/to/flutter/project`.

Options: `-C <project dir>`, `-c <config file>`, `--ledger <file>`.
Other commands: `init` (write a starter config), `list`, `export <csv|tsv|json> [file]`.

## Using the menu

On a terminal every list is arrow-key driven (plain numbered questions are
used instead when input is piped):

| Key | Does |
|---|---|
| Up / Down, `k` / `j`, PgUp / PgDn, Home / End | Move |
| Enter | Choose (single) or confirm (multi) |
| Space | Tick or untick a row (multi select) |
| `a` / `n` / `i` | Tick all, none, or invert the visible rows |
| `/` | Filter the list by typing (Esc clears) |
| `1`-`9` | Jump to that row (single select) |
| Esc or `q` | Back / cancel; Ctrl-C quits |

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

## Output layout

```
app_builds/<app>/<flavor>/<mode>/<versionName>+<versionCode>_<yyyyMMdd-HHmmss>/
    <app>-<flavor>-<mode>-<version>.aab
    build_info.json
    symbols/dart/        # --split-debug-info output (obfuscated builds)
    symbols/mapping/      # R8 mapping.txt, usage.txt, seeds.txt...
    symbols/native/       # unstripped native libraries (.so per ABI)
    symbols/dSYMs/       # iOS
app_builds/ledger.json
```

Projects without flavors use `default`. Names are sanitised for every OS. The
timestamp is local time. The root defaults to `app_builds/` inside the Flutter
project (git-ignore it) and is set with `output_dir`.

## Why the ledger is JSON

A build row is nested (several artifacts, Play status, per-tool symbol upload
times) and typed (numbers, booleans, timestamps). JSON keeps all of that
without loss and can be edited by hand. CSV and TSV flatten it to text, so they
are export formats: **CSV** (RFC 4180, opens in Excel/Sheets) and **TSV**
(tabs and newlines escaped as `\t` and `\n`). The ledger is rewritten
atomically and the previous copy is kept as `ledger.json.bak`. Paths inside it
are relative to the ledger folder, so the whole `app_builds/` folder can be moved.

## Configuration

`dart run ... init` writes `flutter_build_ledger.yaml`. Secrets should come
from the environment, never from a committed file:

| Variable | Purpose |
|---|---|
| `PLAY_SERVICE_ACCOUNT_JSON` | Path to a Google Play service account key |
| `SENTRY_AUTH_TOKEN`, `SENTRY_ORG`, `SENTRY_PROJECT`, `SENTRY_URL` | sentry-cli |
| `FBL_FLUTTER` | Flutter command, e.g. `fvm flutter` |

Crashlytics uses your `firebase login` session. The Firebase app id is read
from `google-services.json` / `GoogleService-Info.plist` or
`flavors.<flavor>.firebase_app_id`.

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
