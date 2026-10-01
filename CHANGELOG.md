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
