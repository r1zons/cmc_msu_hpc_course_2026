# Distributed wave solver: MPI and MPI+OpenMP

Both modes use `build/wave_solver_mpi` and share the same update loop.
`./run.sh mpi` sets one compute thread per rank; `./run.sh hybrid` defaults to
four. `make` and the two V1 executables remain separate.

## Decomposition and exchange

The global interior is `1..N-1` on each axis. With `P` partitions along an
axis and Cartesian coordinate `c`, let `q=(N-1)/P` and `r=(N-1)%P`.
The local length is `q + (c < r)`, the offset is `c*q + min(c,r)`, and
local index `i=1..length` maps to global index `offset+i`. Each rank has
three arrays of shape `(nx+2,ny+2,nz+2)`, with the last axis contiguous.

Open MPI chooses a balanced nonperiodic grid via `MPI_Dims_create`; an
explicit `--dims 1x2x4` is also supported. The six neighbors come from
`MPI_Cart_shift`. Committed subarray datatypes select faces without their
edges/corners. Every step posts receives, posts sends, waits, computes, then
rotates pointers. A send tags its own outgoing face; its peer receives with
the opposite face tag. Exterior halos remain zero on all three layers.

MPI calls run outside OpenMP regions on the thread that called
`MPI_Init_thread(MPI_THREAD_FUNNELED)`. Updates use static work sharing over
planes and SIMD along rows. Each rank first-touches its three arrays in parallel.
Timing starts after an MPI barrier, includes exchanges and updates (including
the special first step), and is reduced with MAX. Initialization and error
checks are outside the timer. The optional verification mode tests all face
values using a global-index pattern and checks every interior point against
the discrete sine mode. The default report compares with the analytical mode.

## Build and verify on Polus

From the project root on Polus:

```bash
source setup.sh mpi
./run.sh hybrid --ranks 4 --n 128 --length pi --dry-run
bash scripts/polus/mpi_benchmark.sh --plan
```

The MPI module defaults to OpenMPI/4.0.2. Its wrapper compiles against the
system MPI C API using GCC from `wave-cpp17` (`OMPI_CXX`). Configure
`POLUS_MPI_MODULE` if needed. Do not run numerical tests on the login node.

Freeze binaries for a new validation/benchmark directory after setup succeeds:

```bash
campaign="$(pwd -P)/results/polus/mpi/$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$(dirname "$campaign")"
mkdir "$campaign" && mkdir "$campaign/bin" "$campaign/logs"
flags='-O3 -Wall -Wextra -Wpedantic -mcpu=power8 -mtune=power8'
make BUILD_DIR="$campaign/bin" mpi optimized CXX="$OMPI_CXX" CXXFLAGS="$flags" \
  > "$campaign/bin/mpi-build.txt" 2>&1
cat "$campaign/bin/mpi-build.txt"  # Continue only if make succeeded.
{
  "$OMPI_CXX" --version | head -1
  "$MPICXX" --showme
  "$MPIEXEC" --version | head -1
  sha256sum "$campaign/bin/wave_solver_mpi" "$campaign/bin/wave_solver_opt"
} >> "$campaign/bin/mpi-build.txt"
export WAVE_MPI_ROOT="$(pwd -P)" WAVE_MPI_BIN_DIR="$campaign/bin" WAVE_MPI_TEST=1
bsub -q short -W 00:10 -x -m "$POLUS_FULL_V1_HOST" -n 16 -R 'span[hosts=1]' \
  -J wave_mpi_verify -o "$campaign/verify.%J.out" -e "$campaign/verify.%J.err" \
  < scripts/polus/mpi_job.lsf
```

Check the LSF result and the `PASS` lines; any failing test stops the suite.
The job uses a hostfile built from LSF slot counts, disables oversubscription,
binds to cores and records rank bindings and hostnames. Benchmarks use 20
steps and CFL fraction 0.5, with `T=20*0.5/sqrt(sum((N/Laxis)^2))`.

After verification, select and submit individual measurements explicitly:

```bash
bash scripts/polus/mpi_benchmark.sh --submit-one "$campaign" mpi 512 1 1 1
bash scripts/polus/mpi_benchmark.sh --submit-one "$campaign" hybrid 512 pi 4 1
"$PYTHON" scripts/analyze_mpi.py "$campaign" > "$campaign/summary.csv"
```

The last argument of the submit command is the repetition number. Repeat
with different positive numbers; keep all logs and use the same frozen
binaries. The summary uses the median of completed repetitions and groups by
problem and execution mode. MPI speedup uses one rank with one thread;
hybrid speedup uses one rank with four threads. Missing one-rank baselines
produce a blank speedup. Smoke timings are not scaling measurements.

The 32-rank MPI and 8-rank × 4-thread hybrid rows require two nodes. After
verifying the two-node configuration, opt in explicitly per submission:

```bash
MPI_ALLOW_TWO_NODES=1 bash scripts/polus/mpi_benchmark.sh --submit-one "$campaign" mpi 512 1 32 1
```

The job requests `span[ptile=16]` without a host restriction, checks the two
16-slot allocations, and maps half the ranks to each host with
`ppr:<ranks/2>:node:PE=<threads>`. For the two-node correctness suite, use
`WAVE_MPI_TEST=multinode`, `-n 32 -R 'span[ptile=16]'` and remove `-m`
from the validation command above. For an end-user scaling comparison,
record the change in host topology and verify that the interconnect chosen
by Open MPI is appropriate. Do not infer InfiniBand use from the host names.

See [MPI_VERIFICATION.md](MPI_VERIFICATION.md) for the initial Polus results.

On another cluster build with `make mpi MPICXX=/path/to/mpicxx`. Use its
scheduler allocation and launcher; `run.sh` targets Open MPI and accepts
`MPIEXEC`, `MPI_SOLVER`, `MPI_HOSTFILE`, `MPI_MAP_BY`, `OMP_PLACES` and `OMP_PROC_BIND`.
For another MPI launcher use `wave_solver_mpi` directly with its equivalent
rank and core mapping options. No cluster paths are in the numerical code.
