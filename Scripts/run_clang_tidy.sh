#!/bin/sh

set -e
set -o pipefail

if ! [ -x "$(command -v xcpretty)" ] ; then
    echo 'xcpretty is not found, aborting. (https://github.com/xcpretty/xcpretty)'
    exit -1
fi

if ! [ -x "$(command -v clang-tidy)" ] ; then
    echo 'clang-tidy is not found, aborting. Do brew install llvm.'
    exit -1
fi

if ! [ -x "$(command -v jq)" ] ; then
    echo 'jq is not found, aborting. Do brew install jq.'
    exit -1
fi

# https://github.com/xcpretty/xcpretty/issues/48
export LC_CTYPE=en_US.UTF-8

# Determine the host architecture
HOST_ARCH=$(uname -m)

# Tools from LLVM, wherever the installed LLVM keg lives (it may be a versioned one)
LLVM_BIN_DIR=$(dirname "$(command -v clang-tidy)")
RUNTIDY="${LLVM_BIN_DIR}/run-clang-tidy"
TIDY="${LLVM_BIN_DIR}/clang-tidy"
APPLY="${LLVM_BIN_DIR}/clang-apply-replacements"

# Get current directory
SCRIPTS_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
ROOT_DIR=$(cd "$SCRIPTS_DIR/.." && pwd)

# Usage: run_clang_tidy.sh [--check] [--use-db <dir>] [--files <list>]
check_mode=0
use_db=""
files_list=""
while [ $# -gt 0 ]; do
    case "$1" in
        --check)
            echo "Dry run - only checking the clang-tidy rules"
            check_mode=1
            ;;
        --use-db)
            shift
            use_db="$1"
            ;;
        --files)
            shift
            files_list="$1"
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit -1
            ;;
    esac
    shift
done

if [ -n "${use_db}" ]; then
    # Reuse the compilation database that run_all_unit_tests.sh has produced, instead of
    # rebuilding the whole project just to obtain one.
    BUILD_DIR="${use_db}"
    DB_DIR="${BUILD_DIR}"
    if ! [ -f "${DB_DIR}/compile_commands.json" ] ; then
        echo "No compile_commands.json found in ${DB_DIR}, aborting." >&2
        exit -1
    fi
    echo "Reusing the compilation database in ${DB_DIR}"
else
    # Allocate a dir for build artifacts
    BUILD_DIR="${SCRIPTS_DIR}/run_clang_tidy.tmp"
    DB_DIR="${SCRIPTS_DIR}"
    mkdir -p "${BUILD_DIR}"
    xattr -w com.apple.xcode.CreatedByBuildSystem true "${BUILD_DIR}"

    # A project to build
    XCODEPROJ="${ROOT_DIR}/Source/NimbleCommander/NimbleCommander.xcodeproj"

    echo Building the target "All"

    # Common invocation of xcodebuild
    XC="xcodebuild \
     -project ${XCODEPROJ} \
     -scheme All \
     -configuration Debug \
     -destination "platform=macOS,arch=${HOST_ARCH}" \
     SYMROOT=${BUILD_DIR} \
     OBJROOT=${BUILD_DIR} \
     -parallelizeTargets \
     ONLY_ACTIVE_ARCH=YES \
     COMPILER_INDEX_STORE_ENABLE=NO"

    # Clean everything first
    ${XC} clean

    # Build the target and capture the invocation command
    $XC build | xcpretty -r json-compilation-database --output "${DB_DIR}/compile_commands.json"
fi

# Remove the "-ivfsstatcache path" flags that clang-tidy doesn't understand
sed -i '' 's/-ivfsstatcache[^"]*\.sdkstatcache//g' "${DB_DIR}/compile_commands.json"

# Likewise for the indexing/ diagnostics options that some builds leave behind - clang-tidy parses
# the command line itself and rejects anything unknown.
python3 - "${DB_DIR}/compile_commands.json" <<'PYTHON'
import json
import re
import sys

path = sys.argv[1]
unwanted = [
    r"-{1,2}index-store-path \S+",
    r"-{1,2}index-unit-output-path \S+",
    r"-{1,2}gen-cdb-fragment-path \S+",
]
with open(path) as file:
    database = json.load(file)
