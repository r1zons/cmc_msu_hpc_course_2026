import csv
import json
import math
from collections import Counter
from pathlib import Path


def read(path, sep=","):
    with open(path, newline="") as stream:
        return list(csv.DictReader(stream, delimiter=sep))


root = Path("raw")
manifest = read(root / "manifest.csv")
account = {row["JobID"]: row for row in read("accounting.psv", "|")}
arrays = read(root / "submissions.csv")
assert len(arrays) == len({row["array_job_id"] for row in arrays}) == 24
assert len(manifest) == len({row["measurement_id"] for row in manifest}) == 432
assert Counter(tuple(row[k] for k in ("ranks", "threads", "n", "length"))
               for row in manifest) == {tuple(row[k] for k in ("ranks", "threads", "n", "length")): 3
                                       for row in manifest}
measurements = {}
seen = set()
counts = Counter()
for array in arrays:
    assert (array["status"], array["task_ids"]) == ("submitted", "0-17"), array
    layout = read(root / "layouts" / (array["layout"] + ".csv"))
    assert len(layout) == 18
    for index, row in enumerate(layout):
        identifier = row["measurement_id"]
        task = f'{array["array_job_id"]}_{index}'
        assert identifier not in measurements
        entry = account[task]
        seen.add(task)
        raw_id = entry["JobIDRaw"]
        nodes, ranks, threads, n, steps, rep = (int(row[k]) for k in
            ("nodes", "ranks", "threads", "n", "steps", "repetition"))
        assert rep in (1, 2, 3)
        assert identifier.endswith(f"-rep{rep}")
        assert n in (128, 256, 512) and steps == 20 and row["cfl"] == "0.5"
        length = float(row["length"])
        assert length in (1, math.pi)
        hosts = ("pg5",) if nodes == 1 else ("pg5", "pg6")
        assert (entry["State"], entry["ExitCode"], entry["NodeList"]) == (
            "COMPLETED", "0:0", "pg5" if nodes == 1 else "pg[5-6]"), task
        prefix = root / "logs" / f"{identifier}.{raw_id}"
        assert Path(f"{prefix}.status").read_text().strip() == "exit_status=0", identifier
        assert "build/wave_solver_mpi: OK" in (root / "logs" / f"{task}.err").read_text(), task
        solver = dict(line.split("=", 1) for line in Path(f"{prefix}.stdout").read_text().splitlines())
        for actual, expected in (("n", "n"), ("time_steps", "steps"), ("mpi_ranks", "ranks"),
                                 ("openmp_threads", "threads"), ("process_grid", "dims")):
            assert solver[actual] == row[expected], (identifier, actual)
        assert solver["boundary_check"] == "passed", identifier
        assert all(float(solver[f"l{axis}"]) == length for axis in "xyz"), identifier
        assert math.isclose(float(solver["physical_final_time"]),
                            steps * length / (2 * math.sqrt(3) * n), rel_tol=1e-13)
        elapsed, error = (float(solver[key]) for key in ("solve_wall_seconds", "max_absolute_error"))
        expected = abs(math.cos(2 * steps * math.asin(0.5 * math.sin(math.pi / (2*n))))
                       - math.cos(steps * math.pi / (2*n)))
        assert math.isfinite(elapsed) and elapsed > 0 and abs(error - expected) <= 1e-12, identifier
        used = set()
        per_host = (ranks + nodes - 1) // nodes
        rank_hosts = []
        assert len(list(prefix.parent.glob(f"{prefix.name}.rank*.json"))) == ranks, identifier
        for rank in range(ranks):
            binding = json.loads(Path(f"{prefix}.rank{rank}.json").read_text())
            host, local = hosts[rank // per_host], rank % per_host
            cores = {(host, *core) for core in binding["cores"]}
            assert (binding["host"], binding["local_rank"]) == (host, local), identifier
            assert len(cores) == len(set(binding["cpus"])) == threads and not used & cores, identifier
            offset = (local // 2) * threads
            assert sorted(binding["cpus"]) == list(range(local % 2 * 24 + offset,
                                                         local % 2 * 24 + offset + threads)), identifier
            assert {core[1] for core in cores} == {local % 2}, identifier
            rank_hosts.append(host)
            used.update(cores)
        assert solver["hosts"].split(",") == rank_hosts, identifier
        counts[entry["NodeList"]] += 1
        measurements[identifier] = (row, dict(
            job_id=raw_id, array_task=task, hosts=",".join(hosts), physical_cores=ranks*threads,
            state=entry["State"], exit_code=entry["ExitCode"], start=entry["Start"], end=entry["End"],
            **{key: solver[key] for key in ("solve_wall_seconds", "max_absolute_error",
                                           "physical_final_time", "boundary_check")}))
assert seen == set(account)
assert counts == {"pg5": 306, "pg[5-6]": 126}
assert [measurements[row["measurement_id"]][0] for row in manifest] == manifest
result = [{**row, **measurements[row["measurement_id"]][1]} for row in manifest]
with open("measurements.csv", "x", newline="") as stream:
    writer = csv.DictWriter(stream, fieldnames=result[0], lineterminator="\n")
    writer.writeheader()
    writer.writerows(result)
print("complete=yes\nvalid=432\narrays=24\nproblem_configurations=144\nrepetitions=3")
print("pg5=306\npg5_pg6=126\nissues=0")
