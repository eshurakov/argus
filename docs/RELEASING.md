# Releasing Argus locally

Argus is a personal application and has no public distribution pipeline. A release is a validated Release build installed locally in `/Applications`.

## Version sources

Application version and build number are defined in `project.yml`:

- `MARKETING_VERSION`
- `CURRENT_PROJECT_VERSION`

The CLI version in `ArgusCLI/main.swift` must match the application version. `scripts/test.sh` verifies the expected CLI version string.

## Release checklist

1. Confirm `docs/SPEC.md` describes the behavior being released.
2. Update the version values when the release identity changes.
3. Run:

   ```sh
   ./scripts/test.sh
   git diff --check
   ```

5. Build without launching:

   ```sh
   ./scripts/build.sh build --release --no-open
   ```

6. Add a dated entry to `CHANGELOG.md` before pushing release changes. Link the final commit after it exists.
7. Install and launch the validated build:

   ```sh
   ./scripts/build.sh install --release
   ```

The script bundles the CLI scaffold, ad-hoc signs the application, asks a running Argus instance to quit, replaces `/Applications/Argus.app`, and launches the new copy.

## Limitations

- The build is ad-hoc signed and is intended for local use.
- There is no notarization, package, update feed, or rollback automation.
- Install replaces the existing application after the quit grace period.
- The build script does not check whether coding-agent processes are running.
- Normal application termination saves the Session Snapshot, but forced termination after the quit timeout may lose state changed since the last save.
