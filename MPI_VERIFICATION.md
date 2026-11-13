# MPI verification on IBM Polus — 2026-11-14

## Implementation

- `src/wave_mpi.cpp`: one solver for MPI and MPI+OpenMP, with a nonperiodic
  Cartesian process grid, uneven block extents, local layers, six derived
  face datatypes, nonblocking exchanges, and global timing/error reductions.
- `Makefile`, `setup.sh`, `run.sh`, `scripts/polus/mpi_env.sh`: build,
  environment and launch; the default V1 build remains available.
- `tests/test_wave_mpi.py`, `scripts/polus/mpi_job.lsf`: compute-node tests
  against the optimized V1 solver, continuous exact solution and independent
  discrete eigenmode. See [MPI.md](MPI.md) for the offset formulas and commands.
- `scripts/polus/mpi_benchmark.sh`, `scripts/analyze_mpi.py`: 54 planned
  configurations, explicit single-row submission, raw logs, and median-based
  speedup against the matching one-rank version.

## Commands and evidence

Used SSH with `BindInterface=en0`. Copied files to a separate directory
`~/wave-mpi-validation.33kS6l` on the server; the existing server checkout and
previous results were untouched. Inspected `module avail`, `mpicxx --showme`,
`mpirun --version`, `ompi_info`, `ldd`, `bqueues -l short` and `bhosts -w`.
Open MPI 4.0.2 provides LSF components. The wrapper was built and run with
Conda GCC 13.4.0, C++17, OpenMP and Conda's POWER8 flags. The binary linked
against `/polusfs/soft/ompi4.0.2/lib/libmpi.so.40` and Conda `libgomp`.

`make -j2 mpi optimized`, `source setup.sh mpi`, and `bash -n` for new and
changed shell scripts succeeded on Polus. The first dry-run exposed the
older Bash behavior for empty arrays under `set -u`; the fixed dry-run passed.
Existing V1 numerical, CLI and eight campaign-infrastructure tests passed.
Locally only source edits and `git diff --check` were done.

| LSF job | Allocation | Result |
|---|---|---|
| 1618608 | c2, 16 requested slots, exclusive | 15/15 passed; c4 was occupied |
| 1618610 | c2+c3, 16 slots/node, exclusive | 32-rank MPI passed; default slot mapping rejected hybrid core binding |
| 1618611 | c2+c3, 16 slots/node, exclusive | Both passed with explicit ranks per node |
| 1618612 | c2, 16 requested slots, exclusive | Final build: 15/15 passed |
| 1618613 | c2+c3, 16 slots/node, exclusive | Benchmark runner and analyzer passed on a real 8 × 4 run |

The one-node suite covered 1/2/4/8 MPI ranks, three-axis `2x2x2`, uneven
blocks, explicit `1x2x4`, all six halo directions, zero boundaries, 1 and
20 steps, `L=1`, `L=pi`, unequal domain lengths and hybrid teams of 2/4.
It also checked `MPI_THREAD_FUNNELED` and rank placement. The two-node suite
checked 32 × 1 at `N=17` (`4x4x2`) and 8 × 4 at `N=128,L=pi` (`2x2x2`),
with half the ranks on each node. The scheduler commands used `short`,
`00:10`, and `-x`: `-n 16 -R 'span[hosts=1]'` with an explicit host for
the one-node suite and `-n 32 -R 'span[ptile=16]'` without a fixed host for
the two-node suite. No core oversubscription was enabled.

Example measured solve times (single executions, not scaling medians):

| Job | Mode | N | L | Ranks × threads | Seconds | Max. abs. error |
|---|---|---:|---|---|---:|---:|
| 1618608 | MPI | 128 | 1 | 1 × 1 | 0.104507 | 1.1226e-6 |
| 1618608 | MPI | 128 | 1 | 8 × 1 | 0.016120 | 1.1226e-6 |
| 1618608 | Hybrid | 128 | 1 | 4 × 4 | 0.008060 | 1.1226e-6 |
| 1618608 | MPI | 256 | pi | 8 × 1 | 0.259303 | 7.0697e-8 |
| 1618608 | Hybrid | 512 | 1 | 4 × 4 | 1.227476 | 4.4269e-9 |
| 1618611 | Hybrid | 128 | pi | 8 × 4 | 0.012782 | 1.1226e-6 |
| 1618613 | Hybrid | 128 | pi | 8 × 4 | 0.013865 | 1.1226e-6 |

The final preflight used `mpi_benchmark.sh --plan` (54 rows),
`MPI_ALLOW_TWO_NODES=1 ... --submit-one ... hybrid 128 pi 8 1` and
`python3 scripts/analyze_mpi.py benchmark-preflight`. Its speedup cell was
blank as expected: no matching benchmark baseline was submitted.

All these times cover updates and MPI exchange; there is no separate
communication timer and no instrumentation inside the exchange path.
The full matrix and another cluster remain unverified. Open MPI reported
an OpenFabrics device initialization warning; cross-node correctness passed,
but the actual data transport and its bandwidth were not measured.
No full performance campaign was submitted.
