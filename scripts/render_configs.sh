#!/bin/bash
#
# Render the readfish configs in configs/templates/ for one machine and experiment.
#
#   scripts/render_configs.sh <site.env> <experiment.env> [output_dir]
#
# The experiment file (see experiments/: DATASET, REF, TARGETS) and then the
# site file (see sites/: socket, threads, index locations) are sourced with
# EXPDIR set to the repo root; together they must define every ${VAR} the
# templates use. Each template is rendered with the decision rules from
# configs/regions/$REGIONS.toml appended and written to
# <output_dir>/rf_<tool>_<DATASET>.toml (default output_dir: configs/generated/<site>).
#
set -euo pipefail

usage() {
    echo "Usage: $0 <site.env> <experiment.env> [output_dir]" >&2
    exit 1
}
[ $# -ge 2 ] && [ $# -le 3 ] || usage
SITE_FILE=$1
EXPERIMENT_FILE=$2
for f in "$SITE_FILE" "$EXPERIMENT_FILE"; do
    [ -f "$f" ] || { echo "Error: '$f' not found." >&2; exit 1; }
done
command -v envsubst >/dev/null || { echo "Error: envsubst not found (apt install gettext-base)." >&2; exit 1; }

export EXPDIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )/.." &> /dev/null && pwd )
TEMPLATE_DIR=$EXPDIR/configs/templates
SITE=$(basename "$SITE_FILE" .env)

set -a
source "$EXPERIMENT_FILE"
source "$SITE_FILE"
set +a

REGIONS_FILE=$EXPDIR/configs/regions/$REGIONS.toml
[ -f "$REGIONS_FILE" ] || { echo "Error: regions file '$REGIONS_FILE' not found." >&2; exit 1; }
OUT=${3:-$EXPDIR/configs/generated/$SITE}
mkdir -p "$OUT"

# substitute <file>: only ${VAR} references, failing on any that are unset
substitute() {
    local file=$1 vars v name
    vars=$(grep -o '\${[A-Za-z_][A-Za-z0-9_]*}' "$file" | sort -u || true)
    for v in $vars; do
        name=${v:2:-1}
        [ -n "${!name:-}" ] || { echo "Error: $(basename "$file") needs \$$name, not set in $SITE_FILE or $EXPERIMENT_FILE." >&2; return 1; }
    done
    envsubst "$(echo $vars)" < "$file"
}

regions=$(substitute "$REGIONS_FILE")
for tpl in "$TEMPLATE_DIR"/rf_*.toml; do
    tool=$(basename "$tpl" .toml)
    out_file=$OUT/${tool}_${DATASET}.toml
    { substitute "$tpl"; echo; echo "$regions"; } > "$out_file"
    echo "$out_file"
done
