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
