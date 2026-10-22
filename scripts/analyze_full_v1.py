#!/usr/bin/env python3
"""Validate and summarize one copied V1 benchmark campaign."""

from __future__ import annotations

import argparse
import csv
import hashlib
import math
import re
import statistics
import sys
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any


GRID_SIZES = (128, 256, 512)
DOMAIN_LENGTHS = {"l1": 1.0, "lpi": math.pi}
THREAD_COUNTS = (1, 2, 4, 8, 16, 20)
REPETITIONS = (1, 2, 3)
NEW_TIME_STEPS = 20
NEW_CFL_FRACTION = 0.5
NEW_POLICY = "cfl_scaled_fixed_steps_v1"
LEGACY_POLICY = "fixed_time_k2n_v1"
FLOAT_TOLERANCE = 2.0e-13
MIN_ERROR_TOLERANCE = 5.0e-12

LEGACY_MANIFEST_FIELDS = (
    "measurement_id",
    "n",
    "domain_id",
    "lx",
    "ly",
    "lz",
    "physical_final_time",
    "time_steps",
    "requested_threads",
    "repetition",
    "job_group",
    "job_name",
)
MANIFEST_FIELDS = (
    "measurement_id",
    "n",
    "domain_id",
    "lx",
    "ly",
    "lz",
    "physical_final_time",
    "time_steps",
    "time_step",
    "cfl_fraction",
    "cfl_squared",
    "requested_threads",
    "repetition",
    "job_group",
    "job_name",
)
SUBMISSION_FIELDS = (
    "timestamp_utc",
    "event",
    "job_group",
    "job_name",
    "job_script",
    "lsf_job_id",
    "details",
)
SUMMARY_FIELDS = (
    "n",
    "domain_id",
    "domain_length",
    "physical_final_time",
    "time_steps",
    "time_step",
    "cfl_fraction",
    "cfl_squared",
    "requested_threads",
    "valid_repetitions",
    "median_seconds",
    "minimum_seconds",
    "maximum_seconds",
    "mean_seconds",
    "standard_deviation_seconds",
    "speedup",
    "parallel_efficiency",
    "median_max_absolute_error",
    "expected_numerical_error",
    "status",
)
ISSUE_FIELDS = ("measurement_id", "category", "detail", "path")

MEASUREMENT_FILE = re.compile(
    r"^(n(?:128|256|512)_(?:l1|lpi)_t(?:1|2|4|8|16|20)_r[123])"
    r"\.job([0-9]+)\.(meta|stdout|stderr)$"
)


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Validate and analyze one full V1 Polus campaign."
    )
    parser.add_argument("campaign_directory", type=Path)
    return parser.parse_args()


def time_parameters(
    n: int, lx: float, ly: float, lz: float, steps: int, cfl_fraction: float
) -> tuple[float, float, float]:
    hx = lx / n
    hy = ly / n
    hz = lz / n
    inverse_sum = 1.0 / hx**2 + 1.0 / hy**2 + 1.0 / hz**2
    time_step = cfl_fraction / math.sqrt(inverse_sum)
    final_time = steps * time_step
    cfl_squared = time_step * time_step * inverse_sum
    return time_step, final_time, cfl_squared


def expected_matrix(policy: str) -> dict[str, dict[str, Any]]:
    expected: dict[str, dict[str, Any]] = {}
    for n in GRID_SIZES:
        for domain_id, length in DOMAIN_LENGTHS.items():
            if policy == NEW_POLICY:
                steps = NEW_TIME_STEPS
                time_step, final_time, cfl_squared = time_parameters(
                    n, length, length, length, steps, NEW_CFL_FRACTION
                )
                cfl_fraction = NEW_CFL_FRACTION
            elif policy == LEGACY_POLICY:
                steps = 2 * n
                final_time = 1.0
                time_step = final_time / steps
                inverse_sum = 3.0 * (n / length) ** 2
                cfl_fraction = time_step * math.sqrt(inverse_sum)
                cfl_squared = cfl_fraction * cfl_fraction
            else:
                raise ValueError(f"unsupported benchmark policy: {policy!r}")
            for threads in THREAD_COUNTS:
                for repetition in REPETITIONS:
                    measurement_id = f"n{n}_{domain_id}_t{threads}_r{repetition}"
                    if n == 512:
                        job_group = measurement_id
                    else:
                        job_group = f"n{n}_{domain_id}_t{threads}_r123"
                    expected[measurement_id] = {
                        "measurement_id": measurement_id,
                        "n": n,
                        "domain_id": domain_id,
                        "length": length,
                        "lx": length,
                        "ly": length,
                        "lz": length,
                        "physical_final_time": final_time,
                        "time_steps": steps,
                        "time_step": time_step,
                        "cfl_fraction": cfl_fraction,
                        "cfl_squared": cfl_squared,
                        "requested_threads": threads,
                        "repetition": repetition,
                        "job_group": job_group,
                    }
    return expected


