# Continuous integration

Everything is driven by a single workflow, [`.github/workflows/build.yml`](../.github/workflows/build.yml).
The fork is developed locally and the workflow is **not** wired to commits - it runs nightly or on
demand. A workflow that fires on every push only burns the shared macOS runner pool, and seven full
builds per push is exactly what used to starve the queue.

## What runs when

| Event | Jobs |
|---|---|
| `schedule` (nightly) | all four test configurations (the Debug one also runs clang-format and clang-tidy), integration tests, DMG - **skipped when `main` has not moved since the last successful nightly** |
| `workflow_dispatch` | Debug tests with clang-format and clang-tidy, DMG; tick `full` to get the nightly set |

The `preflight` job runs first on `ubuntu-latest` (a few seconds, no macOS runner). For a scheduled
run it looks up the most recent **successful scheduled** run and compares its `head_sha` with the
current `github.sha`: if they are the same, the macOS jobs are skipped and the run ends after the
preflight. A manual dispatch always proceeds - it is a deliberate action. A nightly that failed or
was cancelled is not counted as "last successful", so a broken night is retried on the next day.

Trigger a run from the Actions tab (*Build and Test* → *Run workflow*) or with
`gh workflow run build.yml --ref main -f full=true`.

The nightly cron runs at **18:17 UTC**, deliberately not at the top of the hour: GitHub's schedule
queue is congested there, and the runs used to start hours late. Scheduled runs are also the first
thing affected by GitHub's Actions incidents, and a dropped night is not retried - if a nightly is
missing, trigger it by hand with `gh workflow run build.yml --repo cfanmaoli/nimble-commander
--ref main` and check `gh run list`.

A newer run on the same branch cancels the stale one (`concurrency`), and every job has a
`timeout-minutes` cap so a stuck build cannot hold a runner for an hour.

## Jobs

- **unit-tests** - `Scripts/run_all_unit_tests.sh <configuration>` builds the `UnitTests` umbrella
  and runs every test binary: `Debug`, `Release`, `ASAN`, `UBSAN`.
  The Debug job also builds the whole project (`All`) and keeps its compilation database when
  clang-tidy is going to run, so tidy does not need a second build of everything.
  It is the only job that installs LLVM, and it runs `Scripts/run_clang_format.sh --check` and
  clang-tidy itself - folding the linting in here means there is no separate gate job whose
  cancellation (e.g. when no runner can be acquired) would skip every other job.
- **clang-tidy** (inside the Debug job) - `Scripts/run_clang_tidy.sh --check --use-db run_all_unit_tests.tmp`,
  reusing the compilation database that the Debug build has just produced.
- **integration-tests** - starts the docker/colima dependencies and runs
  `Scripts/run_all_integration_tests.sh`.
- **build-unsigned** - `Scripts/build_unsigned.sh`, producing the `nimble-commander-fork-unsigned` DMG.
- **publish-nightly** - only on a scheduled run (or a manual dispatch with `publish_nightly` ticked):
  recreates the rolling [`nightly` pre-release](https://github.com/cfanmaoli/nimble-commander/releases/tag/nightly)
  with the freshly built DMG as `nimble-commander-fork-nightly.dmg` plus its `.sha256`, moves the
  `nightly` tag to the built commit, and writes the commit list since the previous nightly into the
  release notes. The DMG here is unsigned - the notes repeat the right-click-to-open caveat.

## Running the same checks locally

Install the tools once:

```sh
brew install llvm@23 jq
gem install xcpretty
export PATH="$(brew --prefix)/opt/llvm@23/bin:$PATH"
```

Then:

```sh
cd Scripts
./run_clang_format.sh --check

# clang-tidy exactly as CI runs it - builds the compilation database on the first run and
# reuses it afterwards, so a re-check after editing sources takes a few minutes
./check_tidy_local.sh

# the same, but only for the files touched by the branch
git diff --name-only origin/main...HEAD -- Source > /tmp/tidy-files.txt
./check_tidy_local.sh --files /tmp/tidy-files.txt

# unit tests, plus a compilation database for clang-tidy
EMIT_COMPILE_DB=1 ./run_all_unit_tests.sh Debug

# clang-tidy, reusing that database instead of rebuilding the project
./run_clang_tidy.sh --check --use-db run_all_unit_tests.tmp

# ... or only the files touched by a branch
git diff --name-only origin/main...HEAD -- Source > /tmp/tidy-files.txt
./run_clang_tidy.sh --check --use-db run_all_unit_tests.tmp --files /tmp/tidy-files.txt
```

Without `--use-db` the script builds the project itself first, which is handy when no database is
lying around yet.

## Tool versions

`XC_VERSION` and `LLVM_VERSION` live in the workflow's `env` block; the LLVM version is pinned on
purpose, since a newer `clang-format` can reformat untouched files and fail the check. Bump both
in one place when moving to a newer toolchain.

Homebrew downloads are cached between runs, and `brew update` is intentionally not called - it is
slow and it was the flakiest step of the old pipeline.

## The update feed

The non-MAS build checks for updates through Sparkle, which reads `SUFeedURL` from
`NimbleCommander-NonMAS-Info.plist`. It points at `appcast.xml` in the root of the `main` branch
of this repository, so the update check never reaches the upstream project. The checked-in appcast
has no items on purpose - the fork doesn't publish prebuilt binaries - so `Check for Updates`
reports that the installed version is the latest one. See [Release.md](Release.md) for what to do
if that policy ever changes.
