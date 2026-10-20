#!/bin/bash
#
# Render the readfish configs in configs/templates/ for one machine.
#
#   scripts/render_configs.sh <site.env> [output_dir]
#
# The site file (see sites/) is sourced with EXPDIR set to the repo root and
# must define every ${VAR} the templates use. Each template is rendered with
# the decision rules from configs/regions/$REGIONS.toml appended and written
# to <output_dir>/rf_<tool>_<DATASET>.toml
# (default output_dir: configs/generated/<site>).
#
set -euo pipefail

usage() {
    echo "Usage: $0 <site.env> [output_dir]" >&2
    exit 1
}
[ $# -ge 1 ] && [ $# -le 2 ] || usage
SITE_FILE=$1
[ -f "$SITE_FILE" ] || { echo "Error: site file '$SITE_FILE' not found." >&2; exit 1; }
command -v envsubst >/dev/null || { echo "Error: envsubst not found (apt install gettext-base)." >&2; exit 1; }

export EXPDIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )/.." &> /dev/null && pwd )
TEMPLATE_DIR=$EXPDIR/configs/templates
SITE=$(basename "$SITE_FILE" .env)

set -a
source "$SITE_FILE"
set +a

REGIONS_FILE=$EXPDIR/configs/regions/$REGIONS.toml
[ -f "$REGIONS_FILE" ] || { echo "Error: regions file '$REGIONS_FILE' not found." >&2; exit 1; }
OUT=${2:-$EXPDIR/configs/generated/$SITE}
mkdir -p "$OUT"

for tpl in "$TEMPLATE_DIR"/rf_*.toml; do
    tool=$(basename "$tpl" .toml)
    # only substitute ${VAR} references, and fail on any that are unset
    vars=$(grep -o '\${[A-Za-z_][A-Za-z0-9_]*}' "$tpl" | sort -u || true)
    for v in $vars; do
        name=${v:2:-1}
        [ -n "${!name:-}" ] || { echo "Error: $tool needs \$$name, not set in $SITE_FILE." >&2; exit 1; }
    done
    out_file=$OUT/${tool}_${DATASET}.toml
    { envsubst "$(echo $vars)" < "$tpl"; echo; cat "$REGIONS_FILE"; } > "$out_file"
    echo "$out_file"
done
