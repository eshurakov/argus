# Releasing a feature

A feature release increments the minor version. A bugfix release increments the patch version. For example, a
feature completed after `1.0.0` is released as `1.1.0` and tagged `v1.1.0`; a later bugfix is `1.1.1` and `v1.1.1`.

Run the release from `main`. Do not mix unrelated work into the release commits.

## 1. Prepare the version

`VERSION` is the canonical machine-readable version manifest. Prepare the next release with:

```sh
./scripts/release.sh prepare minor
./scripts/release.sh prepare patch
```

`prepare minor` increments the minor semantic version and resets the patch version to zero. `prepare patch`
increments the patch version. Both increment the build number, synchronize `project.yml` and `ArgusCLI/main.swift`,
regenerate the Xcode project, and verify every generated consumer. For a release from version `1.0.0` with build
number `1`, `prepare minor` prepares version `1.1.0` and build number `2`.

Do not edit generated version consumers independently or edit `Argus.xcodeproj/project.pbxproj` by hand. Run
`python3 scripts/version.py verify` to check consistency without changing files.

## 2. Verify the release

Confirm that `docs/SPEC.md` describes the feature being released, then run:

```sh
./scripts/release.sh verify
```

Verification runs version consistency, lint, app tests, Companion CLI checks, `git diff --check`, the Release build,
and built-artifact validation as independent bounded stages. Complete output and the app-test `.xcresult` are retained
under `.build/release-diagnostics/<timestamp>-<pid>/`. A timeout fails the stage, terminates its process group, and reports
the diagnostic path; printed test success never overrides a process that did not exit successfully.

Resolve failures before committing. Review `git status` and `git diff` to make sure the release contains only the
intended feature, its tests and documentation, and the version changes.

## 3. Commit the feature

Commit the verified feature and version changes:

```sh
git add <feature-files> VERSION project.yml Argus.xcodeproj/project.pbxproj ArgusCLI/main.swift
git commit -m "Release turn completion notifications"
```

Use a commit message that names the feature when releasing something else. Record the resulting commit SHA for the
changelog.

## 4. Add the changelog entry

Add a new section at the top of `CHANGELOG.md`. Use the release date as a `YYYY-MM-DD` heading, without the version
number. Describe the user-visible change in plain English and link to the feature commit:

```md
## 2026-07-25

- Argus now shows and sounds an alert when a Kilo turn finishes outside the active tab. ([abc1234](https://github.com/jeanduplessis/argus/commit/abc1234))
```

Commit the changelog separately so it can link to the already-created feature commit:

```sh
git add CHANGELOG.md
git commit -m "Update changelog for 1.1.0"
```

## 5. Tag and push

Check the release identity and working tree before publishing:

```sh
git status --short
git log --oneline origin/main..HEAD
git tag --list "v1.1.0"
```

The working tree must be clean, and the tag must not already exist. Create an annotated tag on the changelog commit:

```sh
git tag -a v1.1.0 -m "Argus 1.1.0"
```

Push `main` first, then the exact release tag:

```sh
git push origin main
git push origin v1.1.0
```

Do not use `git push --tags`; it may publish unrelated local tags. Confirm the remote commit and tag after both pushes
finish.

## 6. Optional local installation

The Git release does not install the app. Follow `docs/RELEASING.md` to install the validated Release build in
`/Applications`.
