#!/bin/bash
#
# Run readfish decision algorithms on a live MinKNOW sequencing position.
#
#   scripts/run_gridion.sh -t <tool>[,<tool>...] -d <device> -n <experiment_name> [-s <site.env>] [-e <experiment.env>] [options] [-- <readfish args>]
#
# Renders the configs for the site (scripts/render_configs.sh), validates the
# chosen one, and runs `readfish targets` from a fresh run directory
# runs/<timestamp>_<tool>_<device>/ that collects the config, logs and the
# readfish chunk log. Expects the selectiveseq conda env to be active.
#
# With several tools (-t mm,mg_local,sp), they run side by side on one flow
# cell: scripts/render_arms.py combines their configs into one with a region
# per tool plus the control region, interleaved over the channels
# (channel c runs region (c - 1) % N), each tool in its own readfish worker
# process with --arm-threads threads (default 2). Needs readfish from the
# ratschlab fork (ak/parallel-arms, installed by setup.sh). The run directory
# is runs/<timestamp>_arms_<device>/; readfish writes per-region logs there.
#
set -euo pipefail

TOOLS="mm mg mg_local mg_map sp sg rh rb cl cn"

usage() {
    echo "Usage: $0 -t <tool>[,<tool>...] -d <device> -n <experiment_name> [options] [-- <readfish args>]"
    echo ""
    echo "Options:"
    echo "  -t, --tool       One of: $TOOLS"
    echo "                   or several, comma-separated, to run them side by side"
    echo "      --arm-threads  Threads per tool when running several (default 2)"
    echo "  -d, --device     MinKNOW sequencing position, e.g. X1 or MN12345"
    echo "  -n, --name       Experiment name passed to readfish"
    echo "  -s, --site       Site file (default: sites/gridion.env)"
    echo "  -e, --experiment Experiment file (default: experiments/hxb2.env)"
    echo "      --dry-run    Run readfish without sending unblocks"
    echo "  -h, --help       Display this help message."
    echo ""
    echo "Everything after '--' is passed to 'readfish targets' unchanged."
    echo ""
    echo "Example:"
    echo "  $0 -t mm -d X1 -n hxb2_mm_run1"
    echo "  $0 -t mm,mg_local,mg,sp,rb,cl,rh -d X1 -n hxb2_arms_run1 --dry-run"
    exit 1
}

export EXPDIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )/.." &> /dev/null && pwd )
SCRIPTDIR=$EXPDIR/scripts

TOOL=""
ARM_THREADS=2
DEVICE=""
NAME=""
SITE_FILE=$EXPDIR/sites/gridion.env
EXPERIMENT_FILE=$EXPDIR/experiments/hxb2.env
READFISH_ARGS=()

while [[ $# -gt 0 ]]; do
    case $1 in
        -t|--tool) TOOL=$2; shift 2 ;;
        --arm-threads) ARM_THREADS=$2; shift 2 ;;
        -d|--device) DEVICE=$2; shift 2 ;;
        -n|--name) NAME=$2; shift 2 ;;
        -s|--site) SITE_FILE=$2; shift 2 ;;
        -e|--experiment) EXPERIMENT_FILE=$2; shift 2 ;;
        --dry-run) READFISH_ARGS+=(--dry-run); shift ;;
        -h|--help) usage ;;
        --) shift; READFISH_ARGS+=("$@"); break ;;
        *) echo "Error: Unknown argument '$1'" >&2; usage ;;
    esac
done

[ -n "$TOOL" ] && [ -n "$DEVICE" ] && [ -n "$NAME" ] || usage
IFS=, read -ra TOOL_LIST <<< "$TOOL"
for t in "${TOOL_LIST[@]}"; do
    [[ " $TOOLS " == *" $t "* ]] || { echo "Error: Unknown tool '$t'." >&2; usage; }
done
command -v readfish >/dev/null || { echo "Error: readfish not found; activate the selectiveseq env." >&2; exit 1; }
if [ "${MINKNOW_SIMULATOR:-}" = "true" ]; then
    echo "Warning: MINKNOW_SIMULATOR=true is set; readfish will expect the MinKNOW API simulator." >&2
fi

# --- Configs ---
SITE=$(basename "$SITE_FILE" .env)
"$SCRIPTDIR/render_configs.sh" "$SITE_FILE" "$EXPERIMENT_FILE" > /dev/null
set -a
source "$EXPERIMENT_FILE"
source "$SITE_FILE"
set +a
if [ ${#TOOL_LIST[@]} -gt 1 ]; then
    python -c "import readfish._arms" 2>/dev/null || {
        echo "Error: running several tools needs readfish from ratschlab/readfish ak/parallel-arms (see setup.sh)." >&2
        exit 1
    }
    TOML=$(python "$SCRIPTDIR/render_arms.py" "$EXPDIR/configs/generated/$SITE" "$DATASET" \
        "${TOOL_LIST[@]}" --threads "$ARM_THREADS")
    RUN_LABEL=arms
else
    TOML=$EXPDIR/configs/generated/$SITE/rf_${TOOL}_${DATASET}.toml
    RUN_LABEL=$TOOL
fi

# --- Run directory ---
RUNDIR=$EXPDIR/runs/$(date +"%Y%m%d_%H%M%S")_${RUN_LABEL}_${DEVICE}
mkdir -p "$RUNDIR"
cp "$TOML" "$RUNDIR/"
{
    echo "tool=$TOOL arm_threads=$ARM_THREADS device=$DEVICE experiment_name=$NAME site=$SITE_FILE experiment=$EXPERIMENT_FILE"
    echo "commit=$(git -C "$EXPDIR" rev-parse HEAD)$(git -C "$EXPDIR" diff --quiet || echo ' (dirty)')"
    echo "readfish $(pip show readfish 2>/dev/null | awk '/^Version/{print $2}') code/readfish $(git -C "$EXPDIR/code/readfish" rev-parse --abbrev-ref HEAD 2>/dev/null) $(git -C "$EXPDIR/code/readfish" rev-parse --short HEAD 2>/dev/null)"
} > "$RUNDIR/run_info.txt"
echo "Run directory: $RUNDIR"

# --- Run readfish ---
cd "$RUNDIR"
readfish validate "$TOML" --log-file "$RUNDIR/readfish_validate.log" || {
    echo "Error: readfish validate failed, see $RUNDIR/readfish_validate.log" >&2
    exit 1
}

readfish targets \
    --toml "$TOML" \
    --device "$DEVICE" \
    --experiment-name "$NAME" \
    --log-file "$RUNDIR/readfish.log" \
    "${READFISH_ARGS[@]}"
