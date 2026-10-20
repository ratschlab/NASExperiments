# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Benchmarking harness for **selective (adaptive) nanopore sequencing**: it compares read classifiers (minimap2/mappy_rs, Collinearity, Metagraph, SPUMONI, Sigmoni, RawHash2, ReadBouncer) used as [readfish](https://github.com/LooseLab/readfish) aligner plugins, on simulated Zymo and Gut datasets that live under `/data/SimulatedDatasets/`. There is no build system, test suite or linter. The repo is bash task scripts, Python analysis scripts and readfish TOML configs. External tools are cloned and built into `code/` by `setup.sh`.

## Purpose of this fork

Upstream (Sayan) runs **in-silico benchmarks**. This fork is for **deploying the decision algorithms on an ONT GridION (Ubuntu 24.04) and running them on real data**. This checkout (`/scratch/NASExperiments_grlab`) is the development copy on a separate Linux server. The final checkout lives on the GridION, so:
- Configs and scripts must not depend on `/scratch/...` paths or on this server's layout.
- On the GridION, MinKNOW manages the dorado basecall server at `ipc:///var/lib/minknow/data/.dorado/dorado-basecall-server.sock`. `/tmp/.dorado/...` is only the dev server's local server.
- Real runs talk to a live MinKNOW, not `MinknoApiSimulator`, so the simulator-only `MINKNOW_SIMULATOR`/cert env vars don't apply.
- Ubuntu 24.04 ships GCC 13 (hence the spumoni header fixes in `setup.sh`) and needs `libboost-all-dev` via apt for the metagraph CLI.
- Never modify Sayan's checkout `/scratch/NASExperiments`; only read from it as the `upstream` remote.

## Fork / upstream layout

- `origin` = `ratschlab/NASExperiments` (this fork, the grlab copy at `/scratch/NASExperiments_grlab`).
- `upstream` = the local checkout `/scratch/NASExperiments` (tracks `sayangoswami/NASExperiments`, branches `main` and `pmh`).
- `git fetch upstream` fails with "dubious ownership" because user `sayan` owns that repo. `git -c safe.directory=...` and `GIT_CONFIG_*` env vars don't fix it, because they don't reach the local upload-pack. It needs a one-time `git config --global --add safe.directory /scratch/NASExperiments/.git`, or a fetch straight from `git@github.com:sayangoswami/NASExperiments.git`.
- Fork-specific differences to keep when syncing:
  - The fork keeps the server-based **metagraphRF** plugin (`configs/templates/rf_mg.toml`, conda `metagraph=0.5.1`) next to upstream's **pymetagraph** bindings (`rf_mg_query` / `rf_mg_align`).
  - `configs/rf_*_zymo.toml` are upstream's benchmark configs. Keep them identical to upstream so merges stay clean. The fork's deployment configs are generated from templates (see below).
  - The fork's `setup.sh` adds `set -e`, skip-if-already-built guards, a TurboPFor build plus a CMakeLists patch for collinearity, and GCC 13 header fixes for spumoni.
  - `*_R9.toml` / `env_R9.yml` are untracked R9.4.1 variants.

## Deployment configs (templates → per-machine, per-experiment readfish TOMLs)

```bash
scripts/render_configs.sh sites/gridion.env experiments/hxb2.env   # -> configs/generated/gridion/rf_<tool>_hxb2.toml
THREADS=8 scripts/render_configs.sh sites/dev.env experiments/hxb2.env
readfish validate configs/generated/gridion/rf_mm_hxb2.toml
EXPERIMENT=$PWD/experiments/hxb2.env SITE=$PWD/sites/dev.env scripts/task_runner.sh -t build_experiment_indices   # all indices into $INDEX_DIR
```

