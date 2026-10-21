#!/bin/bash
#
# Free disk space after setup.sh. Without options it only reports sizes.
#
#   scripts/cleanup_install.sh [--caches] [--builds] [--simulation]
#
#   --caches      pip cache, conda package cache, __pycache__ under code/
#   --builds      build intermediates under code/, keeping everything needed at
#                 runtime and for building indices (tool binaries, librawhash2.so,
#                 spumoni's helper programs, sigmoni and simulator sources)
#   --simulation  uninstall seq2squiggle (signal simulation, not needed for live
#                 runs) and those of its dependencies nothing else requires
#
# Run it from the conda env setup.sh installed into. Re-running setup.sh after
# --builds rebuilds ReadBouncer and pymetagraph from scratch (no incremental build).
#
set -uo pipefail

EXPDIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )/.." &> /dev/null && pwd )
CODE=$EXPDIR/code
CACHES=0
BUILDS=0
SIMULATION=0

usage() {
    echo "Usage: $0 [--caches] [--builds] [--simulation]"
    echo ""
    echo "Without options, only reports sizes and deletes nothing."
    echo "  --caches      remove pip/conda caches and __pycache__ under code/"
    echo "  --builds      remove build intermediates under code/ (keeps runtime files)"
    echo "  --simulation  uninstall seq2squiggle and its otherwise unused dependencies"
    echo "  -h, --help    Display this help message."
    exit 1
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --caches) CACHES=1; shift ;;
        --builds) BUILDS=1; shift ;;
        --simulation) SIMULATION=1; shift ;;
        -h|--help) usage ;;
        *) echo "Error: Unknown argument '$1'" >&2; usage ;;
    esac
done
[ -n "${CONDA_PREFIX:-}" ] || { echo "Error: activate the conda env setup.sh installed into." >&2; exit 1; }

section() { echo; echo "=== $1"; }
size() { du -shc "$@" 2>/dev/null | tail -1 | cut -f1; }
show() { printf '%-60s %s\n' "$1" "$(size "${@:2}")"; }

# Build intermediates: whole directories, or "<dir>:<kept files>" for build
# directories whose runtime files stay.
BUILD_DIRS=(
    "metagraph/metagraph/api/python/pymetagraph/build"
    "metagraph/metagraph/build:metagraph metagraph_DNA"
    "spumoni/build/_deps"
    "rawhash2/build"
    "ReadBouncer/build:main/ReadBouncer"
)
# leftovers from earlier builds (build.<something>)
for d in "$CODE"/*/build.* "$CODE"/metagraph/metagraph/build.*; do
    [ -e "$d" ] && BUILD_DIRS+=("${d#$CODE/}")
done

# seq2squiggle's heavy dependency tree, removed only if nothing else needs it
SIM_PACKAGES="seq2squiggle torch triton lightning pytorch-lightning lightning-utilities torchmetrics
  transformers tokenizers safetensors huggingface-hub wandb sentry-sdk numba llvmlite PyGithub
  rich-click prettytable"

# --- Report ---
section "Disk"
df -h --output=size,used,avail "$EXPDIR" | sed 's/^/  /'

section "Caches"
show "pip cache ($(pip cache dir 2>/dev/null))" "$(pip cache dir 2>/dev/null)"
CONDA_BASE=$(conda info --base 2>/dev/null)
show "conda package cache ($CONDA_BASE/pkgs)" "$CONDA_BASE/pkgs"
mapfile -t PYCACHES < <(find "$CODE" -type d -name __pycache__ 2>/dev/null)
show "__pycache__ under code/ (${#PYCACHES[@]} dirs)" "${PYCACHES[@]:-/nonexistent}"

section "Build intermediates under code/"
for entry in "${BUILD_DIRS[@]}"; do
    dir=${entry%%:*}
    [ -e "$CODE/$dir" ] || continue
    keep=""; [[ "$entry" == *:* ]] && keep=" (keeps: ${entry#*:})"
    show "$dir$keep" "$CODE/$dir"
done

section "Git histories under code/ (kept: needed to update the tools)"
for g in "$CODE"/*/.git; do
    [ -e "$g" ] && show "${g#$CODE/}" "$g"
