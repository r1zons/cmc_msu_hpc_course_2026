# 3D wave equation solver — V1

This is the correctness-first OpenMP implementation of assignment variant 1.
It solves the three-dimensional wave equation with homogeneous Dirichlet
conditions using the specified explicit seven-point finite-difference scheme.

`N` is the number of intervals on **each** spatial axis. Node indices are
`0..N`, so the solver stores `(N+1)^3` nodes per time layer. `T` is physical
simulation time; it is unrelated to the measured program runtime.

## Build

The default build uses a GNU-compatible compiler and OpenMP:

```sh
make
```

The compiler and flags can be overridden, for example on macOS with Homebrew
LLVM:

```sh
make CXX=/usr/local/opt/llvm/bin/clang++
```

## Run

All mathematical and threading parameters are required:

```sh
./build/wave_solver \
  --n 128 --lx 1 --ly 1 --lz 1 --time 1 --steps 256 --threads 4
```

Use `./build/wave_solver --help` for a concise description. The program rejects
unstable inputs instead of changing the requested time step. Output is emitted
as stable `key=value` lines and includes numerical solve time and final-layer
maximum absolute error against the analytical solution.

## Tests

```sh
make test
```

Python-based benchmark infrastructure tests require Python 3.7 or newer. The
interpreter is configurable without changing the C++ toolchain:

```sh
make test PYTHON=/path/to/compatible/python3
```

The dependency-free tests cover the `K=1` hand calculation, zero boundaries,
one-versus-multiple-thread consistency, a noncubic domain, invalid parameters,
CFL rejection, and basic CLI behavior.

## IBM Polus (LSF)

Run these commands from the repository root on Polus. The shared configuration
in `scripts/polus/config.sh` identifies the confirmed Conda installation and
environment. First inspect the system compiler, configured Conda compiler, GNU
Make, LSF commands, and OpenMP support:

```sh
bash scripts/polus/check_env.sh
```

Initialize and activate the configured Conda environment, then build and test
with its C++ compiler:

```sh
source scripts/polus/config.sh
source "${POLUS_CONDA_BASE}/etc/profile.d/conda.sh"
conda activate "${POLUS_CONDA_ENV}"
export LD_LIBRARY_PATH="${CONDA_PREFIX}/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
POLUS_CXX=${CXX:-g++}
POLUS_PYTHON="${POLUS_CONDA_BASE}/bin/python3"
command -v "${POLUS_CXX}"
"${POLUS_PYTHON}" --version

make clean
make CXX="${POLUS_CXX}"
make test CXX="${POLUS_CXX}" PYTHON="${POLUS_PYTHON}"
```

LSF opens output files before a job script starts, so create the log directory
before submitting either job:

```sh
mkdir -p logs/polus
bsub < scripts/polus/openmp_1t.lsf
bsub < scripts/polus/openmp_4t.lsf
```

Monitor submitted jobs and inspect their separate stdout and stderr logs:

```sh
bjobs
bjobs JOB_ID
cat logs/polus/openmp_1t.JOB_ID.out
cat logs/polus/openmp_1t.JOB_ID.err
cat logs/polus/openmp_4t.JOB_ID.out
cat logs/polus/openmp_4t.JOB_ID.err
```

Replace `JOB_ID` in log filenames with the numeric ID printed by `bsub`. The
jobs request exclusive access to one host, 1 or 4 CPU slots, the `normal`
queue, and 15 minutes of scheduler walltime. Confirm that the `normal` queue
and these resource directives match the current Polus configuration before
submission. The scheduler limit does not impose an algorithmic runtime limit
inside the solver.

### OpenMP scaling benchmark

The benchmark runs 1, 2, 4, and 8 threads in each of three repetition rounds,
for 12 sequential measurements on one exclusive node. Build and test with the
configured Conda environment as shown above, then submit from the repository
root:

```sh
mkdir -p logs/polus
bsub < scripts/polus/openmp_benchmark.lsf
bjobs
```

LSF writes job logs to `logs/polus/openmp_benchmark.JOB_ID.out` and
`logs/polus/openmp_benchmark.JOB_ID.err`. Successful measurements are written
to `results/polus/openmp_benchmark_JOB_ID.csv`; individual solver outputs are
kept in `results/polus/openmp_benchmark_JOB_ID_raw/` for debugging. Replace
`JOB_ID` with the numeric ID reported by `bsub`:

```sh
cat results/polus/openmp_benchmark_JOB_ID.csv
ls results/polus/openmp_benchmark_JOB_ID_raw/
```

### Separate scaling jobs

For independent scheduling at 1, 2, 4, 8, 16, and 20 threads, use the batch
submission helper. Each LSF job requests exactly its thread count and performs
three sequential repetitions. Validate all six job files without submitting:

```sh
bash scripts/polus/submit_openmp_scaling.sh --dry-run
```

After building and testing with the configured Conda environment, submit all
six jobs and monitor them:

```sh
bash scripts/polus/submit_openmp_scaling.sh
bjobs
```

