#!/usr/bin/env python3
"""Lightweight tests for full V1 campaign generation and analysis."""

from __future__ import annotations

import csv
import hashlib
import importlib.util
import math
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest


REPOSITORY = Path(__file__).resolve().parents[1]
ANALYZER_PATH = REPOSITORY / "scripts" / "analyze_full_v1.py"
SUBMITTER_PATH = REPOSITORY / "scripts" / "polus" / "submit_full_v1.sh"

spec = importlib.util.spec_from_file_location("analyze_full_v1", ANALYZER_PATH)
if spec is None or spec.loader is None:
    raise RuntimeError("cannot import analyze_full_v1.py")
analyzer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(analyzer)


def independent_error(row: dict[str, object]) -> float:
    n = int(row["n"])
    lx = float(row["lx"])
    ly = float(row["ly"])
    lz = float(row["lz"])
    final_time = float(row["physical_final_time"])
    steps = int(row["time_steps"])
    dt = final_time / steps
    omega = math.pi * math.sqrt(1.0 / lx**2 + 1.0 / ly**2 + 1.0 / lz**2)
    omega_h_squared = 4.0 * math.sin(math.pi / (2.0 * n)) ** 2 * (
        (n / lx) ** 2 + (n / ly) ** 2 + (n / lz) ** 2
    )
    theta = 2.0 * math.asin(0.5 * dt * math.sqrt(omega_h_squared))
    return abs(math.cos(steps * theta) - math.cos(omega * final_time))


def write_key_values(path: Path, values: dict[str, object]) -> None:
    path.write_text(
        "".join(f"{key}={value}\n" for key, value in values.items()),
        encoding="utf-8",
    )


