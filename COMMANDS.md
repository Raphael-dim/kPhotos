# COMMANDS.md — kPhotos cheatsheet

All the commands you need to develop, build, test and debug kPhotos on the iOS
simulator. Quick reference — details and overridable flags live in the
[Makefile](Makefile).

> Convention: `SIMULATOR` defaults to `iPhone 17`. To target another available
> simulator, prefix the command: `SIMULATOR="iPhone 16e" make run-sim`.

---

## 1. Daily workflow

| What | Command | When |
|---|---|---|
| Build + boot sim + install + launch | `make run-sim` | You just changed code and want to see the result |
| Open Xcode (then ⌘R) | `make open` | You'd rather use Xcode for debugging / breakpoints |
| Re-generate the project | `make generate` | You **added/removed a file or a target** (Tuist scans globs at generate time, not at build) |
| Build without launching | `make build` | You just want to check that it compiles |
| Unit tests | `make test` | Before a commit |
| Strict lint | `make lint` | Before a commit |
| Auto-format | `make format` | Before a commit |
| Clean | `make clean` | Weird symptoms, inconsistent builds |

### Special case: you only **edited** an existing file

No need for `make generate`. `make run-sim` (or ⌘R) is enough — Xcode
recompiles what changed.

### Special case: you **added a new `.swift` file**

```bash
make generate && make run-sim
```

Without `generate`, Tuist hasn't seen the new file and it won't appear in the
target → "cannot find type X in scope" compilation error.

---

## 2. First launch / new machine

```bash
make setup       # installs tuist, swiftlint, swiftformat, periphery via mise
make install     # tuist install — resolves SPM packages (3–5 min, ~150 MB)
make generate    # produces kPhotos.xcworkspace
make run-sim     # build and launch
```

Or all at once:

```bash
make setup && make generate && make run-sim
```

---

## 3. Simulator — useful commands

```bash
# List available simulators
xcrun simctl list devices available | grep iPhone

# Boot a simulator without building
xcrun simctl boot "iPhone 17"
open -a Simulator

# Kill the app without restarting the simulator
xcrun simctl terminate booted app.kphotos

# Uninstall the app (useful to reset Realm + photo permissions)
xcrun simctl uninstall booted app.kphotos

# Full reset of the simulator (erases everything)
xcrun simctl erase "iPhone 17"

# Launch the already-installed app
xcrun simctl launch booted app.kphotos

# Launch with console logs attached
xcrun simctl launch --console booted app.kphotos
```

---

## 4. Logs and debugging

```bash
# Stream the app's logs in real time
xcrun simctl spawn booted log stream --predicate 'process == "kPhotos"' --style compact

# Logs from the last 5 minutes
xcrun simctl spawn booted log show --last 5m --predicate 'process == "kPhotos"' --style compact

# Find the app container (useful to inspect Realm)
xcrun simctl get_app_container booted app.kphotos data

# Open the data folder in Finder
open "$(xcrun simctl get_app_container booted app.kphotos data)/Library/Application Support"
```

---

## 5. Quick reset by symptom

| Symptom | Reflex |
|---|---|
| "cannot find type" on a file you just added | `make generate` |
| Corrupted Realm / schema mismatch | `xcrun simctl uninstall booted app.kphotos` then `make run-sim` |
| Blocked photo permissions | Simulator Settings → kPhotos → allow, OR uninstall |
| Inconsistent build after merge / branch switch | `make clean && make generate && make run-sim` |
| `tuist install` fails | `rm -rf Tuist/.build && make install` |
| Broken SPM cache | `rm -rf ~/Library/Caches/org.swift.swiftpm && make install` |
| Xcode is stuck | `killall Xcode` ; `make open` |

---

## 6. Targeted tests

```bash
# Full suite
make test

# A single test class
xcodebuild test \
  -workspace kPhotos.xcworkspace \
  -scheme kPhotos \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:kPhotosTests/TimelineManagerTests

# A single test method
xcodebuild test \
  -workspace kPhotos.xcworkspace \
  -scheme kPhotos \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:kPhotosTests/TimelineManagerTests/testGroupByYearMonth_ordersSectionsByTakenAtDesc
```

---

## 7. Git — conventional workflow

```bash
# Conventional Commits (cf. AGENTS.md §13)
git commit -m "feat(timeline): show device library count"
git commit -m "fix(realm): create application support dir before opening realm"
git commit -m "refactor(core): extract PhotoReading / PhotoWriting protocols"
```

Common scopes: `app`, `core`, `coreui`, `features`, `timeline`, `albums`,
`upload`, `sync`, `widget`, `share`, `ci`, `deps`, `agents`.

---

## 8. Tuist / SPM maintenance

```bash
# View the dependency graph
tuist graph

# Force re-resolution with a new package version
# (edit Tuist/Package.swift, then:)
rm -rf Tuist/.build && make install && make generate

# Check the effective Tuist version
tuist version    # must match .mise.toml

# Update the tools declared in .mise.toml
mise upgrade
```

---

## 9. "I want to..." cheatsheet

| I want to... | I do... |
|---|---|
| ...see the app after a Swift change | `make run-sim` |
| ...add a new file | create the file, then `make generate && make run-sim` |
| ...debug with breakpoints | `make open` then ⌘R in Xcode |
| ...start from a clean state | `make clean && make generate` |
| ...wipe Realm without rebuilding | `xcrun simctl uninstall booted app.kphotos` |
| ...watch logs live | `xcrun simctl spawn booted log stream --predicate 'process == "kPhotos"'` |
| ...switch simulator | `SIMULATOR="iPhone 16e" make run-sim` |
| ...run the tests | `make test` |
