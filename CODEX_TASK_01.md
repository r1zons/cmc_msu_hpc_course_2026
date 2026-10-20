# First Codex task — implement V1, without premature optimization

We have a new repository for a university project on numerical solution of the 3D wave equation. Read `SPEC.md` and `AGENTS.md` completely before writing code; refer to `Задача 2 СучковЕП.pdf` if it is present.

**Implement V1: C++17 + OpenMP, variant 1 only.** The goal is the **simplest correct working implementation**, not the fastest one. Do not add MPI, hybrid MPI/OpenMP, CUDA, periodic boundary conditions, support for other variants, or any fixed execution-time budget.

Please do the work in this sequence:

1. Inspect the repository. Briefly state the proposed minimal file structure and identify any mathematical ambiguities before coding. Do not wait for approval on ordinary file-organization choices; if the numerical problem genuinely contradicts itself, explain the blocker.
2. Implement CLI validation for `--n`, `--lx`, `--ly`, `--lz`, `--time`, `--steps`, `--threads`, and `--help`.
3. Implement the grid, exact solution, initial state, special first time step, and the specified explicit seven-point scheme using `double` and three flat contiguous layer arrays. Set all six faces to zero on every layer. Make `K=1` work.
4. Add OpenMP parallel loops for independent interior nodes, with correct synchronization between layers. Ensure the program runs with `--threads 1` as well as `--threads 4` (if hardware permits).
5. Add a Makefile (`make`, `make test`, `make clean`) without CMake or nonstandard test dependencies. Add a concise README and a sensible `.gitignore`.
6. Add automated small-grid tests, including a hand-check of the first-layer value `0.9988` for `N=2, Lx=Ly=Lz=1, T=0.01, K=1`, boundary zeros, validity/stability failures, noncubic domain, and consistency across thread counts.
7. Build and run the tests. If OpenMP is unavailable in your execution environment, explain how to run the same tests on Polus. Do not claim unexecuted tests passed.

Example CLI:

    ./build/wave_solver --n 128 --lx 1 --ly 1 --lz 1 --time 1 --steps 256 --threads 4

Provide readable output with parameters, actual numerical wall-clock solve time, and maximum absolute error vs. the analytical solution at physical time T. Time measurement must not include parsing/allocation/initial `u^0` setup/reference-error calculation, but must include the first-step computation.

When done, report:
- files created/changed;
- build and test commands;
- actual tests run and outcomes;
- sample program output;
- known limitations and anything that still needs testing on POWER8.

**Do not implement LSF queue scripts in this task.** They will be added once the V1 executable and its CLI are verified; Polus uses IBM Spectrum LSF, not Slurm. This is separate from the decision not to impose an execution-time limit inside the program.
