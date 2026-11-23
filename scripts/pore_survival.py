#!/usr/bin/env python3
"""
pore_survival.py
================
Per-channel pore survival of a live adaptive-sampling run against what
readfish did on the channel, to see whether unblocking wears pores out.

Survival comes from MinKNOW's pore scans (`pore_scan_data_*.csv`): the number
of wells classed `single_pore` per channel at each scan. Activity comes from
the sequencing summary. The run is split at the first pore scan at or after
--split-hours: activity is measured before it, survival after it, for the
channels with at least one single-pore well at that scan. (Measuring both over
the same time confounds them: a channel whose pores live longer also reads and
unblocks more.)

Per channel:
  wells0, wells_split   single-pore wells at the first and the split scan
  well_h_after          well-hours after the split scan per well alive then
  death_h               time of the first scan after which no single-pore well
                        is seen again (run end if never)
  unblocks_per_strand_h readfish unblocks per hour with a strand in the pore
  kept_frac             share of that strand time in reads not unblocked
  strand_frac           share of the time before the split with a strand

Prints per region the means/medians and the half-life of the region's wells
(first scan with at least half of its initial wells gone), the Spearman
correlations of the activity measures with well_h_after (all regions and
tools only, permutation p-values), and a permutation test of well_h_after
between the adaptive regions and the control. Regions come from the
readfish TSVs as in scripts/enrichment.py.

Usage
-----
python scripts/pore_survival.py \\
    --pore-scans /data/uzh_ont/2026_11/run2/pore_scan_data_FBD09949_32d5b518_27edada3.csv \\
    --summary /data/uzh_ont/2026_11/run2/sequencing_summary_FBD09949_32d5b518_27edada3.txt \\
    --run-dir /data/uzh_ont/2026_11/20261117_144544_arms_X1 \\
    --output /data/uzh_ont/2026_11/run2/enrichment/pore_survival_per_channel.tsv

Stretches in which MinKNOW did not write unblocked reads (run 2, 4.7-6.3 h)
undercount unblocks, so put the split before them.
"""
import argparse
import collections
import csv

import numpy as np

from enrichment import channel_regions


def rank(x):
    return np.argsort(np.argsort(x)).astype(float)


