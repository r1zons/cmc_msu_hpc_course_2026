#!/usr/bin/env bash

set -u

n=${1:-}
steps=${2:-}
threads=16
solver=./build/wave_solver
error_tolerance=1e-9

job_id=${LSB_JOBID:-manual-$$}
host_name=$(hostname 2>/dev/null || uname -n)

finish() {
    status=$1
    printf 'completed_at=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'exit_code=%d\n' "$status"
    exit "$status"
}

fail() {
    printf 'pilot error: %s\n' "$1" >&2
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

case "$n:$steps" in
    256:512|512:1024) ;;
    *) fail 'configuration must be N=256,K=512 or N=512,K=1024' ;;
esac

printf 'job_id=%s\n' "$job_id"
printf 'hostname=%s\n' "$host_name"
printf 'started_at=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
printf 'n=%d\n' "$n"
printf 'time_steps=%d\n' "$steps"
printf 'requested_openmp_threads=%d\n' "$threads"

repo_root=${LS_SUBCWD:-}
[[ -n "$repo_root" ]] || fail 'LS_SUBCWD is unavailable; submit from the repository root'
cd "$repo_root" || fail "cannot enter submission directory: $repo_root"
[[ -f Makefile && -f SPEC.md ]] || fail "submission directory is not the repository root: $repo_root"

if [[ -n "${LSB_DJOB_NUMPROC:-}" ]]; then
    [[ "$LSB_DJOB_NUMPROC" =~ ^[0-9]+$ ]] || fail "invalid LSF slot count: $LSB_DJOB_NUMPROC"
    ((LSB_DJOB_NUMPROC == threads)) ||
        fail "LSF allocated $LSB_DJOB_NUMPROC slots but $threads are required"
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
[[ -x /usr/bin/time ]] || fail 'GNU /usr/bin/time is required to record peak memory usage'
/usr/bin/time -f '' -o /dev/null true 2>/dev/null ||
    fail '/usr/bin/time does not support the required GNU output format'

reference_error=$(awk -v n="$n" -v steps="$steps" 'BEGIN {
    pi = atan2(0, -1)
    mode = sin(pi / (2 * n))
    lambda = -12 * n * n * mode * mode
    q = lambda / (steps * steps)
    cosine = 1 + q / 2
    radicand = 1 - cosine * cosine
    if (radicand < 0 && radicand > -1e-15) {
        radicand = 0
    }
    theta = atan2(sqrt(radicand), cosine)
    discrete = cos(steps * theta)
    exact = cos(pi * sqrt(3))
    difference = discrete - exact
    if (difference < 0) {
        difference = -difference
    }
    printf "%.17g\n", difference
}') || fail 'could not calculate the independent discrete-mode reference error'
is_nonnegative_number "$reference_error" || fail "invalid reference error: $reference_error"

side=$((n + 1))
estimated_layer_bytes=$((3 * side * side * side * 8))
results_root=${PILOT_RESULTS_DIR:-results/polus}
base_name=large_grid_pilot_n${n}_${job_id}
raw_file=$results_root/${base_name}.out
resource_file=$results_root/${base_name}.resources
csv_file=$results_root/${base_name}.csv

mkdir -p "$results_root" || fail "cannot create results directory: $results_root"
[[ ! -e "$raw_file" && ! -e "$resource_file" && ! -e "$csv_file" ]] ||
    fail "pilot results already exist for job ID: $job_id"

{
    printf 'job_id=%s\n' "$job_id"
    printf 'hostname=%s\n' "$host_name"
    printf 'n=%d\n' "$n"
    printf 'lx=1\nly=1\nlz=1\n'
    printf 'physical_final_time=1\n'
    printf 'time_steps=%d\n' "$steps"
    printf 'requested_threads=%d\n' "$threads"
    printf 'reference_error=%s\n' "$reference_error"
    printf 'estimated_three_layer_bytes=%d\n' "$estimated_layer_bytes"
} >"$raw_file" || fail "cannot create raw output: $raw_file"

export OMP_NUM_THREADS=$threads
export OMP_DYNAMIC=FALSE
export OMP_PLACES=cores
export OMP_PROC_BIND=close

LC_ALL=C /usr/bin/time -f 'max_rss_kb=%M' -o "$resource_file" \
    "$solver" \
        --n "$n" --lx 1 --ly 1 --lz 1 \
        --time 1 --steps "$steps" --threads "$threads" \
        >>"$raw_file" 2>&1
solver_status=$?
printf 'exit_code=%d\n' "$solver_status" >>"$raw_file"
((solver_status == 0)) || fail "solver failed; see $raw_file"

if ! effective_threads=$(read_output_value openmp_threads "$raw_file"); then
    fail "missing or duplicate effective thread count in $raw_file"
fi
if ! solve_time=$(read_output_value solve_wall_seconds "$raw_file"); then
    fail "missing or duplicate solve time in $raw_file"
fi
if ! max_error=$(read_output_value max_absolute_error "$raw_file"); then
    fail "missing or duplicate numerical error in $raw_file"
fi
if ! max_rss_kb=$(read_output_value max_rss_kb "$resource_file"); then
    fail "missing or duplicate peak memory value in $resource_file"
fi

[[ "$effective_threads" =~ ^[0-9]+$ ]] ||
    fail "malformed effective thread count: $effective_threads"
((effective_threads == threads)) ||
    fail "effective thread count $effective_threads does not match requested count $threads"
is_nonnegative_number "$solve_time" || fail "invalid solve time: $solve_time"
is_nonnegative_number "$max_error" || fail "invalid numerical error: $max_error"
[[ "$max_rss_kb" =~ ^[0-9]+$ ]] || fail "invalid peak memory value: $max_rss_kb"

error_difference=$(awk -v actual="$max_error" -v expected="$reference_error" 'BEGIN {
    difference = actual - expected
    if (difference < 0) {
        difference = -difference
    }
    printf "%.17g\n", difference
}') || fail 'could not compare numerical and reference errors'

if ! awk -v difference="$error_difference" -v tolerance="$error_tolerance" \
        'BEGIN { exit !(difference <= tolerance) }'; then
    fail "numerical error $max_error differs from reference $reference_error by $error_difference"
fi

printf '%s\n' \
    'job_id,hostname,n,lx,ly,lz,physical_final_time,time_steps,requested_threads,effective_threads,solve_wall_seconds,max_absolute_error,reference_error,error_difference,max_rss_kb,estimated_three_layer_bytes,exit_code' \
    >"$csv_file" || fail "cannot create CSV file: $csv_file"
printf '%s,%s,%d,1,1,1,1,%d,%d,%d,%s,%s,%s,%s,%s,%d,%d\n' \
    "$job_id" "$host_name" "$n" "$steps" "$threads" "$effective_threads" \
    "$solve_time" "$max_error" "$reference_error" "$error_difference" \
    "$max_rss_kb" "$estimated_layer_bytes" "$solver_status" \
    >>"$csv_file" || fail "cannot write CSV result: $csv_file"

printf 'pilot_csv=%s\n' "$csv_file"
printf 'pilot_raw_output=%s\n' "$raw_file"
printf 'pilot_resource_output=%s\n' "$resource_file"
printf 'pilot_status=success\n'
finish 0