Each job writes separate scheduler logs named
`logs/polus/openmp_scaling_<threads>t.JOB_ID.{out,err}`. Its three-row CSV is
`results/polus/openmp_<threads>t_JOB_ID.csv`, and raw solver output is retained
in `results/polus/openmp_<threads>t_JOB_ID_raw/`. For example:

```sh
cat logs/polus/openmp_scaling_16t.JOB_ID.out
cat logs/polus/openmp_scaling_16t.JOB_ID.err
cat results/polus/openmp_16t_JOB_ID.csv
ls results/polus/openmp_16t_JOB_ID_raw/
```

### Large-grid pilot

Two one-run pilot jobs cover `N=256, K=512` and `N=512, K=1024`, both with 16
threads. They record solver timing, numerical error, effective thread count,
job ID, hostname, and exit status in per-job CSV files.
Error is checked against an independently evaluated discrete sine-mode
recurrence for each grid, with an absolute comparison tolerance of `1e-9`.

The pilot job files request `03:00`, matching the confirmed 180-minute run limit
of the `normal` queue. Verify that limit before submitting, then validate and
submit without overriding the directives in the files:

```sh
bqueues -l normal
bash scripts/polus/submit_large_grid_pilots.sh --dry-run
bash scripts/polus/submit_large_grid_pilots.sh
bjobs
```

Each job writes separate LSF logs under `logs/polus/`. Structured and raw pilot
results use the job ID in their filenames. Peak memory is reported by LSF in
its standard job resource summary; the running script does not parse or copy it
into the CSV. Inspect the scheduler stdout log (and `bjobs -l` or `bhist -l`, as
available on Polus) for that summary:

```sh
cat logs/polus/large_grid_pilot_n256.JOB_ID.out
cat logs/polus/large_grid_pilot_n512.JOB_ID.out
cat results/polus/large_grid_pilot_n256_JOB_ID.csv
cat results/polus/large_grid_pilot_n512_JOB_ID.csv
bjobs -l JOB_ID
bhist -l JOB_ID
```

### Final V1 benchmark

The final benchmark contains 108 measurements: `N=128,256,512`, cubic domains
with side length `1` or `pi`, six thread counts, and three repetitions. Every
job is restricted to
`polus-c4-ib.bmc.hpc.cs.msu.ru`, requests exclusive single-host placement, and
uses the configured `short` queue and `00:10` walltime. All `N=512`
repetitions are separate jobs; the three repetitions for each `N=128` and
`N=256` configuration share one job. This is 60 LSF jobs requesting 510 CPU
slots in total across all job requests.

The queue and walltime are defined once in `scripts/polus/config.sh` as
`POLUS_FULL_V1_QUEUE` and `POLUS_FULL_V1_WALLTIME`. Ten minutes provides
headroom over the current conservative 5--6 minute estimate for one `N=512`,
one-thread measurement, but the actual `short`-queue RUNLIMIT has not been
independently confirmed. Checking it is mandatory before submission:

```sh
bqueues -l short
```

If the reported limit does not permit `00:10`, adjust
`POLUS_FULL_V1_WALLTIME` in the shared configuration before creating the
campaign. Do not submit with the historical `03:00` reservation and do not
fall back automatically to `normal`.

This campaign follows the assignment's request for approximately 20 time
steps: every run uses `K=20` and a normalized CFL fraction of `0.5`. For each
spatial grid, the submission script calculates

```text
dt = 0.5 / sqrt(1/hx^2 + 1/hy^2 + 1/hz^2)
T  = 20 * dt
```

where `hx=Lx/N`, `hy=Ly/N`, and `hz=Lz/N`. On a cubic domain this reduces to
`dt = 0.5*L/(sqrt(3)*N)`. Consequently the solver's squared CFL expression is
`dt^2*(1/hx^2 + 1/hy^2 + 1/hz^2) = 0.25`. Values are written to the manifest
and passed to `--time` with approximately 17 significant decimal digits. All
thread counts and repetitions for a given `N,L` pair use exactly the same
physical problem.

The resulting physical final time is not one second and is not constant as the
grid changes:

| N | L | dt | T |
|---:|---:|---:|---:|
| 128 | 1 | 0.0022552744890219759 | 0.045105489780439517 |
| 256 | 1 | 0.0011276372445109880 | 0.022552744890219759 |
| 512 | 1 | 0.00056381862225549399 | 0.011276372445109879 |
| 128 | pi | 0.0070851537665399134 | 0.14170307533079826 |
| 256 | pi | 0.0035425768832699567 | 0.070851537665399131 |
| 512 | pi | 0.0017712884416349784 | 0.035425768832699565 |

Here `T` is simulated physical time. It is distinct from
`solve_wall_seconds`, which is measured execution time and is used for the
OpenMP scaling statistics.

Prepare and verify the existing Conda environment, then build and test before
submitting. LSF jobs never rebuild the executable:

```sh
./setup.sh
```

