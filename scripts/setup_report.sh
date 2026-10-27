#!/bin/bash
#
# Report the state of the tool installation, e.g. to diagnose a setup.sh run.
# Read-only; run it from the conda env setup.sh installed into.
#
#   scripts/setup_report.sh [> report.txt]
#
set -u

EXPDIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )/.." &> /dev/null && pwd )
CODE=$EXPDIR/code

section() { echo; echo "=== $1"; }

section "Host"
echo "date: $(date -Is)   host: $(hostname)   user: $(whoami)"
. /etc/os-release && echo "OS: $PRETTY_NAME   kernel: $(uname -r)"
echo "cores: $(nproc)   RAM: $(free -g | awk '/^Mem:/{print $2}') GB   available: $(free -g | awk '/^Mem:/{print $7}') GB"
echo "free disk in $EXPDIR: $(df -h --output=avail "$EXPDIR" | tail -1 | tr -d ' ')"
echo "gcc: $(gcc -dumpfullversion 2>/dev/null || echo missing)   cmake: $(cmake --version 2>/dev/null | head -1 | awk '{print $3}')"

section "Repository"
echo "NASExperiments: $(git -C "$EXPDIR" rev-parse --abbrev-ref HEAD) $(git -C "$EXPDIR" rev-parse --short HEAD)$(git -C "$EXPDIR" diff --quiet || echo ' (uncommitted changes)')"

section "Conda env"
echo "env: ${CONDA_DEFAULT_ENV:-none} (${CONDA_PREFIX:-no prefix})"
echo "python: $(python --version 2>&1)   $(command -v python)"
echo "conda metagraph (server backend): $("${CONDA_PREFIX:-/nonexistent}/bin/metagraph" --version 2>/dev/null | head -1 || echo missing)"

section "Tool checkouts (code/)"
for d in minimap2 TurboPFor-Integer-Compression collinearity metagraph metagraphRF spumoni rawhash2 cumin \
         ReadBouncer sigmoni seq2squiggle MinknoApiSimulator; do
    if [ -d "$CODE/$d/.git" ] || [ -f "$CODE/$d/.git" ]; then
        g="git -C $CODE/$d -c submodule.recurse=false"
        printf '%-32s %-28s %s%s\n' "$d" "$($g rev-parse --abbrev-ref HEAD 2>/dev/null)" \
            "$($g log -1 --format='%h %cs %s' 2>/dev/null | cut -c1-60)" \
            "$($g diff --quiet 2>/dev/null || echo ' (modified)')"
    else
        printf '%-32s %s\n' "$d" "MISSING"
    fi
done

section "Binaries"
for b in minimap2/minimap2 collinearity/build/Collinearity metagraph/metagraph/build/metagraph \
         spumoni/build/spumoni rawhash2/rawhash2 ReadBouncer/build/main/ReadBouncer cumin/build/cumin; do
    if [ -x "$CODE/$b" ]; then
        printf '%-40s ok   %s\n' "$b" "$(stat -c %y "$CODE/$b" | cut -d. -f1)"
    else
        printf '%-40s missing\n' "$b"
    fi
done
echo "metagraph (code/): $("$CODE/metagraph/metagraph/build/metagraph" --version 2>/dev/null | head -1 || echo missing)"

section "Python packages"
for p in readfish ont-pybasecall-client-lib metagraph-api metagraphRF pymetagraph pyspumoni pyrawhash \
         pyreadbouncer pycollinearity pycumin sigmoni uncalled4 mappy-rs seq2squiggle torch mksim numpy pysam setuptools; do
    printf '%-28s %s\n' "$p" "$(pip show "$p" 2>/dev/null | awk '/^Version:/{print $2}')"
done | sed 's/ $/ MISSING/'

section "Plugin imports"
cd /tmp
for m in readfish.plugins.mappy_rs metagraphRF pymetagraph pyspumoni sigmoni pyrawhash pyreadbouncer pycollinearity pycumin; do
    if r=$(timeout 120 python -c "import $m" 2>&1); then
        printf '%-28s ok\n' "$m"
    else
        printf '%-28s FAILED: %s\n' "$m" "$(tail -1 <<< "$r")"
    fi
done
python -c "import pymetagraph; pymetagraph.AnnotatedGraph" 2>/dev/null \
    && echo "pymetagraph has AnnotatedGraph: yes" || echo "pymetagraph has AnnotatedGraph: NO"
python -c "from metagraphRF.aligner import Aligner; Aligner._init_local" 2>/dev/null \
    && echo "metagraphRF has local backend: yes" || echo "metagraphRF has local backend: NO"
pip check 2>&1 | tail -5

section "Basecaller"
/opt/ont/dorado/bin/dorado_basecall_server --version 2>&1 | grep -m1 -i version | sed 's/^[: ]*//'
source "$EXPDIR/scripts/gridion_common.sh"
address=$(dorado_address)
echo "running server listens on: ${address:-no dorado_basecall_server running}"
if [[ "$address" == ipc://* ]]; then
    ls -la "${address#ipc://}" 2>&1
    [ -w "${address#ipc://}" ] && echo "socket writable by $(whoami): yes" || echo "socket writable by $(whoami): NO"
fi
exit 0