done

section "Conda env $CONDA_DEFAULT_ENV"
show "$CONDA_PREFIX" "$CONDA_PREFIX"
SP=$(python -c "import sysconfig; print(sysconfig.get_paths()['purelib'])")
installed_sim=""
for p in $SIM_PACKAGES; do
    pip show "$p" &>/dev/null && installed_sim+="$p "
done
nvidia=$(pip list 2>/dev/null | awk '/^nvidia-/ {print $1}' | tr '\n' ' ')
echo "simulation packages installed: ${installed_sim:-none}"
echo "nvidia-* wheels installed: ${nvidia:-none}"
[ -n "$installed_sim$nvidia" ] && show "  their size in site-packages" \
    "$SP"/torch "$SP"/triton "$SP"/nvidia "$SP"/transformers "$SP"/wandb "$SP"/numba "$SP"/llvmlite "$SP"/seq2squiggle
echo "numpy: $(pip show numpy 2>/dev/null | awk '/^Version/{print $2}')   pysam: $(pip show pysam 2>/dev/null | awk '/^Version/{print $2}')"

# --- Actions ---
if [ "$CACHES" = 1 ]; then
    section "Removing caches"
    pip cache purge
    conda clean --all -y
    [ ${#PYCACHES[@]} -gt 0 ] && rm -rf "${PYCACHES[@]}"
fi

if [ "$BUILDS" = 1 ]; then
    section "Removing build intermediates"
    for entry in "${BUILD_DIRS[@]}"; do
        dir=$CODE/${entry%%:*}
        [ -e "$dir" ] || continue
        if [[ "$entry" == *:* ]]; then
            keep=(${entry#*:})
            # delete everything in dir except the kept files (and the directories leading to them)
            find "$dir" -mindepth 1 -depth \( -type f -o -type l \) | while read -r f; do
                rel=${f#$dir/}
                skip=0
                for k in "${keep[@]}"; do [ "$rel" = "$k" ] && skip=1; done
                [ $skip = 1 ] || rm -f "$f"
            done
            find "$dir" -mindepth 1 -depth -type d -empty -delete
        else
            rm -rf "$dir"
        fi
        echo "cleaned ${entry%%:*}"
    done
fi

if [ "$SIMULATION" = 1 ]; then
    section "Uninstalling simulation packages"
    nvidia_all=$(pip list 2>/dev/null | awk '/^nvidia-/ {print $1}')
    removable=""
    # iterate until stable: a package goes if everything requiring it goes too
    candidates="$installed_sim $nvidia_all"
    changed=1
    while [ $changed = 1 ]; do
        changed=0
        for p in $candidates; do
            [[ " $removable " == *" $p "* ]] && continue
            req=$(pip show "$p" 2>/dev/null | awk -F': ' '/^Required-by/{print $2}' | tr -d ',')
            ok=1
            for r in $req; do
                [[ " $removable " == *" $r "* ]] || [ "$r" = "$p" ] || ok=0
            done
            if [ $ok = 1 ]; then removable+=" $p"; changed=1; fi
        done
    done
    kept=""
    for p in $candidates; do [[ " $removable " == *" $p "* ]] || kept+=" $p"; done
    echo "removing:$removable"
    [ -n "$kept" ] && echo "keeping (still required by other packages):$kept"
    [ -n "$removable" ] && pip uninstall -y $removable
    echo "numpy is now $(pip show numpy 2>/dev/null | awk '/^Version/{print $2}') (seq2squiggle pins numpy ^1.26; other tools were tested with 2.2.6)"
fi

if [ "$CACHES$BUILDS$SIMULATION" != 000 ]; then
    section "Disk afterwards"
    df -h --output=size,used,avail "$EXPDIR" | sed 's/^/  /'
fi
