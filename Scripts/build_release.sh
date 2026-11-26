#!/bin/sh

# Packaging for a signed release. The app itself (and the privileged helper inside it) is signed by
# the Xcode archive/export with the NonMAS configuration's identity - by default the maintainer's
# Apple Development certificate of team 359W39ZS37, which is enough for Administrator Mode.
# Distribution-related signing is opt-in: set NC_CODESIGN_IDENTITY to the identity that should sign
# the DMG and NC_NOTARY_PROFILE to a 'notarytool' keychain profile (see
# 'xcrun notarytool store-credentials'). Without them the DMG is not signed/notarised, and the
# script says so at the end.

set -e
set -o pipefail

if ! [ -x "$(command -v xcpretty)" ] ; then
    echo 'xcpretty is not found, aborting. (https://github.com/xcpretty/xcpretty)'
    exit -1
fi

if ! [ -x "$(command -v create-dmg)" ] ; then
    echo 'create-dmg is not found, aborting. (https://github.com/create-dmg/create-dmg)'
    exit -1
fi

# https://github.com/xcpretty/xcpretty/issues/48
export LC_CTYPE=en_US.UTF-8

PBUDDY=/usr/libexec/PlistBuddy

# Set up the paths to the sources and artifacts
SCRIPTS_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
ROOT_DIR=$(cd "$SCRIPTS_DIR/.." && pwd)
XCODEPROJ="${ROOT_DIR}/Source/NimbleCommander/NimbleCommander.xcodeproj"
CODESIGN_IDENTITY="${NC_CODESIGN_IDENTITY:-}"
NOTARY_PROFILE="${NC_NOTARY_PROFILE:-}"
# The default export options reference a provisioning profile by name - point NC_EXPORT_OPTIONS at
# your own file when signing with a different one.
EXPORT_OPTIONS="${NC_EXPORT_OPTIONS:-${SCRIPTS_DIR}/export_options.plist}"
EXPECTED_TEAM="${NC_EXPECTED_TEAM_ID:-359W39ZS37}"
BUILD_DIR="${SCRIPTS_DIR}/build_release.tmp"
ARCHIVE_PATH="${BUILD_DIR}/NC_NonMAS.xcarchive"
BUILT_PATH="${BUILD_DIR}/built"
# A release must be built from a clean, tagged commit: otherwise the DMG and the tag may point at
# different trees.
RELEASE_TAG=$(git -C "${ROOT_DIR}" describe --tags --exact-match HEAD 2>/dev/null || true)
if [ -z "${RELEASE_TAG}" ]; then
    echo 'HEAD is not tagged. Create and check out the release tag before building.' >&2
    exit 1
fi
if [ -n "$(git -C "${ROOT_DIR}" status --porcelain --untracked-files=no)" ]; then
    echo 'The working tree has tracked modifications. Commit or stash them before building.' >&2
    exit 1
fi

mkdir -p "${BUILD_DIR}"
mkdir -p "${ARCHIVE_PATH}"

# Build Help.pdf and copy it into the NC sources
${SCRIPTS_DIR}/build_help.sh
cp -f "${SCRIPTS_DIR}/build_help.tmp/Help.pdf" "${ROOT_DIR}/Source/NimbleCommander/NimbleCommander/Resources/Help.pdf"

# Gather common flags in the XC variable
XC="xcodebuild \
 -project ${XCODEPROJ} \
 -scheme NimbleCommander-NonMAS \
 -configuration Release \
 OTHER_CFLAGS=\"-fdebug-prefix-map=${ROOT_DIR}=.\""

# Build and archive the project
$XC -archivePath ${ARCHIVE_PATH} archive | xcpretty

# Export a signed version
xcodebuild -exportArchive \
 -archivePath $ARCHIVE_PATH \
 -exportPath $BUILT_PATH \
 -exportOptionsPlist "${EXPORT_OPTIONS}"

# Extract the version number and the build number
APP_NAME=$($XC -showBuildSettings | grep " FULL_PRODUCT_NAME =" | sed -e 's/.*= *//' )
APP_PATH="${BUILT_PATH}/${APP_NAME}"
VERSION=$( $PBUDDY -c "Print CFBundleShortVersionString" "${APP_PATH}/Contents/Info.plist" )
BUILD=$( $PBUDDY -c "Print CFBundleVersion" "${APP_PATH}/Contents/Info.plist" )
TAG_VERSION="${RELEASE_TAG#v}"
if [ "${VERSION}" != "${TAG_VERSION}" ]; then
    echo "The app version (${VERSION}) does not match the release tag (${RELEASE_TAG})." >&2
    exit 1
fi

# The archived app must be signed by the expected team; an export that silently falls back to an
# unsigned app must not be published.
codesign --verify --deep --strict "${APP_PATH}"
ACTUAL_TEAM=$(codesign -dv --verbose=4 "${APP_PATH}" 2>&1 | sed -n 's/^TeamIdentifier=//p' | head -n 1 || true)
if [ "${ACTUAL_TEAM}" != "${EXPECTED_TEAM}" ]; then
    echo "Unexpected signing team: '${ACTUAL_TEAM}' (expected '${EXPECTED_TEAM}')." >&2
    exit 1
fi

DMG_NAME="nimble-commander-fork-${VERSION}(${BUILD}).dmg"

# Wrap the built application into a .dmg disk image
set -- \
 --volname "Nimble Commander-Fork" \
 --window-pos 200 200 \
 --window-size 610 386 \
 --background "dmg/background.png" \
 --text-size 12 \
 --icon-size 128 \
 --icon "${APP_NAME}" 176 192 \
 --app-drop-link 432 192
if [ -n "${CODESIGN_IDENTITY}" ]; then
    set -- "$@" --codesign "${CODESIGN_IDENTITY}"
fi
create-dmg "$@" "${DMG_NAME}" "${APP_PATH}"

if [ -n "${NOTARY_PROFILE}" ]; then
    # Upload the built dmg into Apple's notary service and wait for the response, then staple it.
    xcrun notarytool submit "${DMG_NAME}" --keychain-profile "${NOTARY_PROFILE}" --wait
    xcrun stapler staple "${DMG_NAME}"
else
    echo 'NC_NOTARY_PROFILE is not set - the DMG was not notarised.'
fi
if [ -z "${CODESIGN_IDENTITY}" ]; then
    echo 'NC_CODESIGN_IDENTITY is not set - the DMG itself is not signed.'
fi

# Done!
