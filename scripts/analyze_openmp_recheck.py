#!/usr/bin/env python3
"""Offline recheck analysis; Python >=3.7, standard library only."""
from __future__ import annotations

import argparse
import csv
import math
from pathlib import Path
import statistics

from analyze_full_v1 import read_key_values, discrete_error_reference


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("campaign", type=Path)
    parser.add_argument("--original", type=Path, help="optional original full campaign")
    args = parser.parse_args()
    campaign = args.campaign
    issues = []
    summary = []
    observations = []
    with (campaign / "manifest.csv").open(newline="") as handle:
        manifest = list(csv.DictReader(handle))
    if [row["configuration"] for row in manifest] != ["A", "B", "C"]:
        raise ValueError("expected exactly configurations A, B, C")
    for row in manifest:
        name = row["configuration"]
        length = 1.0 if name == "B" else math.pi
        threads = 20 if name == "C" else 16
        dt = 0.5 * length / (math.sqrt(3) * 128)
        expected = discrete_error_reference(128, length, length, length, 20 * dt, 20)
        for key, value in (("l", length), ("threads", threads), ("dt", dt), ("T", 20*dt), ("K", 20), ("cfl_fraction", .5), ("warmups", 2), ("repetitions", 10)):
            if not math.isclose(float(row[key]), value, rel_tol=2e-13):
                raise ValueError(f"{name}: invalid manifest {key}")
        times, errors = [], []
        for phase, count in (("warmup", 2), ("measured", 10)):
            for repetition in range(1, count + 1):
                paths = list((campaign / "measurements").glob(f"{name}_{phase}_{repetition}.job*.meta"))
                try:
                    if len(paths) != 1:
                        raise ValueError(f"expected one result, found {len(paths)}")
                    path = paths[0]
                    meta = read_key_values(path)
                    if meta["exit_code"] != "0":
                        raise ValueError(f"solver exit {meta['exit_code']}")
                    for key, value in (("configuration", name), ("phase", phase), ("repetition", str(repetition))):
                        if meta[key] != value:
                            raise ValueError(f"metadata mismatch: {key}")
                    output = read_key_values(path.with_suffix(".stdout"))
                    for key, value in (("n",128), ("node_count",129**3), ("lx",length), ("ly",length), ("lz",length), ("time_steps",20), ("physical_final_time",20*dt), ("tau",dt), ("openmp_threads",threads)):
                        actual = float(output[key])
                        if not math.isfinite(actual) or not math.isclose(actual, value, rel_tol=2e-13):
                            raise ValueError(f"solver parameter mismatch: {key}")
                    elapsed, error = float(output["solve_wall_seconds"]), float(output["max_absolute_error"])
                    if not all(math.isfinite(x) and x >= 0 for x in (elapsed, error)):
                        raise ValueError("nonfinite or negative measurement")
                    if abs(error - expected) > 5e-12:
                        raise ValueError(f"error {error} differs from reference {expected}")
                    observations.append(dict(configuration=name, phase=phase, repetition=repetition, seconds=elapsed, error=error, job_id=meta["job_id"]))
                    if phase == "measured":
                        times.append(elapsed)
                        errors.append(error)
                except (OSError, ValueError, KeyError) as exc:
                    issues.append(f"{name} {phase} {repetition}: {exc}")
        mean = statistics.mean(times) if times else 0
        std = statistics.stdev(times) if len(times) > 1 else 0
        summary.append(dict(configuration=name, valid_repetitions=len(times), minimum=min(times) if times else "", median=statistics.median(times) if times else "", maximum=max(times) if times else "", mean=mean, standard_deviation=std, coefficient_of_variation=std/mean if mean else "", relative_range=(max(times)-min(times))/mean if mean else "", minimum_error=min(errors) if errors else "", maximum_error=max(errors) if errors else ""))
    analysis = campaign / "analysis"
    analysis.mkdir(exist_ok=True)
    for filename, rows in (("summary.csv", summary), ("invocation_order.csv", observations)):
        with (analysis / filename).open("w", newline="") as handle:
            fields = list(rows[0]) if rows else ["configuration"]
            writer = csv.DictWriter(handle, fieldnames=fields)
            writer.writeheader()
            writer.writerows(rows)
    comparisons = []
    for name, pattern in (("A", "n128_lpi_t16"), ("B", "n128_l1_t16"), ("C", "n128_lpi_t20")):
        original = [.05865, .08823, .11493] if name == "A" else []
        provenance = "user-supplied approximate times" if original else "unavailable locally"
        if args.original:
            original = []
            try:
                for repetition in range(1, 4):
                    paths = list((args.original / "measurements").glob(f"{pattern}_r{repetition}.job*.stdout"))
                    if len(paths) != 1:
                        raise ValueError(f"expected one original repetition {repetition}, found {len(paths)}")
                    value = float(read_key_values(paths[0])["solve_wall_seconds"])
                    if not math.isfinite(value) or value < 0:
                        raise ValueError("invalid original timing")
                    original.append(value)
                provenance = "original raw timings; validate original campaign with analyze_full_v1.py"
            except (OSError, ValueError, KeyError) as exc:
                issues.append(f"original {name}: {exc}")
                original = []
                provenance = "unavailable or invalid"
        comparisons.append(f"Original {name}: {original} seconds ({provenance})")
        current = next(row for row in summary if row["configuration"] == name)
        if original and current["valid_repetitions"]:
            baseline = statistics.median(original)
            comparisons.append(f"{name}: original median={baseline:.9g}s; recheck median={current['median']:.9g}s; new/old ratio={current['median']/baseline if baseline else 'undefined'}")
    report = ["COMPLETE" if not issues else "INCOMPLETE"] + comparisons
    report.extend(str(row) for row in summary)
    report.extend(issues)
    report.append("Inspect invocation_order.csv alongside per-process stderr affinity records and LSF logs. Slow measurements are retained. Timing alone cannot identify a hardware cause. Warm-ups use separate processes and do not retain an OpenMP thread pool across invocations.")
    text = "\n".join(report) + "\n"
    (analysis / "report.txt").write_text(text)
    (analysis / "missing_or_failed.txt").write_text("\n".join(issues) + ("\n" if issues else ""))
    print(text, end="")
    return int(bool(issues))


if __name__ == "__main__":
    raise SystemExit(main())
