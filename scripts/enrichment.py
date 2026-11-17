#!/usr/bin/env python3
"""
enrichment.py
=============
Per-region enrichment of a live adaptive-sampling run, from MinKNOW's
sequencing summary, an aligned BAM of the run's (sup) basecalls and the
readfish TSVs.

Each read is assigned to a phase by its start time and to a region by its
channel. A phase is a stretch of the run with one readfish invocation:
channel -> region comes from the `condition` column of the readfish TSVs in
that invocation's run directory (`runs/<timestamp>_<tool>_<device>/`; with
several tools side by side the per-region TSVs and the control reads of the
main TSV together give every channel). A phase without readfish ("-") puts
all channels into one region "all".

A read is labelled by its longest primary alignment (dorado's split reads are
merged into their parent via the `pi` tag) and counts as kept unless MinKNOW
ended it with a readfish unblock (`data_service_unblock*`). Per phase and
region it reports:
  chans, reads        channels and reads in the region
  <target>% etc.      read shares of the target, the other contigs and unmapped
  kept, tgt%kept      kept reads and the target's share among them
  tgt_kept            target reads kept, other_rej: other mapped reads unblocked
  tgt_kb/ch/h         target kilobases per channel and hour
  tgt_base%, enrich   target share of all bases, and its ratio to the phase's
                      control region (the readfish region with `control = true`)

Unblocked reads are short and about a fifth of them do not map, so tgt_kept
is somewhat overstated, alike in all adaptive regions.

Usage
-----
# one readfish invocation for the whole run (e.g. run 2, 72 h), in 6 h bins
python scripts/enrichment.py \\
    --summary <minknow_dir>/sequencing_summary_*.txt --bam <basecalls>/run2.bam \\
    --phase run:runs/<timestamp>_arms_X1 --bin-hours 6

# run 1 of 2026-11-17: no readfish, mm halves, then 4 tools interleaved
python scripts/enrichment.py \\
    --summary /data/uzh_ont/2026_11/run1/sequencing_summary_FBD09949_d4338097_822d3ca8.txt \\
    --bam /data/uzh_ont/2026_11/run1/basecalls/run1.bam \\
    --phase none:-:0:563.4 \\
    --phase mm_halves:runs/20261117_135607_mm_X1:563.4:914.4 \\
    --phase arms:runs/20261117_140209_arms_X1:927:1803

Times are seconds since the start of the acquisition (the summary's
start_time); a phase without times spans the whole run. The output is a TSV.
"""
import argparse
import collections
import csv
import glob
import subprocess
import sys
from pathlib import Path


def reads_by_parent(bam: str) -> dict:
    """parent read id -> [contig of the longest primary piece, bases, longest piece]"""
    out = {}
    # primary mapped and unmapped records, no secondary/supplementary
    proc = subprocess.Popen(["samtools", "view", "-F", "0x900", bam], stdout=subprocess.PIPE, text=True)
    for line in proc.stdout:
        f = line.split("\t", 11)
        tags = f[11].rstrip("\n").split("\t") if len(f) > 11 else []
        rid = next((t[5:] for t in tags if t.startswith("pi:Z:")), f[0])
        contig, n = ("*" if int(f[1]) & 4 else f[2]), len(f[9])
        entry = out.setdefault(rid, ["*", 0, 0])
        entry[1] += n
        if contig != "*" and n > entry[2]:
            entry[0], entry[2] = contig, n
    if proc.wait():
        sys.exit(f"Error: samtools view {bam} failed")
    return out


def channel_regions(run_dir: str) -> dict:
    """channel -> region (majority `condition`) over the readfish TSVs of one invocation"""
    votes = collections.defaultdict(collections.Counter)
    tsvs = [p for p in glob.glob(f"{run_dir}/*_readfish*.tsv") if not p.endswith("_batches.tsv")]
    if not tsvs:
        sys.exit(f"Error: no readfish TSVs in {run_dir}")
    for path in tsvs:
        for r in csv.DictReader(open(path), delimiter="\t"):
            votes[int(r["channel"])][r["condition"]] += 1
    return {c: v.most_common(1)[0][0] for c, v in votes.items()}


