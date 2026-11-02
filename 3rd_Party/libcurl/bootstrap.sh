#!/bin/sh
set -o pipefail
set -o xtrace
set -e

CUR_DIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )
TMP_DIR=${CUR_DIR}/curl.tmp

mkdir ${TMP_DIR}
cd ${TMP_DIR} 

git clone -b curl-8_23_0 --single-branch --depth=1 https://github.com/curl/curl.git

cd curl

# curl 8.23 prefers pipe2() when it is compiled against the macOS 27 SDK. In the archive that is a
# weak import, and linking the LTO-ed bitcode with an older SDK (as GitHub's macOS 26 runners do)
# turns it into a hard undefined symbol, breaking the build. The fork targets macOS 12 anyway, so
# take the portable pipe() path that every supported system has.
perl -0pi -e 's/#elif defined\(__APPLE__\) && defined\(HAVE_BUILTIN_AVAILABLE\)/#elif 0 \/* pipe2() disabled by the fork, see bootstrap.sh *\//' lib/socketpair.c
grep -q 'pipe2() disabled by the fork' lib/socketpair.c

mkdir build
cd build

cmake \
  -D CMAKE_OSX_ARCHITECTURES="arm64" \
  -D CMAKE_C_FLAGS="-fvisibility=hidden -flto" \
  -D CMAKE_OSX_DEPLOYMENT_TARGET="12.0" \
  -D CMAKE_IGNORE_PREFIX_PATH="/usr/local;/opt/homebrew" \
  -D USE_APPLE_SECTRUST="ON" \
  -D USE_APPLE_IDN="ON" \
  -D CURL_USE_LIBSSH="OFF" \
  -D CURL_USE_LIBSSH2="OFF" \
  -D CURL_BROTLI="OFF" \
  -D CURL_USE_LIBPSL="OFF" \
  -D USE_LIBIDN2="OFF" \
  -D USE_NGHTTP2="OFF" \
  -D USE_OPENSSL="ON" \
  -D CURL_DISABLE_LDAP="ON" \
  -D CURL_ZLIB="ON" \
  -D BUILD_STATIC_LIBS="ON" \
  -D BUILD_SHARED_LIBS="OFF" \
  -D ZLIB_INCLUDE_DIR=${CUR_DIR}/../z/include \
  -D ZLIB_LIBRARY=${CUR_DIR}/../z/lib/libz.a \
  -D ZSTD_INCLUDE_DIR=${CUR_DIR}/../zstd/include \
  -D ZSTD_LIBRARY=${CUR_DIR}/../zstd/lib/libzstd.a \
  -D OPENSSL_INCLUDE_DIR=${CUR_DIR}/../OpenSSL/include \
  -D OPENSSL_SSL_LIBRARY=${CUR_DIR}/../OpenSSL/lib/libssl.a \
  -D OPENSSL_CRYPTO_LIBRARY=${CUR_DIR}/../OpenSSL/lib/libcrypto.a \
  ..
make -j

#  --debug-find

cd ./../../../
rm -rf ./include/
rm -rf ./lib/

mkdir include
mkdir include/curl
mkdir lib

cp ./curl.tmp/curl/include/curl/*.h ./include/curl/
cp ./curl.tmp/curl/build/lib/libcurl.a ./lib/
cp ./curl.tmp/curl/build/lib/curl_config.h ./include/curl/

rm -rf ${TMP_DIR} 
