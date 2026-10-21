#!/bin/bash
#
# Check that the readfish decision algorithms are ready to run on this machine.
#
#   scripts/check_tools.sh [-s <site.env>] [-e <experiment.env>] [-t <tool>]... [--sample <reads>]
#
# For each tool, using its rendered config from scripts/render_configs.sh:
#   1. plugin   the readfish plugin module imports
#   2. index    every absolute path in [mapper_settings] exists (as a file,
#               directory or prefix of files); for mg also MG_GRAPH/MG_ANNO
#   3. validate `readfish validate` initialises caller and aligner
#               (starts a metagraph server for mg if none is listening)
#   4. map      with --sample: benchmark_aligner.py runs the plugin on the
#               given BLOW5 file(s), truncated to the readfish decision
#               window, and reports how many target reads are kept and how
#               many other reads are ejected (truth from the read IDs and
#               --manifest, see scripts/make_check_sample.py)
# Later steps are skipped once a step fails. Logs go to
# runs/check_<timestamp>/. Expects the selectiveseq conda env to be active.
#
set -uo pipefail

ALL_TOOLS="mm mg mg_local sp sg rh rb cl"
# tools that work on raw signal and need no basecalling for step 4
RAW_TOOLS="rh sg"

usage() {
    echo "Usage: $0 [-s <site.env>] [-t <tool>]... [--sample <reads>]"
    echo ""
    echo "Options:"
    echo "  -s, --site       Site file (default: sites/gridion.env)"
    echo "  -e, --experiment Experiment file (default: experiments/hxb2.env)"
    echo "  -t, --tool       Tool to check, repeatable (default: all of $ALL_TOOLS)"
    echo "      --sample     BLOW5 file, glob or folder for the mapping step"
    echo "      --manifest   contig/true_label TSV (default: <sample>_manifest.tsv)"
    echo "      --truncate   raw samples per read (default: $TRUNCATE, 1.2 s at 5 kHz)"
    echo "      --batches    Batches of $BATCH_SIZE reads to map per tool (default: all)"
    echo "  -h, --help       Display this help message."
    exit 1
}

export EXPDIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )/.." &> /dev/null && pwd )
SCRIPTDIR=$EXPDIR/scripts
SITE_FILE=$EXPDIR/sites/gridion.env
EXPERIMENT_FILE=$EXPDIR/experiments/hxb2.env
TOOLS=()
SAMPLE=""
MANIFEST=""
# 6000 samples (1.2 s at 5 kHz) reproduces the live mappy_rs decisions of the
# 2026-03-25 HXB2 run (58% of HXB2_IN kept, >95% of other reads ejected)
TRUNCATE=6000
BATCH_SIZE=512
MAX_BATCHES=0

while [[ $# -gt 0 ]]; do
    case $1 in
        -s|--site) SITE_FILE=$2; shift 2 ;;
        -e|--experiment) EXPERIMENT_FILE=$2; shift 2 ;;
        -t|--tool) TOOLS+=("$2"); shift 2 ;;
        --sample) SAMPLE=$2; shift 2 ;;
        --manifest) MANIFEST=$2; shift 2 ;;
        --truncate) TRUNCATE=$2; shift 2 ;;
        --batches) MAX_BATCHES=$2; shift 2 ;;
        -h|--help) usage ;;
        *) echo "Error: Unknown argument '$1'" >&2; usage ;;
    esac
