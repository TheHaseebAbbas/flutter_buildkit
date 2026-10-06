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
