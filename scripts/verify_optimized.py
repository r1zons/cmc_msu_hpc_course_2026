#!/usr/bin/env python3
"""Verify the optimized solver against the exact discrete sine recurrence."""

from __future__ import annotations

import argparse
import math
import subprocess


def expected_error(n: int, length: float, final_time: float, steps: int) -> float:
    dt = final_time / steps
    omega = math.pi * math.sqrt(3.0) / length
    omega_h_squared = (
        12.0 * math.sin(math.pi / (2.0 * n)) ** 2 * (n / length) ** 2
    )
    theta = 2.0 * math.asin(0.5 * dt * math.sqrt(omega_h_squared))
    return abs(math.cos(steps * theta) - math.cos(omega * final_time))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("solver")
    parser.add_argument("--threads", type=int, default=1)
    args = parser.parse_args()
    for n in (128, 256, 512):
        for length in (1.0, math.pi):
            final_time = 20.0 * 0.5 * length / (math.sqrt(3.0) * n)
            command = [
                args.solver,
                "--n", str(n), "--lx", repr(length), "--ly", repr(length),
                "--lz", repr(length), "--time", format(final_time, ".17g"),
                "--steps", "20", "--threads", str(args.threads),
            ]
            completed = subprocess.run(
                command, check=True, text=True, stdout=subprocess.PIPE
            )
            values = dict(
                line.split("=", 1) for line in completed.stdout.splitlines()
                if "=" in line
            )
            observed = float(values["max_absolute_error"])
            reference = expected_error(n, length, final_time, 20)
            tolerance = max(5.0e-12, 1.0e-6 * reference)
            if abs(observed - reference) > tolerance:
                raise AssertionError(
                    f"N={n}, L={length}: observed={observed:.17g}, "
                    f"reference={reference:.17g}, tolerance={tolerance:.3g}"
                )
            print(
                f"N={n} L={length:.17g} threads={args.threads} "
                f"seconds={float(values['solve_wall_seconds']):.9g} "
                f"error={observed:.17g} reference={reference:.17g}"
            )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
