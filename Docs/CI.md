# Continuous integration

Everything is driven by a single workflow, [`.github/workflows/build.yml`](../.github/workflows/build.yml).
The heavy jobs are deliberately kept off the everyday push path - GitHub's macOS runner pool is limited
and a pipeline that takes seven full builds per push starves the queue.

## What runs when

| Event | Jobs |
|---|---|
| `push` | clang-format, unit tests (Debug), unsigned DMG |
| `pull_request` | clang-format, unit tests (Debug + Release), clang-tidy (touched files only) |
| `schedule` (nightly) | everything: all four test configurations, full clang-tidy, integration tests, DMG |
| `workflow_dispatch` | same as push; tick `full` to get the nightly set |

A newer push to the same branch cancels the stale run (`concurrency`), and every job has a
`timeout-minutes` cap so a stuck build cannot hold a runner for an hour.

## Jobs

- **clang-format** - installs LLVM and runs `Scripts/run_clang_format.sh --check` over `Source`.
- **unit-tests** - `Scripts/run_all_unit_tests.sh <configuration>` builds the `UnitTests` umbrella
  and runs every test binary: `Debug`, `Release`, `ASAN`, `UBSAN`.
  The Debug job also builds the whole project (`All`) and keeps its compilation database when
  clang-tidy is going to run, so tidy does not need a second build of everything.
- **clang-tidy** (inside the Debug job) - `Scripts/run_clang_tidy.sh --check --use-db run_all_unit_tests.tmp`.
  On pull requests only the touched translation units are analysed; if a header changed, everything
  is analysed instead.
- **integration-tests** - starts the docker/colima dependencies and runs
  `Scripts/run_all_integration_tests.sh`.
- **build-unsigned** - `Scripts/build_unsigned.sh`, producing the `nimble-commander-fork-unsigned` DMG.

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
