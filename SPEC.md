# SPEC — Wave Solver, Variant 1 (V1: OpenMP)

## 1. Scope and goal

Implement a **correct, simple, testable** numerical solution of the 3D wave equation for **variant 1 only** of the attached university assignment *«Задача 2 СучковЕП.pdf»*.

V1: **C++17 + OpenMP**, no MPI and no CUDA. Later, separate implementations may use MPI, MPI+OpenMP, and CUDA C++. Do not implement them in V1.

The first implementation is a correctness baseline. No execution-time budget or automatic stop condition is required. **Physical modeling time** `T` is not the same as measured wall-clock runtime.

## 2. Mathematical problem

Domain:

    Omega = [0, Lx] × [0, Ly] × [0, Lz],   0 <= t <= T

PDE:

    ∂²u/∂t² = ∂²u/∂x² + ∂²u/∂y² + ∂²u/∂z².

Initial conditions:

    u(x,y,z,0) = phi(x,y,z) = sin(pi*x/Lx) sin(pi*y/Ly) sin(pi*z/Lz)
    ∂u/∂t(x,y,z,0) = 0.

Variant 1 boundary conditions: **u = 0 on all six faces** at every time layer (homogeneous Dirichlet).

Analytical reference solution (used for validation, not for stepping):

    u_exact(x,y,z,t) = sin(pi*x/Lx) sin(pi*y/Ly) sin(pi*z/Lz) cos(a*t),
    a = pi * sqrt(1/Lx² + 1/Ly² + 1/Lz²).

## 3. Discretization (as in the assignment)

Interpret `N` as the number of intervals per spatial axis:

    i,j,k = 0,...,N; node count = (N+1)^3.
    hx = Lx/N, hy = Ly/N, hz = Lz/N.

This is consistent with the explicit grid definition in the assignment. Note that its illustrative tables use `N^3` notation; document our convention in the help/output.

Time grid:

    t_n = n*tau, n = 0,...,K; tau = T/K.

Seven-point discrete Laplacian at interior nodes:

    Lap_h(u)[i,j,k] =
        (u[i-1,j,k] - 2*u[i,j,k] + u[i+1,j,k])/hx²
      + (u[i,j-1,k] - 2*u[i,j,k] + u[i,j+1,k])/hy²
      + (u[i,j,k-1] - 2*u[i,j,k] + u[i,j,k+1])/hz².

Time initialization:

    u^0[i,j,k] = phi(x_i,y_j,z_k)
    u^1[i,j,k] = u^0[i,j,k] + (tau²/2) * Lap_h(u^0)[i,j,k]

for interior nodes. Explicitly set all boundary nodes to zero.

For n=1,...,K-1:

    u^(n+1)[i,j,k] = 2*u^n[i,j,k] - u^(n-1)[i,j,k]
                        + tau² * Lap_h(u^n)[i,j,k].

The implementation must handle `K=1` (first-layer formula only). Do not compute the next layer in place over the current input layer.

### Stability precondition

Require

    tau² * (1/hx² + 1/hy² + 1/hz²) <= 1

within a small tolerance for floating-point evaluation. On violation, produce an informative error and exit with nonzero status. **Do not silently alter `K` or `T`.**

## 4. Command-line interface

Example:

    ./build/wave_solver --n 128 --lx 1 --ly 1 --lz 1 --time 1 --steps 256 --threads 4

Required parameters: `--n`, `--lx`, `--ly`, `--lz`, `--time`, `--steps`, `--threads`. Provide `--help`. No hidden defaults for essential mathematical parameters; require each argument or clearly document any deliberately chosen test-only defaults.

Validation:
- `N >= 2`; `K >= 1`; `threads >= 1`.
- All domain lengths and `T` strictly positive and finite.
- Detect invalid/unknown arguments, integer overflow in allocation dimensions, allocation errors, and stability violation.

No artificial wall-clock time limit and no auto-selection of `K` to meet a deadline.

## 5. V1 architecture and implementation constraints

