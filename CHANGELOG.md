## 0.2.2 - 2026-10-06

- Menus now use the terminal's height. The visible list was capped at 20 rows,
  reserved 8 rows for the rest, and was measured once when the menu opened.
  It is now measured on every redraw (so resizing works), reserves only the
  rows actually drawn, and shows "more above/below" only when items are
  really hidden. The indicator lines count toward the row budget.
- CI no longer runs on every pull request push: it runs when a PR is marked
  ready for review, on `main`, and on demand.

## 0.2.1 - 2026-10-06

- Menus no longer repeat their heading on every arrow key: list lines are cut
  to the terminal width so redraws stay in place.
- build_runner now runs as `dart run build_runner build` (`flutter pub run`
  is deprecated), and `--delete-conflicting-outputs` is no longer a default
  (newer build_runner ignores it). `pre_build.build_runner_args` still passes
  anything you set.

## 0.2.0

Safety release. Behavior changes are marked **Changed**.

- Delete is hardened. A build folder must lie strictly inside the ledger's
  folder after resolving symlinks, must not contain another build, and must
  hold a `build_info.json` with the build's id; released builds' artifact
  paths are checked the same way. `BuildManager.delete` gained `dryRun`.
- Failed builds are recorded. The folder is kept with a new `build.log`
  (the output of `flutter build`), and the ledger gets a row with status
  `failed`, the exit code and the command line. Failed rows cannot be
  published, uploaded or have symbols sent. `BuildRecord` gained `failure`,
  `command` and `isFailed`; `BuildStatus` gained `failed`.
- Every build now stores the command line it ran (`command`).
- Ctrl-C during a build stops `flutter` and removes the unfinished folder
  (`InterruptGuard`).
- The build id is chosen before the build, so a duplicate id can no longer
  reject a finished build.
- **Changed:** `play.default_release_status` now defaults to `draft` (it was
  `completed`). The menu pre-selects draft, shows a summary before uploading,
  and the production track needs `production` typed to confirm. Set
  `default_release_status: completed` to keep the old behavior.
- **Changed:** `ProcessRunner.stream` has a new optional `logFile`; subclasses
  that override it must accept it. With a log file the output is copied to the
  console and the file, so `flutter` no longer sees a terminal for that run.
- CSV and TSV exports neutralize cells that start with `=`, `+`, `-`, `@`, a
  tab or a carriage return. They also gain the columns `target`, `command`,
  `failure_exit_code` and `play_edit_id` at the end.
- **Changed:** `config` shows `set (N chars)` for secrets instead of the
  first four characters.
- The menu warns when a delete removes the symbols of a build that was once
  published and then unmarked.

Command line and CI:

- New non-interactive commands: `build`, `publish`, `mark`, `symbols`,
  `trace` and `delete` (with `--dry-run`/`--yes`). They never prompt, accept
  `--json` and return stable exit codes (`ExitCodes`): 69 upload failed, 70
  build failed, 71 trace failed, 72 delete failed. The same code is available
  as `Cli` in the library. See `doc/ci.md`.
- `list` and `export` gained `--flavor`, `--status`, `--since` and `--limit`;
  `list --json` prints the rows; the table has a Status column.
- `list`, `export`, `mark` and `delete` work outside a Flutter project when
  `--ledger` is given. `export` creates missing parent folders.
- **Changed:** `init` exits 73 (was 1) when the config file exists.
- Output files are found without clocks: the output folders are snapshotted
  before `flutter build`, the `Built <path>` lines Flutter prints are used
  first, and otherwise the files that are new or changed are taken. A flavor
  must match a whole part of the file name (`pro` no longer matches
  `app-production-release.apk`). When several candidates are left and the
  build is not split per ABI the build fails with the list instead of guessing.
- GitHub Actions workflow: format, analyze and tests on Linux, macOS and
  Windows, plus a `pub publish --dry-run`.

Ledger, Google Play and library:

- The ledger takes a lock file around every change and re-reads the file
  first, so two processes no longer overwrite each other's rows. A bad ledger
  file blocks a write instead of being replaced. The first save of each day
  keeps a copy in `.history/` (seven days) next to the existing `.bak`.
  `Ledger` gained `lockWait` and `highestVersionCode`.
- Google Play: the track is read before it is changed. A staged or halted
  rollout is no longer dropped silently: the upload throws
  `PlayTrackInUseException` unless `replaceExisting` (`--replace-existing`)
  is set; the menu asks. `PlayPublisher` takes an `httpClient`, which is also
  what makes it testable with `package:http/testing.dart` (new direct
  dependency `http`).
