#!/bin/bash
#
set -e

export EXPDIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
cd $EXPDIR

# Keep a full log of this run (and a state report at the end, see
# scripts/setup_report.sh) under logs/
mkdir -p logs
SETUP_LOG=$EXPDIR/logs/setup_$(date +%Y%m%d_%H%M%S).log
exec > >(tee -a "$SETUP_LOG") 2>&1
trap 'echo "### setup.sh FAILED at line $LINENO (exit $?): $BASH_COMMAND"; echo "### log: $SETUP_LOG"' ERR
step() { echo; echo "### $(date '+%F %T') $*"; }
step "setup.sh started in $EXPDIR (env: ${CONDA_DEFAULT_ENV:-none}, commit $(git -C "$EXPDIR" rev-parse --short HEAD 2>/dev/null))"

# Parallel build jobs: one per core, but at most one per 4 GB of available RAM,
# since metagraph's compile jobs need 2-4 GB each. Override with JOBS=<n>.
if [ -z "${JOBS:-}" ]; then
    JOBS=$(awk '/^MemAvailable:/ {print int($2 / 1024 / 1024 / 4)}' /proc/meminfo)
    if [ "$JOBS" -gt "$(nproc)" ]; then JOBS=$(nproc); fi
    if [ "$JOBS" -lt 1 ]; then JOBS=1; fi
fi
# also used by the pip/scikit-build-core builds (pymetagraph)
export CMAKE_BUILD_PARALLEL_LEVEL=$JOBS
echo "Building with $JOBS parallel jobs"

# Create directory structure
mkdir -p code log logs out results tmp

step "minimap2"
# setup minimap2
cd $EXPDIR/code
if [ ! -f minimap2/minimap2 ]; then
    [ -d minimap2 ] || git clone https://github.com/lh3/minimap2.git
    cd minimap2 && make -j $JOBS
else
    echo "minimap2 binary found, skipping."
fi

step "TurboPFor"
# setup TurboPFor (required by collinearity)
cd $EXPDIR/code
if [ ! -f TurboPFor-Integer-Compression/libic.a ]; then
    [ -d TurboPFor-Integer-Compression ] || git clone https://github.com/powturbo/TurboPFor-Integer-Compression.git
    cd TurboPFor-Integer-Compression && make -j $JOBS
else
    echo "TurboPFor already built, skipping."
fi
TURBOPFOR_DIR=$EXPDIR/code/TurboPFor-Integer-Compression

step "collinearity"
# setup collinearity
cd $EXPDIR/code
if ! pip show pycollinearity &>/dev/null || [ ! -f collinearity/build/Collinearity ]; then
    [ -d collinearity ] || git clone --recursive https://github.com/ratschlab/collinearity.git
    cd collinearity
    # patch hardcoded TurboPFor path in CMakeLists.txt
    sed -i "s|/home/sayan/Downloads/TurboPFor-Integer-Compression|${TURBOPFOR_DIR}|g" CMakeLists.txt
    # for python bindings
    pip show pycollinearity &>/dev/null || pip install .
    # to build from source
    if [ ! -f build/Collinearity ]; then
        mkdir -p build && cd build
        cmake ..
        make -j $JOBS
    fi
else
    echo "collinearity already installed, skipping."
fi

step "readfish"
# readfish from the ratschlab fork: upstream 2026.1.0 plus regions with their own
# caller/aligner in parallel worker processes (readfish._arms); replaces the
# PyPI readfish 2024.3.0 that env.yml installs
READFISH_BRANCH=ak/parallel-arms
cd $EXPDIR/code
[ -d readfish ] || git clone -b $READFISH_BRANCH https://github.com/ratschlab/readfish.git
cd readfish
if [ "$(git branch --show-current)" != "$READFISH_BRANCH" ]; then
    echo "WARNING: code/readfish is on '$(git branch --show-current)', not $READFISH_BRANCH;" >&2
    echo "         run_gridion.sh with several tools needs that branch." >&2
fi
if ! python -c "import readfish._arms" &>/dev/null; then
    pip install ".[all]"
else
    echo "readfish with parallel regions found, skipping."