def add_issue(
    issues: list[dict[str, str]],
    measurement_id: str,
    category: str,
    detail: str,
    path: Path | str = "",
) -> None:
    issues.append(
        {
            "measurement_id": measurement_id,
            "category": category,
            "detail": detail.replace("\n", " "),
            "path": str(path),
        }
    )


def read_csv(path: Path, fields: tuple[str, ...]) -> list[dict[str, str]]:
    with path.open(newline="", encoding="utf-8") as handle:
        reader = csv.DictReader(handle)
        if tuple(reader.fieldnames or ()) != fields:
            raise ValueError(
                f"unexpected header: {reader.fieldnames!r}; expected {list(fields)!r}"
            )
        rows = list(reader)
    if any(None in row for row in rows):
        raise ValueError("a row has more columns than the header")
    return rows


def read_manifest(path: Path) -> tuple[list[dict[str, str]], tuple[str, ...]]:
    with path.open(newline="", encoding="utf-8") as handle:
        reader = csv.DictReader(handle)
        fields = tuple(reader.fieldnames or ())
        if fields not in (MANIFEST_FIELDS, LEGACY_MANIFEST_FIELDS):
            raise ValueError(
                "unexpected manifest header: "
                f"{reader.fieldnames!r}; expected current or historical schema"
            )
        rows = list(reader)
    if any(None in row for row in rows):
        raise ValueError("a manifest row has more columns than the header")
    return rows, fields