- **Changed:** the library no longer exports the menu (`App`), the settings and
  launch.json screens, or `WindowsConsole`. `Cli` and `ExitCodes` are public.
- Config: `flutter_buildkit.local.yaml` is merged over the shared config.
  The shared file is now meant to be committed; auto-configuration offers to
  ignore the local overlay instead of the main file. The `flutter` command
  and string settings split on whitespace but honor quotes, so paths with
  spaces work (`splitCommandLine`).
- A warning is shown when the version code is not higher than one already in
  the ledger for the app (menu and `build`).
- Releases carry more provenance. `BuildRecord` gained `signing` (certificate
  SHA-256 and subject, read with `apksigner` or `keytool`; a warning when a
  release is debug-signed or differs from earlier releases of the package),
  `buildIds` (ELF build ids of the Dart symbols) and `environment` (OS, host,
  Flutter channel and revision, Dart SDK, engine, hash of the dart-define
  file). `trace auto` and the menu match a crash's `build_id` (or version) to
  a build and warn on a mismatch.
- Google Play pre-flight: `publish` stops before uploading when the version
  code is already on Play (any track) or the AAB is debug-signed.
  `PlayPublisher.checkAccess` backs `doctor --online`.
- New commands: `doctor` (tools, Play key, disk, output folder; exit 75),
  `verify` (ledger vs disk: files, hashes, symbols, orphans; exit 76) and
  `prune` (old logs, failed builds, uploaded symbols per `retention:`).
  `list`/`export` got `--bom`; the menu's CSV export writes a BOM for Excel.
- **Changed:** an upload to the `internal` track no longer makes a build
  immortal. What keeps symbols and the row on delete is
  `delete_policy.retain_on` (default `published, alpha, beta, production`;
  `play` restores "any upload"). Deleting a build that was published once and
  unmarked needs its id typed (menu) or `--force`.
- **Changed:** the ledger JSON stores `publishedAt`, `play` and
  `symbolUploads` at the top level; `status` is derived and ignored on load.
  Files from 0.1.x are still read, and a file saved by 0.2 keeps older tools
  working only for the derived fields.
- **Changed:** a config that names executables in the shared file
  (`flutter`, `*.cli`, `android.*`) must be trusted: the menu asks once, the
  non-interactive commands exit 78 until `--trust-config` / `FBK_TRUST_CONFIG=1`.
  Warnings for a Sentry token in the YAML and an un-ignored Play key inside
  the project. `AppConfig` gained `sharedCommands`, `warnings`, `retainOn`,
  `logRetentionDays` and `symbolsKeepLast`; new `ConfigTrust`.
- Mapping and native symbol folders are found by listing
  `outputs/mapping/`, so multi-dimension flavors (`devFreeRelease`) work.
- Docs: Crashlytics and the R8 mapping, Firebase auth in CI, trusting a
  config, provenance, verify and prune.
- Docs: README (install globally, `dart run flutter_buildkit:fbk`), new
  `doc/ci.md` and `doc/security.md`, config overlay and ledger lock.

## 0.1.2

- Added an `example/` folder with runnable examples by topic (library API,
  configuration, layouts and naming, ledger and exports, symbols and traces,
  VS Code and auto-configuration, CLI and prompts) and `example/README.md`.
- README rewritten: shorter, with a table of contents; the full reference moved
  to `doc/configuration.md`, `doc/project-setup.md` and
  `doc/builds-and-ledger.md`.
- Documented the library and `ConsoleAbort`, so every public symbol has docs.
- Fix: the command line now exits with its error code (64 usage, 66 no
  project, 74 ledger, 78 config); it always exited 0 before.
- Docs: `output_dir` does not expand `~`; use an absolute or relative path.

## 0.1.1

- README: install from pub.dev instead of git.

## 0.1.0

- First release.
- Interactive menu that builds APK, AAB and IPA files for any mix of flavors,
  entry points and modes, with optional `flutter clean`, `build_runner` and
  `flutter gen-l10n` first.
- JSON build ledger with status, condition and history per build; CSV and TSV
  export.
- Organised output folders and file names, configurable with layout presets
  or templates.
- Stores Dart, native and R8 mapping symbols; uploads them to Crashlytics and
  Sentry; traces crashes from the stored symbols.
- Google Play upload through the API, or marking a build uploaded or
  published in the ledger.
- Settings editor, auto-configuration from the project, and VS Code
  `launch.json` generation.
