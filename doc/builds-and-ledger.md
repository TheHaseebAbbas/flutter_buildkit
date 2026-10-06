# Builds, folders and the ledger

Where builds are stored, what the ledger records, how deletion and crash tracing work.

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
`app_builds/dev/release/1.2.0-b42-.../`. With `output_dir: ../builds` it gives
`../builds/my_app/dev/release/1.2.0-b42-.../`. Custom templates are used
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
| `status` | `failed` (the build did not finish; only `build.log` is kept), `built` (stored, not released), `uploaded` (on Google Play, not published), `published` (marked public). The most advanced one wins; clearing the published mark steps back. |
| `condition` | `ready`, or `artifacts deleted, symbols kept` after the APK/AAB/IPA files were removed. |
| `symbols_status` | `stored, not uploaded`, `uploaded to crashlytics, sentry`, `missing` (an obfuscated build without symbols) or `none (not obfuscated)`. |
| history | what happened and when: built, uploaded to Google Play (track, release status), marked published, unmarked, debug symbols uploaded (tool), files deleted. |

The list shows Status, Files and Symbols columns, the build details show the
full history, and CSV/TSV/JSON exports carry `status`, `condition`,
`symbols_status` and `last_event_at`. In CSV and TSV a cell that starts with
`=`, `+`, `-`, `@`, a tab or a carriage return gets a leading `'`, so a
spreadsheet shows it as text instead of running it as a formula; JSON is
unchanged. Rows written by earlier versions get
their history rebuilt from their dates.

## Why the ledger is JSON

A build row is nested (several artifacts, Play status, per-tool symbol upload
times) and typed (numbers, booleans, timestamps). JSON keeps all of that
without loss and can be edited by hand. CSV and TSV flatten it to text, so they
are export formats: **CSV** (RFC 4180, opens in Excel/Sheets) and **TSV**
(tabs and newlines escaped as `\t` and `\n`). The ledger is rewritten
atomically and the previous copy is kept as `ledger.json.bak`. Paths inside it
are relative to the ledger folder, so the whole `app_builds/` folder can be moved.


## Build log and failed builds

Every build writes the output of `flutter build` to `build.log` in its folder.
When a build fails, the folder is kept with that log and the ledger gets a row
with status `failed`, the exit code and the exact command line, so a failure
is never silently forgotten. Delete the row like any other build when you no
longer need it. Pressing Ctrl-C during a build stops `flutter` and removes the
unfinished folder.

## Delete rules

* A build that was **never published and never uploaded to Play** is removed
  completely: its folder (files, symbols, mappings) and its ledger row.
* A **released** build (marked published or uploaded to Play) only loses its
  APK/AAB/IPA files. Its debug symbols, mappings and ledger row are kept
  forever, so crashes from the field can still be traced. The row shows
  `files deleted`.

The ledger is a file you can edit by hand, so before removing anything the
tool checks every path. The build folder must lie **strictly inside** the
ledger's folder after symlinks are resolved, must not hold another build, and
must contain a `build_info.json` with the build's id. A build that fails a
check is reported and left alone. From code, `BuildManager.delete(..., dryRun: true)` runs the checks and
reports what would be removed without changing anything.

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
