"""Summarize completed single-run MPI benchmark logs, by model and problem."""
import csv
import math
import statistics
import sys
from collections import defaultdict
from pathlib import Path

groups = defaultdict(list)
errors = defaultdict(list)
for path in sorted(Path(sys.argv[1]).glob("logs/*/*.out")):
    values = dict(line.split("=", 1) for line in path.read_text(errors="replace").splitlines()
                  if "=" in line)
    if values.get("boundary_check") != "passed":
        print(f"ignored incomplete run: {path}", file=sys.stderr)
        continue
    model = path.parent.name.split("_")[0]
    key = (model, int(values["n"]), float(values["lx"]), values["physical_final_time"],
           int(values["time_steps"]), int(values["openmp_threads"]),
           int(values["mpi_ranks"]), values["process_grid"])
    elapsed = float(values["solve_wall_seconds"])
    error = float(values["max_absolute_error"])
    n, length, t, steps = key[1:5]
    theta = 2*math.asin(0.5*math.sin(math.pi/(2*n)))
    expected = abs(math.cos(steps*theta)-math.cos(math.pi*math.sqrt(3)*float(t)/length))
    if (not math.isfinite(elapsed) or elapsed <= 0 or not math.isfinite(error)
            or abs(error-expected) > 8*sys.float_info.epsilon*(steps+1)**2):
        print(f"ignored invalid measurement: {path}", file=sys.stderr)
        continue
    groups[key].append(elapsed)
    errors[key].append(error)

writer = csv.writer(sys.stdout)
writer.writerow(("mode", "n", "length", "t", "steps", "threads", "ranks", "process_grid",
                 "reps", "median_seconds", "min_seconds", "max_seconds", "median_error", "speedup"))
for key, times in sorted(groups.items()):
    reference = groups.get((*key[:6], 1, "1x1x1"))
    median = statistics.median(times)
    writer.writerow((*key, len(times), median, min(times), max(times),
                     statistics.median(errors[key]),
                     statistics.median(reference)/median if reference else ""))
if not groups:
    sys.exit("no valid benchmark measurements")
