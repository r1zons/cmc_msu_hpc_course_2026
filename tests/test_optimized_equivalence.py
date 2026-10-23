#!/usr/bin/env python3
"""Compare V1 and optimized kernels on representative stable problems."""

from __future__ import annotations

import math
import subprocess
import sys


def run(executable: str, n: int, length: float, threads: int) -> dict[str, str]:
    final_time = 20.0 * 0.5 * length / (math.sqrt(3.0) * n)
    completed = subprocess.run(
        [executable, "--n", str(n), "--lx", repr(length), "--ly", repr(length),
         "--lz", repr(length), "--time", format(final_time, ".17g"),
         "--steps", "20", "--threads", str(threads)],
        check=True, text=True, stdout=subprocess.PIPE,
    )
    return dict(line.split("=", 1) for line in completed.stdout.splitlines()
                if "=" in line)


def main() -> int:
    if len(sys.argv) != 3:
        raise SystemExit("usage: test_optimized_equivalence.py BASELINE OPTIMIZED")
    for n in (32, 64, 128):
        for length in (1.0, math.pi):
            for threads in (1, 4):
                baseline = run(sys.argv[1], n, length, threads)
                optimized = run(sys.argv[2], n, length, threads)
                baseline_error = float(baseline["max_absolute_error"])
                optimized_error = float(optimized["max_absolute_error"])
                tolerance = max(1.0e-13, 1.0e-7 * baseline_error)
                if abs(baseline_error - optimized_error) > tolerance:
                    raise AssertionError(
                        f"N={n}, L={length}, threads={threads}: "
                        f"error {optimized_error} differs from {baseline_error}"
                    )
    print("Baseline/optimized equivalence tests passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
