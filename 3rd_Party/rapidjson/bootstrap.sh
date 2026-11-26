#!/bin/sh
set -o pipefail
set -o xtrace
set -e

CUR_DIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )
TMP_DIR=${CUR_DIR}/rapidjson.tmp

mkdir ${TMP_DIR}
cd ${TMP_DIR} 

git clone https://github.com/Tencent/rapidjson
cd rapidjson
git checkout 297637bc0a0f00dc504dbc1a47ebdaa577f8ae19
cd ..

rm -rf ./include/

cp -R ${TMP_DIR}/rapidjson/include .

rm -rf ${TMP_DIR}
