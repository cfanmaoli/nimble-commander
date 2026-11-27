#!/bin/sh

# Packaging for a signed nightly. Signing and notarisation are opt-in and have to be provided by the
# maintainer: set NC_CODESIGN_IDENTITY to a Developer ID Application identity and NC_NOTARY_PROFILE
# to a 'notarytool' keychain profile (see 'xcrun notarytool store-credentials'). Without them the DMG
# is built unsigned, and the script says so at the end.

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
BUILD_DIR="${SCRIPTS_DIR}/build_nightly.tmp"
ARCHIVE_PATH="${BUILD_DIR}/NC_NonMAS.xcarchive"
BUILT_PATH="${BUILD_DIR}/built"
mkdir -p "${BUILD_DIR}"
mkdir -p "${ARCHIVE_PATH}"

# Help.pdf is a tracked artifact; only build it if missing or empty so builds do not dirty the tree.
if [ ! -s "${ROOT_DIR}/Source/NimbleCommander/NimbleCommander/Resources/Help.pdf" ]; then
    ${SCRIPTS_DIR}/build_help.sh
    cp -f "${SCRIPTS_DIR}/build_help.tmp/Help.pdf" "${ROOT_DIR}/Source/NimbleCommander/NimbleCommander/Resources/Help.pdf"
fi

# Gather common flags in the XC variable
XC="xcodebuild \
 -project ${XCODEPROJ} \
 -scheme NimbleCommander-NonMAS \
 -configuration Release \
 -parallelizeTargets \
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
DMG_NAME="nimble-commander-fork-nightly-${VERSION}(${BUILD}).dmg"
DSYM_ZIP_NAME="nimble-commander-fork-nightly-${VERSION}(${BUILD}).dSYM.zip"
DSYM_ZIP_PATH="${PWD}/${DSYM_ZIP_NAME}"

# Package all freshly built dSYM directories for symbolication
rm -f "${DSYM_ZIP_PATH}"
for dSYM in "${ARCHIVE_PATH}"/dSYMs/*; do
    if [ -d "${dSYM}" ]; then
        dSYM_NAME="$(basename "${dSYM}")"
        ln -sf "${dSYM}" "${dSYM_NAME}"
        zip -qr "${DSYM_ZIP_PATH}" "${dSYM_NAME}"
        rm -f "${dSYM_NAME}"
    fi
done

# Wrap the built application into a .dmg disk image
set -- \
 --volname "Nimble Commander-Fork Nightly" \
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
