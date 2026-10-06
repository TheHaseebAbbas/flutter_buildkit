# Project setup

How flutter_buildkit learns about your project: entry points, auto-configuration, VS Code run configurations, the settings editor and the per-build options.

## Several entry points (main files)

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

## Set up from the project

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
by accident. It also offers to add the output folder and the personal overlay
(`flutter_buildkit.local.yaml`) to `.gitignore`; the main config is meant to
be committed. Secrets are never read into the file: the Sentry auth token
stays out, and for Play only the key's path is used.

### Entry points can be anywhere

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

## VS Code run configurations

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

## Editing the settings from the menu

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

## Options asked before each build

The build menu asks, per run: flavors, outputs, modes, version name and code,
the pre-build steps, **Build options** (obfuscate and keep Dart symbols; split
APKs per ABI when an APK is built) and extra `flutter build` arguments. The
answers start from your config, so you only change what differs this time.
