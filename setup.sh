#!/bin/bash
#
set -e

export EXPDIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
cd $EXPDIR

# Create directory structure
mkdir -p code log out results tmp

# setup minimap2
cd $EXPDIR/code
if [ ! -f minimap2/minimap2 ]; then
    [ ! -d minimap2 ] && git clone https://github.com/lh3/minimap2.git
    cd minimap2 && make -j8
else
    echo "minimap2 binary found, skipping."
fi

# setup TurboPFor (required by collinearity)
cd $EXPDIR/code
if [ ! -f TurboPFor-Integer-Compression/libic.a ]; then
    [ ! -d TurboPFor-Integer-Compression ] && git clone https://github.com/powturbo/TurboPFor-Integer-Compression.git
    cd TurboPFor-Integer-Compression && make -j8
else
    echo "TurboPFor already built, skipping."
fi
TURBOPFOR_DIR=$EXPDIR/code/TurboPFor-Integer-Compression

# setup collinearity
cd $EXPDIR/code
if ! pip show collinearity &>/dev/null || [ ! -f collinearity/build/Collinearity ]; then
    [ ! -d collinearity ] && git clone --recursive https://github.com/ratschlab/collinearity.git
    cd collinearity
    # patch hardcoded TurboPFor path in CMakeLists.txt
    sed -i "s|/home/sayan/Downloads/TurboPFor-Integer-Compression|${TURBOPFOR_DIR}|g" CMakeLists.txt
    pip show collinearity &>/dev/null || pip install .
    if [ ! -f build/Collinearity ]; then
        mkdir -p build && cd build
        cmake ..
        make -j 8
    fi
else
    echo "collinearity already installed, skipping."
fi

# setup metagraph
cd $EXPDIR/code
if ! pip show metagraphRF &> /dev/null 
then
    conda install -c bioconda -c conda-forge metagraph
    [ ! -d metagraphRF ] && git clone https://github.com/ratschlab/metagraphRF
    cd metagraphRF
    pip show metagraphRF &>/dev/null || pip install .
else
    echo "metagraphRF module found, skipping."
fi

# setup spumoni
cd $EXPDIR/code
if [ ! -f spumoni/build/spumoni ]; then
    [ ! -d spumoni ] && git clone --recursive https://github.com/ratschlab/spumoni.git
    cd spumoni
    mkdir -p build && cd build
    cmake ..
    # Fix GCC 13: add missing <cstdint> to bwt2lcp (reverted by cmake git fetch)
    grep -q "cstdint" _deps/bwt2lcp-src/internal/include.hpp || \
        sed -i 's/#include <algorithm>/#include <algorithm>\n#include <cstdint>/' \
            _deps/bwt2lcp-src/internal/include.hpp
    # Fix GCC 13: add missing <utility> to shaped_slp/sux Vector.hpp
    grep -q "<utility>" _deps/shaped_slp-src/external/sux/sux/util/Vector.hpp || \
        sed -i 's/#include <sys\/mman.h>/#include <sys\/mman.h>\n#include <utility>/' \
            _deps/shaped_slp-src/external/sux/sux/util/Vector.hpp
    make -j 16
    make install
    cd ..
fi
if ! pip show spumoni &>/dev/null; then
    cd $EXPDIR/code/spumoni
    pip install .
else
    echo "spumoni already installed, skipping."
fi

# setup rawhash
cd $EXPDIR/code
if [ ! -f rawhash2/build/rawhash2 ]; then
    [ ! -d rawhash2 ] && git clone -b cmake_merge --recursive https://github.com/ratschlab/RawHash.git rawhash2
    cd rawhash2
    git submodule update --init --recursive
    mkdir -p build && cd build
    cmake NOHDF5=1 NOPOD5=1 ..
    make -j 8
    cd ..
    pip show rawhash2 &>/dev/null || pip install .
else
    echo "rawhash2 binary found, skipping."
fi

# Setup Minknow API Simulator
cd $EXPDIR/code
if ! pip show minknow-api-simulator &>/dev/null; then
    [ ! -d MinknoApiSimulator ] && git clone https://github.com/ratschlab/MinknoApiSimulator.git
    cd MinknoApiSimulator/certs
    ./generate.sh
    cd ..
    pip install .
else
    echo "MinknoApiSimulator already installed, skipping."
fi

cd $EXPDIR