- `configs/templates/rf_<tool>.toml` holds the caller and mapper settings, with `${VAR}` placeholders and tool tuning values taken from upstream's `benchmark_all_zymo.sh`.
- `configs/regions/<name>.toml` holds the decision policy (`[[regions]]`). It is shared by all tools, selected by `REGIONS`, and appended to every rendered config. The default, `target_control`, reproduces the 2026-03 GridION runs: a target half (`targets = ${TARGETS}`, `no_map` unblock, `no_seq` proceed, everything else stop_receiving) and a control half (`control = true`, stop_receiving everywhere). `min_chunks=1`, `max_chunks=2`, and `above_max_chunks` is left at the readfish default (unblock). readfish only applies `above_max_chunks` when the action would be `proceed`, so it never fires in the control region.
- `experiments/<name>.env` describes the biology: `DATASET`, the reference `REF` that indices are built from, and `TARGETS` (a TOML list of the target region's contigs). `experiments/hxb2.env` is the HIV HXB2 amplicon experiment: enrich HXB2_IN, with HXB2_PRRT as the off-target amplicon.
- `sites/<machine>.env` describes the machine: the basecall socket and model, `THREADS`, `CODE_DIR`, `INDEX_DIR`, `RB_IBF`, `MG_SERVER_PORT`/`MG_GRAPH`/`MG_ANNO` and `REGIONS`. The experiment file is sourced first, so the site file can use `DATASET`/`REF`. Both are bash files sourced with `EXPDIR` set to the repo root, and their values use `: ${VAR:=default}`, so environment variables override them.
- The renderer only substitutes the `${VAR}`s that appear in a template, and it fails if any of them is unset. `configs/generated/` is gitignored.
- `INDEX_DIR` follows the layout written by `build_experiment_indices.sh` (and upstream's `build_all_<dataset>_indices.sh`): `<INDEX_DIR>/<tool>/<DATASET>.*` (`mm/hxb2.mmi`, `cl/hxb2.cidx`, `mg/hxb2.dbg`, `sp/hxb2`, `rh/hxb2.ind`, `sg/refs/ref`, `rb/<REF basename>.ibf`). The Collinearity index is about 4.3 GB even for the 1.4 kb HXB2_IN reference.
- readfish semantics: with `targets = []`, every mapped read counts as *off*-target (`Targets.check_coord` is always False). So `*_off` decides what happens to mapped reads and `no_map` decides unmapped ones.

## Setup

```bash
conda env create -f env.yml && conda activate selectiveseq
./setup.sh            # clones/builds everything into code/, idempotent
```

- Metagraph's CLI build needs system static Boost (`libboost-all-dev`). Conda Boost is not enough.
- Build gotchas, all handled in `setup.sh` / `build_experiment_indices.sh`:
  - metagraph needs its bundled sdsl-lite installed first, built with `-DCMAKE_POSITION_INDEPENDENT_CODE=ON` (pymetagraph's `.so` needs PIC). Remove `sdsl-lite/include/gtest` afterwards.
  - pymetagraph needs `CMAKE_ARGS="-DBoost_DIR=..."` pointing at the system Boost. Delete `api/python/pymetagraph/build/` after a failed attempt, because its cache points at pip's deleted build env.
  - Sigmoni must be installed editable (`pip install -e .`), because it loads pore models from `<source>/poremodel/`.
  - Sigmoni's dependency `ont_fast5_api` needs `setuptools<81` (`pkg_resources`).
  - Sigmoni needs spumoni ≥ `fcaa6c5` (`get_pml_batch`).
  - RawHash needs its `cmake` branch (R10.4.1 k-mer model).
- The skip-if-built guards in `setup.sh` never update an existing checkout, so pull and rebuild by hand when a tool's upstream changes.
- metagraph graphs must be built by the `sg/readfish-bindings` binary (`code/metagraph/metagraph/build/metagraph`, v0.4.5, first on `task_runner.sh`'s PATH). pymetagraph cannot read annotations written by conda's metagraph 0.5.1 ("can't load label encoder"), but 0.5.1's `server_query` (used for metagraphRF) reads graphs built by 0.4.5.
- `build_experiment_indices.sh` re-wraps `REF` into `$INDEX_DIR/ref/` because pysam (and so Sigmoni) rejects FASTAs with uneven line lengths, such as `HXB2_IN.fasta`.
- `ont-dorado-server` is not installed by `setup.sh`. It is extracted manually into `code/ont-dorado-server/`, and `run_dorado_v0.7.4.sh` starts it locally.
- The `ont-pybasecall-client-lib` version (dorado ≥7.3) or `ont-pyguppy-client-lib` version (≤7.2) must match the server version. `tools/basecall.py` switches between them with commented imports. Check the server with `/opt/ont/dorado/bin/dorado_basecall_server --version`. A mismatched client does not error out: readfish hangs at "Initialising Caller", and the server log (`/var/log/dorado/`) keeps showing "Clients connected: 0". As of 2026-10-20, both the GridION and the dev server (`selseq`, which also runs MinKNOW) have dorado server 7.13.6 (API 26.0.0), so the pin is client 7.13.6. Dorado 7.13 expects the model as a model set (`dna_r10.4.1_e8.2_400bps_fast@v5.2.0||`). Without the `||` the server rejects it with `basecall_config_unavailable`.

## Running experiments: the task-runner pattern

Almost everything runs through `scripts/task_runner.sh`:

```bash
scripts/task_runner.sh -t build_all_zymo_indices          # all tasks (ALL_TASKS)
scripts/task_runner.sh -t benchmark_all_zymo 1-3,5        # selected tasks
SIGNAL_LENGTH=3200 scripts/task_runner.sh -t benchmark_all_zymo 2
```

- A task file (`scripts/<name>.sh`) defines `ALL_TASKS="1-n"` and functions `f1..fn` (`f0` is often a sanity check). `task_runner.sh` sources it after exporting `EXPDIR, CODEDIR, LOGDIR(=logs/), OUTDIR(=out/), TMPDIR(=tmp/), RESDIR, CONFDIR, SCRIPTDIR`. It also adds the built tools in `code/` to `PATH` and defines `measure`, which reports peak process-tree PSS, CPU and elapsed time. Task output is tee'd to `logs/<name>_<timestamp>.log`.
- Task files only work through the runner, because they rely on `$SCRIPTDIR` and `measure`.
- `build_all_*_indices.sh` (+ `build_common.sh`) builds per-tool indices into `tmp/<dataset>/<tool>/`. It overrides `OUTDIR`.
- `benchmark_all_*.sh` (+ `bench_common.sh`) calls `run_benchmark`, which wraps `scripts/benchmark_aligner.py`. `SIGNAL_LENGTH` must be a multiple of 1600, otherwise tasks skip.

`scripts/benchmark_aligner.py` is the core harness. It loads any readfish `Aligner` plugin by module name, using `--plugin` plus a `--plugin-args "k=v ..."` string. It streams BLOW5 (raw signal) or FASTA/Q input in batches, optionally basecalls on the fly through the dorado server, truncates signals or bases to mimic MinKNOW chunks, and writes per-read decisions plus throughput and memory metrics. For a quick check, use `--max-batches N` or `--max-batches-per-file N`.

Ground truth comes from read IDs (squigulator `<prefix>!<contig>!<start>!<end>!<strand>`, seq2squiggle without the prefix). A manifest TSV (`contig`, `true_label`, built by `make_manifest.py`) maps each contig to a target (1, Community 1) or deplete (0, Community 0) label.

Post-processing: `analyze_runs.py` (precision/recall/F1 and related metrics per tool/run) and `bootstrap_ci.py` (95% CIs). Data simulation: `run_seq2squiggle.sh`, `sample_reads.py`, `qc_signals.sh`, plus `simulation/` (squigulator; documents how the Zymo data was generated).

## Live runs on the GridION

```bash
conda activate selectiveseq
scripts/run_gridion.sh -t mm -d X1 -n hxb2_mm_run1 [--dry-run] [-s sites/dev.env] [-e experiments/hxb2.env] [-- <readfish targets args>]
```

`-t` is one of `mm mg mg_query mg_align sp sg rh rb cl`. The script works through these steps:
1. Renders the site's configs.
2. Creates `runs/<timestamp>_<tool>_<device>/` (gitignored). It holds the config used, `run_info.txt` (commit, readfish version), the readfish logs, and the chunk-log TSV that readfish writes to the current working directory.
3. For `mg` (metagraphRF), starts `metagraph server_query -i $MG_GRAPH -a $MG_ANNO --port $MG_SERVER_PORT` on 127.0.0.1, unless a server is already listening. It stops the server again on exit.
4. Runs `readfish validate`, then `readfish targets` against the local MinKNOW. Simulator env vars are not needed; the script warns if `MINKNOW_SIMULATOR=true` is set.

Before deploying, check every tool with `scripts/check_tools.sh [-s sites/dev.env] [-e experiments/hxb2.env] [-t <tool>]... [--sample data/check/hxb2.blow5]`. It runs four steps per tool on the rendered config: plugin import, index paths present, `readfish validate` (starting the metagraph server for `mg`), and, with `--sample`, a `benchmark_aligner.py` run. That run reports `kept <target reads mapped>/<targets> ejected <others unmapped>/<others>`, with signals truncated to `--truncate` samples (default 6000).

Real-data check samples come from `scripts/make_check_sample.py`. It takes reads from the *control* half of a past run (full length, never unblocked), labels them by their primary alignment in the sup-basecall BAM, rewrites the read IDs to `<id>!<contig>!<start>!<end>!<strand>` (the form `benchmark_aligner.py` takes ground truth from), and writes `<out>.blow5` plus `<out>_manifest.tsv`. The 2026-03 HXB2 runs live in `/data/uzh_ont/2026_03`: POD5s, `basecalls/*.bam` (sup v5.2.0, aligned to `refs/all_refs.fasta`), and the readfish chunk logs and logs. The readfish logs embed the exact TOML used, as a base64-encoded, zlib-compressed blob after `readfish.targets eJ...`. Samples go to the gitignored `data/check/`, and the GridION has no data, so copy them over with the indices.

Calibration against the live runs: at 6000 samples (1.2 s), mappy_rs keeps 58–60% of HXB2_IN reads and ejects about 96% of the others, which matches the live 2026-03-25 run (57.9% kept). metagraphRF reproduces its live 27.7% (2026-03-30) only with a 10000–12000-sample window (27–29%). It maps 15–30× slower than mappy_rs, so live it decided on later, longer chunks: the median sequence length at decision was 531 bases, against 280 for mappy_rs. Compare tools at equal windows, but expect slower tools to see more sequence live. Also, because metagraphRF ignores `seed_length`, its seeds are min(k, 19): graphs with k ≥ 19 behave the same, and k=15/17 raise sensitivity (33%/25% at 6000 samples) at about the same specificity.

Tuning on `data/check/hxb2_6000.{blow5,fastq}` (sample truncated to 6000 samples, basecalled once with `scripts/basecall_blow5.py`, so sweeps need no dorado server):
- RawHash needs `r10 = true` at mapping time as well, not only for the index. `min_mapq` sets the trade-off; 15 gives 18% of targets kept with 4.7% of other reads kept.
- Sigmoni does not discriminate on this data at any setting (see the note in `configs/templates/rf_sg.toml`). It prints a pass/fail table and writes logs to `runs/check_<timestamp>/<tool>.<step>.log`. `scripts/gridion_common.sh` holds the metagraph server helpers shared with `run_gridion.sh`, and `scripts/mapper_settings.py` reads the plugin module, paths and args from a rendered TOML.

metagraphRF caveat: the installed plugin (`code/metagraphRF`, 0.1.0.dev5) only reads `port` and `min_exact_match`. It silently drops `seed_length`, `connect_anchors` and `extend_chains`, so those run at the `GraphClient.align` defaults (19 / true / true), even though the client supports them.

## Live readfish runs against the MinKNOW simulator

1. Start the dorado basecall server (`run_dorado_v0.7.4.sh`).
2. Start the simulator (`run_server.sh`, which wraps `mksimserver --certs code/MinknoApiSimulator/certs --profile <dna-r9-prom|dna-r10-min|...> --input <blow5>`).
3. Run `readfish targets --toml configs/rf_<tool>_zymo.toml --port 50051 --device MN12345 ...` with the `MINKNOW_*` cert env vars set (see `run_readfish.sh`), or use `scripts/simulate_run.sh` after editing `INPUT_SIGNAL`/`CONFIG_TOML`.
4. Validate a config first with `readfish validate <toml>`.

readfish writes per-read decisions to `test_run_readfish.tsv` in the current working directory.

Config naming: `rf_<tool>_<dataset>.toml` (`mm`=mappy_rs, `cl`=collinearity, `mg`=metagraph, `sp`=spumoni, `sg`=sigmoni, `rh`=rawhash, `rb`=readbouncer). Each config has `[caller_settings.dorado]` (basecaller model and socket), `[mapper_settings.<plugin>]` (index paths are absolute and must be edited per machine) and `[[regions]]` decision rules.

## Ad-hoc utilities

`tools/run.py <function> key=value ...` dispatches to `basecall` (`tools/basecall.py`, BLOW5 to FASTA via the dorado server) and `truncate_signal` (`tools/utils.py`).