fi

step "metagraph CLI"
# build metagraph (CLI for index building + pymetagraph bindings) from master
# (pymetagraph align/map since #731, min_seed_length since #733)
# From https://metagraph.ethz.ch/static/docs/installation.html#install-from-source
METAGRAPH_BRANCH=master
# the current pymetagraph API (map takes min_seed_length since #733)
PYMETAGRAPH_OK='import inspect, pymetagraph; assert "min_seed_length" in inspect.signature(pymetagraph.AnnotatedGraph.map).parameters'
cd $EXPDIR/code
[ -d metagraph ] || git clone -b $METAGRAPH_BRANCH --recursive https://github.com/ratschlab/metagraph.git
cd metagraph
# move checkouts of the retired pre-merge branch to master, and update master if
# the installed pymetagraph is older than #733
if [ "$(git branch --show-current)" = ak/pymetagraph-align ]; then
    git fetch origin master && git checkout $METAGRAPH_BRANCH
fi
if [ "$(git branch --show-current)" = "$METAGRAPH_BRANCH" ] && ! python -c "$PYMETAGRAPH_OK" &>/dev/null; then
    git pull --ff-only origin $METAGRAPH_BRANCH
fi
if [ "$(git branch --show-current)" != "$METAGRAPH_BRANCH" ]; then
    echo "WARNING: code/metagraph is on '$(git branch --show-current)', not $METAGRAPH_BRANCH;" >&2
    echo "         pymetagraph needs that branch (git -C code/metagraph checkout $METAGRAPH_BRANCH)." >&2
fi
git submodule update --init --recursive

# (sdsl-lite is built by metagraph's own CMake project on master, position-independent
# when building the python bindings; no separate install step needed)

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
  # NO_SUDO=1 skips the install attempt; the timeout guards against sudo hanging
  if [ "${NO_SUDO:-0}" != 1 ] && timeout 5 sudo -n true 2>/dev/null; then
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
  make -j $JOBS metagraph
else
  echo "WARNING: skipping the metagraph CLI/server build -- could not find or" >&2
  echo "         install a system Boost with static libs (libboost-all-dev)." >&2
  echo "         Ask your admin to run: sudo apt-get install -y libboost-all-dev" >&2
  echo "         then re-run setup.sh to build the metagraph CLI binary." >&2
  echo "         (pymetagraph python bindings will still be installed below.)" >&2
fi

step "pymetagraph"
# pymetagraph python bindings (in-process queries and alignment, used by
# metagraphRF). Separate cmake invocation via scikit-build-core with
# -DBUILD_PYTHON_BINDINGS=ON, which switches metagraph's CMakeLists.txt to shared
# Boost libs. Reinstalled if an older pymetagraph (before #733) is present.
if ! python -c "$PYMETAGRAPH_OK" &>/dev/null; then
    cd $EXPDIR/code/metagraph/metagraph/api/python/pymetagraph
    # a failed earlier attempt leaves a CMake cache pointing at pip's deleted build env
    rm -rf build
    # point it at the system Boost, not the conda env's
    if [ -n "$BOOST_DIR" ] && [ -n "$BOOST_IOSTREAMS_DIR" ]; then
        CMAKE_ARGS="-DBoost_DIR=$BOOST_DIR -Dboost_iostreams_DIR=$BOOST_IOSTREAMS_DIR" pip install .
    else
        pip install .
    fi
else
    echo "pymetagraph already installed, skipping."
fi

step "metagraphRF"
# setup metagraphRF: readfish plugin running MetaGraph in-process through pymetagraph
# (built above, hence --no-deps); reinstalled over the older server/local-backend version
METAGRAPHRF_BRANCH=ak/pymetagraph-only
cd $EXPDIR/code
[ -d metagraphRF ] || git clone -b $METAGRAPHRF_BRANCH https://github.com/ratschlab/metagraphRF
cd metagraphRF
if [ "$(git branch --show-current)" != "$METAGRAPHRF_BRANCH" ]; then
    echo "WARNING: code/metagraphRF is on '$(git branch --show-current)', not $METAGRAPHRF_BRANCH;" >&2
    echo "         the mg_query/mg_map templates need that branch (mode = query | map)." >&2