def build_synthetic_campaign(root: Path, policy: str) -> Path:
    root.mkdir()
    (root / "measurements").mkdir()
    (root / "analysis").mkdir()
    solver = root / "wave_solver"
    solver.write_bytes(b"synthetic immutable solver\n")
    checksum = hashlib.sha256(solver.read_bytes()).hexdigest()

    metadata: dict[str, object] = {"binary_sha256": checksum}
    fields = analyzer.LEGACY_MANIFEST_FIELDS
    if policy in (analyzer.NEW_POLICY, analyzer.ROUND_POLICY):
        fields = analyzer.ROUND_MANIFEST_FIELDS if policy == analyzer.ROUND_POLICY else analyzer.MANIFEST_FIELDS
        metadata.update(
            {
                "manifest_schema_version": 3 if policy == analyzer.ROUND_POLICY else 2,
                "benchmark_policy": policy,
                "time_steps": 20,
                "cfl_fraction": 0.5,
                "cfl_squared": 0.25,
                "repetitions": 10 if policy == analyzer.ROUND_POLICY else 3,
            }
        )
    write_key_values(root / "metadata.txt", metadata)

    matrix = analyzer.expected_matrix(policy)
    manifest_rows: list[dict[str, object]] = []
    groups = sorted({str(row["job_group"]) for row in matrix.values()})
    job_ids = {group: str(100000 + index) for index, group in enumerate(groups)}
    job_names = {group: f"synthetic_{group}" for group in groups}

    for measurement_id, row in matrix.items():
        manifest_row: dict[str, object] = {
            "measurement_id": measurement_id,
            "n": row["n"],
            "domain_id": row["domain_id"],
            "lx": format(float(row["lx"]), ".17g"),
            "ly": format(float(row["ly"]), ".17g"),
            "lz": format(float(row["lz"]), ".17g"),
            "physical_final_time": format(
                float(row["physical_final_time"]), ".17g"
            ),
            "time_steps": row["time_steps"],
            "requested_threads": row["requested_threads"],
            "repetition": row["repetition"],
            "job_group": row["job_group"],
            "job_name": job_names[str(row["job_group"])],
        }
        if policy in (analyzer.NEW_POLICY, analyzer.ROUND_POLICY):
            manifest_row.update(
                {
                    "time_step": format(float(row["time_step"]), ".17g"),
                    "cfl_fraction": format(float(row["cfl_fraction"]), ".17g"),
                    "cfl_squared": format(float(row["cfl_squared"]), ".17g"),
                }
            )
        if policy == analyzer.ROUND_POLICY:
            manifest_row["round"] = row["repetition"]
        manifest_rows.append(manifest_row)

    with (root / "manifest.csv").open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        writer.writerows(manifest_rows)

    with (root / "submissions.csv").open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=analyzer.SUBMISSION_FIELDS)
        writer.writeheader()
        for group in groups:
            writer.writerow(
                {
                    "timestamp_utc": "2026-10-22T00:00:00Z",
                    "event": "accepted",
                    "job_group": group,
                    "job_name": job_names[group],
                    "job_script": f"jobs/{group}.lsf",
                    "lsf_job_id": job_ids[group],
                    "details": "synthetic",
                }
            )

    for row in manifest_rows:
        measurement_id = str(row["measurement_id"])
        group = str(row["job_group"])
        job_id = job_ids[group]
        stem = root / "measurements" / f"{measurement_id}.job{job_id}"
        meta: dict[str, object] = {
            "measurement_id": measurement_id,
            "job_group": group,
            "job_id": job_id,
            "hostname": "polus-c4",
            "hostname_fqdn": "polus-c4-ib.bmc.hpc.cs.msu.ru",
            "LSB_HOSTS": "polus-c4",
            "n": row["n"],
            "domain_id": row["domain_id"],
            "lx": row["lx"],
            "ly": row["ly"],
            "lz": row["lz"],
            "physical_final_time": row["physical_final_time"],
            "time_steps": row["time_steps"],
            "requested_threads": row["requested_threads"],
            "repetition": row["repetition"],
            "binary_sha256": checksum,
            "started_at_utc": "2026-10-22T00:00:00Z",
            "completed_at_utc": "2026-10-22T00:00:01Z",
            "solver_exit_code": 0,
        }
        if policy in (analyzer.NEW_POLICY, analyzer.ROUND_POLICY):
            meta.update(
                {
                    "time_step": row["time_step"],
                    "cfl_fraction": row["cfl_fraction"],
                    "cfl_squared": row["cfl_squared"],
                }
            )
        if policy == analyzer.ROUND_POLICY:
            meta["round"] = row["repetition"]
            meta["configuration_id"] = measurement_id.rsplit("_r", 1)[0]
        write_key_values(Path(f"{stem}.meta"), meta)

        repetition_factor = (1.0 + (int(row["repetition"]) - (5.5 if policy == analyzer.ROUND_POLICY else 2)) * 0.02)
        solve_time = (
            0.01
            * (int(row["n"]) / 128) ** 3
            * repetition_factor
            / int(row["requested_threads"])
        )
        output = {
            "n": row["n"],
            "node_count": (int(row["n"]) + 1) ** 3,
            "lx": row["lx"],
            "ly": row["ly"],
            "lz": row["lz"],
            "physical_final_time": row["physical_final_time"],
            "time_steps": row["time_steps"],
            "tau": format(
                float(row["physical_final_time"]) / int(row["time_steps"]),
                ".17g",
            ),
            "openmp_threads": row["requested_threads"],
            "solve_wall_seconds": format(solve_time, ".17g"),
            "max_absolute_error": format(independent_error(row), ".17g"),
        }
        write_key_values(Path(f"{stem}.stdout"), output)
        Path(f"{stem}.stderr").write_text("", encoding="utf-8")
    return root


