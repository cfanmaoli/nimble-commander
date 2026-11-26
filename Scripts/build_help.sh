#!/bin/sh

set -e
set -o pipefail

if ! [ -x "$(command -v pandoc)" ] ; then
    echo 'pandoc is not found, aborting. do brew install pandoc'
    exit -1
fi

if ! [ -x "$(command -v xelatex)" ] ; then
    if [ -x "$(command -v weasyprint)" ] ; then
        echo 'xelatex is not found, falling back to weasyprint'
    else
        echo 'Neither xelatex nor weasyprint is available; install one of them.'
        exit -1
    fi
fi

# get current directory
SCRIPTS_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

BUILD_DIR="${SCRIPTS_DIR}/build_help.tmp"
mkdir -p "${BUILD_DIR}"

cd "${SCRIPTS_DIR}/../Docs"

if [ -x "$(command -v xelatex)" ] ; then
    pandoc \
     ./Help.md \
     --pdf-engine=xelatex \
     --fail-if-warnings=true \
     -f markdown-implicit_figures \
     --toc \
     -V toc-title:"Nimble Commander-Fork User Guide" \
     -V colorlinks=true \
     -V linkcolor=blue \
     -V urlcolor=blue \
     -V toccolor=blue \
     -V geometry:margin=1in \
     -o ${BUILD_DIR}/Help.pdf
else
    pandoc \
     ./Help.md \
     --standalone \
     --embed-resources \
     --fail-if-warnings=true \
     -f markdown-implicit_figures \
     --toc \
     --metadata title:"Nimble Commander-Fork User Guide" \
     -o ${BUILD_DIR}/Help.html
    weasyprint ${BUILD_DIR}/Help.html ${BUILD_DIR}/Help.pdf
fi
