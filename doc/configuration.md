# Configuration

Settings come from three places, later ones winning: built-in defaults, the
config file, then environment variables (for secrets and tool paths). Command
line options win for their own settings.

* **Config file:** `flutter_buildkit.yaml` in the Flutter project root (or
  `-c <file>`). Create a commented starter with
  `dart run flutter_buildkit init`. Commit it: flavors, layout, entry points
  and track defaults are project knowledge the whole team shares.
* **Personal overlay:** `flutter_buildkit.local.yaml` next to it, with the
  same keys, wins over the shared file (maps are merged key by key, lists
  are replaced). Put secrets and machine paths there (for example
  `play.service_account_json`) and add it to `.gitignore`.
* **See what is in effect:** `dart run flutter_buildkit config` prints every
  setting (secrets masked).
* Everything is optional. With no config file the app works with defaults,
  detecting flavors from Gradle and Xcode.

## Config file reference

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
| `pre_build.build_runner_args` | `[]` | Arguments for build_runner. |
| `flavors.<name>.target` | `lib/main_<name>.dart` if it exists | Entry point (`-t`). |
| `flavors.<name>.dart_define_file` | none | File for `--dart-define-from-file`. |
| `flavors.<name>.package_name` | from Gradle | Android application id (used for Play). |
| `flavors.<name>.firebase_app_id` | from `google-services.json` | Crashlytics app id. |
| `flavors.<name>.sentry_project` | `sentry.project` | Sentry project for this flavor. |
| `flavors.<name>.extra_args` | `[]` | Extra `flutter build` arguments for this flavor. |
| `play.service_account_json` | none | Play service account key (path). |
| `play.default_track` | `internal` | `internal`, `alpha`, `beta` or `production`. |
| `play.default_release_status` | `draft` | `draft`, `completed` or `inProgress`. A draft is finished in Play Console, so a wrong pick never rolls out to users. |
| `play.upload_mapping` | `true` | Attach the R8 mapping to the Play upload. |
| `crashlytics.enabled` | `true` | Offer Crashlytics for symbol upload. |
| `crashlytics.cli` | `firebase` | Firebase CLI command. |
| `sentry.enabled` | `true` | Offer Sentry for symbol upload. |
| `sentry.cli` | `sentry-cli` | sentry-cli command. |
| `sentry.org`, `sentry.project`, `sentry.url` | none | Sentry organisation, project, self-hosted URL. |
| `sentry.auth_token` | none | Prefer the `SENTRY_AUTH_TOKEN` variable. |
| `android.retrace`, `android.ndk_stack` | found on PATH / SDK | Tools for "Trace a crash". |
| `delete_policy.retain_on` | `[published, alpha, beta, production]` | What keeps a build's symbols and row when it is deleted: `published` (marked published), `play` (any Play upload) or Play track names. Uploads to `internal` do not count by default. |
| `retention.log_days` | `90` | `prune` removes `build.log` and failed builds older than this many days. |
| `retention.symbols_keep_last` | none | `prune` removes the local symbols of released builds beyond the newest N per app and flavor, only when already uploaded to Crashlytics or Sentry. |

## Trusting a config

A config can name programs the tool starts (`flutter`, `crashlytics.cli`,
`sentry.cli`, `android.retrace`, `android.ndk_stack`). The first time a shared
`flutter_buildkit.yaml` sets any of them, the menu lists them and asks
"Trust this config?"; the answer is stored per project and per set of
commands in `~/.flutter_buildkit/trusted.json`, so changing a command asks
again. Commands from `flutter_buildkit.local.yaml` or the `FBK_*` variables
are yours and never asked about. The non-interactive commands cannot ask: they
exit 78 until you run once with `--trust-config` or set `FBK_TRUST_CONFIG=1`.

When loading, a warning is printed if `sentry.auth_token` is in the shared
YAML, or the Play key lies inside the project without being git-ignored.

## Environment variables and options

| Name | Overrides / does |
|---|---|
| `PLAY_SERVICE_ACCOUNT_JSON` | `play.service_account_json` |
| `SENTRY_AUTH_TOKEN`, `SENTRY_ORG`, `SENTRY_PROJECT`, `SENTRY_URL` | the `sentry.*` settings |
| `FBK_FLUTTER` | `flutter` (quote a path with spaces: `"C:\Program Files\flutter\bin\flutter.bat"`; or use a list in the YAML: `[fvm, flutter]`) |
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

## Example `flutter_buildkit.yaml`

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


## Google Play

Create a service account in Google Cloud, invite it in Play Console
(Users and permissions) with release permissions for the app, and point
`PLAY_SERVICE_ACCOUNT_JSON` at its key. Only **release AABs** are uploaded, to
the track you choose; R8 mapping is attached. Play requires the first upload
of a brand new app to be done in Play Console; use "only mark the ledger" for
that one and the API afterwards.

## Symbols

Every build stores its debug symbols next to the binaries: Dart symbols
(`--split-debug-info`), the full R8 mapping folder, unstripped native
libraries per ABI and, for iOS, dSYMs. Dart symbols exist only for obfuscated
profile/release builds (`obfuscate: true`, the default). Deleting an
unreleased build also deletes its symbols, so the delete menu warns when they
were never uploaded. Crashlytics gets the Dart and native symbols (and dSYMs
on iOS); Sentry gets the whole symbols folder plus the R8 mapping. Crashlytics
R8 mappings are normally uploaded by its Gradle plugin at build time.

### Crashlytics and the R8 mapping

`flutter_buildkit` uploads Dart and native symbols to Crashlytics with
`firebase crashlytics:symbols:upload`. It does **not** upload the R8
`mapping.txt`: Crashlytics needs it to read Java/Kotlin frames of an
obfuscated Android build, and the Crashlytics Gradle plugin normally sends it
during `assembleRelease`/`bundleRelease`, so a standard Flutter project with
the plugin applied is covered. The mapping is still stored in
`symbols/mapping/` for "Trace a crash", and sent to Google Play (`play.upload_mapping`)
and Sentry. If your build does not apply the Gradle plugin, upload it yourself;
see `firebase help crashlytics:mappingfile:upload` for the flags your CLI
version supports.

### Firebase and Sentry in CI

The Firebase CLI needs a login. In a pipeline set `GOOGLE_APPLICATION_CREDENTIALS`
to a service account key file with the Firebase Crashlytics Admin role (or pass a
token through `FIREBASE_TOKEN`); locally `firebase login` is enough. For Sentry
export `SENTRY_AUTH_TOKEN`. `doctor` shows what is missing.
