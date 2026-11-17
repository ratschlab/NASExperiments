# GridION run sheet: HXB2 test library, first live runs

Host GXB03789, user `grid`, repo `/home/grid/NASExperiments`, conda env `selectiveseq_v2`, position X1.
HXB2 test library for us only, so all runs are live (readfish unblocks); no dry runs needed.
MinKNOW's live basecalling is off in all runs: readfish basecalls its chunks itself through the
dorado server, and without MinKNOW's whole-read basecalls on the same server and GPU, readfish's
basecalls wait less. Reads are basecalled afterwards from pod5 with sup and `--emit-moves`.

Three runs on one flow cell:

| run | length | bulk FAST5 | readfish | purpose |
|---|---|---|---|---|
| 1 | ~30 min sequencing | on | none, then mm, then 4 tools | bulk signal for the run inspector; mm baseline comparable to March; first multi-tool test |
| 2 | ~1 h | off | 4 tools | check the multi-tool mechanics before committing 72 h |
| 3 | 72 h | off | 4 tools | pore death against adaptive-sampling throughput |

## 1. Update and check (no flow cell needed) — done 2026-11-17

```bash
cd /home/grid/NASExperiments && git pull
conda activate selectiveseq_v2 && ./setup.sh
scripts/check_tools.sh --sample data/check/hxb2.blow5
```

Result `runs/check_20261117_130108` (readfish 2026.1.0 from the fork): all tools pass, identical to
2026-11-09. HXB2_IN kept / others ejected of 1000 / 2000: mm 601/1905, mg_query 605/1902,
mg_map 653/1890, sp 679/1890, rh 178/1906, rb 809/1846, cl 388/1943, cn 158/1983 (sg keeps
everything).

Before the runs: `git pull` again (this sheet), and check free space with `df -h /home /data`
(run 1 bulk ~9 GB before compression on the data disk; readfish logs of run 3 ~6–8 GB under
`/home/grid/NASExperiments/runs`).

Commands below assume:
```bash
conda activate selectiveseq_v2 && cd /home/grid/NASExperiments
```
Start readfish inside `tmux` so it survives a closed terminal (essential for run 3).

**Before every readfish start, check the dorado server** (MinKNOW manages it; it is not yet
confirmed that it stays up with live basecalling off):
```bash
pgrep -a dorado_basecall            # running, with --port /home/grid/.dorado/dorado-basecall-server.sock
ls -l /home/grid/.dorado/dorado-basecall-server.sock
```
`run_gridion.sh` takes the address from that `--port` (adding `ipc://`), so a different path is
fine. If it is not running, readfish gets no basecalls (it hangs at "Initialising Caller"): turn
live basecalling on for that run and note it.

## 2. Run 1: bulk FAST5 (~30 min of sequencing)

For `ont_signal_viz` (`ont-inspector`): its bulk FAST5 layer is not written yet and gets built on
this recording; its notes ask for 10–15 minutes of bulk FAST5 including a few minutes without
readfish (to tell whether the instrument-wide ADC full-scale samples come from MinKNOW or from
readfish's loop). Bulk output is a run option and costs ~18 GB per hour (5.1 MB/s, raw signal of
all 512 channels), so it gets its own short run.

Minutes count from the start of sequencing, i.e. after MinKNOW's initial pore scan.

- [ ] In MinKNOW, start run 1 on X1 with bulk FAST5 output on (output settings; raw signal, all
  channels), pod5 output on, live basecalling off. Note flow cell, library and run ID.
- [ ] Minutes 0–5: readfish not running. Check the dorado server (above).
- [ ] Minute 5: mm alone (target/control halves, as in March). Note the clock time.
  ```bash
  scripts/run_gridion.sh -t mm -d X1 -n hxb2_run1_mm
  ```
- [ ] Minute 15: stop it (Ctrl-C), then start the 4 tools + control, interleaved by channel.
  Note the clock time.
  ```bash
  scripts/run_gridion.sh -t mm,mg_query,mg_map,rh -d X1 -n hxb2_run1_arms
  ```
- [ ] Minute 30: stop readfish (Ctrl-C), then end the MinKNOW run.

## 3. Run 2: multi-tool check (~1 h, no bulk)

- [ ] Before run 2 (readfish stopped): update readfish to show a status line per tool on screen
  every 10 s (`mm: …`, `mg_query: …`, …, `control: …`; run 1's multi-tool part printed nothing):
  ```bash
  git pull && ./setup.sh
  ```
  `setup.sh` pulls `code/readfish` and reinstalls it (about a minute); the rest is skipped.

- [ ] Start run 2 on the same flow cell, bulk output off, otherwise as run 1 (pod5 on, live
  basecalling off). Check the dorado server.
- [ ] Once reads come in:
  ```bash
  scripts/run_gridion.sh -t mm,mg_query,mg_map,rh -d X1 -n hxb2_run2_arms
  ```
- [ ] Check while it runs:
  - `channels.toml` in the MinKNOW run directory shows five interleaved regions (mm, mg_query,
    mg_map, rh, control).
  - In `runs/<timestamp>_arms_X1/`, each tool's `*_batches.tsv` grows, and `wait_s` stays well
    below a second (`tail` them).
  - The dorado server stays up, and `top` shows CPU headroom.
- [ ] After ~1 h, stop readfish, end the run, and copy back `runs/` (or send me the arms run
  directories) if anything looks off. If all is fine, go on with run 3.

## 4. Run 3: 72 h, pore death against adaptive-sampling throughput (no bulk)

Interleaving makes this comparison clean: each tool's channels are spread evenly over the flow
cell, so pore death per tool is not confounded with position (the March half split showed a
spatial gradient), and the control region (never unblocked) is the baseline. Per channel we then
compare unblock rate and sequenced yield against when the channel's pores die. This is also the
long run the inspector's `channel_survival` has been waiting for.

- [ ] Start run 3 on the same flow cell, 72 h, bulk output off, pod5 on, live basecalling off.
  Check the dorado server. Keep MinKNOW's periodic pore
  (mux) scans at their default: they are what pore death is measured from.
- [ ] In `tmux`:
  ```bash
  scripts/run_gridion.sh -t mm,mg_query,mg_map,rh -d X1 -n hxb2_run3_arms_72h
  ```
- [ ] Note the time of every intervention: library reloads, flushes, readfish restarts. Any
  stretch without readfish changes the unblock rate, so if readfish stops, restart it with the
  same command and note the gap.
- [ ] Check readfish once or twice a day (`tmux attach`; `tail` of the `*_batches.tsv`), and
  disk space.
- [ ] After 72 h: stop readfish, end the run.

## 5. Copy back to the dev server

- [ ] The three MinKNOW run directories (pod5, `channels.toml`, `pore_scan_data_*.csv`,
  `sequencing_summary`, reports; run 1 also the bulk FAST5).
- [ ] `runs/` entries of the three runs: config, `run_info.txt`, readfish TSVs per tool
  (`*_readfish_<tool>.tsv`), `*_batches.tsv`, logs.
- [ ] The intervention times of run 3, and the clock times from run 1.

**Afterwards on the dev server:** basecall the pod5s with sup (`dorado basecaller ... --emit-moves`,
as the inspector asks) and align to `refs/all_refs.fasta` as for March.

**What we look at afterwards:** per tool the wait / basecall / align times per batch, decision
latency (sequence length and chunks at decision), enrichment of HXB2_IN against the control
region and against March (mm live: 57.9% of HXB2_IN kept), and in run 3 pore survival per
channel against unblock rate and yield, per tool and for the control.
