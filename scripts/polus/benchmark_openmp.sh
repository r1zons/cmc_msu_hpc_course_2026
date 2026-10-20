#!/usr/bin/env bash

set -u

solver=./build/wave_solver
repetitions=3
thread_counts=(1 2 4 8)
expected_error=2.54675495e-05
error_tolerance=1e-10

fail() {
    printf 'benchmark error: %s\n' "$1" >&2
    exit 1
}

read_output_value() {
    key=$1
    file=$2
    awk -F= -v key="$key" '
        $1 == key {
            if (found) {
                exit 2
            }
            value = $2
            found = 1
        }
        END {
            if (!found) {
                exit 1
            }
            print value
        }
    ' "$file"
}

is_nonnegative_number() {
    value=$1
    [[ "$value" =~ ^[+]?[0-9]+([.][0-9]*)?([eE][+-]?[0-9]+)?$ ]] &&
        awk -v value="$value" 'BEGIN { exit !(value + 0 >= 0) }'
}

[[ -f Makefile && -f SPEC.md ]] || fail 'run this script from the repository root'
[[ -x "$solver" ]] || fail "$solver is missing or not executable"

total_runs=$((repetitions * ${#thread_counts[@]}))
((total_runs == 12)) || fail "internal configuration defines $total_runs runs instead of 12"

job_id=${LSB_JOBID:-manual-$$}
host_name=$(hostname 2>/dev/null || uname -n)
results_root=${BENCHMARK_RESULTS_DIR:-results/polus}
raw_dir=$results_root/openmp_benchmark_${job_id}_raw
csv_file=$results_root/openmp_benchmark_${job_id}.csv

mkdir -p "$results_root" || fail "cannot create results directory: $results_root"
[[ ! -e "$csv_file" && ! -e "$raw_dir" ]] || fail "results already exist for job ID: $job_id"
mkdir "$raw_dir" || fail "cannot create raw-output directory: $raw_dir"

printf '%s\n' \
    'job_id,hostname,repetition,requested_threads,effective_threads,solve_wall_seconds,max_absolute_error,exit_code' \
    >"$csv_file" || fail "cannot create CSV file: $csv_file"

export OMP_DYNAMIC=FALSE
export OMP_PLACES=cores
export OMP_PROC_BIND=close

printf 'benchmark_job_id=%s\n' "$job_id"
printf 'benchmark_hostname=%s\n' "$host_name"
printf 'benchmark_runs=%d\n' "$total_runs"
printf 'benchmark_csv=%s\n' "$csv_file"
printf 'benchmark_raw_directory=%s\n' "$raw_dir"

completed_runs=0
for ((repetition = 1; repetition <= repetitions; ++repetition)); do
    for requested_threads in "${thread_counts[@]}"; do
        export OMP_NUM_THREADS=$requested_threads
        raw_file=$raw_dir/rep${repetition}_threads${requested_threads}.out

        {
            printf 'job_id=%s\n' "$job_id"
            printf 'hostname=%s\n' "$host_name"
            printf 'repetition=%d\n' "$repetition"
            printf 'requested_threads=%d\n' "$requested_threads"
        } >"$raw_file" || fail "cannot create raw output: $raw_file"

        "$solver" \
            --n 128 --lx 1 --ly 1 --lz 1 \
            --time 1 --steps 256 --threads "$requested_threads" \
            >>"$raw_file" 2>&1
        solver_status=$?
        printf 'exit_code=%d\n' "$solver_status" >>"$raw_file"

        if ((solver_status != 0)); then
            fail "solver failed for repetition $repetition with $requested_threads threads; see $raw_file"
        fi

        if ! effective_threads=$(read_output_value openmp_threads "$raw_file"); then
            fail "missing or duplicate effective thread count in $raw_file"
        fi
        if ! solve_time=$(read_output_value solve_wall_seconds "$raw_file"); then
            fail "missing or duplicate solve time in $raw_file"
        fi
        if ! max_error=$(read_output_value max_absolute_error "$raw_file"); then
            fail "missing or duplicate numerical error in $raw_file"
        fi

        [[ "$effective_threads" =~ ^[0-9]+$ ]] ||
            fail "malformed effective thread count in $raw_file: $effective_threads"
        ((effective_threads == requested_threads)) ||
            fail "effective thread count $effective_threads does not match requested count $requested_threads"
        is_nonnegative_number "$solve_time" ||
            fail "invalid solve time in $raw_file: $solve_time"
        is_nonnegative_number "$max_error" ||
            fail "invalid numerical error in $raw_file: $max_error"

        if ! awk -v actual="$max_error" -v expected="$expected_error" \
                -v tolerance="$error_tolerance" 'BEGIN {
                    difference = actual - expected
                    if (difference < 0) {
                        difference = -difference
                    }
                    exit !(difference <= tolerance)
                }'; then
            fail "numerical error outside baseline tolerance in $raw_file: $max_error"
        fi

        printf '%s,%s,%d,%d,%d,%s,%s,%d\n' \
            "$job_id" "$host_name" "$repetition" "$requested_threads" \
            "$effective_threads" "$solve_time" "$max_error" "$solver_status" \
            >>"$csv_file" || fail "cannot append to CSV file: $csv_file"

        completed_runs=$((completed_runs + 1))
        printf 'completed_run=%d/%d repetition=%d requested_threads=%d solve_wall_seconds=%s\n' \
            "$completed_runs" "$total_runs" "$repetition" \
            "$requested_threads" "$solve_time"
    done
done

((completed_runs == total_runs)) || fail "completed $completed_runs of $total_runs runs"
printf 'benchmark_status=success\n'
