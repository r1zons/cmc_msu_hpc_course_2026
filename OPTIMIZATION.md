# OpenMP V1 optimization notes

The historical V1 implementation and all full-campaign scripts remain intact.
The new executable is `build/wave_solver_opt`; it uses the same CLI,
double-precision scheme, boundary conditions, three time layers, and error
calculation as `build/wave_solver`.

## Baseline diagnosis

The existing solver already rotates three `std::vector` objects in O(1), so
there is no per-step full-layer copy to remove. Its important costs are:

- `collapse(3)` prevents Clang 19 from vectorizing the stencil loops in a local
  optimization report. It also turns the natural contiguous inner loop into an
  OpenMP collapsed iteration space.
- A new OpenMP parallel region is entered for every time layer.
- Three value-initialized vectors are first touched serially. On a multi-socket
  node this can place most pages on the NUMA node of the master thread.
- Grid strides, flat indices, squared spacings, and the three center terms are
  repeatedly reconstructed in the hot loop.

The optimized variant therefore uses a persistent OpenMP region, static
outer-`i` partitioning, explicit SIMD over contiguous `k`, precomputed stencil
weights, 64-byte-aligned uninitialized layers, and parallel first touch of all
three layers. Layer roles are still changed only by pointer swaps. Ordinary
cached stores are retained because an output layer becomes the current input
on the next time step; non-temporal stores would discard useful data.

## Traffic and roofline model

For `N=512`, one layer has `513^3 = 135,005,697` doubles, or 1.080 GB; three
layers occupy 3.240 GB. Twenty steps update
`20 * 511^3 = 2,668,656,620` interior points.

With spatial reuse, the optimistic compulsory traffic per update is 24 bytes
(one current value, one previous value, one output). A more realistic streaming
lower bound is 32 bytes when write allocation/writeback is included. The
worst no-cache-reuse count is 72 bytes (eight input loads plus one store). The
kernel performs only about 11 floating-point operations per update, so at the
32-byte bound its arithmetic intensity is about 0.34 flop/byte and a vectorized
20-core run should be memory-bound.

The historical Polus median `2.9211 s` at `N=512`, 20 threads corresponds to
0.913 GLUP/s. Depending on which traffic bound is observed, that implies
21.9, 29.2, or 65.8 GB/s. A twofold result (`<= 1.4606 s`) needs at least 43.8,
58.5, or 131.5 GB/s respectively. Because no STREAM result or memory-controller
counter for the exact `polus-c4-ib.bmc.hpc.cs.msu.ru` node is available, using
a vendor peak here would be misleading. At the practical 32-byte bound the
parametric lower limits are:

| Sustained bandwidth | Lower time | Maximum speedup vs 2.9211 s |
|---:|---:|---:|
| 40 GB/s | 2.135 s | 1.37x |
| 60 GB/s | 1.423 s | 2.05x |
| 80 GB/s | 1.067 s | 2.74x |
| 120 GB/s | 0.712 s | 4.10x |

Thus 2x is physically plausible only if the optimized NUMA placement and
vectorized kernel sustain roughly 60 GB/s or more under the realistic model.
Only the Polus A/B below can establish that.

## Local evidence (not Polus)

Both binaries were compiled with the same Clang 19 `-O2` flags and run with
`OMP_DYNAMIC=FALSE`, `OMP_PLACES=cores`, and `OMP_PROC_BIND=close`. Runs were
interleaved. The host has 12 logical CPUs and is not a POWER8 system.

| N | Threads | Repetitions | V1 median | Optimized median | Speedup |
|---:|---:|---:|---:|---:|---:|
| 128 | 1 | 5 | 0.6043 s | 0.08114 s | 7.45x |
| 128 | 8 | 5 | 0.1044 s | 0.05474 s | 1.91x |
| 256 | 1 | 4 | 3.9806 s | 0.7835 s | 5.08x |
| 256 | 8 | 4 | 0.7782 s | 0.6167 s | 1.26x |
| 512 | 1 | 1 | 33.4286 s | 6.7064 s | 4.98x |
| 512 | 8 | 3 | 6.1644 s | 5.2165 s | 1.18x |

The compiler report says the baseline stencil loops were not vectorized and
all optimized hot `k` loops were vectorized (width two on this x86 host).
The decreasing multi-thread speedup at large N demonstrates local bandwidth
saturation and is why these numbers must not be presented as a Polus result.
The largest observed baseline/optimized error difference was about `3.1e-14`.

## Correctness and reproducibility

Run the complete baseline and optimized checks:

```sh
make test-all
python3 scripts/verify_optimized.py build/wave_solver_opt --threads 8
```

The second command checks `N=128,256,512` and both `L=1,pi` against the exact
discrete sine-mode recurrence at 20 steps and CFL 0.5.

For the Polus A/B, activate the same Conda environment used by V1, then:

```sh
bqueues -l short
bash scripts/polus/prepare_optimization_ab.sh
# Inspect the printed campaign path, metadata.txt, manifest.csv, and job script.
bash scripts/polus/submit_optimization_ab.sh ABSOLUTE_CAMPAIGN --submit
# Wait until all jobs finish; no command above submits without explicit --submit.
python3 scripts/analyze_optimization_ab.py ABSOLUTE_CAMPAIGN
```

Preparation builds and freezes baseline and optimized binaries with identical
explicit flags (`-O3 -mcpu=power8 -mtune=power8` by default), records compiler
version and SHA-256 hashes, and creates 150 planned measurements: both variants,
`N=128,256,512`, 1/4/8/16/20 threads, and five independent repetitions. Each
measurement is one LSF job on the required host, with `short`, `00:10`, `-x`,
`span[hosts=1]`, exact requested slots, 20 steps, CFL 0.5, and close core
binding. The analyzer validates the theoretical error and reports median,
min/max, sample standard deviation, coefficient of variation, and A/B speedup.

## Ranked next steps if Polus remains below 2x

1. Measure sustained bandwidth and NUMA counters on the same exclusive node;
   compare close versus spread binding as a separate controlled experiment.
2. Inspect GCC POWER8 vectorization output and generated VSX instructions. The
   current source is portable and should vectorize, but this must be confirmed
   with the actual compiler.
3. Try small `i/j` cache tiles only if counters show excess current-layer
   reloads. The three adjacent N=512 planes are about 6.3 MB, so tiling may have
   limited benefit relative to the engineering cost.
4. Consider multi-step temporal blocking only after the above. It can reduce
   compulsory traffic but requires halo/time-skew handling and substantially
   raises correctness risk. It is intentionally not part of this safe variant.

No claim of a 2x 20-thread Polus improvement is made until `summary.csv` from
the exact-host A/B supports it.