def spearman(x, y, n_perm=5000, seed=1):
    rx, ry = rank(np.asarray(x)), rank(np.asarray(y))
    rho = np.corrcoef(rx, ry)[0, 1]
    rng = np.random.default_rng(seed)
    perm = np.array([np.corrcoef(rx, rng.permutation(ry))[0, 1] for _ in range(n_perm)])
    return rho, (np.abs(perm) >= abs(rho)).mean()


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[1],
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--pore-scans", required=True, help="MinKNOW pore_scan_data_*.csv")
    parser.add_argument("--summary", required=True, help="MinKNOW sequencing_summary_*.txt")
    parser.add_argument("--run-dir", required=True, help="readfish run directory (regions per channel)")
    parser.add_argument("--split-hours", type=float, default=4.5,
                        help="split at the first pore scan at or after this time (default 4.5)")
    parser.add_argument("--output", help="per-channel TSV")
    args = parser.parse_args()

    regions = channel_regions(args.run_dir)
    names = sorted(set(regions.values()), key=lambda r: (r == "control", r))

    wells = collections.defaultdict(collections.Counter)
    scan_h = {}
    for r in csv.DictReader(open(args.pore_scans)):
        s = int(r["scan_number"])
        scan_h.setdefault(s, float(r["seconds_since_start_of_run"] or 0) / 3600)
        if r["mux_scan_assessment"] == "single_pore":
            wells[int(r["channel"])][s] += 1
    scans = sorted(scan_h)
    times = np.array([scan_h[s] for s in scans])
    split = int(np.argmax(times >= args.split_hours))
    if times[split] < args.split_hours:
        raise SystemExit(f"Error: no pore scan at or after {args.split_hours} h")
    split_s = times[split] * 3600

    act = collections.defaultdict(collections.Counter)
    end_s = 0.0
    for r in csv.DictReader(open(args.summary), delimiter="\t"):
        t, d = float(r["start_time"]), float(r["duration"])
        end_s = max(end_s, t + d)
        if t >= split_s:
            continue
        a = act[int(r["channel"])]
        a["strand"] += d
        if r["end_reason"].startswith("data_service_unblock"):
            a["unblocks"] += 1
        else:
            a["kept"] += d
    dt = np.diff(np.append(times, end_s / 3600))

    rows = []
    for ch in sorted(regions):
        w = np.array([wells[ch][s] for s in scans])
        a = act[ch]
        if w[split] == 0 or a["strand"] < 60:
            continue
        alive = split + np.nonzero(w[split:])[0][-1]
        rows.append(dict(
            channel=ch, region=regions[ch], wells0=int(w[0]), wells_split=int(w[split]),
            well_h_after=round(float((w[split:] * dt[split:]).sum() / w[split]), 2),
            death_h=round(float(times[alive + 1] if alive + 1 < len(times) else end_s / 3600), 2),
            unblocks_per_strand_h=round(a["unblocks"] / (a["strand"] / 3600), 1),
            kept_frac=round(a["kept"] / a["strand"], 4),
            strand_frac=round(a["strand"] / split_s, 4)))

    print(f"split at pore scan {scans[split]} ({times[split]:.1f} h); channels with a single-pore well then")
    print("region      chans  half_life_h  wells@split  well_h_after  death_h  unblocks/strand-h  kept_frac")
    for name in names:
        rs = [r for r in rows if r["region"] == name]
        chs = [c for c, reg in regions.items() if reg == name]
        tot = np.array([sum(wells[c][s] for c in chs) for s in scans])
        half = times[np.argmax(tot <= tot[0] / 2)] if (tot <= tot[0] / 2).any() else float("nan")
        if not rs:
            continue
        print(f"{name:10} {len(rs):6} {half:12.1f} {np.mean([r['wells_split'] for r in rs]):12.2f} "
              f"{np.mean([r['well_h_after'] for r in rs]):13.1f} {np.median([r['death_h'] for r in rs]):8.1f} "
              f"{np.median([r['unblocks_per_strand_h'] for r in rs]):18.0f} {np.median([r['kept_frac'] for r in rs]):10.0%}")

    print("\nSpearman correlation with well_h_after (permutation p)")
    for label, rs in [("all regions", rows), ("adaptive regions", [r for r in rows if r["region"] != "control"])]:
        cells = []
        for x in ("unblocks_per_strand_h", "kept_frac", "strand_frac"):
            rho, p = spearman([r[x] for r in rs], [r["well_h_after"] for r in rs])
            cells.append(f"{x} {rho:+.2f} (p={p:.3f})")
        print(f"  {label} (n={len(rs)}): " + "; ".join(cells))

    c = np.array([r["well_h_after"] for r in rows if r["region"] == "control"])
    t = np.array([r["well_h_after"] for r in rows if r["region"] != "control"])
    if len(c) and len(t):
        obs = t.mean() - c.mean()
        both = np.concatenate([c, t])
        rng = np.random.default_rng(2)
        perm = np.array([(lambda p: p[len(c):].mean() - p[:len(c)].mean())(rng.permutation(both))
                         for _ in range(10000)])
        print(f"\nwell_h_after, adaptive regions vs control: {t.mean():.1f} vs {c.mean():.1f} "
              f"(difference {obs:+.1f}, permutation p={np.mean(np.abs(perm) >= abs(obs)):.3f})")

    if args.output:
        with open(args.output, "w") as f:
            out = csv.DictWriter(f, fieldnames=list(rows[0]), delimiter="\t", lineterminator="\n")
            out.writeheader()
            out.writerows(rows)


if __name__ == "__main__":
    main()