- C++17, standard library, OpenMP only; no third-party dependencies, no MPI, no CUDA.
- Use a flat contiguous storage structure of `double` for each temporal layer.
- Begin with three layer arrays (`previous`, `current`, `next`); rotate their roles without copying full arrays.
- Treat spatial boundaries as identically zero for every layer.
- Separate: configuration/validation; mathematical reference; grid and memory; time-stepping; error measurement; output.
- Prefer simple structs and free functions. Avoid unnecessary inheritance, templates, backend abstractions, frameworks, and preemptive MPI/CUDA code.
- OpenMP parallelism over interior spatial nodes. Each thread writes disjoint output elements. Observe the synchronization required between time layers.
- 1 OpenMP thread is a valid sequential reference mode.
- Be correct for `Lx`, `Ly`, `Lz` that differ, not only for cubes.

## 6. Outputs and timing

Print at minimum:
- Parameters: N, total node count, Lx, Ly, Lz, T, K, tau, effective OpenMP thread count.
- Wall-clock time of the numerical solve (include the first-layer calculation and all subsequent steps; exclude argument parsing, allocation, initialization of u^0, and analytical error computation).
- Max absolute error of the final layer at physical time T over all spatial nodes:

    max_{0<=i,j,k<=N} |u_numeric(i,j,k,T) - u_exact(x_i,y_j,z_k,T)|.

Do not store all time layers to check error. Time measurement can use `omp_get_wtime()`.

A stable machine-readable output format (e.g., `key=value` lines) is desirable; no complex reporting pipeline is needed for V1. Do not conflate physical time `T` with execution time.

## 7. Testing and acceptance

Provide build and automated small-grid smoke tests runnable **without access to Polus**. Tests should cover:

1. Valid small configuration completes and produces finite error and nonnegative elapsed time.
2. `K=1` correctly uses the special first-layer formula.
3. All six faces remain exactly zero in the numerical arrays.
4. One OpenMP thread and multiple OpenMP threads give numerically consistent results for the same problem.
5. Invalid inputs and violations of the stability condition fail cleanly.
6. Unequal `Lx`, `Ly`, `Lz` work correctly.

Useful independent hand-check: for `N=2`, `Lx=Ly=Lz=1`, `T=0.01`, `K=1`, the unique interior node at (1,1,1) has `u^0=1`, `Lap_h(u^0)=-24`, so `u^1=0.9988` (up to floating-point rounding). This checks the first-layer computation, not the analytical result.

The analytical formula must **not** be substituted for numerical stepping.

Use no arbitrary universal error threshold (e.g. `1e-6`) across all grids and time parameters; compare against mathematically justified independent tests and against 1-thread results.

## 8. Build and deployment

- Use a **Makefile**, not CMake.
- Primary environment is the IBM Polus POWER8 cluster; C++17 is available according to user confirmation.
- A portable GNU/G++ OpenMP build should be supported (`-std=c++17`, `-fopenmp`; compiler configurable through Make variables).
- Do not hardwire POWER8 flags into all builds; optional architecture flags may be added later.
- Provide useful `make`, `make test`, `make clean` targets.
- Build artifacts and result logs should be ignored by Git.
- For Polus, the documented batch scheduler is **IBM Spectrum LSF**: OpenMP jobs may be submitted through `bsub` command files; later MPI jobs may use `mpisubmit.pl`. The queue scripts will be implemented/tested in a later stage after V1 runs locally. Do not invent Slurm scripts.
- Scheduler wall-time reservations are distinct from the **absence of an algorithmic runtime limit** in V1.

## 9. Explicitly out of scope for V1

MPI, MPI+OpenMP, CUDA C++, support for variants 2–8, periodic boundary conditions, fixed wall-clock stopping budgets, cache blocking, manual VSX intrinsics, aggressive `fast-math`, temporal blocking, and optimization-driven redesign.

## 10. Source and precedence

Original assignment: `Задача 2 СучковЕП.pdf` (especially sections 2, 3, 5, 6, 7). If this SPEC deliberately fixes an ambiguity (such as `N` intervals), follow the SPEC and document it. If a mathematical contradiction is found, **stop and report it instead of silently changing the scheme**.
