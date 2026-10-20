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
command -v "${POLUS_CXX}"

make clean
make CXX="${POLUS_CXX}"
make test CXX="${POLUS_CXX}"
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
threads. They record solver timing, numerical error, and peak resident memory.
Error is checked against an independently evaluated discrete sine-mode
recurrence for each grid, with an absolute comparison tolerance of `1e-9`.

No walltime is guessed in the job files. Check the current `normal` queue limits
on Polus, choose an allowed `HH:MM` value, and validate the resulting submission
commands before submitting:

```sh
bqueues -l normal
bash scripts/polus/submit_large_grid_pilots.sh --walltime HH:MM --dry-run
bash scripts/polus/submit_large_grid_pilots.sh --walltime HH:MM
bjobs
```

Each job writes separate LSF logs under `logs/polus/`. Structured and raw pilot
results use the job ID in their filenames:

```sh
cat logs/polus/large_grid_pilot_n256.JOB_ID.out
cat logs/polus/large_grid_pilot_n512.JOB_ID.out
cat results/polus/large_grid_pilot_n256_JOB_ID.csv
cat results/polus/large_grid_pilot_n512_JOB_ID.csv
cat results/polus/large_grid_pilot_n512_JOB_ID.resources
```

## Scope

V1 uses C++17, `double`, three contiguous time-layer arrays, and OpenMP. It has
no MPI, CUDA, alternate boundary variants, or algorithmic runtime limit.
