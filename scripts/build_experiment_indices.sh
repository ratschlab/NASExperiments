#!/bin/bash
#
# Build all decision-algorithm indices for one experiment into
# $INDEX_DIR/<tool>/, the layout configs/templates/ expect.
#
#   EXPERIMENT=experiments/hxb2.env [SITE=sites/dev.env] scripts/task_runner.sh -t build_experiment_indices [1-7]
#

# --- List of all tasks to run by default ---
export ALL_TASKS="1-7"

source "$SCRIPTDIR/build_common.sh"

: ${EXPERIMENT:?set EXPERIMENT to an experiments/*.env file}
: ${SITE:=$EXPDIR/sites/dev.env}
set -a
source "$EXPERIMENT"
source "$SITE"
set +a
export RAWHASH_DIR=$CODEDIR/rawhash2
export PATH=$RAWHASH_DIR/build/bin:$PATH
export OUTDIR=$INDEX_DIR
export NUM_THREADS=$THREADS
export OMP_NUM_THREADS=$NUM_THREADS

# Re-wrap the reference to a fixed line length (some FASTAs, e.g. HXB2_IN, have
# uneven lines, which pysam/samtools faidx and hence sigmoni reject).
mkdir -p $OUTDIR/ref
awk '/^>/ { if (seq) print seq; print; seq = ""; next } { seq = seq $0 } END { if (seq) print seq }' $REF \
    | fold -w 60 > $OUTDIR/ref/$(basename $REF)
export REF=$OUTDIR/ref/$(basename $REF)

f1() {
    build_start cl "Building Collinearity index for $DATASET.."
    measure Collinearity \
    --ref $REF \
    --idx $OUTDIR/cl/$DATASET \
    --bw 1024 --sparse --n_threads $NUM_THREADS
}

f2() {
    build_start sp "Building Spumoni index for $DATASET.."
    measure spumoni build -r $REF -M -P -m -o $OUTDIR/sp/$DATASET
}

f3() {
    build_start mg "Building Metagraph index for $DATASET.."
    measure metagraph build --mode canonical -v -p $NUM_THREADS -k 19 -o $OUTDIR/mg/$DATASET $REF
    measure metagraph annotate -v -p $NUM_THREADS -i $OUTDIR/mg/$DATASET.dbg --anno-header -o $OUTDIR/mg/$DATASET $REF
}

f4() {
    build_start mm "Building Minimap2 index for $DATASET.."
    measure minimap2 -t $NUM_THREADS -x map-ont -d $OUTDIR/mm/$DATASET.mmi $REF
}

f5() {
    build_start rb "Building readBouncer index for $DATASET.."
    build_readbouncer_index 17
}

f6() {
    build_start rh "Building RawHash index for $DATASET.."
    measure rawhash2 --r10 -t $NUM_THREADS -d $OUTDIR/rh/$DATASET.ind -p \
        $RAWHASH_DIR/extern/local_kmer_models/uncalled_r1041_model_only_means.txt \
        $REF
}

f7() {
    build_start sg "Building Sigmoni index for $DATASET.."
    measure sigmoni-index -p $REF \
        -o $OUTDIR/sg --spumoni-path $SPUMONI_BUILD_DIR \
        --poremodel $CODEDIR/sigmoni/poremodel/model_r1041_400bps_dm_it2.tsv
}
