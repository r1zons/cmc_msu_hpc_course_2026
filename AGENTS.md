# Instructions for Codex — Wave Solver

## Project scope

- This repository concerns the university assignment "Задача 2", **variant 1 only**.
- Read `SPEC.md` and consult the original PDF when available before making mathematical changes.
- Delivery sequence: **V1 OpenMP** → V2 MPI → V3 MPI+OpenMP → V4 CUDA C++.
- **Current scope is V1.** Do not add future versions preemptively.

## Engineering priorities

1. Mathematical correctness and reproducibility.
2. Simple, readable C++17 code and robust input validation.
3. Working OpenMP parallelization and tests.
4. Measured optimization later, only on explicit request.

Keep code small, cohesive, and easily auditable. Prefer plain structs/functions and contiguous `double` arrays. Avoid speculative abstractions, complicated template systems, external dependencies, and unnecessary configuration mechanisms.

## Required conventions

- Build with `make`, **not CMake**.
- Use only the C++ standard library and OpenMP in V1.
- No MPI or CUDA code in V1, even in otherwise unused paths.
- `N` means number of intervals per axis; nodes run `0..N`, totaling `(N+1)^3`.
- `T` is physical final time; `K` is the requested number of time steps; `tau=T/K`.
- No execution-time budget/automatic timeout and **do not silently change inputs**.
- Enforce CFL stability condition before the solve.
- The known analytical solution is for initialization and validation, never a shortcut for time stepping.
- Use `double`, zero Dirichlet values on all faces, three layers initially.
- V1 must be correct with one or multiple OpenMP threads.

## Change discipline

- Work in small coherent changes. After each stage: build, run tests, and report what was verified.
- Include command lines and relevant actual outputs in the completion report; do not claim tests that were not run.
- If the current environment cannot compile OpenMP or run Polus jobs, clearly say so; do not claim successful cluster testing.
- When optimizing later, compare against the same `N,Lx,Ly,Lz,T,K` and report both runtime and final-layer error.
- Do not modify the numerical method or boundary conditions for speed without explicit approval.
- Do not create queue-submission scripts with an invented scheduler. Polus uses IBM Spectrum LSF per official documentation; queue scripts are a **later, separate stage**.

## Expected V1 finish criteria

- `make` builds the OpenMP executable.
- `make test` runs small-grid correctness checks with no third-party test framework.
- CLI accepts and validates all parameters specified in `SPEC.md`.
- Program reports numerical runtime and final-time maximum absolute error.
- Test with 1 and several OpenMP threads; program is free of obvious data races in numerical kernels.
- `README.md` documents build, run and tests, including the meaning of `N` and `T`.

When there is ambiguity, prefer the mathematically conservative and simpler interpretation; explicitly record assumptions in the report. Do not silently fill in missing specifications.
