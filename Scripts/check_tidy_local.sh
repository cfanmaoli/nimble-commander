#!/bin/bash
# Runs the same clang-tidy gate as CI, locally. The compilation database is built once and then
# reused, so a re-check after editing sources only pays for clang-tidy itself (a few minutes).
#
#   Scripts/check_tidy_local.sh              # check everything
#   Scripts/check_tidy_local.sh --rebuild    # throw the database away and build it again
#   Scripts/check_tidy_local.sh --files list # check only the files in the given list
#
# Requires clang-tidy/run-clang-tidy from LLVM 23 and xcpretty:
#   brew install llvm@23
#   gem install --user-install xcpretty
set -euo pipefail

SCRIPTS_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
ROOT_DIR=$(cd "${SCRIPTS_DIR}/.." && pwd)
BUILD_DIR="${SCRIPTS_DIR}/run_all_unit_tests.tmp"
DB="${BUILD_DIR}/compile_commands.json"

if [ -d "${LLVM_DIR:-}" ]; then
    export PATH="${LLVM_DIR}/bin:${PATH}"
elif [ -d "$(brew --prefix llvm@23 2>/dev/null || echo /nonexistent)" ]; then
    export PATH="$(brew --prefix llvm@23)/bin:${PATH}"
fi
export PATH="${HOME}/.gem/ruby/2.6.0/bin:${PATH}"

for tool in clang-tidy run-clang-tidy xcpretty; do
    if ! command -v "${tool}" >/dev/null 2>&1; then
        echo "${tool} is not found - install LLVM 23 and xcpretty first" >&2
        exit 1
    fi
done

rebuild=0
files_arg_count=0
files_arg=()
while [ $# -gt 0 ]; do
    case "$1" in
        --rebuild) rebuild=1 ;;
        --files) shift; files_arg=(--files "$1"); files_arg_count=1 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
    shift
done

if [ "${rebuild}" -eq 1 ] || ! [ -f "${DB}" ]; then
    echo "Building the compilation database in ${BUILD_DIR}"
    rm -rf "${BUILD_DIR}"
    mkdir -p "${BUILD_DIR}"
    ( cd "${SCRIPTS_DIR}" && xcodebuild \
        -project ../Source/NimbleCommander/NimbleCommander.xcodeproj \
        -scheme All -configuration Debug \
        -destination "platform=macOS,arch=$(uname -m)" \
        SYMROOT="${BUILD_DIR}" OBJROOT="${BUILD_DIR}" \
        -parallelizeTargets COMPILER_INDEX_STORE_ENABLE=NO build |
        xcpretty -r json-compilation-database --output "${DB}" )
fi

cd "${SCRIPTS_DIR}"
if [ ${files_arg_count} -gt 0 ]; then
    exec ./run_clang_tidy.sh --check --use-db run_all_unit_tests.tmp "${files_arg[@]}"
else
    exec ./run_clang_tidy.sh --check --use-db run_all_unit_tests.tmp
fi
