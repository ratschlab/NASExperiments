#!/bin/bash

# --- List of all tasks to run by default ---
# This variable is used by the main script when no numbers are specified.
export ALL_TASKS="0-2"

# other variables
export DATADIR=/data/SimulatedDatasets/Zymo

export COLLINEARITY=/tmp/tmp.nyy4hBNiZM/collinearity/cmake-build-debug/Collinearity

# --- Individual Task Functions ---

f0() {
    measure $COLLINEARITY \
    --ref $DATADIR/Refs1.fasta \
    --idx $TMPDIR/Zymo
}

f1() {
    echo "Running with different bandwidths without compression.."
    bw_values=(16 32 64 128 256 512 1024)

    for bw in "${bw_values[@]}"; do
        measure $COLLINEARITY \
        --ref $DATADIR/Refs1.fasta \
        --idx $TMPDIR/Zymo --bw ${bw};

        measure $COLLINEARITY \
        --idx $TMPDIR/Zymo \
        --qry $DATADIR/reads/Reads0_180.fasta $DATADIR/reads/Reads1_180.fasta \
        --out $OUTDIR/zymo-cl-${bw}.tsv;
    done
}

f2() {
    echo "Running with different bandwidths with compression .."
    bw_values=(16 32 64 128 256 512 1024)

    for bw in "${bw_values[@]}"; do
        measure $COLLINEARITY \
        --ref $DATADIR/Refs1.fasta \
        --idx $TMPDIR/Zymo --bw ${bw} \
        --compressed;

        measure $COLLINEARITY \
        --idx $TMPDIR/Zymo \
        --qry $DATADIR/reads/Reads0_180.fasta $DATADIR/reads/Reads1_180.fasta \
        --out $OUTDIR/zymo-cl-${bw}.tsv;
    done
}
