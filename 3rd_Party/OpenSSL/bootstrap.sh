#!/bin/sh
set -o pipefail
set -o xtrace
set -e

CUR_DIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )
TMP_DIR=${CUR_DIR}/openssl.tmp

mkdir ${TMP_DIR}
cd ${TMP_DIR}

git clone -b openssl-3.6.5 --single-branch --depth 1 https://github.com/openssl/openssl.git openssl

# NB! No -fvisibility=hidden neither -flto passed, since OpenSSL3 is quite a snowflake...
CFLAGS="-mmacosx-version-min=12.0 -Os -isysroot $(xcrun --sdk macosx --show-sdk-path)"

cd openssl
arch -arch arm64 ./config \
  --with-zlib-include=../../../z/include \
  --with-zlib-lib=../../../z/lib \
  --with-zstd-include=../../../zstd/include \
  --with-zstd-lib=../../../zstd/lib \
  --prefix=${CUR_DIR}/openssl.tmp/installed/ \
  no-shared \
  no-asm \
  zlib \
  enable-zstd \
  enable-md2 \
  enable-rc5 \
  CFLAGS="${CFLAGS}"
make -j4
make -j4 test
make -j4 install

cd ..
cd ..
rm -rf ./include/
rm -rf ./lib/
mkdir include
mkdir lib

cp ${TMP_DIR}/installed/lib/*.a ./lib/
cp -R ${TMP_DIR}/installed/include/* ./include/

rm -rf ${TMP_DIR}
