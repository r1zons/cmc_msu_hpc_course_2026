"""Polus compute-node verification against V1 optimized and discrete modes."""
import math
import os
import subprocess
import sys


def execute(cmd, env=None):
    done = subprocess.run(cmd, check=True, text=True, stdout=subprocess.PIPE, env=env)
    print("$", " ".join(cmd), flush=True)
    print(done.stdout, end="", flush=True)
    return dict(line.split("=", 1) for line in done.stdout.splitlines() if "=" in line)


def verify(optimized, mode, ranks, threads, n, lengths, steps, dims=None, hosts=1):
    factor = math.sqrt(sum((n / length)**2 for length in lengths))
    t = steps * (0.5 / factor)
    problem = ["--n", str(n), "--steps", str(steps), "--time", repr(t)]
    for axis, length in zip(("lx", "ly", "lz"), lengths):
        problem += ["--" + axis, repr(length)]
    cmd = ["bash", "run.sh", mode, "--ranks", str(ranks), "--threads", str(threads),
           "--verify"] + problem
    if dims:
        cmd += ["--dims", dims]
    env = None
    if hosts == 2:
        env = dict(os.environ, MPI_MAP_BY=f"ppr:{ranks//2}:node:PE={threads}")
    result = execute(cmd, env)
    reference = execute([optimized, "--threads", "1"] + problem)
    sides = [int(d) for d in result["process_grid"].split("x")]
    assert math.prod(sides) == ranks
    if dims:
        assert result["process_grid"] == dims
    elif ranks in (8, 32):
        assert sorted(sides) == ([2, 2, 2] if ranks == 8 else [2, 4, 4])
    placement = result["hosts"].split(",")
    assert len(placement) == ranks and len(set(placement)) == hosts
    if hosts == 2:
        assert all(placement.count(host) * threads == 16 for host in set(placement))
    assert int(result["mpi_ranks"]) == ranks and int(result["openmp_threads"]) == threads
    assert int(result["mpi_thread_level"]) >= 1
    assert result["halo_check"] == result["boundary_check"] == "passed"
    tolerance = 8 * sys.float_info.epsilon * (steps+1)**2
    assert float(result["discrete_max_error"]) <= tolerance
    error = float(result["max_absolute_error"])
    # On odd N the largest sampled sine is strictly less than one.
    theta = 2 * math.asin(0.5 * math.sin(math.pi/(2*n)))
    peak = math.sin(math.pi*(n//2)/n)**3
    exact_amp = math.cos(math.pi*math.sqrt(sum(1/x**2 for x in lengths))*t)
    theoretical = peak * abs(math.cos(steps*theta) - exact_amp)
    assert abs(error - theoretical) <= tolerance, (error, theoretical)
    assert abs(error - float(reference["max_absolute_error"])) <= tolerance
    elapsed = float(result["solve_wall_seconds"])
    assert math.isfinite(elapsed) and elapsed > 0
    print(f"PASS {mode} ranks={ranks} threads={threads} N={n} K={steps} "
          f"L={lengths} grid={result['process_grid']} seconds={elapsed:.8g} error={error:.5g}",
          flush=True)


if __name__ == "__main__":
    if not os.environ.get("LSB_JOBID"):
        sys.exit("run this suite inside a Polus LSF allocation")
    opt = sys.argv[1]
    cases = [
        ("mpi", 1, 1, 8, (1,)*3, 1),
        ("mpi", 2, 1, 11, (1, 1.3, 2), 20),
        ("mpi", 4, 1, 16, (math.pi,)*3, 20),
        ("mpi", 8, 1, 16, (1,)*3, 1),
        ("mpi", 8, 1, 17, (math.pi,)*3, 20, "1x2x4"),
        ("hybrid", 2, 2, 11, (1, 1.3, 2), 1),
        ("hybrid", 4, 4, 16, (math.pi,)*3, 20),
        ("mpi", 1, 1, 128, (1,)*3, 20),
        ("mpi", 4, 1, 128, (1,)*3, 20),
        ("mpi", 8, 1, 128, (1,)*3, 20),
        ("hybrid", 1, 4, 128, (1,)*3, 20),
        ("hybrid", 2, 4, 128, (1,)*3, 20),
        ("hybrid", 4, 4, 128, (1,)*3, 20),
        ("mpi", 8, 1, 256, (math.pi,)*3, 20),
        ("hybrid", 4, 4, 512, (1,)*3, 20),
    ]
    multi = len(sys.argv) > 2 and sys.argv[2] == "multinode"
    if multi:
        cases = [
            ("mpi", 32, 1, 17, (1, 1.3, 2), 20),
            ("hybrid", 8, 4, 128, (math.pi,)*3, 20),
        ]
    for case in cases:
        verify(opt, *case, hosts=2 if multi else 1)
    print(f"PASS all {len(cases)} cases")
