#!/bin/bash

# --- List of all tasks to run by default ---
# This variable is used by the main script when no numbers are specified.
export ALL_TASKS="1-2"

# other variables
export DATADIR=/data/SimulatedDatasets/Gut
export READDIR=$DATADIR/basecalled/180/fast

export COLLINEARITY=/tmp/tmp.nyy4hBNiZM/collinearity/cmake-build-debug/Collinearity

# --- Individual Task Functions ---

f1() {
    echo "Running with different bandwidths.."
    bw_values=(16 32 64 128 256 512 1024)

    for bw in "${bw_values[@]}"; do
        measure $COLLINEARITY \
        --ref $DATADIR/Refs_d0.2_Comm_1.fa \
        --idx $TMPDIR/Gut02 --bw ${bw};

        measure $COLLINEARITY \
        --idx $TMPDIR/Gut02 \
        --qry $READDIR/reads_d0.2_Comm_0.fasta $READDIR/reads_d0.2_Comm_1.fasta \
        --out $OUTDIR/gut02-cl-${bw}.tsv;
    done
}

f2() {
    echo "Running with different bandwidths.."
    bw_values=(16 32 64 128 256 512 1024)

    for bw in "${bw_values[@]}"; do
        measure $COLLINEARITY \
        --ref $DATADIR/Refs_d0.2_Comm_1.fa \
        --idx $TMPDIR/Gut02 --bw ${bw} \
        --compressed

        measure $COLLINEARITY \
        --idx $TMPDIR/Gut02 \
        --qry $READDIR/reads_d0.2_Comm_0.fasta $READDIR/reads_d0.2_Comm_1.fasta \
        --out $OUTDIR/gut02-cl-${bw}.tsv;
    done
}