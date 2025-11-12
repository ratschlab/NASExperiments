#!/bin/bash

# --- List of all tasks to run by default ---
# This variable is used by the main script when no numbers are specified.
export ALL_TASKS="0-1"

# other variables
export DATADIR=/data/SimulatedDatasets/Zymo

f0() {
    measure minimap2 -x map-ont -d $TMPDIR/zymo.mmi $DATADIR/Refs1.fasta
}

f1() {
    measure minimap2 -x map-ont --secondary=no $TMPDIR/zymo.mmi $DATADIR/reads/Reads0_180.fasta > $OUTDIR/zymo-mm.paf
    measure minimap2 -x map-ont --secondary=no $TMPDIR/zymo.mmi $DATADIR/reads/Reads1_180.fasta >> $OUTDIR/zymo-mm.paf
}