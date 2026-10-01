# flutter_build_ledger

An interactive Dart console app that builds a Flutter project (APK, AAB, IPA),
files every build in a predictable folder tree, and keeps a **ledger** of what
was built, published, uploaded to Google Play, and symbolicated.

## Run it

```sh
dart pub get
cd /path/to/your/flutter/project
dart run /path/to/flutter_build_ledger/bin/flutter_build_ledger.dart
# or install the command:  dart pub global activate --source path .   ->  fbl
```

Options: `-C <project dir>`, `-c <config file>`, `--ledger <file>`.
Other commands: `init` (write a starter config), `list`, `export <csv|tsv|json> [file]`.

## Menu

| Item | What it does |
|---|---|
| Build app | Pick flavor (from Gradle product flavors and Xcode schemes), output (APK / AAB / IPA on macOS), mode, version name and code; runs `flutter build` and records the result. |
| List builds | Table of all ledger rows, newest first, with status. |
| Build details | Everything stored for one build, including SHA-256 of each artifact. |
| Mark as published | Flags a build as released to users (toggle to clear). |
| Upload to Google Play | Really uploads the AAB through the Play Developer API when credentials are configured; otherwise (or by choice) only marks the ledger as uploaded. |
| Upload debug symbols | Firebase Crashlytics (`firebase` CLI) and/or Sentry (`sentry-cli`). |
| Delete builds | Removes the build folder **and** its ledger row. |
| Export ledger | CSV, TSV or JSON file. |

## Output layout

```
builds/<app>/<flavor>/<mode>/<versionName>+<versionCode>_<yyyyMMdd-HHmmss>/
    <app>-<flavor>-<mode>-<version>.aab
    build_info.json
    symbols/dart/        # --split-debug-info output (obfuscated builds)
    symbols/mapping.txt  # R8 mapping, when produced
    symbols/dSYMs/       # iOS
builds/ledger.json
```

Projects without flavors use `default`. Names are sanitised for every OS. The
timestamp is local time. The root defaults to `builds/` inside the Flutter
project (git-ignore it) and is set with `output_dir`.

## Why the ledger is JSON

A build row is nested (several artifacts, Play status, per-tool symbol upload
times) and typed (numbers, booleans, timestamps). JSON keeps all of that
without loss and can be edited by hand. CSV and TSV flatten it to text, so they
are export formats: **CSV** (RFC 4180, opens in Excel/Sheets) and **TSV**
(tabs and newlines escaped as `\t` and `\n`). The ledger is rewritten
atomically and the previous copy is kept as `ledger.json.bak`. Paths inside it
are relative to the ledger folder, so the whole `builds/` folder can be moved.

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

Crash symbols are only kept for obfuscated profile/release builds
(`obfuscate: true`, the default). Deleting such a build before uploading its
symbols loses the only copy, so the delete menu warns about it.

## Development

```sh
dart analyze && dart test
```

The tests cover the ledger (persistence, atomic save, export, delete), the
folder layout, Gradle flavor parsing, build arguments and config. Building,
the Play API, `firebase` and `sentry-cli` are thin wrappers and are not run in
tests; the build pipeline was smoke-tested against a fake `flutter` script.
