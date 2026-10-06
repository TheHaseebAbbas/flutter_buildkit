# Using flutter_buildkit in CI and scripts

Besides the menu, every step has a command that never prompts, prints plain
text (or JSON with `--json`) and returns a stable exit code. Global options
(`-C`, `-c`, `--ledger`) work with all of them.

| Command | Does |
|---|---|
| `build --flavor dev,prod --type aab --mode release` | Builds every combination, one ledger row each. `--version-name`, `--build-number`, `--entry`, `--[no-]obfuscate`, `--split-per-abi`, `--arg`, `--skip-pre-build`, `--notes`. Defaults: type `apk`, mode `release`, version from `pubspec.yaml`. With flavors in the project, `--flavor` is required (`none` for no flavor). |
| `publish <id\|latest> --track internal` | Uploads the AAB through the Play API. `--release-status` (default from the config, `draft`), `--fraction`, `--notes`, `--notes-file`. The track is read first; a staged or halted rollout on it is not dropped unless you pass `--replace-existing`. `--mark-only` just records the upload. The `production` track needs `--yes`. |
| `mark <id...> [--clear]` | Marks builds as published in the ledger (or clears the mark). |
| `symbols <id\|latest> --to crashlytics,sentry` | Uploads debug symbols. Defaults to the tools enabled in the config. |
| `trace <id\|latest\|auto> --file crash.txt` | De-obfuscates a stack trace (stdin when no file). `auto` picks the build from the report's `build_id`. `--kind`, `--save`. |
| `delete <id...> --dry-run` / `--yes` | Deletes builds by the normal rules. Needs one of the two flags; a build that was published once and unmarked also needs `--force`. |
| `doctor [--online]` | Checks Flutter, git, JDK, Android SDK, `apksigner`, the CLIs, the Play key (`--online` tries it against Google Play), the output folder, disk space and the ledger. |
| `verify [--quick]` | Compares the ledger with the disk (files, hashes, symbols, orphan folders). |
| `prune --dry-run` / `--yes` | Applies the `retention` settings; `--log-days`, `--symbols-keep`. |
| `list`, `export <fmt> [file]` | `--flavor`, `--status`, `--since 7d`, `--limit`, `--json` (list), `--bom` (csv, for Excel). |

A config that names executables (`flutter: fvm flutter`, ...) in the shared file
must be trusted once: run with `--trust-config` or set `FBK_TRUST_CONFIG=1` in CI.

An id can be shortened to any unique prefix; `latest` is the newest build that
did not fail. `list`, `export`, `mark`, `delete`, `verify` and `prune` work with just
`--ledger <file>` outside a Flutter project.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Success |
| 64 | Usage: unknown command, option or id; delete without `--yes` |
| 66 | No Flutter project |
| 69 | An upload to Play, Crashlytics or Sentry failed |
| 70 | At least one build failed (the failed rows and `build.log` are kept) |
| 71 | A trace could not be de-obfuscated |
| 72 | A delete or prune was refused or failed |
| 73 | `init`: the config file already exists (was 1 before 0.2.0) |
| 74 | Ledger unreadable or invalid |
| 75 | `doctor` found a failing check |
| 76 | `verify` found differences between the ledger and the disk |
| 78 | Config invalid, or the config names executables you have not trusted (see `--trust-config`) |
| 130 | Interrupted with Ctrl-C |

With `--json`, stdout holds only the JSON document; build output and progress
go to stderr.

## GitHub Actions

```yaml
jobs:
  release:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: subosito/flutter-action@v2
        with:
          channel: stable
      - run: flutter pub get
      - run: dart pub global activate flutter_buildkit
      - name: Build
        run: fbk build --flavor prod --type aab --build-number ${{ github.run_number }} --json > build.json
      - name: Upload to the internal track
        env:
          PLAY_SERVICE_ACCOUNT_JSON: ${{ runner.temp }}/play.json
        run: |
          echo '${{ secrets.PLAY_KEY_JSON }}' > "$PLAY_SERVICE_ACCOUNT_JSON"
          fbk publish latest --track internal --release-status draft
      - uses: actions/upload-artifact@v4
        with:
          name: builds
          path: app_builds/
```

For GitLab CI or any other runner the same commands apply: install Flutter,
run `dart pub global activate flutter_buildkit`, then call `fbk`.

Install it globally in CI (as above) instead of as a dev dependency: it keeps
`googleapis` out of your app's dependency graph. Keep secrets in environment
variables (`PLAY_SERVICE_ACCOUNT_JSON`, `SENTRY_AUTH_TOKEN`), not in the YAML.
For Crashlytics uploads the `firebase` CLI needs credentials in CI: set
`GOOGLE_APPLICATION_CREDENTIALS` or pass a token as Firebase documents.
