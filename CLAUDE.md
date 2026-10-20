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

## Deployment configs (templates → per-machine readfish TOMLs)

```bash
scripts/render_configs.sh sites/gridion.env          # -> configs/generated/gridion/rf_<tool>_<DATASET>.toml
DATASET=gut THREADS=8 scripts/render_configs.sh sites/dev.env
readfish validate configs/generated/gridion/rf_mm_zymo.toml
```

- `configs/templates/rf_<tool>.toml` holds the caller and mapper settings, with `${VAR}` placeholders and tool tuning values taken from upstream's `benchmark_all_zymo.sh`.
- `configs/regions/<name>.toml` holds the decision policy (`[[regions]]`). It is shared by all tools, selected by `REGIONS`, and appended to every rendered config. The default, `target_control`, is the experimental design used on the GridION: a target half (`no_map` unblock, `no_seq` proceed, everything else stop_receiving) and a control half (stop_receiving everywhere, including `above_max_chunks`).
- `sites/<machine>.env` is a bash file sourced with `EXPDIR` set to the repo root. It sets the basecall socket and model, `THREADS`, `DATASET`, `CODE_DIR`, `INDEX_DIR`, `RB_IBF`, `MG_SERVER_PORT` and `REGIONS`. Values use `: ${VAR:=default}`, so environment variables override them.
- The renderer only substitutes the `${VAR}`s that appear in a template, and it fails if any of them is unset. `configs/generated/` is gitignored.
- `INDEX_DIR` follows the layout written by `build_all_<dataset>_indices.sh`: `<INDEX_DIR>/<tool>/<DATASET>.*` (`mm/zymo.mmi`, `cl/zymo.cidx`, `mg/zymo.dbg`, `sp/zymo`, `rh/zymo.ind`, `sg/refs/ref`, `rb/Refs1.ibf`).
- readfish semantics: with `targets = []`, every mapped read counts as *off*-target (`Targets.check_coord` is always False). So `*_off` decides what happens to mapped reads and `no_map` decides unmapped ones.

## Setup

```bash
conda env create -f env.yml && conda activate selectiveseq
./setup.sh            # clones/builds everything into code/, idempotent
```

- Metagraph's CLI build needs system static Boost (`libboost-all-dev`). Conda Boost is not enough.
- `ont-dorado-server` is not installed by `setup.sh`. It is extracted manually into `code/ont-dorado-server/`, and `run_dorado_v0.7.4.sh` starts it locally.
- The `ont-pybasecall-client-lib` version (dorado ≥7.3) or `ont-pyguppy-client-lib` version (≤7.2) must match the server version. `tools/basecall.py` switches between them with commented imports.

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

## Live readfish runs against the MinKNOW simulator

1. Start the dorado basecall server (`run_dorado_v0.7.4.sh`).
2. Start the simulator (`run_server.sh`, which wraps `mksimserver --certs code/MinknoApiSimulator/certs --profile <dna-r9-prom|dna-r10-min|...> --input <blow5>`).
3. Run `readfish targets --toml configs/rf_<tool>_zymo.toml --port 50051 --device MN12345 ...` with the `MINKNOW_*` cert env vars set (see `run_readfish.sh`), or use `scripts/simulate_run.sh` after editing `INPUT_SIGNAL`/`CONFIG_TOML`.
4. Validate a config first with `readfish validate <toml>`.

readfish writes per-read decisions to `test_run_readfish.tsv` in the current working directory.

Config naming: `rf_<tool>_<dataset>.toml` (`mm`=mappy_rs, `cl`=collinearity, `mg`=metagraph, `sp`=spumoni, `sg`=sigmoni, `rh`=rawhash, `rb`=readbouncer). Each config has `[caller_settings.dorado]` (basecaller model and socket), `[mapper_settings.<plugin>]` (index paths are absolute and must be edited per machine) and `[[regions]]` decision rules.

## Ad-hoc utilities

`tools/run.py <function> key=value ...` dispatches to `basecall` (`tools/basecall.py`, BLOW5 to FASTA via the dorado server) and `truncate_signal` (`tools/utils.py`).
