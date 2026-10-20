#!/usr/bin/env python3
"""
make_check_sample.py
====================
Build a small labelled BLOW5 sample from a real adaptive-sampling run, for
scripts/check_tools.sh --sample.

Reads are taken from the run's *control* region (never unblocked, so full
length and unbiased) and labelled by their primary alignment in a BAM of
full-length (e.g. sup) basecalls. Read IDs are rewritten to the
squigulator-style form benchmark_aligner.py parses ground truth from:

    <read_id>!<contig>!<start>!<end>!<strand>     (contig "unmapped" if none)

and a manifest TSV (contig, true_label) marks the --targets contigs as 1 and
everything else as 0.

Usage
-----
python scripts/make_check_sample.py \\
    --pod5 /data/uzh_ont/2026_03/FBC32350_8a59354e_79e20d4a_*.pod5 \\
    --bam /data/uzh_ont/2026_03/basecalls/8a59354e.bam \\
    --readfish-tsv /data/uzh_ont/2026_03/8a59354e-c093-4906-8300-1c0868b2294e_readfish.tsv \\
    --targets HXB2_IN \\
    --per-class 1000 \\
    --out data/check/hxb2
# -> data/check/hxb2.blow5, data/check/hxb2_manifest.tsv
"""
import argparse
import csv
import logging
import random
import subprocess
import sys
from pathlib import Path

import pod5
import pyslow5

logger = logging.getLogger("make_check_sample")


def control_read_ids(readfish_tsv: str) -> set:
    """Read IDs readfish saw in the control region."""
    ids = set()
    with open(readfish_tsv) as fh:
        for row in csv.DictReader(fh, delimiter="\t"):
            if row["condition"] == "control":
                ids.add(row["read_id"])
    logger.info("%d reads in the control region", len(ids))
    return ids


def primary_alignments(bam: str, keep: set) -> dict:
    """read_id -> (contig, start, end, strand) of the primary alignment, for reads in keep."""
    hits = {}
    proc = subprocess.Popen(["samtools", "view", "-F", "0x900", bam],
                            stdout=subprocess.PIPE, text=True)
    for line in proc.stdout:
        f = line.split("\t", 10)
        read_id = f[0]
        if read_id not in keep:
            continue
        if f[2] == "*":
            hits[read_id] = ("unmapped", 0, 0, "+")
        else:
            start = int(f[3]) - 1
            # aligned reference length from the CIGAR (M, D, N, =, X consume the reference)
            num, ref_len = "", 0
            for c in f[5]:
                if c.isdigit():
                    num += c
                else:
                    if c in "MDN=X":
                        ref_len += int(num)
                    num = ""
            strand = "-" if int(f[1]) & 0x10 else "+"
            hits[read_id] = (f[2], start, start + ref_len, strand)
    if proc.wait() != 0:
        sys.exit("samtools view failed")
    return hits


def blow5_header(s5, run_info) -> dict:
    """BLOW5 header from a POD5 run info, empty strings for fields POD5 lacks."""
    header = {k: "" for k in s5.get_empty_header()}
    tracking = dict(run_info.tracking_id)
    for k in header:
        if k in tracking:
            header[k] = str(tracking[k])
    header.update({
        "run_id": run_info.acquisition_id,
        "flow_cell_id": run_info.flow_cell_id,
        "sample_id": run_info.sample_id,
        "sample_frequency": str(run_info.sample_rate),
        "sequencing_kit": run_info.sequencing_kit,
        "exp_start_time": str(run_info.acquisition_start_time),
    })
    return header


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--pod5", nargs="+", required=True, help="POD5 file(s) of the run")
    p.add_argument("--bam", required=True, help="BAM of full-length basecalls aligned to all references")
    p.add_argument("--readfish-tsv", required=True, help="readfish chunk log of the run (selects control reads)")
    p.add_argument("--targets", nargs="+", required=True, help="contigs labelled as target (true_label 1)")
    p.add_argument("--per-class", type=int, default=1000, help="reads per contig class (each contig + unmapped)")
    p.add_argument("--seed", type=int, default=1)
    p.add_argument("--out", required=True, help="output prefix")
    args = p.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(name)s %(message)s")

    control = control_read_ids(args.readfish_tsv)
    hits = primary_alignments(args.bam, control)

    by_contig = {}
    for read_id, hit in hits.items():
        by_contig.setdefault(hit[0], []).append(read_id)
    rng = random.Random(args.seed)
    chosen = {}
    for contig in sorted(by_contig):
        ids = sorted(by_contig[contig])
        pick = rng.sample(ids, min(args.per_class, len(ids)))
        logger.info("%s: %d control reads, sampling %d", contig, len(ids), len(pick))
        for read_id in pick:
            chosen[read_id] = hits[read_id]

    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    blow5_path = out.with_suffix(".blow5")
    s5 = pyslow5.Open(str(blow5_path), "w")
    with pod5.Reader(args.pod5[0]) as reader:
        run_info = next(reader.reads()).run_info
    s5.write_header(blow5_header(s5, run_info))
    written = 0
    for path in args.pod5:
        with pod5.Reader(path) as reader:
            for read in reader.reads(selection=list(chosen), missing_ok=True):
                read_id = str(read.read_id)
                contig, start, end, strand = chosen.pop(read_id)
                run_info = read.run_info
                digitisation = float(run_info.adc_max - run_info.adc_min + 1)
                record, aux = s5.get_empty_record(aux=True)
                record["read_id"] = f"{read_id}!{contig}!{start}!{end}!{strand}"
                record["read_group"] = 0
                record["digitisation"] = digitisation
                record["offset"] = float(read.calibration.offset)
                record["range"] = float(read.calibration.scale) * digitisation
                record["sampling_rate"] = float(run_info.sample_rate)
                record["len_raw_signal"] = len(read.signal)
                record["signal"] = read.signal
                aux["channel_number"] = str(read.pore.channel)
                aux["start_time"] = int(read.start_sample)
                aux["read_number"] = int(read.read_number)
                aux["start_mux"] = int(read.pore.well)
                aux["median_before"] = float(read.median_before)
                s5.write_record(record, aux)
                written += 1
    s5.close()
    if chosen:
        logger.warning("%d sampled reads were not found in the POD5 files", len(chosen))
    logger.info("Wrote %d reads to %s", written, blow5_path)

    manifest_path = Path(f"{out}_manifest.tsv")
    with open(manifest_path, "w") as fh:
        fh.write("contig\ttrue_label\n")
        for contig in sorted(by_contig):
            fh.write(f"{contig}\t{1 if contig in args.targets else 0}\n")
    logger.info("Wrote manifest %s", manifest_path)


if __name__ == "__main__":
    main()