`setup.sh` activates the configured environment, performs a clean build, and
runs the existing tests. It keeps the environment active in the interactive
shell when sourced; when executed normally, activation is limited to the
script process. It uses GCC from `wave-cpp17` and explicitly runs Python tests
with `${POLUS_CONDA_BASE}/bin/python3` (Python 3.10.12 on the confirmed Polus
installation), rather than the system Python 3.6. Every generated LSF job
initializes Conda independently.

Inspect the complete plan without creating files or contacting LSF:

```sh
bash scripts/polus/submit_full_v1.sh --dry-run
```

On Polus, verify the queue limit and host, create a new timestamped campaign,
submit its jobs, and monitor them:

```sh
bqueues -l short
bhosts polus-c4-ib.bmc.hpc.cs.msu.ru
bash scripts/polus/submit_full_v1.sh --dry-run
bash scripts/polus/submit_full_v1.sh
bjobs
```

Each invocation creates a different directory such as
`results/polus/full_v1/2026-10-21_03-30-00/`. It contains the complete manifest,
incremental submission records, a private solver copy and checksum, generated
LSF scripts, scheduler logs, and raw measurement files:

```text
CAMPAIGN_DIRECTORY/
  manifest.csv
  submissions.csv
  metadata.txt
  config.sh
  wave_solver
  jobs/
  logs/
  measurements/
  analysis/
```

Every job uses the copied solver rather than mutable `build/wave_solver` and
checks its SHA-256 checksum before execution. Solver stdout, stderr, and a small
metadata file are stored separately for every measurement. Names include the
configuration, repetition, and LSF job ID. Jobs record `hostname`,
`hostname -f`, and `LSB_HOSTS`; they do not reject a valid allocation merely
because Polus reports a short hostname. LSF log files contain the scheduler's
resource summary, including peak-memory information. The campaign is otherwise
self-contained; execution still requires Bash, LSF, a SHA-256 utility, and the
Conda installation and environment named in its copied `config.sh`.

There is deliberately no automatic resume. If submission is interrupted or a
job fails, retain the campaign, inspect `submissions.csv`, `bjobs`, `bhist`, and
the corresponding files under `jobs/`, `logs/`, and `measurements/`. Submit a
specific generated job manually only after confirming that doing so cannot
duplicate an active run:

```sh
bsub < CAMPAIGN_DIRECTORY/jobs/JOB_GROUP.lsf
```

Published Polus documentation has mentioned limits of four simultaneously
running jobs per user and 200 total queued CPU slots, but these values may be
outdated or account-dependent. The submission plan prints both 60 jobs and 510
total requested slots. If the scheduler rejects the full campaign because of
current capacity policy, do not retry automatically or switch queues. Preserve
the partial `submissions.csv`, identify the job scripts that were not accepted,
and submit those scripts manually in smaller batches after accepted jobs leave
the queue.

After the jobs finish, copy the entire campaign directory to the local machine
and analyze it without LSF access:

```sh
"${POLUS_CONDA_BASE}/bin/python3" scripts/analyze_full_v1.py CAMPAIGN_DIRECTORY
cat CAMPAIGN_DIRECTORY/analysis/report.txt
cat CAMPAIGN_DIRECTORY/analysis/summary.csv
cat CAMPAIGN_DIRECTORY/analysis/missing_or_failed.csv
```

On a local macOS machine, use any Python 3.7-or-newer interpreter in place of
the Polus path. The analyzer uses `manifest.csv` to determine completeness, validates solver
parameters, `T/K`, CFL policy, and effective thread counts, independently
evaluates the discrete sine-mode recurrence, and reports duplicates, corrupt
outputs, failed runs, and missing runs. The comparison tolerance is
`max(5e-12, 1e-6*expected_error)`, which remains meaningful for the expected
errors down to roughly `4.4e-9`. Statistics and speedups use only valid
measurements for identical `N`, domain, `K`, and `T`. Incomplete campaigns
still produce useful partial analysis but return a nonzero status. Core
analysis uses only the Python standard library; four labeled plots are added
when matplotlib is available.

The finite-difference method is second order in space and time. The new error
plot is a **CFL-scaled, fixed-step-count benchmark**: because both `dt` and `T`
change when `N` changes, it is not a conventional fixed-final-time convergence
study. In particular, the approximately 16-fold error reduction observed when
doubling `N` must not be described as fourth-order convergence, and this
campaign is not expected to produce `1e-13` errors. The earlier `T=1`,
`K=2*N` campaign remains a separate fixed-time convergence study; the analyzer
continues to recognize its historical manifest format and does not rewrite it.

The new campaign no longer uses the `normal` queue or its former three-hour
reservation. The short-queue RUNLIMIT, host acceptance, and observed runtime
still require validation on Polus. Confirm the generated plan and run a small
preflight before committing cluster resources to all 60 jobs.

## Scope

V1 uses C++17, `double`, three contiguous time-layer arrays, and OpenMP. It has
no MPI, CUDA, alternate boundary variants, or algorithmic runtime limit.
