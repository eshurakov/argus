# Releasing a feature

A feature release increments the minor version. For example, a feature completed after `1.0.0` is released as
`1.1.0` and tagged `v1.1.0`.

Run the release from `main`. Do not mix unrelated work into the release commits.

## 1. Prepare the version

Update every version source:

- Set `MARKETING_VERSION` in `project.yml` to the new semantic version.
- Increment `CURRENT_PROJECT_VERSION` in `project.yml` by one.
- Set the CLI version in `ArgusCLI/main.swift` to the same semantic version.
- Update the CLI version assertion in `scripts/test.sh`.

For a release from version `1.0.0` with build number `1`, use version `1.1.0` and build number `2`.

Regenerate the Xcode project after changing `project.yml`:

```sh
./scripts/build.sh generate
```

Do not edit `Argus.xcodeproj/project.pbxproj` by hand. Confirm that the generated project contains the new
`MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` values.

## 2. Verify the release

Confirm that `docs/SPEC.md` describes the feature being released, then run:

```sh
./scripts/test.sh
git diff --check
./scripts/build.sh build --release --no-open
```

Resolve failures before committing. Review `git status` and `git diff` to make sure the release contains only the
intended feature, its tests and documentation, and the version changes.

## 3. Commit the feature

Commit the verified feature and version changes:

```sh
git add <feature-files> project.yml Argus.xcodeproj/project.pbxproj ArgusCLI/main.swift scripts/test.sh
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
