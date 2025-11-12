#!/bin/bash

# --- List of all tasks to run by default ---
# This variable is used by the main script when no numbers are specified.
export ALL_TASKS="0-7"

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
    measure $COLLINEARITY \
    --idx $TMPDIR/Zymo \
    --qry $DATADIR/reads/Reads01_180.fasta \
    --out $OUTDIR/zymo \
    --bw 16
}

f2() {
    measure $COLLINEARITY \
    --idx $TMPDIR/Zymo \
    --qry $DATADIR/reads/Reads01_180.fasta \
    --out $OUTDIR/zymo \
    --bw 32
}

f3() {
    measure $COLLINEARITY \
    --idx $TMPDIR/Zymo \
    --qry $DATADIR/reads/Reads01_180.fasta \
    --out $OUTDIR/zymo \
    --bw 64
}

f4() {
    measure $COLLINEARITY \
    --idx $TMPDIR/Zymo \
    --qry $DATADIR/reads/Reads01_180.fasta \
    --out $OUTDIR/zymo \
    --bw 128
}

f5() {
    measure $COLLINEARITY \
    --idx $TMPDIR/Zymo \
    --qry $DATADIR/reads/Reads01_180.fasta \
    --out $OUTDIR/zymo \
    --bw 256
}

f6() {
    measure $COLLINEARITY \
    --idx $TMPDIR/Zymo \
    --qry $DATADIR/reads/Reads01_180.fasta \
    --out $OUTDIR/zymo \
    --bw 512
}

f7() {
    measure $COLLINEARITY \
    --idx $TMPDIR/Zymo \
    --qry $DATADIR/reads/Reads01_180.fasta \
    --out $OUTDIR/zymo \
    --bw 1024
}
