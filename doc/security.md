# Security notes

* **The config runs commands.** `flutter`, `crashlytics.cli`, `sentry.cli`,
  `android.retrace` and `android.ndk_stack` name programs the tool starts.
  Treat `flutter_buildkit.yaml` in a repository you cloned like a Makefile:
  read it before running the tool there.
* **Secrets.** Prefer environment variables (`PLAY_SERVICE_ACCOUNT_JSON`,
  `SENTRY_AUTH_TOKEN`). If a value must live in a file, use
  `flutter_buildkit.local.yaml` and keep it out of git. Keep the Play key file
  outside the project. `config` prints only `set (N chars)` for secrets. The
  Sentry token reaches `sentry-cli` through its environment, never on the
  command line.
* **What is sent where.** Google Play: the AAB, the R8 mapping (if enabled)
  and release notes, using the service account. Crashlytics and Sentry: the
  symbol files of the chosen build, through their own CLIs. Nothing else
  leaves the machine.
* **The ledger is a file you can edit.** Delete never trusts it blindly: paths
  must resolve (symlinks included) to a folder strictly inside the ledger's
  folder that holds the build's own `build_info.json`; see
  [Delete rules](builds-and-ledger.md#delete-rules).
* **Play uploads default to `draft`** and the production track needs explicit
  confirmation (`--yes` on the command line).
* **Stability.** The package is below 1.0, so a minor version can change the
  API or defaults. Each change is listed in the changelog; changes that alter
  behavior say so.
