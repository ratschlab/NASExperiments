#!/bin/bash

# --- List of all tasks to run by default ---
# This variable is used by the main script when no numbers are specified.
export ALL_TASKS="0-2"

# other variables
export DATADIR=/data/SimulatedDatasets/Zymo

f0() {
    spumoni build -r $DATADIR/Refs1.fasta -M -P -m -o $TMPDIR/zymo
}

f1() {
    spumoni run -r $TMPDIR/zymo -p $DATADIR/reads/Reads01_180.fasta -m -P -c -t 16
}

f2() {
    #
}