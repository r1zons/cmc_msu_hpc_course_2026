#!/usr/bin/env python3
"""Validate and summarize a prepared Polus optimization A/B campaign."""

from __future__ import annotations

import csv
import math
from pathlib import Path
import statistics
import sys


def expected_error(n: int) -> float:
    dt = 0.5 / (math.sqrt(3.0) * n)
    final_time = 20.0 * dt
    omega = math.pi * math.sqrt(3.0)
    omega_h_sq = 12.0 * n * n * math.sin(math.pi / (2.0 * n)) ** 2
    theta = 2.0 * math.asin(0.5 * dt * math.sqrt(omega_h_sq))
    return abs(math.cos(20.0 * theta) - math.cos(omega * final_time))


def main() -> int:
    if len(sys.argv) != 2:
        raise SystemExit("usage: analyze_optimization_ab.py CAMPAIGN")
    campaign = Path(sys.argv[1])
    metadata = {}
    for line in (campaign / "metadata.txt").read_text(encoding="utf-8").splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            metadata[key] = value
    with (campaign / "manifest.csv").open(newline="", encoding="utf-8") as f:
        manifest = list(csv.DictReader(f))
    rows: dict[str, dict[str, str]] = {}
    for path in (campaign / "measurements").glob("*.csv"):
        with path.open(newline="", encoding="utf-8") as f:
            data = list(csv.DictReader(f))
        if len(data) == 1:
            rows[data[0]["measurement_id"]] = data[0]

    failures: list[str] = []
    grouped: dict[tuple[int, int, str], list[float]] = {}
    errors: dict[tuple[int, int, str], list[float]] = {}
    for planned in manifest:
        identity = planned["measurement_id"]
        row = rows.get(identity)
        if row is None:
            failures.append(f"missing {identity}")
            continue
        n, threads = int(row["n"]), int(row["threads"])
        expected_hash = metadata[f"{row['variant']}_sha256"]
        identity_matches = all(
            row[key] == planned[key]
            for key in ("variant", "n", "threads", "repetition")
        )
        host_matches = row["hostname"] == metadata["required_host"]
        hash_matches = row["binary_sha256"] == expected_hash
        if (not identity_matches or not host_matches or not hash_matches or
                int(row["exit_code"]) != 0 or
                int(row["effective_threads"]) != threads):
            failures.append(f"invalid execution {identity}")
            continue
        error = float(row["max_absolute_error"])
        reference = expected_error(n)
        if abs(error - reference) > max(5.0e-12, 1.0e-6 * reference):
            failures.append(f"wrong error {identity}: {error} vs {reference}")
            continue
        key = (n, threads, row["variant"])
        grouped.setdefault(key, []).append(float(row["solve_wall_seconds"]))
        errors.setdefault(key, []).append(error)

    fields = [
        "n", "threads", "variant", "count", "median_seconds", "min_seconds",
        "max_seconds", "mean_seconds", "stdev_seconds", "cv", "speedup",
        "median_error",
    ]
    summary: list[dict[str, object]] = []
    for n in (128, 256, 512):
        for threads in (1, 4, 8, 16, 20):
            baseline = grouped.get((n, threads, "baseline"), [])
            baseline_median = statistics.median(baseline) if baseline else math.nan
            for variant in ("baseline", "optimized"):
                values = grouped.get((n, threads, variant), [])
                if not values:
                    continue
                if len(values) != 5:
                    failures.append(
                        f"expected 5 repetitions for N={n}, threads={threads}, "
                        f"variant={variant}; got {len(values)}"
                    )
                mean = statistics.mean(values)
                stdev = statistics.stdev(values) if len(values) > 1 else 0.0
                median = statistics.median(values)
                summary.append({
                    "n": n, "threads": threads, "variant": variant,
                    "count": len(values), "median_seconds": median,
                    "min_seconds": min(values), "max_seconds": max(values),
                    "mean_seconds": mean, "stdev_seconds": stdev,
                    "cv": stdev / mean if mean else math.nan,
                    "speedup": baseline_median / median,
                    "median_error": statistics.median(errors[(n, threads, variant)]),
                })
    with (campaign / "summary.csv").open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=fields)
        writer.writeheader()
        writer.writerows(summary)
    with (campaign / "report.txt").open("w", encoding="utf-8") as f:
        f.write(f"planned={len(manifest)}\nvalid={sum(map(len, grouped.values()))}\n")
        f.write(f"failures={len(failures)}\n")
        for failure in failures:
            f.write(f"{failure}\n")
        for row in summary:
            if row["variant"] == "optimized":
                f.write(
                    f"N={row['n']} threads={row['threads']} "
                    f"median={row['median_seconds']:.9g}s "
                    f"speedup={row['speedup']:.4f} cv={row['cv']:.4f}\n"
                )
    print((campaign / "report.txt").read_text(encoding="utf-8"), end="")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
