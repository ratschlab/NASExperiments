#!/bin/bash
#
# Run one readfish decision algorithm on a live MinKNOW sequencing position.
#
#   scripts/run_gridion.sh -t <tool> -d <device> -n <experiment_name> [options] [-- <readfish args>]
#
# Renders the configs for the site (scripts/render_configs.sh), validates the
# chosen one, starts a metagraph server for metagraphRF if none is listening,
# and runs `readfish targets` from a fresh run directory
# runs/<timestamp>_<tool>_<device>/ that collects the config, logs and the
# readfish chunk log. Expects the selectiveseq conda env to be active.
#
set -euo pipefail

TOOLS="mm mg mg_query mg_align sp sg rh rb cl"

usage() {
    echo "Usage: $0 -t <tool> -d <device> -n <experiment_name> [options] [-- <readfish args>]"
    echo ""
    echo "Options:"
    echo "  -t, --tool       One of: $TOOLS"
    echo "  -d, --device     MinKNOW sequencing position, e.g. X1 or MN12345"
    echo "  -n, --name       Experiment name passed to readfish"
    echo "  -s, --site       Site file (default: sites/gridion.env)"
    echo "      --dry-run    Run readfish without sending unblocks"
    echo "  -h, --help       Display this help message."
    echo ""
    echo "Everything after '--' is passed to 'readfish targets' unchanged."
    echo ""
    echo "Example:"
    echo "  $0 -t mm -d X1 -n zymo_mm_run1"
    exit 1
}

export EXPDIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )/.." &> /dev/null && pwd )
SCRIPTDIR=$EXPDIR/scripts

TOOL=""
DEVICE=""
NAME=""
SITE_FILE=$EXPDIR/sites/gridion.env
READFISH_ARGS=()

while [[ $# -gt 0 ]]; do
    case $1 in
        -t|--tool) TOOL=$2; shift 2 ;;
        -d|--device) DEVICE=$2; shift 2 ;;
        -n|--name) NAME=$2; shift 2 ;;
        -s|--site) SITE_FILE=$2; shift 2 ;;
        --dry-run) READFISH_ARGS+=(--dry-run); shift ;;
        -h|--help) usage ;;
        --) shift; READFISH_ARGS+=("$@"); break ;;
        *) echo "Error: Unknown argument '$1'" >&2; usage ;;
    esac
done

[ -n "$TOOL" ] && [ -n "$DEVICE" ] && [ -n "$NAME" ] || usage
[[ " $TOOLS " == *" $TOOL "* ]] || { echo "Error: Unknown tool '$TOOL'." >&2; usage; }
command -v readfish >/dev/null || { echo "Error: readfish not found; activate the selectiveseq env." >&2; exit 1; }
if [ "${MINKNOW_SIMULATOR:-}" = "true" ]; then
    echo "Warning: MINKNOW_SIMULATOR=true is set; readfish will expect the MinKNOW API simulator." >&2
fi

# --- Configs ---
SITE=$(basename "$SITE_FILE" .env)
"$SCRIPTDIR/render_configs.sh" "$SITE_FILE" > /dev/null
set -a
source "$SITE_FILE"
set +a
TOML=$EXPDIR/configs/generated/$SITE/rf_${TOOL}_${DATASET}.toml

# --- Run directory ---
RUNDIR=$EXPDIR/runs/$(date +"%Y%m%d_%H%M%S")_${TOOL}_${DEVICE}
mkdir -p "$RUNDIR"
cp "$TOML" "$RUNDIR/"
{
    echo "tool=$TOOL device=$DEVICE experiment_name=$NAME site=$SITE_FILE"
    echo "commit=$(git -C "$EXPDIR" rev-parse HEAD)$(git -C "$EXPDIR" diff --quiet || echo ' (dirty)')"
    echo "readfish $(pip show readfish 2>/dev/null | awk '/^Version/{print $2}')"
} > "$RUNDIR/run_info.txt"
echo "Run directory: $RUNDIR"

# --- metagraph server for metagraphRF ---
source "$SCRIPTDIR/gridion_common.sh"
trap mg_server_stop EXIT
if [ "$TOOL" = "mg" ]; then
    mg_server_start "$RUNDIR/metagraph_server.log"
fi

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