def parse_phase(spec: str):
    parts = spec.split(":")
    if len(parts) not in (2, 4):
        sys.exit(f"Error: --phase {spec}: expected NAME:RUN_DIR[:T0:T1]")
    name, run_dir = parts[:2]
    t0, t1 = (float(parts[2]), float(parts[3])) if len(parts) == 4 else (0.0, float("inf"))
    regions = None if run_dir == "-" else channel_regions(run_dir)
    return name, t0, t1, regions


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[1],
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--summary", required=True, help="MinKNOW sequencing_summary_*.txt")
    parser.add_argument("--bam", required=True, help="aligned BAM of the run's basecalls")
    parser.add_argument("--phase", action="append", required=True,
                        help="NAME:RUN_DIR[:T0:T1], RUN_DIR '-' for no readfish; repeatable")
    parser.add_argument("--target", default="HXB2_IN", help="target contig (default HXB2_IN)")
    parser.add_argument("--bin-hours", type=float, default=0,
                        help="split each phase into bins of this many hours")
    args = parser.parse_args()

    phases = [parse_phase(p) for p in args.phase]
    reads = reads_by_parent(args.bam)
    target = args.target

    stats = collections.defaultdict(collections.Counter)
    chans = collections.defaultdict(set)
    span = {}
    control_regions = set()
    for r in csv.DictReader(open(args.summary), delimiter="\t"):
        t, ch = float(r["start_time"]), int(r["channel"])
        for name, t0, t1, regions in phases:
            if not t0 <= t < t1:
                continue
            region = "all" if regions is None else regions.get(ch)
            if region is None:
                break
            if args.bin_hours:
                name = f"{name}_{int(t // (args.bin_hours * 3600)) * args.bin_hours:g}h"
            key = (name, region)
            chans[key].add(ch)
            a, b = span.get(name, (t, t))
            span[name] = (min(a, t), max(b, t))
            contig, bases, _ = reads.get(r["read_id"], ("*", 0, 0))
            label = "target" if contig == target else ("*" if contig == "*" else "other")
            s = stats[key]
            s["reads"] += 1
            s[label] += 1
            s["bases"] += bases
            s[label + "_b"] += bases
            if not r["end_reason"].startswith("data_service_unblock"):
                s["kept"] += 1
                s["kept_" + label] += 1
            break
    for name, _, _, regions in phases:
        if regions is not None:
            control_regions |= {reg for reg in regions.values() if reg == "control"}

    controls = {name: s["target_b"] / max(s["bases"], 1)
                for (name, region), s in stats.items() if region in control_regions}
    out = csv.writer(sys.stdout, delimiter="\t", lineterminator="\n")
    out.writerow(["phase", "region", "chans", "reads", f"{target}%", "other%", "unmapped%", "kept",
                  "tgt%kept", "tgt_kept", "other_rej", "tgt_kb/ch/h", "tgt_base%", "enrich"])
    for (name, region), s in sorted(stats.items(), key=lambda kv: (span[kv[0][0]][0], kv[0][1])):
        n, nc = s["reads"], len(chans[(name, region)])
        hours = max(span[name][1] - span[name][0], 1) / 3600
        share = s["target_b"] / max(s["bases"], 1)
        ctl = controls.get(name)
        out.writerow([
            name, region, nc, n,
            f"{s['target'] / n:.1%}", f"{s['other'] / n:.1%}", f"{s['*'] / n:.1%}",
            s["kept"], f"{s['kept_target'] / max(s['kept'], 1):.1%}",
            f"{s['kept_target'] / max(s['target'], 1):.1%}",
            f"{1 - s['kept_other'] / max(s['other'], 1):.1%}",
            f"{s['target_b'] / nc / hours / 1e3:.0f}",
            f"{share:.1%}", f"{share / ctl:.2f}" if ctl else "-"])


if __name__ == "__main__":
    main()
