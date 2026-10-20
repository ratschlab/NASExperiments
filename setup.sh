#!/bin/bash
#
set -e

export EXPDIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
cd $EXPDIR

# Create directory structure
mkdir -p code log logs out results tmp

# setup minimap2
cd $EXPDIR/code
if [ ! -f minimap2/minimap2 ]; then
    [ -d minimap2 ] || git clone https://github.com/lh3/minimap2.git
    cd minimap2 && make -j8
else
    echo "minimap2 binary found, skipping."
fi

# setup TurboPFor (required by collinearity)
cd $EXPDIR/code
if [ ! -f TurboPFor-Integer-Compression/libic.a ]; then
    [ -d TurboPFor-Integer-Compression ] || git clone https://github.com/powturbo/TurboPFor-Integer-Compression.git
    cd TurboPFor-Integer-Compression && make -j8
else
    echo "TurboPFor already built, skipping."
fi
TURBOPFOR_DIR=$EXPDIR/code/TurboPFor-Integer-Compression

# setup collinearity
cd $EXPDIR/code
if ! pip show collinearity &>/dev/null || [ ! -f collinearity/build/Collinearity ]; then
    [ -d collinearity ] || git clone --recursive https://github.com/ratschlab/collinearity.git
    cd collinearity
    # patch hardcoded TurboPFor path in CMakeLists.txt
    sed -i "s|/home/sayan/Downloads/TurboPFor-Integer-Compression|${TURBOPFOR_DIR}|g" CMakeLists.txt
    # for python bindings
    pip show collinearity &>/dev/null || pip install .
    # to build from source
    if [ ! -f build/Collinearity ]; then
        mkdir -p build && cd build
        cmake ..
        make -j 8
    fi
else
    echo "collinearity already installed, skipping."
fi

# setup metagraphRF (server-based readfish plugin, uses conda metagraph)
cd $EXPDIR/code
if ! pip show metagraphRF &> /dev/null
then
    conda install -c bioconda -c conda-forge metagraph=0.5.1
    [ -d metagraphRF ] || git clone https://github.com/ratschlab/metagraphRF
    cd metagraphRF
    pip show metagraphRF &>/dev/null || pip install .
else
    echo "metagraphRF module found, skipping."
fi

# build metagraph from sg/readfish-bindings branch
# From https://metagraph.ethz.ch/static/docs/installation.html#install-from-source
cd $EXPDIR/code
[ -d metagraph ] || git clone -b sg/readfish-bindings --recursive https://github.com/ratschlab/metagraph.git
cd metagraph
git submodule update --init --recursive
mkdir -p metagraph/build
cd metagraph/build

# metagraph's CLI/server build (BUILD_PYTHON_BINDINGS=OFF) requires Boost with
# static libs. A conda env's boost-cpp package only ships shared libs and its
# CMake config gets found before the system one, so point cmake at the system
# (apt libboost-all-dev) Boost explicitly, installing it first if it's missing.
# (The pymetagraph python bindings below use shared Boost and don't need this.)
BOOST_DIR=$(find /usr/lib/*/cmake -maxdepth 1 -type d -iname 'Boost-*' -print -quit 2>/dev/null || true)
BOOST_IOSTREAMS_DIR=$(find /usr/lib/*/cmake -maxdepth 1 -type d -iname 'boost_iostreams-*' -print -quit 2>/dev/null || true)
if [ -z "$BOOST_DIR" ] || [ -z "$BOOST_IOSTREAMS_DIR" ]; then
  echo "metagraph: system Boost (static libs) not found, trying to install libboost-all-dev..."
  if sudo -n true 2>/dev/null; then
    sudo apt-get update && sudo apt-get install -y libboost-all-dev
  elif [ "$(id -u)" = "0" ]; then
    apt-get update && apt-get install -y libboost-all-dev
  fi
  BOOST_DIR=$(find /usr/lib/*/cmake -maxdepth 1 -type d -iname 'Boost-*' -print -quit 2>/dev/null || true)
  BOOST_IOSTREAMS_DIR=$(find /usr/lib/*/cmake -maxdepth 1 -type d -iname 'boost_iostreams-*' -print -quit 2>/dev/null || true)
