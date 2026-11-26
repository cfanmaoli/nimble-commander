#!/bin/sh
set -o pipefail
set -o xtrace
set -e

CUR_DIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )
TMP_DIR=${CUR_DIR}/sparkle.tmp

mkdir ${TMP_DIR}
cd ${TMP_DIR} 

git clone -b 2.10.1 --single-branch --depth=1 --recursive https://github.com/sparkle-project/Sparkle.git

cd Sparkle

XC="xcodebuild \
  -project Sparkle.xcodeproj \
  -scheme Sparkle \
  -configuration Release"
BINARY_DIR=$($XC -showBuildSettings | grep " BUILT_PRODUCTS_DIR =" | sed -e 's/.*= *//')
BINARY_NAME=$($XC -showBuildSettings | grep " FULL_PRODUCT_NAME =" | sed -e 's/.*= *//')
BINARY_PATH=$BINARY_DIR/$BINARY_NAME
echo ${BINARY_PATH}
$XC clean build

cd ./../..

rm -rf ./Sparkle.framework

cp -R ${BINARY_PATH} .

# The app is arm64-only; drop the unused x86_64 slices after extracting the release.
find Sparkle.framework -type f -perm -111 | while read binary; do
    if lipo -info "$binary" 2>/dev/null | grep -q x86_64; then
        lipo -thin arm64 -output "$binary.arm64" "$binary"
        mv "$binary.arm64" "$binary"
        chmod +x "$binary"
    fi
done

rm -rf ${TMP_DIR}