class BenchmarkTests(unittest.TestCase):
    def run_analyzer(self, campaign: Path) -> subprocess.CompletedProcess[str]:
        environment = os.environ.copy()
        environment["MPLCONFIGDIR"] = str(
            Path(tempfile.gettempdir()) / "wave_solver_test_mplconfig"
        )
        return subprocess.run(
            [sys.executable, "-S", str(ANALYZER_PATH), str(campaign)],
            env=environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

    def test_cfl_time_parameters_and_references(self) -> None:
        expected_errors = {
            128: 1.1226403880959523e-6,
            256: 7.0696683840409946e-8,
            512: 4.426873645435592e-9,
        }
        for length in (1.0, math.pi):
            for n in analyzer.GRID_SIZES:
                dt, final_time, squared = analyzer.time_parameters(
                    n, length, length, length, 20, 0.5
                )
                self.assertAlmostEqual(dt, 0.5 * length / (math.sqrt(3.0) * n))
                self.assertAlmostEqual(final_time, 20.0 * dt)
                self.assertAlmostEqual(squared, 0.25, places=15)
                reference = analyzer.discrete_error_reference(
                    n, length, length, length, final_time, 20
                )
                self.assertAlmostEqual(reference, expected_errors[n], delta=3.0e-15)

    def test_dry_run_matrix_and_no_submission(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            marker = Path(temporary) / "bsub_called"
            mock = Path(temporary) / "bsub"
            mock.write_text(f"#!/bin/sh\ntouch {marker}\nexit 99\n", encoding="utf-8")
            mock.chmod(0o755)
            environment = os.environ.copy()
            environment["PATH"] = f"{temporary}:{environment['PATH']}"
            before = set((REPOSITORY / "results" / "polus" / "full_v1").glob("*")) if (
                REPOSITORY / "results" / "polus" / "full_v1"
            ).is_dir() else set()
            completed = subprocess.run(
                ["bash", str(SUBMITTER_PATH), "--dry-run"],
                cwd=REPOSITORY,
                env=environment,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            self.assertEqual(completed.returncode, 0, completed.stderr)
            again = subprocess.run(["bash", str(SUBMITTER_PATH), "--dry-run"], env=environment, text=True, capture_output=True, check=True)
            self.assertEqual(completed.stdout, again.stdout)
            plans = [line for line in completed.stdout.splitlines() if line.startswith("job:")]
            rounds = {}
            for line in plans:
                identity = re.search(r"group=(\S+)", line).group(1)
                config, repetition = identity.rsplit("_r", 1)
                rounds.setdefault(int(repetition), []).append(config)
            self.assertEqual(set(rounds), set(range(1, 11)))
            self.assertTrue(all(len(set(values)) == 36 for values in rounds.values()))
            self.assertEqual(len({tuple(v) for v in rounds.values()}), 10)
            self.assertFalse(marker.exists())
            self.assertEqual(completed.stdout.count("\njob:"), 360)
            self.assertEqual(completed.stdout.count("\n  measurement:"), 360)
            self.assertIn("planned_configurations=36", completed.stdout)
            self.assertIn("planned_jobs=360", completed.stdout)
            self.assertIn("planned_measurements=360", completed.stdout)
            self.assertIn("planned_total_requested_slots=3060", completed.stdout)
            self.assertIn("queue=short", completed.stdout)
            self.assertIn("walltime=00:10", completed.stdout)
            self.assertNotIn("queue=normal", completed.stdout)
            self.assertNotIn("walltime=03:00", completed.stdout)
            for line in completed.stdout.splitlines():
                if line.startswith("  measurement:"):
                    self.assertIn("--steps 20", line)
                    self.assertNotIn("--time 1 ", line)
            after = set((REPOSITORY / "results" / "polus" / "full_v1").glob("*")) if (
                REPOSITORY / "results" / "polus" / "full_v1"
            ).is_dir() else set()
            self.assertEqual(before, after)

    def test_queue_and_walltime_are_read_from_shared_configuration(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fake_repo = Path(temporary) / "repo"
            (fake_repo / "scripts" / "polus").mkdir(parents=True)
            shutil.copy2(SUBMITTER_PATH, fake_repo / "scripts" / "polus")
            config = (REPOSITORY / "scripts" / "polus" / "config.sh").read_text(
                encoding="utf-8"
            )
            config = config.replace(
                "POLUS_FULL_V1_QUEUE=short", "POLUS_FULL_V1_QUEUE=testshort"
            ).replace(
                "POLUS_FULL_V1_WALLTIME=00:10",
                "POLUS_FULL_V1_WALLTIME=00:07",
            )
            (fake_repo / "scripts" / "polus" / "config.sh").write_text(
                config, encoding="utf-8"
            )
            (fake_repo / "Makefile").write_text("all:\n\t@true\n", encoding="utf-8")
            (fake_repo / "SPEC.md").write_text("synthetic\n", encoding="utf-8")
            completed = subprocess.run(
                ["bash", "scripts/polus/submit_full_v1.sh", "--dry-run"],
                cwd=fake_repo,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertIn("queue=testshort", completed.stdout)
            self.assertIn("walltime=00:07", completed.stdout)

    def test_generated_lsf_resources_and_unique_campaigns(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fake_repo = Path(temporary) / "repo"
            (fake_repo / "scripts" / "polus").mkdir(parents=True)
            (fake_repo / "build").mkdir()
            shutil.copy2(SUBMITTER_PATH, fake_repo / "scripts" / "polus")
            shutil.copy2(REPOSITORY / "scripts" / "polus" / "config.sh", fake_repo / "scripts" / "polus")
            (fake_repo / "Makefile").write_text("all:\n\t@true\n", encoding="utf-8")
            (fake_repo / "SPEC.md").write_text("synthetic\n", encoding="utf-8")
            solver = fake_repo / "build" / "wave_solver"
            solver.write_text('#!/bin/sh\nprintf "mock solver output\\n"\nexit "${TEST_SOLVER_EXIT:-0}"\n', encoding="utf-8")
            solver.chmod(0o755)
            bin_dir = Path(temporary) / "bin"
            bin_dir.mkdir()
            counter = Path(temporary) / "counter"
            counter.write_text("200000", encoding="utf-8")
            bsub = bin_dir / "bsub"
            bsub.write_text(
                "#!/bin/sh\n"
                f"n=$(cat {counter})\n"
                "n=$((n + 1))\n"
                f"printf '%s\\n' \"$n\" > {counter}\n"
                "cat >/dev/null\n"
                "printf 'Job <%s> is submitted.\\n' \"$n\"\n",
                encoding="utf-8",
            )
            bsub.chmod(0o755)
            environment = os.environ.copy()
            environment["PATH"] = f"{bin_dir}:{environment['PATH']}"
            for _ in range(2):
                completed = subprocess.run(
                    ["bash", "scripts/polus/submit_full_v1.sh", "--prepare"],
                    cwd=fake_repo,
                    env=environment,
                    text=True,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    check=False,
                )
                self.assertEqual(completed.returncode, 0, completed.stderr)
                self.assertIn(
                    "prepared_jobs=360 measurements=360 total_requested_slots=3060",
                    completed.stdout,
                )

            campaigns = sorted((fake_repo / "results" / "polus" / "full_v1").iterdir())
            self.assertEqual(len(campaigns), 2)
            self.assertNotEqual(campaigns[0], campaigns[1])
            campaign = campaigns[0]
            jobs = sorted((campaign / "jobs").glob("*.lsf"))
            self.assertEqual(len(jobs), 360)
            with (campaign / "manifest.csv").open(newline="", encoding="utf-8") as handle:
                manifest = list(csv.DictReader(handle))
            self.assertEqual(len(manifest), 360)
            self.assertTrue(all(row["time_steps"] == "20" for row in manifest))
            metadata = analyzer.read_key_values(campaign / "metadata.txt")
            self.assertEqual(metadata["queue"], "short")
            self.assertEqual(metadata["walltime"], "00:10")
            for job in jobs:
                syntax = subprocess.run(
                    ["bash", "-n", str(job)],
                    text=True,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    check=False,
                )
                self.assertEqual(syntax.returncode, 0, syntax.stderr)
                text = job.read_text(encoding="utf-8")
                group = job.stem
                job_rows = [row for row in manifest if row["job_group"] == group]
                self.assertEqual(len(job_rows), 1)
                threads = int(re.search(r"_t(1|2|4|8|16|20)_", job.name).group(1))
                self.assertIn(f"#BSUB -n {threads}\n", text)
                self.assertIn("#BSUB -W 00:10\n", text)
                self.assertIn("#BSUB -q short\n", text)
                self.assertNotIn("#BSUB -W 03:00\n", text)
                self.assertNotIn("#BSUB -q normal\n", text)
                self.assertIn("#BSUB -x\n", text)
                self.assertIn("#BSUB -m polus-c4-ib.bmc.hpc.cs.msu.ru\n", text)
                self.assertIn(f"solver={campaign.resolve()}/wave_solver\n", text)
                self.assertNotIn("/build/wave_solver", text)
                self.assertEqual(text.count('LC_ALL=C "$solver"'), 1)
                self.assertNotIn("for repetition", text)
                self.assertIn("--steps 20", text)
                self.assertNotIn("--time 1 --steps", text)
                self.assertIn(
                    f"--time {job_rows[0]['physical_final_time']} --steps 20",
                    text,
                )

            # Exclusive allocations can advertise 20 slots even for a smaller
            # OpenMP team; that allocation metadata must not reject the job.
            conda_root = Path(temporary) / "conda"
            (conda_root / "etc/profile.d").mkdir(parents=True)
            (conda_root / "lib").mkdir()
            (conda_root / "etc/profile.d/conda.sh").write_text(
                f'conda() {{ export CONDA_PREFIX="{conda_root}"; }}\n'
            )
            with (campaign / "config.sh").open("a") as f:
                f.write(f'\nPOLUS_CONDA_BASE="{conda_root}"\n')
            subprocess.run(["bash", str(jobs[0])], check=True, capture_output=True,
                           env=dict(environment, LSB_JOBID="999", LSB_DJOB_NUMPROC="20", LSB_HOSTS="polus-c4"))
            self.assertEqual(len(list((campaign / "measurements").glob("*.meta"))), 1)
            failed_solver = subprocess.run(["bash", str(jobs[1])], capture_output=True,
                env=dict(environment, LSB_JOBID="998", LSB_DJOB_NUMPROC="20", TEST_SOLVER_EXIT="7"))
            self.assertEqual(failed_solver.returncode, 7)
            failure_meta = next((campaign / "measurements").glob("*.job998.meta"))
            self.assertIn("solver_exit_code=7", failure_meta.read_text())
            self.assertTrue(failure_meta.with_suffix(".stdout").is_file())
            self.assertTrue(failure_meta.with_suffix(".stderr").is_file())

            # Preparation never invokes bsub. Two explicit batches must be bounded
            # and must select different jobs in manifest order.
            self.assertEqual(counter.read_text().strip(), "200000")
            submit_next = ["bash", "scripts/polus/submit_full_v1.sh", "--submit-next", str(campaign)]
            accepted_before = set()
            offset = 0
            for _ in range(2):
                completed = subprocess.run(submit_next, cwd=fake_repo, env=environment,
                                           text=True, capture_output=True)
                self.assertEqual(completed.returncode, 0, completed.stderr)
                with (campaign / "submissions.csv").open(newline="") as f:
                    accepted = [r for r in csv.DictReader(f) if r["event"] == "accepted"]
                groups = [r["job_group"] for r in accepted]
                self.assertEqual(len(groups), len(set(groups)))
                batch = [r for r in accepted if r["job_group"] not in accepted_before]
                self.assertTrue(0 < len(batch) <= 12)
                slots = {r["job_group"]: int(r["requested_threads"]) for r in manifest}
                self.assertLessEqual(sum(slots[r["job_group"]] for r in batch), 120)
                self.assertEqual([r["job_group"] for r in batch],
                                 [r["job_group"] for r in manifest[offset:offset+len(batch)]])
                if len(batch) < 12:
                    self.assertGreater(sum(slots[r["job_group"]] for r in batch) +
                                       int(manifest[offset+len(batch)]["requested_threads"]), 120)
                offset += len(batch)
                accepted_before = set(groups)

            # An intent without an acceptance survives interruption and blocks
            # further calls, even if LSF accepted the job before the interruption.
            row = manifest[offset]
            with (campaign / "submissions.csv").open("a", newline="") as f:
                csv.writer(f).writerow(["now", "submitting", row["job_group"], row["job_name"], "job", "", "injected interruption"])
            count_before = counter.read_text()
            completed = subprocess.run(submit_next, cwd=fake_repo, env=environment,
                                       text=True, capture_output=True)
            self.assertNotEqual(completed.returncode, 0)
            self.assertIn("reconcile", completed.stderr)
            self.assertEqual(counter.read_text(), count_before)

            # A failed bsub stops immediately and cannot be retried automatically.
            bsub.write_text("#!/bin/sh\ncat >/dev/null\necho injected-failure >&2\nexit 1\n")
            failed_command = submit_next[:-1] + [str(campaigns[1])]
            completed = subprocess.run(failed_command, cwd=fake_repo, env=environment,
                                       text=True, capture_output=True)
            self.assertNotEqual(completed.returncode, 0)
            self.assertIn("bsub failed", completed.stderr)
            self.assertIn(",failed,", (campaigns[1] / "submissions.csv").read_text())
            completed = subprocess.run(failed_command, cwd=fake_repo, env=environment,
                                       text=True, capture_output=True)
            self.assertIn("reconcile", completed.stderr)
            # Model successful bsub with an unparseable response. Leave intent
            # recorded, and block the next invocation rather than guess.
            record = campaigns[1] / "submissions.csv"
            record.write_text(record.read_text().splitlines()[0] + "\n")
            bsub.write_text("#!/bin/sh\ncat >/dev/null\necho 'accepted but ID unavailable'\n")
            completed = subprocess.run(failed_command, cwd=fake_repo, env=environment,
                                       text=True, capture_output=True)
            self.assertIn("uncertain acceptance", completed.stderr)
            completed = subprocess.run(failed_command, cwd=fake_repo, env=environment,
                                       text=True, capture_output=True)
            self.assertIn("reconcile", completed.stderr)

    def test_round_synthetic_campaign(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            campaign = build_synthetic_campaign(Path(temporary) / "rounds", analyzer.ROUND_POLICY)
            result = self.run_analyzer(campaign)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            with (campaign / "analysis/summary.csv").open(newline="") as f:
                rows = list(csv.DictReader(f))
            self.assertTrue(all(row["valid_repetitions"] == "10" for row in rows))
            row = next(r for r in rows if r["n"] == "128" and r["domain_id"] == "l1" and r["requested_threads"] == "4")
            self.assertAlmostEqual(float(row["speedup"]), 4)
            self.assertAlmostEqual(float(row["parallel_efficiency"]), 1)
            import statistics
            factors = [1 + (r - 5.5) * .02 for r in range(1,11)]
            self.assertAlmostEqual(float(row["coefficient_of_variation"]), statistics.stdev(factors))
            output = next((campaign / "measurements").glob("*r10.job*.meta"))
            saved = output.read_bytes()
            duplicate = output.with_name(output.name.replace(".job", ".job9"))
            duplicate.write_bytes(saved)
            self.assertNotEqual(self.run_analyzer(campaign).returncode, 0)
            duplicate.unlink()
            output.unlink()
            self.assertNotEqual(self.run_analyzer(campaign).returncode, 0)
            output.write_bytes(saved)
            meta = analyzer.read_key_values(output)
            meta["round"] = "9"
            write_key_values(output, meta)
            self.assertNotEqual(self.run_analyzer(campaign).returncode, 0)

    def test_manifest_rejects_wrong_problem_parameters(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            campaign = build_synthetic_campaign(
                Path(temporary) / "campaign", analyzer.NEW_POLICY
            )
            original_rows, fields = analyzer.read_manifest(campaign / "manifest.csv")
            corruptions = {
                "n": "129",
                "lx": "1.01",
                "physical_final_time": "0.1",
                "time_steps": "21",
                "time_step": "0.001",
                "cfl_fraction": "0.4",
                "cfl_squared": "0.16",
                "requested_threads": "3",
            }
            for field, wrong_value in corruptions.items():
                with self.subTest(field=field):
                    rows = [dict(row) for row in original_rows]
                    measurement_id = rows[0]["measurement_id"]
                    rows[0][field] = wrong_value
                    issues: list[dict[str, str]] = []
                    valid, _ = analyzer.validate_manifest(
                        rows,
                        fields,
                        analyzer.NEW_POLICY,
                        issues,
                        campaign / "manifest.csv",
                    )
                    self.assertNotIn(measurement_id, valid)
                    self.assertTrue(
                        any(
                            issue["measurement_id"] == measurement_id
                            and issue["category"] == "manifest_mismatch"
                            for issue in issues
                        )
                    )

    def test_complete_current_and_historical_campaigns(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            current = build_synthetic_campaign(Path(temporary) / "current", analyzer.NEW_POLICY)
            raw_before = {
                path.relative_to(current): hashlib.sha256(path.read_bytes()).hexdigest()
                for path in (current / "measurements").iterdir()
            }
            first = self.run_analyzer(current)
            self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
            second = self.run_analyzer(current)
            self.assertEqual(second.returncode, 0, second.stdout + second.stderr)
            raw_after = {
                path.relative_to(current): hashlib.sha256(path.read_bytes()).hexdigest()
                for path in (current / "measurements").iterdir()
            }
            self.assertEqual(raw_before, raw_after)
            with (current / "analysis" / "summary.csv").open(newline="", encoding="utf-8") as handle:
                summary = list(csv.DictReader(handle))
            self.assertEqual(len(summary), 36)
            row = next(
                item
                for item in summary
                if item["n"] == "128"
                and item["domain_id"] == "l1"
                and item["requested_threads"] == "4"
            )
            self.assertAlmostEqual(float(row["speedup"]), 4.0)
            self.assertAlmostEqual(float(row["parallel_efficiency"]), 1.0)
            self.assertEqual(row["time_steps"], "20")

            historical = build_synthetic_campaign(
                Path(temporary) / "historical", analyzer.LEGACY_POLICY
            )
            old_result = self.run_analyzer(historical)
            self.assertEqual(old_result.returncode, 0, old_result.stdout + old_result.stderr)
            report = (historical / "analysis" / "report.txt").read_text(encoding="utf-8")
            self.assertIn("historical fixed-final-time campaign", report)

    def test_duplicate_and_mismatched_measurements_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            campaign = build_synthetic_campaign(Path(temporary) / "campaign", analyzer.NEW_POLICY)
            original = next((campaign / "measurements").glob("n128_l1_t1_r1.job*.meta"))
            duplicate_stem = campaign / "measurements" / "n128_l1_t1_r1.job999999"
            shutil.copy2(original, Path(f"{duplicate_stem}.meta"))
            shutil.copy2(original.with_suffix(".stdout"), Path(f"{duplicate_stem}.stdout"))
            shutil.copy2(original.with_suffix(".stderr"), Path(f"{duplicate_stem}.stderr"))
            result = self.run_analyzer(campaign)
            self.assertNotEqual(result.returncode, 0)
            issues = (campaign / "analysis" / "missing_or_failed.csv").read_text(encoding="utf-8")
            self.assertIn("duplicate_measurement", issues)

            for path in campaign.glob("measurements/n128_l1_t1_r1.job999999.*"):
                path.unlink()
            stdout = original.with_suffix(".stdout")
            values = analyzer.read_key_values(stdout)
            values["time_steps"] = "21"
            write_key_values(stdout, values)
            result = self.run_analyzer(campaign)
            self.assertNotEqual(result.returncode, 0)
            issues = (campaign / "analysis" / "missing_or_failed.csv").read_text(encoding="utf-8")
            self.assertIn("solver output time_steps does not match", issues)

            values["time_steps"] = "20"
            write_key_values(stdout, values)
            metadata = analyzer.read_key_values(original)
            metadata["solver_exit_code"] = "9"
            write_key_values(original, metadata)
            result = self.run_analyzer(campaign)
            self.assertNotEqual(result.returncode, 0)
            issues = (campaign / "analysis" / "missing_or_failed.csv").read_text(
                encoding="utf-8"
            )
            self.assertIn("solver_failed", issues)


if __name__ == "__main__":
    unittest.main()