for entry in database:
    command = entry["command"]
    for pattern in unwanted:
        command = re.sub(pattern, "", command)
    entry["command"] = re.sub(r"\s+", " ", command).strip()
with open(path, "w") as file:
    json.dump(database, file, indent=1)
PYTHON

# Extract all unique response files into an array, removing the '@' symbol
response_files=($(jq -r '.[].command' "${DB_DIR}/compile_commands.json" | grep -o '@[^ ]*' | sed 's/^@//' | sort | uniq))
# Process each response file
for file in "${response_files[@]}"; do
  # Use sed to modify the file in-place and remove -fmodules and -fmodules-cache-path=...
  sed -i '' -E "s/'?-fmodules-cache-path=[^ ]+'?//g; s/'?-fmodules'?//g" "$file"
done

# Find all files ending with "-Swift.h" and search for "@import" statements
find "$BUILD_DIR" -type f -name '*-Swift.h' | while read file; do
  # Use sed to comment out the lines in place
  sed -i '' -E 's/^(@import [A-Za-z]+;)/\/\/ \1/' "$file"
done

# Optionally narrow the analysis down to a list of files, e.g. the ones touched by a pull request
TIDY_DB_DIR="${DB_DIR}"
if [ -n "${files_list}" ]; then
    if ! [ -s "${files_list}" ] ; then
        echo "The file list ${files_list} is empty - nothing to check."
        exit 0
    fi
    FILTERED_DB_DIR="${BUILD_DIR}/filtered-compile-db"
    mkdir -p "${FILTERED_DB_DIR}"
    python3 - "${DB_DIR}/compile_commands.json" "${files_list}" "${ROOT_DIR}" "${FILTERED_DB_DIR}/compile_commands.json" <<'PYTHON'
import json
import os
import sys

database_path, list_path, root, output_path = sys.argv[1:]
with open(database_path) as file:
    database = json.load(file)
wanted = set()
with open(list_path) as file:
    for line in file:
        line = line.strip()
        if line:
            wanted.add(os.path.normpath(os.path.join(root, line)))
selected = [entry for entry in database if os.path.normpath(entry["file"]) in wanted]
with open(output_path, "w") as file:
    json.dump(selected, file, indent=1)
print(f"Restricted the compilation database to {len(selected)} of {len(database)} entries.")
PYTHON
    TIDY_DB_DIR="${FILTERED_DB_DIR}"
fi

if [ "$(jq length "${TIDY_DB_DIR}/compile_commands.json")" = "0" ] ; then
    echo "No compilation units left to check."
    exit 0
fi

# Log file to capture the output of run-clang-tidy
LOG_FILE="${BUILD_DIR}/run-clang-tidy.log"

# Run clang-tidy in parallel via run-clang-tidy
if [ $check_mode -eq 1 ]; then
    echo "Running in check mode. No fixes will be applied."
    ${RUNTIDY} \
     -p ${TIDY_DB_DIR} \
     -config-file ${ROOT_DIR}/Source/.clang-tidy \
     -clang-tidy-binary ${TIDY} \
     -clang-apply-replacements-binary ${APPLY} \
     -j $(sysctl -n hw.activecpu) \
     -use-color 1 \
     "${ROOT_DIR}/Source/.*" 2>&1 | tee ${LOG_FILE}
else
    echo "Running in fix mode. Fixes will be applied."
    ${RUNTIDY} \
     -p ${TIDY_DB_DIR} \
     -config-file ${ROOT_DIR}/Source/.clang-tidy \
     -clang-tidy-binary ${TIDY} \
     -clang-apply-replacements-binary ${APPLY} \
     -j $(sysctl -n hw.activecpu) \
     -use-color 1 \
     -fix \
     -format \
     "${ROOT_DIR}/Source/.*" 2>&1 | tee ${LOG_FILE}
fi

# Exit with non-zero if in check mode and any issues were found
if [ $check_mode -eq 1 ]; then
    if grep -q "warning:" ${LOG_FILE} || grep -q "error:" ${LOG_FILE}; then
        echo "Clang-tidy check failed. Please run Scripts/run_clang_tidy.sh before submitting your code."
        exit 1
    else
        echo "Clang-tidy check passed."
        exit 0
    fi
fi