done
[ ${#TOOLS[@]} -gt 0 ] || TOOLS=($ALL_TOOLS)
for t in "${TOOLS[@]}"; do
    [[ " $ALL_TOOLS " == *" $t "* ]] || { echo "Error: Unknown tool '$t'." >&2; usage; }
done
if [ -n "$SAMPLE" ] && [ -z "$MANIFEST" ]; then
    MANIFEST=${SAMPLE%.blow5}_manifest.tsv
fi
if [ -n "$SAMPLE" ] && [ ! -f "$MANIFEST" ]; then
    echo "Error: manifest '$MANIFEST' not found; pass --manifest." >&2; exit 1
fi
command -v readfish >/dev/null || { echo "Error: readfish not found; activate the selectiveseq env." >&2; exit 1; }

# --- Configs ---
SITE=$(basename "$SITE_FILE" .env)
"$SCRIPTDIR/render_configs.sh" "$SITE_FILE" "$EXPERIMENT_FILE" > /dev/null || exit 1
set -a
source "$EXPERIMENT_FILE"
source "$SITE_FILE"
set +a
source "$SCRIPTDIR/gridion_common.sh"
trap mg_server_stop EXIT

LOGS=$EXPDIR/runs/check_$(date +"%Y%m%d_%H%M%S")
mkdir -p "$LOGS"
echo "Logs: $LOGS"

# path_exists <path>: file, directory, or prefix of at least one file
path_exists() {
    [ -e "$1" ] || compgen -G "$1*" > /dev/null
}

declare -A RESULT
STEPS="plugin index validate map"

check_tool() {
    local tool=$1
    local toml=$EXPDIR/configs/generated/$SITE/rf_${tool}_${DATASET}.toml
    local log=$LOGS/$tool
    local module p missing=()

    # 1. plugin
    module=$(python -I "$SCRIPTDIR/mapper_settings.py" "$toml" module)
    if ! python -c "import $module" > "$log.plugin.log" 2>&1; then
        RESULT[$tool,plugin]="FAIL"; return
    fi
    RESULT[$tool,plugin]="ok"

    # 2. index
    local paths
    paths=$(python -I "$SCRIPTDIR/mapper_settings.py" "$toml" paths)
    [ "$tool" = "mg" ] && paths+=$'\n'"$MG_GRAPH"$'\n'"$MG_ANNO"
    while read -r p; do
        [ -z "$p" ] || path_exists "$p" || missing+=("$p")
    done <<< "$paths"
    if [ ${#missing[@]} -gt 0 ]; then
        printf '%s\n' "${missing[@]}" > "$log.index.log"
        RESULT[$tool,index]="FAIL"; return
    fi
    RESULT[$tool,index]="ok"

    # 3. validate
    if [ "$tool" = "mg" ] && ! mg_server_start "$log.metagraph_server.log"; then
        RESULT[$tool,validate]="FAIL"; return
    fi
    if ! (cd "$LOGS" && timeout 300 readfish validate "$toml" --log-file "$log.validate.log" > /dev/null 2>&1); then
        RESULT[$tool,validate]="FAIL"; return
    fi
    RESULT[$tool,validate]="ok"

    # 4. map
    [ -n "$SAMPLE" ] || { RESULT[$tool,map]="-"; return; }
    local basecall_args=()
    if [[ " $RAW_TOOLS " != *" $tool "* ]]; then
        basecall_args=(--basecall-address "$BASECALL_ADDRESS" --basecall-config "$BASECALL_CONFIG")
    fi
    if ! timeout 1800 python "$SCRIPTDIR/benchmark_aligner.py" \
            --input "$SAMPLE" \
            --plugin "$module" \
            --plugin-args "$(python -I "$SCRIPTDIR/mapper_settings.py" "$toml" args)" \
            --output "$LOGS/$tool/" \
            --tool "$tool" \
            --dataset check \
            --manifest "$MANIFEST" \
            --truncate-signals "$TRUNCATE" \
            --batch-size "$BATCH_SIZE" \
            --max-batches "$MAX_BATCHES" \
            "${basecall_args[@]}" > "$log.map.log" 2>&1; then
        RESULT[$tool,map]="FAIL"; return
    fi
    # a mapped read is kept (stop_receiving), an unmapped one ejected (unblock)
    RESULT[$tool,map]=$(python -I -c "
import csv
n = {(t, m): 0 for t in '01' for m in '01'}
for r in csv.DictReader(open('$LOGS/$tool/${tool}_check_per_read.tsv'), delimiter='\t'):
    n[r['true_label'], str(int(r['mapped'] in ('1', 'True')))] += 1
tgt, oth = n['1', '1'] + n['1', '0'], n['0', '1'] + n['0', '0']
print(f\"kept {n['1', '1']}/{tgt} ejected {n['0', '0']}/{oth}\")")
}

for tool in "${TOOLS[@]}"; do
    echo "--- Checking $tool ---"
    check_tool "$tool"
    [ "$tool" = "mg" ] && mg_server_stop
done

# --- Summary ---
echo ""
printf '%-10s' tool; for s in $STEPS; do printf '%-30s' "$s"; done; echo
FAILED=0
for tool in "${TOOLS[@]}"; do
    printf '%-10s' "$tool"
    for s in $STEPS; do
        r=${RESULT[$tool,$s]:-skipped}
        [ "$r" = "FAIL" ] && FAILED=1
        printf '%-30s' "$r"
    done
    echo
done
echo ""
echo "Logs per tool and step: $LOGS/<tool>.<step>.log"
exit $FAILED
