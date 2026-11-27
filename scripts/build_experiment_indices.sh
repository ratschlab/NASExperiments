#!/bin/bash
#
# Build all decision-algorithm indices for one experiment into
# $INDEX_DIR/<tool>/, the layout configs/templates/ expect.
#
#   EXPERIMENT=experiments/hxb2.env [SITE=sites/dev.env] scripts/task_runner.sh -t build_experiment_indices [1-8]
#

# index settings come from the experiment file; unset = previous values

# --- List of all tasks to run by default ---
export ALL_TASKS="1-8"

source "$SCRIPTDIR/build_common.sh"

: ${EXPERIMENT:?set EXPERIMENT to an experiments/*.env file}
: ${SITE:=$EXPDIR/sites/dev.env}
set -a
source "$EXPERIMENT"
source "$SITE"
set +a
export RAWHASH_DIR=$CODEDIR/rawhash2
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
    # k from experiment file (k >= 16 segfaults on HXB2_IN); --sparse dropped, not a flag of this build
    measure Collinearity \
    --ref $REF \
    --idx $OUTDIR/cl/$DATASET \
    -k ${CL_K:-15} --bw 1024 --n_threads $NUM_THREADS
}

f2() {
    build_start sp "Building Spumoni index for $DATASET.."
    # minimizer windows from experiment file
    measure spumoni build -r $REF -M -P -m -K ${SP_K:-4} -W ${SP_W:-11} -o $OUTDIR/sp/$DATASET
}

f3() {
    build_start mg "Building Metagraph index for $DATASET.."
    # k from experiment file
    measure metagraph build --mode canonical -v -p $NUM_THREADS -k ${MG_K:-19} -o $OUTDIR/mg/$DATASET $REF
    measure metagraph annotate -v -p $NUM_THREADS -i $OUTDIR/mg/$DATASET.dbg --anno-header -o $OUTDIR/mg/$DATASET $REF
}

f4() {
    build_start mm "Building Minimap2 index for $DATASET.."
    # k/w from experiment file
    measure minimap2 -t $NUM_THREADS -x map-ont -k ${MM_K:-15} -w ${MM_W:-10} -d $OUTDIR/mm/$DATASET.mmi $REF
}

f5() {
    build_start rb "Building readBouncer index for $DATASET.."
    # k-mer size from experiment file
    build_readbouncer_index ${RB_KMER_SIZE:-17}
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

f8() {
    build_start cn "Building Cumin index for $DATASET.."
    # index settings from experiment file
    measure cumin build --ref $REF --idx $OUTDIR/cn/$DATASET.idx \
        --k ${CN_K:-15} --s ${CN_S:-8} --downsample ${CN_DOWNSAMPLE:-2} --win ${CN_WIN:-4000} --overlap ${CN_OVERLAP:-2}
}
