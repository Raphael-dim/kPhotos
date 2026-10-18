# Development commands

The [Makefile](Makefile) is the source of truth. Run commands from the repository root.

| Purpose | Command |
| --- | --- |
| Install pinned tools | `make setup` |
| Resolve packages and apply the reviewed Realm compatibility shim | `make install` |
| Generate the workspace after adding/removing source files | `make generate` |
| Open Xcode | `make open` |
| Build / run simulator | `make build` / `make run-sim` |
| Choose a simulator | `make run-sim SIMULATOR="iPhone 16e"` |
| Run tests | `make test` |
| Verify GPL headers, formatting and lint | `make check-headers format-check lint-ci` |
| Apply formatting | `make format` |
| Scan for unused code | `make dead-code` |
| Scan publishable files for secrets | `make check-secrets` |
| Refresh official kDrive API reference | `./scripts/update_api_doc.sh` |
| Remove generated build files | `make clean` |

## First launch and daily changes

```sh
make setup
make generate
make run-sim
```

`make generate` already runs dependency installation. The first resolution downloads the packages and may take several minutes.
After editing an existing file, use `make build`, `make run-sim` or Run in Xcode.
After adding/removing a source file, resource or target, regenerate first: Tuist discovers files when generating the workspace.
`SIMULATOR` defaults to `iPhone 17`; `SCHEME` defaults to `kPhotos`.

## Targeted tests

Run a single test class:

```sh
xcodebuild test -workspace kPhotos.xcworkspace -scheme kPhotos \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:kPhotosTests/TimelineManagerTests
```

Add `/testMethodName` to the `-only-testing` value to run one method. Use an actual method name from the test class.
Run the relevant suite again after changing production behavior; full tests remain a pre-PR check.

## Simulator lifecycle and diagnostics

These commands target the currently booted simulator. Use `xcrun simctl list devices available` to identify a specific device
when more than one is booted, then replace `booted` with its identifier.

```sh
xcrun simctl list devices available
xcrun simctl boot "iPhone 17"
open -a Simulator
xcrun simctl terminate booted app.kphotos
xcrun simctl launch booted app.kphotos
xcrun simctl launch --console booted app.kphotos
```

The launch command runs the already-installed build; it does not compile changes.
For logs and container inspection:

```sh
xcrun simctl spawn booted log stream --predicate 'process == "kPhotos"' --style compact
xcrun simctl spawn booted log show --last 5m --predicate 'process == "kPhotos"' --style compact
xcrun simctl get_app_container booted app.kphotos data
```

Logs and container contents can contain private data. Keep exports outside Git, preferably in ignored `.local/`.
Inspect app data with the app stopped; do not edit a live Realm or copy auxiliary pipes as ordinary files.

## Troubleshooting without losing app data

| Symptom | First action |
| --- | --- |
| Newly added type/resource is missing | `make generate`, then rebuild |
| Missing workspace/dependencies | `make generate`; inspect the installation error if it fails |
| Stale build after a merge or target change | `make clean`, then `make generate` and rebuild |
| Photo permission is limited/denied | Check the simulator/device Photos settings for kPhotos |
| Keychain failure on simulator | Check ad-hoc signing; do not disable signing |
| Realm schema, corruption or decryption error | Preserve the database and diagnose migration/key access before changing anything |
| Dependency install or Realm shim fails | Check the lockfile, installed tool versions and upstream compatibility before clearing caches |

`make clean` removes project build/generated files; it does not reset the installed app container or its Keychain.
Uninstalling an app or erasing a simulator destroys local test data. Reserve those actions for an explicitly disposable test environment,
never as the default repair for a real library or an unknown Realm error.

## Tuist, SPM and tool maintenance

```sh
mise exec -- tuist version
mise exec -- tuist graph
```

Change a package constraint in `Tuist/Package.swift` only after reviewing release notes, advisories and licensing.
Resolve with `make install`, regenerate with `make generate`, and inspect the changes in `Tuist/Package.resolved`.
If the existing lock satisfies the constraint, installation may retain the locked version; a deliberate upgrade needs an explicit
constraint/update decision, not deleting the lockfile and accepting arbitrary versions.
For Realm, inspect `scripts/prepare_realm.py` and validate migration/encryption as well as compilation.

For tool upgrades, edit the pinned version in `.mise.toml`, run `make setup`, and verify checks with that version.
Do not replace pinned versions with an unreviewed blanket tool upgrade.

## Commit and API checks

Commit format, scopes and review requirements live in [AGENTS.md](AGENTS.md#conventional-commits) and [WORKFLOW.md](WORKFLOW.md).
Public pull requests follow [CONTRIBUTING.md](CONTRIBUTING.md).

API probes in `scripts/api_test*.sh` perform real writes and cleanup; use only a disposable test folder and never publish their output.
