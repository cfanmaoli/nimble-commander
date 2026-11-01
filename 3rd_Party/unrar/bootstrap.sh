#!/bin/sh
set -o pipefail
set -o xtrace
set -e

CUR_DIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )
TMP_DIR=${CUR_DIR}/unrar.tmp

mkdir ${TMP_DIR}
cd ${TMP_DIR}

wget https://www.rarlab.com/rar/unrarsrc-7.3.2.tar.gz
tar -xf unrarsrc-7.3.2.tar.gz
cd unrar

# The objects that the upstream 'make lib' target builds: the UnRAR DLL API plus everything it
# needs. The compression-only parts (recvol, rs, suballoc, ...) are not a part of it.
OBJECTS="rar strlist strfn pathfn smallfn global file filefn filcreat
archive arcread unicode system crypt crc rawread encname resource match timefn rdwrfn
consio options errhnd rarvm secpassword rijndael getbits sha1 sha256 blake2s hash extinfo
extract volume list find unpack headers threadpool rs16 cmddata ui largepage
filestr scantree dll qopen"

CFLAGS="-std=c++11 -fvisibility=hidden -flto -Os -mmacosx-version-min=11.0 -DNDEBUG
  -DRAR_SMP -DRARDLL -D_FILE_OFFSET_BITS=64 -D_LARGEFILE_SOURCE -pthread
  -ffile-prefix-map=${TMP_DIR}=/nc-build"

for obj in ${OBJECTS}; do
  clang++ -c ${CFLAGS} -arch arm64 ${obj}.cpp -o ${obj}.o &
done
wait
libtool -static -o libunrar.a ./*.o

cd ./../..

rm -rf ./include/
rm -rf ./lib/

mkdir include
mkdir lib

cp ./unrar.tmp/unrar/dll.hpp ./include/
cp ./unrar.tmp/unrar/rardefs.hpp ./include/
cp ./unrar.tmp/unrar/version.hpp ./include/
cp ./unrar.tmp/unrar/libunrar.a ./lib/

rm -rf ${TMP_DIR}