def read_key_values(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    with path.open(encoding="utf-8") as handle:
        for line_number, raw_line in enumerate(handle, 1):
            line = raw_line.rstrip("\n")
            if not line:
                continue
            if "=" not in line:
                raise ValueError(f"line {line_number} is not key=value")
            key, value = line.split("=", 1)
            if not key or key in values:
                raise ValueError(f"missing or duplicate key on line {line_number}: {key!r}")
            values[key] = value
    return values


def campaign_policy(
    metadata: dict[str, str], manifest_fields: tuple[str, ...]
) -> str:
    policy = metadata.get("benchmark_policy")
    if policy is None:
        if manifest_fields != LEGACY_MANIFEST_FIELDS:
            raise ValueError("campaign metadata does not identify the manifest policy")
        return LEGACY_POLICY
    if policy not in (NEW_POLICY, LEGACY_POLICY):
        raise ValueError(f"unsupported benchmark_policy: {policy!r}")
    if policy == NEW_POLICY:
        if metadata.get("manifest_schema_version") != "2":
            raise ValueError("CFL-scaled campaign metadata requires schema version 2")
        if parse_integer(metadata.get("time_steps", ""), "metadata time_steps") != NEW_TIME_STEPS:
            raise ValueError("campaign metadata time_steps does not match policy")
        if not close_enough(
            parse_finite(metadata.get("cfl_fraction", ""), "metadata cfl_fraction"),
            NEW_CFL_FRACTION,
        ):
            raise ValueError("campaign metadata cfl_fraction does not match policy")
        if not close_enough(
            parse_finite(metadata.get("cfl_squared", ""), "metadata cfl_squared"),
            NEW_CFL_FRACTION**2,
        ):
            raise ValueError("campaign metadata cfl_squared does not match policy")
    return policy


def parse_integer(value: str, name: str) -> int:
    if not re.fullmatch(r"[0-9]+", value):
        raise ValueError(f"{name} is not a nonnegative integer: {value!r}")
    return int(value)


def parse_finite(value: str, name: str, *, nonnegative: bool = False) -> float:
    try:
        result = float(value)
    except ValueError as error:
        raise ValueError(f"{name} is not numeric: {value!r}") from error
    if not math.isfinite(result):
        raise ValueError(f"{name} is not finite: {value!r}")
    if nonnegative and result < 0.0:
        raise ValueError(f"{name} is negative: {value!r}")
    return result


def close_enough(
    actual: float, expected: float, tolerance: float = FLOAT_TOLERANCE
) -> bool:
    return math.isclose(actual, expected, rel_tol=tolerance, abs_tol=2.0e-15)


def discrete_error_reference(
    n: int, lx: float, ly: float, lz: float, final_time: float, steps: int
) -> float:
    """Evolve the discrete sine eigenmode using the solver's scalar recurrence."""
    tau = final_time / steps
    sine_squared = math.sin(math.pi / (2.0 * n)) ** 2
    eigenvalue = -4.0 * sine_squared * (
        (n / lx) ** 2 + (n / ly) ** 2 + (n / lz) ** 2
    )
    previous = 1.0
    current = previous + 0.5 * tau * tau * eigenvalue * previous
    for _ in range(1, steps):
        following = 2.0 * current - previous + tau * tau * eigenvalue * current
        previous, current = current, following
    omega = math.pi * math.sqrt(1.0 / lx**2 + 1.0 / ly**2 + 1.0 / lz**2)
    exact = math.cos(omega * final_time)
    return abs(current - exact)


def numerical_error_tolerance(expected_error: float) -> float:
    return max(MIN_ERROR_TOLERANCE, 1.0e-6 * expected_error)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def validate_manifest(
    rows: list[dict[str, str]],
    fields: tuple[str, ...],
    policy: str,
    issues: list[dict[str, str]],
    path: Path,
) -> tuple[dict[str, dict[str, Any]], dict[str, str]]:
    if policy == NEW_POLICY and fields != MANIFEST_FIELDS:
        raise ValueError("the CFL-scaled policy requires manifest schema version 2")
    if policy == LEGACY_POLICY and fields != LEGACY_MANIFEST_FIELDS:
        raise ValueError("the historical fixed-time policy requires the legacy manifest schema")
    canonical = expected_matrix(policy)
    manifest: dict[str, dict[str, Any]] = {}
    job_names: dict[str, str] = {}

    for row_number, row in enumerate(rows, 2):
        measurement_id = row["measurement_id"]
        if measurement_id in manifest:
            add_issue(
                issues,
                measurement_id,
                "duplicate_manifest_row",
                f"manifest row {row_number} duplicates an earlier row",
                path,
            )
            continue
        expected = canonical.get(measurement_id)
        if expected is None:
            add_issue(
                issues,
                measurement_id,
                "unexpected_manifest_row",
                f"manifest row {row_number} is outside the V1 matrix",
                path,
            )
            continue
        try:
            parsed_final_time = parse_finite(
                row["physical_final_time"], "physical_final_time"
            )
            parsed_steps = parse_integer(row["time_steps"], "time_steps")
            if parsed_steps < 1:
                raise ValueError("time_steps must be positive")
            parsed = {
                "measurement_id": measurement_id,
                "n": parse_integer(row["n"], "n"),
                "domain_id": row["domain_id"],
                "lx": parse_finite(row["lx"], "lx"),
                "ly": parse_finite(row["ly"], "ly"),
                "lz": parse_finite(row["lz"], "lz"),
                "physical_final_time": parsed_final_time,
                "time_steps": parsed_steps,
                "time_step": parse_finite(
                    row.get("time_step", "")
                    or str(parsed_final_time / parsed_steps),
                    "time_step",
                ),
                "cfl_fraction": parse_finite(
                    row.get("cfl_fraction", "") or str(expected["cfl_fraction"]),
                    "cfl_fraction",
                ),
                "cfl_squared": parse_finite(
                    row.get("cfl_squared", "") or str(expected["cfl_squared"]),
                    "cfl_squared",
                ),
                "requested_threads": parse_integer(
                    row["requested_threads"], "requested_threads"
                ),
                "repetition": parse_integer(row["repetition"], "repetition"),
                "job_group": row["job_group"],
                "job_name": row["job_name"],
            }
        except ValueError as error:
            add_issue(issues, measurement_id, "invalid_manifest_row", str(error), path)
            continue

        mismatch = []
        for key in (
            "n",
            "domain_id",
            "time_steps",
            "requested_threads",
            "repetition",
            "job_group",
        ):
            if parsed[key] != expected[key]:
                mismatch.append(f"{key}={parsed[key]!r}, expected {expected[key]!r}")
        for key in ("lx", "ly", "lz"):
            if not close_enough(parsed[key], expected[key]):
                mismatch.append(
                    f"{key}={parsed[key]!r}, expected {expected[key]!r}"
                )
        for key in (
            "physical_final_time",
            "time_step",
            "cfl_fraction",
            "cfl_squared",
        ):
            if not close_enough(parsed[key], expected[key]):
                mismatch.append(
                    f"{key}={parsed[key]!r}, expected {expected[key]!r}"
                )
        derived_time_step = parsed["physical_final_time"] / parsed["time_steps"]
        if not close_enough(parsed["time_step"], derived_time_step):
            mismatch.append("time_step does not equal physical_final_time/time_steps")
        hx = parsed["lx"] / parsed["n"]
        hy = parsed["ly"] / parsed["n"]
        hz = parsed["lz"] / parsed["n"]
        inverse_sum = 1.0 / hx**2 + 1.0 / hy**2 + 1.0 / hz**2
        derived_fraction = parsed["time_step"] * math.sqrt(inverse_sum)
        derived_squared = parsed["time_step"] ** 2 * inverse_sum
        if not close_enough(parsed["cfl_fraction"], derived_fraction):
            mismatch.append("cfl_fraction is inconsistent with dt and the spatial grid")
        if not close_enough(parsed["cfl_squared"], derived_squared):
            mismatch.append("cfl_squared is inconsistent with dt and the spatial grid")
        if not parsed["job_name"]:
            mismatch.append("job_name is empty")
        old_name = job_names.setdefault(parsed["job_group"], parsed["job_name"])
        if old_name != parsed["job_name"]:
            mismatch.append("job_name differs within one job group")
        if mismatch:
            add_issue(
                issues,
                measurement_id,
                "manifest_mismatch",
                "; ".join(mismatch),
                path,
            )
            continue
        manifest[measurement_id] = {
            **expected,
            "job_name": parsed["job_name"],
            "schema_version": 2 if fields == MANIFEST_FIELDS else 1,
        }

    for measurement_id in sorted(canonical.keys() - manifest.keys()):
        add_issue(
            issues,
            measurement_id,
            "manifest_missing",
            "expected measurement is absent or invalid in manifest.csv",
            path,
        )
    return manifest, job_names


def load_submissions(
    path: Path, job_names: dict[str, str], issues: list[dict[str, str]]
) -> tuple[dict[str, set[str]], set[str]]:
    accepted: dict[str, set[str]] = defaultdict(set)
    blocked_groups: set[str] = set()
    try:
        rows = read_csv(path, SUBMISSION_FIELDS)
    except (OSError, ValueError) as error:
        add_issue(issues, "", "invalid_submissions", str(error), path)
        return accepted, set(job_names)

    final_events: dict[str, list[str]] = defaultdict(list)
    for row_number, row in enumerate(rows, 2):
        group = row["job_group"]
        event = row["event"]
        if group not in job_names:
            add_issue(
                issues,
                "",
                "unknown_submission_group",
                f"row {row_number} names unknown group {group!r}",
                path,
            )
            continue
        if row["job_name"] != job_names[group]:
            add_issue(
                issues,
                "",
                "submission_mismatch",
                f"row {row_number} has the wrong job name for {group}",
                path,
            )
            blocked_groups.add(group)
        if event == "accepted":
            try:
                job_id = str(parse_integer(row["lsf_job_id"], "lsf_job_id"))
            except ValueError as error:
                add_issue(issues, "", "invalid_submission", str(error), path)
                blocked_groups.add(group)
                continue
            accepted[group].add(job_id)
            final_events[group].append(event)
        elif event in {"failed", "uncertain", "interrupted"}:
            final_events[group].append(event)
        elif event != "submitting":
            add_issue(
                issues,
                "",
                "invalid_submission_event",
                f"row {row_number} has event {event!r}",
                path,
            )
            blocked_groups.add(group)

    for group in job_names:
        if len(accepted[group]) > 1:
            add_issue(
                issues,
                "",
                "duplicate_submission",
                f"job group {group} has accepted LSF IDs {sorted(accepted[group])}",
                path,
            )
            blocked_groups.add(group)
        elif not accepted[group]:
            events = final_events.get(group, [])
            category = "submission_missing"
            detail = f"job group {group} has no accepted submission"
            if events:
                category = "submission_" + events[-1]
                detail += f"; last recorded event is {events[-1]}"
            add_issue(issues, "", category, detail, path)
    return accepted, blocked_groups


def validate_measurement(
    metadata_path: Path,
    manifest_row: dict[str, Any],
    job_id_from_name: str,
    accepted_ids: set[str],
    campaign_checksum: str,
) -> dict[str, Any]:
    metadata = read_key_values(metadata_path)
    required_metadata = {
        "measurement_id",
        "job_group",
        "job_id",
        "hostname",
        "hostname_fqdn",
        "LSB_HOSTS",
        "n",
        "domain_id",
        "lx",
        "ly",
        "lz",
        "physical_final_time",
        "time_steps",
        "requested_threads",
        "repetition",
        "binary_sha256",
        "started_at_utc",
        "completed_at_utc",
        "solver_exit_code",
    }
    if manifest_row["schema_version"] >= 2:
        required_metadata.update({"time_step", "cfl_fraction", "cfl_squared"})
    missing = sorted(required_metadata - metadata.keys())
    if missing:
        raise ValueError(f"metadata keys are missing: {', '.join(missing)}")

    expected_strings = {
        "measurement_id": manifest_row["measurement_id"],
        "job_group": manifest_row["job_group"],
        "job_id": job_id_from_name,
        "domain_id": manifest_row["domain_id"],
        "binary_sha256": campaign_checksum,
    }
    for key, expected in expected_strings.items():
        if metadata[key] != expected:
            raise ValueError(f"metadata {key}={metadata[key]!r}, expected {expected!r}")
    if job_id_from_name not in accepted_ids:
        raise ValueError(
            f"LSF job {job_id_from_name} is not an accepted submission for "
            f"{manifest_row['job_group']}"
        )
    for key in ("hostname", "hostname_fqdn", "LSB_HOSTS"):
        if not metadata[key]:
            raise ValueError(f"metadata {key} is empty")

    integer_expectations = {
        "n": manifest_row["n"],
        "time_steps": manifest_row["time_steps"],
        "requested_threads": manifest_row["requested_threads"],
        "repetition": manifest_row["repetition"],
    }
    for key, expected in integer_expectations.items():
        if parse_integer(metadata[key], key) != expected:
            raise ValueError(f"metadata {key} does not match the manifest")
    for key in ("lx", "ly", "lz"):
        if not close_enough(parse_finite(metadata[key], key), manifest_row[key]):
            raise ValueError(f"metadata {key} does not match the manifest")
    if not close_enough(
        parse_finite(metadata["physical_final_time"], "physical_final_time"),
        manifest_row["physical_final_time"],
    ):
        raise ValueError("metadata physical_final_time does not match the manifest")
    if manifest_row["schema_version"] >= 2:
        for key in ("time_step", "cfl_fraction", "cfl_squared"):
            if not close_enough(parse_finite(metadata[key], key), manifest_row[key]):
                raise ValueError(f"metadata {key} does not match the manifest")

    solver_exit_code = parse_integer(metadata["solver_exit_code"], "solver_exit_code")
    if solver_exit_code != 0:
        raise RuntimeError(f"solver exited with status {solver_exit_code}")

    stdout_path = metadata_path.with_suffix(".stdout")
    stderr_path = metadata_path.with_suffix(".stderr")
    if not stdout_path.is_file():
        raise ValueError(f"solver stdout is missing: {stdout_path.name}")
    if not stderr_path.is_file():
        raise ValueError(f"solver stderr is missing: {stderr_path.name}")
    output = read_key_values(stdout_path)
    required_output = {
        "n",
        "node_count",
        "lx",
        "ly",
        "lz",
        "physical_final_time",
        "time_steps",
        "tau",
        "openmp_threads",
        "solve_wall_seconds",
        "max_absolute_error",
    }
    missing_output = sorted(required_output - output.keys())
    if missing_output:
        raise ValueError(f"solver output keys are missing: {', '.join(missing_output)}")

    n = manifest_row["n"]
    integer_output = {
        "n": n,
        "node_count": (n + 1) ** 3,
        "time_steps": manifest_row["time_steps"],
        "openmp_threads": manifest_row["requested_threads"],
    }
    for key, expected in integer_output.items():
        if parse_integer(output[key], key) != expected:
            raise ValueError(f"solver output {key} does not match the manifest")
    for key in ("lx", "ly", "lz"):
        if not close_enough(parse_finite(output[key], key), manifest_row[key]):
            raise ValueError(f"solver output {key} does not match the manifest")
    if not close_enough(
        parse_finite(output["physical_final_time"], "physical_final_time"),
        manifest_row["physical_final_time"],
    ):
        raise ValueError("solver physical_final_time does not match the manifest")
    if not close_enough(
        parse_finite(output["tau"], "tau"), manifest_row["time_step"]
    ):
        raise ValueError("solver tau does not match T/K")

    solve_time = parse_finite(
        output["solve_wall_seconds"], "solve_wall_seconds", nonnegative=True
    )
    observed_error = parse_finite(
        output["max_absolute_error"], "max_absolute_error", nonnegative=True
    )
    expected_error = discrete_error_reference(
        n,
        manifest_row["lx"],
        manifest_row["ly"],
        manifest_row["lz"],
        manifest_row["physical_final_time"],
        manifest_row["time_steps"],
    )
    difference = abs(observed_error - expected_error)
    tolerance = numerical_error_tolerance(expected_error)
    if difference > tolerance:
        raise ValueError(
            f"numerical error {observed_error:.17g} differs from reference "
            f"{expected_error:.17g} by {difference:.17g} "
            f"(tolerance {tolerance:.17g})"
        )
    return {
        "time": solve_time,
        "error": observed_error,
        "expected_error": expected_error,
        "error_tolerance": tolerance,
        "job_id": job_id_from_name,
        "metadata_path": metadata_path,
    }


def write_csv(path: Path, fields: tuple[str, ...], rows: list[dict[str, Any]]) -> None:
    temporary = path.with_name(path.name + ".tmp")
    with temporary.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(rows)
    temporary.replace(path)


def format_number(value: float | None) -> str:
    return "" if value is None else format(value, ".17g")


def make_summary(
    valid: dict[str, dict[str, Any]], policy: str
) -> tuple[list[dict[str, Any]], int]:
    summaries: list[dict[str, Any]] = []
    complete_configurations = 0
    medians: dict[tuple[int, str, float, int, int], float] = {}
    canonical = expected_matrix(policy)

    for n in GRID_SIZES:
        for domain_id, length in DOMAIN_LENGTHS.items():
            for threads in THREAD_COUNTS:
                configuration = canonical[f"n{n}_{domain_id}_t{threads}_r1"]
                values = [
                    valid[f"n{n}_{domain_id}_t{threads}_r{repetition}"]
                    for repetition in REPETITIONS
                    if f"n{n}_{domain_id}_t{threads}_r{repetition}" in valid
                ]
                times = [item["time"] for item in values]
                errors = [item["error"] for item in values]
                complete = len(values) == 3
                median_time = statistics.median(times) if times else None
                if complete:
                    complete_configurations += 1
                    medians[
                        (
                            n,
                            domain_id,
                            configuration["physical_final_time"],
                            configuration["time_steps"],
                            threads,
                        )
                    ] = median_time  # type: ignore[assignment]
                summaries.append(
                    {
                        "n": n,
                        "domain_id": domain_id,
                        "domain_length": format_number(length),
                        "physical_final_time": format_number(
                            configuration["physical_final_time"]
                        ),
                        "time_steps": configuration["time_steps"],
                        "time_step": format_number(configuration["time_step"]),
                        "cfl_fraction": format_number(
                            configuration["cfl_fraction"]
                        ),
                        "cfl_squared": format_number(
                            configuration["cfl_squared"]
                        ),
                        "requested_threads": threads,
                        "valid_repetitions": len(values),
                        "median_seconds": format_number(median_time),
                        "minimum_seconds": format_number(min(times) if times else None),
                        "maximum_seconds": format_number(max(times) if times else None),
                        "mean_seconds": format_number(
                            statistics.mean(times) if times else None
                        ),
                        "standard_deviation_seconds": format_number(
                            statistics.stdev(times) if len(times) > 1 else None
                        ),
                        "speedup": "",
                        "parallel_efficiency": "",
                        "median_max_absolute_error": format_number(
                            statistics.median(errors) if errors else None
                        ),
                        "expected_numerical_error": format_number(
                            discrete_error_reference(
                                n,
                                configuration["lx"],
                                configuration["ly"],
                                configuration["lz"],
                                configuration["physical_final_time"],
                                configuration["time_steps"],
                            )
                        ),
                        "status": "complete" if complete else "incomplete",
                    }
                )

    for row in summaries:
        key = (
            int(row["n"]),
            str(row["domain_id"]),
            float(row["physical_final_time"]),
            int(row["time_steps"]),
            int(row["requested_threads"]),
        )
        baseline = medians.get((key[0], key[1], key[2], key[3], 1))
        current = medians.get(key)
        if baseline is not None and current is not None and current > 0.0:
            speedup = baseline / current
            row["speedup"] = format_number(speedup)
            row["parallel_efficiency"] = format_number(speedup / key[4])
    return summaries, complete_configurations


def generate_plots(
    analysis_dir: Path,
    summaries: list[dict[str, Any]],
    valid: dict[str, dict[str, Any]],
    policy: str,
) -> str:
    plot_names = (
        "execution_time.png",
        "speedup.png",
        "parallel_efficiency.png",
        "numerical_error.png",
    )
    for name in plot_names:
        (analysis_dir / name).unlink(missing_ok=True)
    try:
        import matplotlib

        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except Exception as error:  # Plotting is optional; core CSV analysis is not.
        return f"matplotlib unavailable ({error}); plots were not generated"

    def plot_metric(field: str, ylabel: str, filename: str) -> None:
        figure, axis = plt.subplots()
        for n in GRID_SIZES:
            for domain_id in DOMAIN_LENGTHS:
                rows = [
                    row
                    for row in summaries
                    if row["n"] == n
                    and row["domain_id"] == domain_id
                    and row[field] != ""
                    and row["status"] == "complete"
                ]
                if rows:
                    axis.plot(
                        [int(row["requested_threads"]) for row in rows],
                        [float(row[field]) for row in rows],
                        marker="o",
                        label=f"N={n}, L={'1' if domain_id == 'l1' else 'pi'}",
                    )
        axis.set_xlabel("OpenMP threads")
        axis.set_ylabel(ylabel)
        axis.grid(True, alpha=0.3)
        axis.legend(fontsize="small")
        figure.tight_layout()
        figure.savefig(analysis_dir / filename, dpi=150)
        plt.close(figure)

    try:
        plot_metric("median_seconds", "Median solve time (seconds)", "execution_time.png")
        plot_metric("speedup", "Speedup relative to one thread", "speedup.png")
        plot_metric(
            "parallel_efficiency", "Parallel efficiency", "parallel_efficiency.png"
        )

        figure, axis = plt.subplots()
        for domain_id, length in DOMAIN_LENGTHS.items():
            observed_x: list[int] = []
            observed_y: list[float] = []
            for n in GRID_SIZES:
                errors = [
                    result["error"]
                    for measurement_id, result in valid.items()
                    if measurement_id.startswith(f"n{n}_{domain_id}_")
                ]
                if errors:
                    observed_x.append(n)
                    observed_y.append(statistics.median(errors))
            label = "L=1" if domain_id == "l1" else "L=pi"
            if observed_x:
                axis.plot(
                    observed_x, observed_y, marker="o", label=f"Observed {label}"
                )
            axis.plot(
                list(GRID_SIZES),
                [
                    float(
                        next(
                            row["expected_numerical_error"]
                            for row in summaries
                            if row["n"] == n
                            and row["domain_id"] == domain_id
                            and row["requested_threads"] == 1
                        )
                    )
                    for n in GRID_SIZES
                ],
                linestyle="--",
                label=f"Reference {label}",
            )
        axis.set_xlabel("N (intervals per axis)")
        axis.set_ylabel("Maximum absolute error")
        if policy == NEW_POLICY:
            axis.set_title("CFL-scaled fixed-20-step error (final time varies with N and L)")
        else:
            axis.set_title("Fixed-final-time numerical error")
        axis.set_yscale("log")
        axis.grid(True, alpha=0.3)
        axis.legend(fontsize="small")
        figure.tight_layout()
        figure.savefig(analysis_dir / "numerical_error.png", dpi=150)
        plt.close(figure)
    except Exception as error:  # Do not make optional charts a core dependency.
        for name in plot_names:
            (analysis_dir / name).unlink(missing_ok=True)
        return f"plot generation failed ({error}); CSV analysis is still available"
    return "four matplotlib plots generated"


def main() -> int:
    arguments = parse_arguments()
    campaign = arguments.campaign_directory.expanduser().resolve()
    analysis_dir = campaign / "analysis"
    if not campaign.is_dir():
        print(f"analysis error: campaign directory does not exist: {campaign}", file=sys.stderr)
        return 2
    analysis_dir.mkdir(exist_ok=True)
    for name in ("summary.csv", "missing_or_failed.csv", "report.txt"):
        (analysis_dir / name).unlink(missing_ok=True)

    issues: list[dict[str, str]] = []
    manifest_path = campaign / "manifest.csv"
    submissions_path = campaign / "submissions.csv"
    metadata_path = campaign / "metadata.txt"
    solver_path = campaign / "wave_solver"

    metadata: dict[str, str] = {}
    try:
        metadata = read_key_values(metadata_path)
        campaign_checksum = metadata["binary_sha256"]
        if not re.fullmatch(r"[0-9a-fA-F]{64}", campaign_checksum):
            raise ValueError("binary_sha256 is malformed")
        if not solver_path.is_file():
            raise ValueError("campaign wave_solver is missing")
        actual_checksum = sha256(solver_path)
        if actual_checksum.lower() != campaign_checksum.lower():
            raise ValueError(
                f"campaign binary checksum mismatch: {actual_checksum} != {campaign_checksum}"
            )
        campaign_identity_ok = True
    except (OSError, KeyError, ValueError) as error:
        campaign_checksum = ""
        campaign_identity_ok = False
        add_issue(issues, "", "invalid_campaign_metadata", str(error), metadata_path)

    policy = LEGACY_POLICY
    try:
        manifest_rows, manifest_fields = read_manifest(manifest_path)
        policy = campaign_policy(metadata, manifest_fields)
        manifest, job_names = validate_manifest(
            manifest_rows, manifest_fields, policy, issues, manifest_path
        )
    except (OSError, ValueError) as error:
        manifest = {}
        job_names = {}
        add_issue(issues, "", "invalid_manifest", str(error), manifest_path)

    accepted, blocked_groups = load_submissions(submissions_path, job_names, issues)

    measurements_dir = campaign / "measurements"
    candidates: dict[str, list[tuple[Path, str]]] = defaultdict(list)
    if measurements_dir.is_dir():
        for path in measurements_dir.glob("*.meta"):
            match = MEASUREMENT_FILE.fullmatch(path.name)
            if match is None:
                add_issue(issues, "", "unrecognized_measurement_file", "unrecognized metadata filename", path)
                continue
            candidates[match.group(1)].append((path, match.group(2)))
        for path in list(measurements_dir.glob("*.stdout")) + list(
            measurements_dir.glob("*.stderr")
        ):
            match = MEASUREMENT_FILE.fullmatch(path.name)
            if match is None:
                add_issue(issues, "", "unrecognized_measurement_file", "unrecognized raw filename", path)
                continue
            if not path.with_suffix(".meta").is_file():
                add_issue(
                    issues,
                    match.group(1),
                    "orphan_raw_output",
                    "raw output has no matching metadata file",
                    path,
                )
    else:
        add_issue(issues, "", "missing_measurements_directory", "measurements directory is absent", measurements_dir)

    for measurement_id in sorted(candidates.keys() - manifest.keys()):
        for path, _ in candidates[measurement_id]:
            add_issue(
                issues,
                measurement_id,
                "unexpected_measurement",
                "measurement is not present in the valid manifest",
                path,
            )

    valid: dict[str, dict[str, Any]] = {}
    for measurement_id, manifest_row in sorted(manifest.items()):
        found = candidates.get(measurement_id, [])
        if not found:
            add_issue(
                issues,
                measurement_id,
                "missing",
                "no measurement metadata file was found",
                measurements_dir,
            )
            continue
        if len(found) != 1:
            add_issue(
                issues,
                measurement_id,
                "duplicate_measurement",
                f"found {len(found)} measurement metadata files",
                measurements_dir,
            )
            continue
        if manifest_row["job_group"] in blocked_groups:
            add_issue(
                issues,
                measurement_id,
                "ambiguous_submission",
                "the corresponding submission record is invalid or duplicated",
                found[0][0],
            )
            continue
        path, job_id = found[0]
        if not campaign_identity_ok:
            add_issue(
                issues,
                measurement_id,
                "invalid_binary_identity",
                "campaign binary identity could not be verified",
                path,
            )
            continue
        try:
            result = validate_measurement(
                path,
                manifest_row,
                job_id,
                accepted.get(manifest_row["job_group"], set()),
                campaign_checksum,
            )
        except RuntimeError as error:
            add_issue(issues, measurement_id, "solver_failed", str(error), path)
            continue
        except (OSError, ValueError) as error:
            add_issue(issues, measurement_id, "invalid_measurement", str(error), path)
            continue
        valid[measurement_id] = result

    summaries, complete_configurations = make_summary(valid, policy)
    write_csv(analysis_dir / "summary.csv", SUMMARY_FIELDS, summaries)
    write_csv(analysis_dir / "missing_or_failed.csv", ISSUE_FIELDS, issues)
    plot_status = generate_plots(analysis_dir, summaries, valid, policy)

    expected_jobs = len({row["job_group"] for row in manifest.values()})
    accepted_jobs = sum(len(ids) for ids in accepted.values())
    complete = (
        len(manifest) == 108
        and expected_jobs == 60
        and len(valid) == 108
        and complete_configurations == 36
        and not issues
    )
    issue_counts = Counter(issue["category"] for issue in issues)
    report_lines = [
        "V1 OpenMP campaign analysis",
        f"Campaign: {campaign}",
        f"Benchmark policy: {policy}",
        f"Expected measurements: 108",
        f"Manifest measurements validated: {len(manifest)}",
        f"Expected LSF jobs represented by manifest: {expected_jobs}",
        f"Accepted LSF jobs recorded: {accepted_jobs}",
        f"Valid measurements: {len(valid)}",
        f"Complete configurations: {complete_configurations}/36",
        "Numerical-error tolerance: max(5e-12, 1e-6 * expected_error)",
        (
            "Interpretation: CFL-scaled fixed-20-step benchmark; physical final "
            "time varies with N and L, so the error curve is not a fixed-time "
            "convergence-order experiment."
            if policy == NEW_POLICY
            else "Interpretation: historical fixed-final-time campaign."
        ),
        f"Plot status: {plot_status}",
        f"Campaign status: {'COMPLETE' if complete else 'INCOMPLETE'}",
    ]
    if issue_counts:
        report_lines.append("Issues:")
        report_lines.extend(
            f"  {category}: {count}" for category, count in sorted(issue_counts.items())
        )
    report_lines.extend(
        (
            "",
            "Artifacts:",
            "  summary.csv",
            "  missing_or_failed.csv",
            "  report.txt",
        )
    )
    temporary_report = analysis_dir / "report.txt.tmp"
    temporary_report.write_text("\n".join(report_lines) + "\n", encoding="utf-8")
    temporary_report.replace(analysis_dir / "report.txt")

    print("\n".join(report_lines))
    return 0 if complete else 1


if __name__ == "__main__":
    sys.exit(main())