fi

if [ -f metagraph_DNA ]; then
  echo "metagraph binary found, skipping."
elif [ -n "$BOOST_DIR" ] && [ -n "$BOOST_IOSTREAMS_DIR" ]; then
  cmake -DBoost_DIR="$BOOST_DIR" -Dboost_iostreams_DIR="$BOOST_IOSTREAMS_DIR" ..
  make -j 16
else
  echo "WARNING: skipping the metagraph CLI/server build -- could not find or" >&2
  echo "         install a system Boost with static libs (libboost-all-dev)." >&2
  echo "         Ask your admin to run: sudo apt-get install -y libboost-all-dev" >&2
  echo "         then re-run setup.sh to build the metagraph CLI binary." >&2
  echo "         (pymetagraph python bindings will still be installed below.)" >&2
fi

# pymetagraph python bindings (readfish-compatible aligner plugin)
# Separate cmake invocation via scikit-build-core with -DBUILD_PYTHON_BINDINGS=ON,
# which switches metagraph's CMakeLists.txt to shared Boost libs, so the static-lib
# workaround above isn't needed here.
if ! pip show pymetagraph &>/dev/null; then
    cd $EXPDIR/code/metagraph/metagraph/api/python/pymetagraph
    pip install .
else
    echo "pymetagraph already installed, skipping."
fi

# setup spumoni
cd $EXPDIR/code
if [ ! -f spumoni/build/spumoni ]; then
    [ -d spumoni ] || git clone --recursive https://github.com/ratschlab/spumoni.git
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
# python bindings
if ! pip show spumoni &>/dev/null; then
    cd $EXPDIR/code/spumoni
    pip install .
else
    echo "spumoni already installed, skipping."
fi

# setup rawhash
cd $EXPDIR/code
if [ ! -f rawhash2/build/rawhash2 ]; then
    [ -d rawhash2 ] || git clone -b cmake --recursive https://github.com/ratschlab/RawHash.git rawhash2
    cd rawhash2
    git submodule update --init --recursive
    mkdir -p build && cd build
    cmake NOHDF5=1 NOPOD5=1 ..
    make -j 8
    # for python bindings
    cd ..
    pip show rawhash2 &>/dev/null || pip install .
else
    echo "rawhash2 binary found, skipping."
fi

# setup ReadBouncer
cd $EXPDIR/code
[ -d ReadBouncer ] || git clone --recursive https://github.com/ratschlab/ReadBouncer.git
cd ReadBouncer
git submodule update --init --recursive
mkdir -p build && cd build
cmake ../src
make -j 8

# pyreadbouncer python bindings
cd $EXPDIR/code/ReadBouncer
pip install .

# setup sigmoni
# requires SPUMONI (built above) and Uncalled4
cd $EXPDIR/code
[ -d sigmoni ] || git clone https://github.com/ratschlab/sigmoni.git
cd sigmoni
pip install uncalled4
pip install .

# setup seq2squiggle
cd $EXPDIR/code
[ -d seq2squiggle ] || git clone https://github.com/ZKI-PH-ImageAnalysis/seq2squiggle.git
cd seq2squiggle
pip install .

# Setup Minknow API Simulator
cd $EXPDIR/code
if ! pip show minknow-api-simulator &>/dev/null; then
    [ -d MinknoApiSimulator ] || git clone https://github.com/ratschlab/MinknoApiSimulator.git
    cd MinknoApiSimulator/certs
    ./generate.sh
    cd ..
    pip install .
else
    echo "MinknoApiSimulator already installed, skipping."
fi

# NOTE: ont-dorado-server is NOT set up by this script. It is ONT's vendored
# Dorado/Guppy basecall server binary distribution, gated behind an ONT
# community login (https://community.nanoporetech.com/). Download the Linux
# server package matching your basecaller version and extract it to
# $EXPDIR/code/ont-dorado-server/ -- see README.md step 5 for checking
# client/server version compatibility.

cd $EXPDIR
