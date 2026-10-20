#!/usr/bin/env bash

set -u

requested_threads=${1:-}
repetitions=3
solver=./build/wave_solver
expected_error=2.54675495e-05
error_tolerance=1e-10

job_id=${LSB_JOBID:-manual-$$}
host_name=$(hostname 2>/dev/null || uname -n)

finish() {
    status=$1
    printf 'completed_at=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'exit_code=%d\n' "$status"
    exit "$status"
}

fail() {
    printf 'benchmark error: %s\n' "$1" >&2
    finish 1
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

case "$requested_threads" in
    1|2|4|8|16|20) ;;
    *) fail 'thread count must be one of: 1, 2, 4, 8, 16, 20' ;;
esac

printf 'job_id=%s\n' "$job_id"
printf 'hostname=%s\n' "$host_name"
printf 'started_at=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
printf 'requested_openmp_threads=%d\n' "$requested_threads"

repo_root=${LS_SUBCWD:-}
[[ -n "$repo_root" ]] || fail 'LS_SUBCWD is unavailable; submit from the repository root'
cd "$repo_root" || fail "cannot enter submission directory: $repo_root"
[[ -f Makefile && -f SPEC.md ]] || fail "submission directory is not the repository root: $repo_root"

if [[ -n "${LSB_DJOB_NUMPROC:-}" ]]; then
    [[ "$LSB_DJOB_NUMPROC" =~ ^[0-9]+$ ]] || fail "invalid LSF slot count: $LSB_DJOB_NUMPROC"
    ((LSB_DJOB_NUMPROC == requested_threads)) ||
        fail "LSF allocated $LSB_DJOB_NUMPROC slots but $requested_threads were requested"
fi

config_file=scripts/polus/config.sh
[[ -r "$config_file" ]] || fail "Polus configuration is missing or unreadable: $config_file"
source "$config_file" || fail "could not read Polus configuration: $config_file"

conda_setup=$POLUS_CONDA_BASE/etc/profile.d/conda.sh
[[ -r "$conda_setup" ]] || fail "Conda initialization script is missing or unreadable: $conda_setup"
set +u
source "$conda_setup"
conda_init_status=$?
set -u
((conda_init_status == 0)) || fail 'could not initialize Conda'

set +u
conda activate "$POLUS_CONDA_ENV"
conda_activate_status=$?
set -u
((conda_activate_status == 0)) || fail 'could not activate the configured Conda environment'
[[ -n "${CONDA_PREFIX:-}" && -d "$CONDA_PREFIX/lib" ]] ||
    fail 'activated Conda environment has no usable library directory'
export LD_LIBRARY_PATH="$CONDA_PREFIX/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

[[ -x "$solver" ]] || fail "$solver is missing or not executable; build before submission"

results_root=${BENCHMARK_RESULTS_DIR:-results/polus}
raw_dir=$results_root/openmp_${requested_threads}t_${job_id}_raw
csv_file=$results_root/openmp_${requested_threads}t_${job_id}.csv

mkdir -p "$results_root" || fail "cannot create results directory: $results_root"
[[ ! -e "$csv_file" && ! -e "$raw_dir" ]] || fail "results already exist for job ID: $job_id"
mkdir "$raw_dir" || fail "cannot create raw-output directory: $raw_dir"

printf '%s\n' \
    'job_id,hostname,repetition,requested_threads,effective_threads,solve_wall_seconds,max_absolute_error,exit_code' \
    >"$csv_file" || fail "cannot create CSV file: $csv_file"

export OMP_NUM_THREADS=$requested_threads
export OMP_DYNAMIC=FALSE
export OMP_PLACES=cores
export OMP_PROC_BIND=close

printf 'conda_environment=%s\n' "$POLUS_CONDA_ENV"
printf 'conda_prefix=%s\n' "$CONDA_PREFIX"
printf 'benchmark_repetitions=%d\n' "$repetitions"
printf 'benchmark_csv=%s\n' "$csv_file"
printf 'benchmark_raw_directory=%s\n' "$raw_dir"

for ((repetition = 1; repetition <= repetitions; ++repetition)); do
    raw_file=$raw_dir/rep${repetition}.out
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

    ((solver_status == 0)) ||
        fail "solver failed in repetition $repetition; see $raw_file"

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

    printf 'completed_repetition=%d/%d solve_wall_seconds=%s\n' \
        "$repetition" "$repetitions" "$solve_time"
done

printf 'benchmark_status=success\n'
finish 0