fi
# reinstalled (after a pull) if older than the pymetagraph API of #733
if ! python -c 'from metagraphRF import MODE_SETTINGS; assert "min_seed_length" in MODE_SETTINGS["map"]' &>/dev/null; then
    [ "$(git branch --show-current)" = "$METAGRAPHRF_BRANCH" ] && git pull --ff-only origin $METAGRAPHRF_BRANCH
    pip install --no-deps .
else
    echo "metagraphRF with pymetagraph modes found, skipping."
fi

step "spumoni"
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
    make -j $JOBS
    make install
    cd ..
fi
# python bindings
if ! pip show pyspumoni &>/dev/null; then
    cd $EXPDIR/code/spumoni
    pip install .
else
    echo "spumoni already installed, skipping."
fi

step "rawhash"
# setup rawhash
cd $EXPDIR/code
if [ ! -f rawhash2/rawhash2 ]; then
    [ -d rawhash2 ] || git clone -b cmake --recursive https://github.com/ratschlab/RawHash.git rawhash2
    cd rawhash2
    git submodule update --init --recursive
    mkdir -p build && cd build
    cmake NOHDF5=1 NOPOD5=1 ..
    make -j $JOBS
    # for python bindings
    cd ..
    pip show pyrawhash &>/dev/null || pip install .
else
    echo "rawhash2 binary found, skipping."
fi

step "ReadBouncer"
# setup ReadBouncer
cd $EXPDIR/code
[ -d ReadBouncer ] || git clone --recursive https://github.com/ratschlab/ReadBouncer.git
cd ReadBouncer
git submodule update --init --recursive
mkdir -p build && cd build
cmake ../src
make -j $JOBS

# pyreadbouncer python bindings
cd $EXPDIR/code/ReadBouncer
pip install .

step "sigmoni"
# setup sigmoni
# requires SPUMONI (built above) and Uncalled4
cd $EXPDIR/code
[ -d sigmoni ] || git clone https://github.com/ratschlab/sigmoni.git
cd sigmoni
pip install "setuptools<81" uncalled4   # ont_fast5_api needs pkg_resources
# editable: sigmoni loads its pore models from <source>/poremodel/
pip install -e .

step "cumin"
# setup cumin (open-syncmer-based)
cd $EXPDIR/code
if ! pip show pycumin &>/dev/null || [ ! -f cumin/build/cumin ]; then
    [ -d cumin ] || git clone --recursive https://github.com/sayangoswami/cumin.git
    cd cumin
    git submodule update --init --recursive
    if [ ! -f build/cumin ]; then
        mkdir -p build && cd build
        cmake ..
        make -j $JOBS
        cd ..
    fi
    # for python bindings
    pip show pycumin &>/dev/null || pip install .
else
    echo "cumin already installed, skipping."
fi

step "seq2squiggle"
# setup seq2squiggle (signal simulation only, not needed for live runs on a GridION;
# pulls in torch with CUDA wheels, ~5 GB, and pins numpy ^1.26;
# opt-in with WITH_SIMULATION=1)
cd $EXPDIR/code
if [ "${WITH_SIMULATION:-0}" != 1 ]; then
    echo "skipping (simulation tools are opt-in: WITH_SIMULATION=1)"
else
    [ -d seq2squiggle ] || git clone https://github.com/ZKI-PH-ImageAnalysis/seq2squiggle.git
    cd seq2squiggle
    pip install .
fi

step "MinKNOW API simulator"
# Setup Minknow API Simulator (only for simulated runs, not needed for live runs
# on a GridION; opt-in with WITH_SIMULATION=1)
cd $EXPDIR/code
if [ "${WITH_SIMULATION:-0}" != 1 ]; then
    echo "skipping (simulation tools are opt-in: WITH_SIMULATION=1)"
elif ! pip show mksim &>/dev/null; then
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

step "setup.sh finished"
"$EXPDIR/scripts/setup_report.sh" || echo "### (setup_report.sh failed; the install itself finished)"
echo
echo "### log: $SETUP_LOG"
