#!/usr/bin/env bash

set -u
set -o pipefail

thread_counts=(1 2 4 8 16 20)
grid_sizes=(128 256 512)
domain_ids=(l1 lpi)
time_steps=20
cfl_fraction=0.5
dry_run=FALSE
mode=''
random_seed=20261023

usage() {
    printf 'Usage: %s --dry-run | --prepare | --submit-next CAMPAIGN_DIRECTORY\n' "$0" >&2
}

fail() {
    printf 'full V1 submission error: %s\n' "$1" >&2
    exit 1
}

sha256_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{ print $1 }'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{ print $1 }'
    else
        return 1
    fi
}

csv_text() {
    printf '%s' "$1" | tr '\n,' ' ;'
}


case "${1:-}" in
    --dry-run) dry_run=TRUE; [[ $# == 1 ]] || exit 2 ;;
    --prepare) [[ $# == 1 ]] || exit 2 ;;
    --submit-next) mode=submit; [[ $# == 2 ]] || exit 2; submit_campaign=$2 ;;
    *) usage; exit 2 ;;
esac
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) || exit 1
repo_root=$(cd -- "$script_dir/../.." && pwd -P) || exit 1
cd "$repo_root" || exit 1
[[ -f Makefile && -f SPEC.md ]] || fail 'repository root not found'

config_file=$script_dir/config.sh
[[ -r "$config_file" ]] || fail "missing Polus configuration: $config_file"
# shellcheck source=/dev/null
source "$config_file" || fail 'could not read the Polus configuration'
[[ -n "${POLUS_CONDA_BASE:-}" && -n "${POLUS_CONDA_ENV:-}" ]] ||
    fail 'Polus Conda configuration is incomplete'
[[ -n "${POLUS_FULL_V1_HOST:-}" ]] || fail 'the required Polus host is not configured'
[[ -n "${POLUS_FULL_V1_QUEUE:-}" ]] || fail 'the Polus queue is not configured'
[[ -n "${POLUS_FULL_V1_WALLTIME:-}" ]] || fail 'the Polus walltime is not configured'
[[ "$POLUS_FULL_V1_QUEUE" =~ ^[A-Za-z0-9_.-]+$ ]] ||
    fail 'the configured Polus queue contains unsupported characters'
[[ "$POLUS_FULL_V1_WALLTIME" =~ ^[0-9]+:[0-5][0-9]$ ]] ||
    fail 'the configured Polus walltime must use HH:MM format'

domain_length() {
    case "$1" in
        l1) printf '1\n' ;;
        lpi) printf '3.14159265358979323846\n' ;;
        *) return 1 ;;
    esac
}

time_parameters() {
    local n=$1 lx=$2 ly=$3 lz=$4
    LC_ALL=C awk -v n="$n" -v lx="$lx" -v ly="$ly" -v lz="$lz" \
        -v steps="$time_steps" -v fraction="$cfl_fraction" 'BEGIN {
            hx = lx / n
            hy = ly / n
            hz = lz / n
            inverse_sum = 1 / (hx * hx) + 1 / (hy * hy) + 1 / (hz * hz)
            dt = fraction / sqrt(inverse_sum)
            final_time = steps * dt
            cfl_squared = dt * dt * inverse_sum
            printf "%.17g %.17g %.17g\n", dt, final_time, cfl_squared
        }'
}


# Explicit Python override; prefer Anaconda base on Polus, compatible local Python otherwise.
python_executable=${PYTHON:-}
if [[ -z "$python_executable" ]]; then
    if [[ -x "$POLUS_CONDA_BASE/bin/python3" ]]; then
        python_executable=$POLUS_CONDA_BASE/bin/python3
    else
        python_executable=python3
    fi
fi
"$python_executable" -c 'import sys; sys.exit(sys.version_info < (3, 7))' ||
    fail 'Python >=3.7 required; set PYTHON to a compatible interpreter'

if [[ "$mode" == submit ]]; then
    campaign_dir=$(cd -- "$submit_campaign" && pwd -P) || fail 'campaign not found'
    submissions=$campaign_dir/submissions.csv
    [[ -r "$submissions" ]] || fail 'missing submission record'
    command -v bsub >/dev/null || fail 'bsub unavailable'
    # Prevent simultaneous operators selecting the same batch. Never remove a stale guard automatically.
    guard=$campaign_dir/.submitting
    mkdir "$guard" 2>/dev/null || fail 'submission guard exists; check active submitters before manual removal'
    trap 'rmdir "$guard"' EXIT
    eligible=$("$python_executable" - "$campaign_dir" <<'PYTHON'
import csv, sys
from pathlib import Path
campaign = Path(sys.argv[1])
with (campaign/'submissions.csv').open(newline='') as f:
    events = list(csv.DictReader(f))
states = {}
for row in events:
    group, event = row['job_group'], row['event']
    if event not in ('submitting', 'accepted', 'failed'):
        sys.exit('Unknown submission event; reconcile manually')
    if event == 'accepted' and not row['lsf_job_id'].isdigit():
        sys.exit('Invalid accepted job ID; reconcile manually')
    if event == 'submitting':
        if group in states:
            sys.exit('Repeated submission attempt; reconcile manually')
    elif states.get(group) != 'submitting':
        sys.exit('Malformed submission history; reconcile manually')
    states[group] = event
if any(state != 'accepted' for state in states.values()):
    sys.exit('Failed/interrupted/uncertain submission: reconcile bjobs/bhist and submissions.csv before continuing; never retry uncertain acceptance')
with (campaign/'manifest.csv').open(newline='') as f:
    rows = list(csv.DictReader(f))
if len(rows) != 360 or len({r['job_group'] for r in rows}) != 360:
    sys.exit('Expected a prepared 360-job campaign')
if set(states) - {r['job_group'] for r in rows}:
    sys.exit('Unknown submitted group; reconcile manually')
for row in rows:
    if row['job_group'] not in states:
        print(row['job_group'], row['job_name'], row['requested_threads'])
PYTHON
    ) || fail 'cannot select a safe batch'
    jobs=0
    slots=0
    while read -r group name threads; do
        [[ -n "$group" ]] || continue
        [[ "$group" =~ ^n[0-9]+_l(pi|1)_t[0-9]+_r[0-9]+$ && "$threads" =~ ^[0-9]+$ ]] || fail 'invalid manifest'
        ((jobs < 12 && slots + threads <= 120)) || break
        job=$campaign_dir/jobs/$group.lsf
        [[ -r "$job" ]] || fail "missing $job"
        printf '%s,submitting,%s,%s,%s,,calling bsub\n' "$(date -u +%FT%TZ)" "$group" "$name" "$(csv_text "$job")" >> "$submissions" || fail 'cannot record intent'
        if output=$(bsub < "$job" 2>&1); then
            job_id=$(awk 'match($0, /<[0-9]+>/) {print substr($0,RSTART+1,RLENGTH-2); exit}' <<< "$output")
            [[ "$job_id" =~ ^[0-9]+$ ]] || fail "uncertain acceptance: $output; reconcile manually"
            printf '%s,accepted,%s,%s,%s,%s,%s\n' "$(date -u +%FT%TZ)" "$group" "$name" "$(csv_text "$job")" "$job_id" "$(csv_text "$output")" >> "$submissions" || fail "accepted job $job_id could not be recorded"
        else
            printf '%s,failed,%s,%s,%s,,%s\n' "$(date -u +%FT%TZ)" "$group" "$name" "$(csv_text "$job")" "$(csv_text "$output")" >> "$submissions"
            fail "bsub failed: $output; no retry performed"
        fi
        ((jobs += 1))
        ((slots += threads))
        printf 'submitted: group=%s job_id=%s slots=%s\n' "$group" "$job_id" "$threads"
    done <<< "$eligible"
    printf 'batch_jobs=%d batch_requested_slots=%d; inspect bjobs before next batch\n' "$jobs" "$slots"
    exit 0
fi

plan=$("$python_executable" - "$random_seed" <<'PYTHON'
import random, sys
configurations = [(n, domain, threads) for n in (128,256,512)
                  for domain in ('l1','lpi') for threads in (1,2,4,8,16,20)]
for repetition in range(1,11):
    ordered = list(configurations)
    random.Random(int(sys.argv[1]) + repetition).shuffle(ordered)
    for n, domain, threads in ordered:
        print(n, domain, threads, repetition)
PYTHON
) || fail 'cannot generate plan'

if [[ "$dry_run" == TRUE ]]; then
    printf 'random_seed=%s round_seed=random_seed+round\n' "$random_seed"
    while read -r n domain_id threads repetition; do
        length=$(domain_length "$domain_id")
        read -r dt final_time cfl_squared <<< "$(time_parameters "$n" "$length" "$length" "$length")"
        printf 'job: group=n%s_%s_t%s_r%s round=%s N=%s L=%s threads=%s slots=%s queue=%s walltime=%s host=%s exclusive=yes span_hosts=1 dt=%s T=%s cfl_squared=%s\n' "$n" "$domain_id" "$threads" "$repetition" "$repetition" "$n" "$length" "$threads" "$threads" "$POLUS_FULL_V1_QUEUE" "$POLUS_FULL_V1_WALLTIME" "$POLUS_FULL_V1_HOST" "$dt" "$final_time" "$cfl_squared"
        printf '  measurement: wave_solver --n %s --lx %s --ly %s --lz %s --time %s --steps 20 --threads %s\n' "$n" "$length" "$length" "$length" "$final_time" "$threads"
    done <<< "$plan"
    printf 'planned_configurations=36\nplanned_rounds=10\nplanned_jobs=360\nplanned_measurements=360\nplanned_total_requested_slots=3060\n'
    exit 0
fi
solver_source=$repo_root/build/wave_solver
[[ -x "$solver_source" ]] ||
    fail "$solver_source is missing or not executable; run ./setup.sh first"


campaign_root=$repo_root/results/polus/full_v1
mkdir -p "$campaign_root" || fail "cannot create campaign root: $campaign_root"
timestamp=$(date -u '+%Y-%m-%d_%H-%M-%S') || fail 'cannot create campaign timestamp'
campaign_id=$timestamp
suffix=0
while ! mkdir "$campaign_root/$campaign_id" 2>/dev/null; do
    ((suffix += 1))
    printf -v campaign_id '%s_%02d' "$timestamp" "$suffix"
done
campaign_dir=$campaign_root/$campaign_id
jobs_dir=$campaign_dir/jobs
logs_dir=$campaign_dir/logs
measurements_dir=$campaign_dir/measurements
analysis_dir=$campaign_dir/analysis
mkdir "$jobs_dir" "$logs_dir" "$measurements_dir" "$analysis_dir" ||
    fail "cannot initialize campaign directories under $campaign_dir"

campaign_solver=$campaign_dir/wave_solver
campaign_config=$campaign_dir/config.sh
cp "$solver_source" "$campaign_solver" || fail 'cannot copy the solver into the campaign'
chmod 755 "$campaign_solver" || fail 'cannot make the campaign solver executable'
cp "$config_file" "$campaign_config" || fail 'cannot copy the Polus configuration into the campaign'
chmod 644 "$campaign_config" || fail 'cannot set campaign configuration permissions'
binary_sha256=$(sha256_file "$campaign_solver") || fail 'no SHA-256 utility is available'
[[ "$binary_sha256" =~ ^[0-9a-fA-F]{64}$ ]] || fail 'invalid SHA-256 result'

compiler_command=${CXX:-g++}
compiler_version=$($compiler_command --version 2>/dev/null | sed -n '1p' | tr ',' ';')
[[ -n "$compiler_version" ]] || compiler_version=unavailable
git_commit=$(git rev-parse HEAD 2>/dev/null || printf 'unavailable')
git_changes=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
cat >"$campaign_dir/metadata.txt" <<EOF
campaign_id=$campaign_id
created_at_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
repository_root=$repo_root
binary_source=$solver_source
binary_path=$campaign_solver
binary_sha256=$binary_sha256
compiler_command=$compiler_command
compiler_version=$compiler_version
git_commit=$git_commit
git_change_count=$git_changes
build_hostname=$(hostname 2>/dev/null || uname -n)
build_architecture=$(uname -m 2>/dev/null || printf 'unknown')
conda_base=$POLUS_CONDA_BASE
conda_environment=$POLUS_CONDA_ENV
queue=$POLUS_FULL_V1_QUEUE
walltime=$POLUS_FULL_V1_WALLTIME
required_host=$POLUS_FULL_V1_HOST
manifest_schema_version=3
benchmark_policy=cfl_scaled_rounds_v1
time_steps=$time_steps
cfl_fraction=$cfl_fraction
cfl_squared=0.25
expected_configurations=36
expected_jobs=360
expected_measurements=360
repetitions=10
random_seed=$random_seed
round_seed_rule=random_seed+round
submission_order=manifest.csv row order
python_executable=$python_executable
python_version=$("$python_executable" --version 2>&1)
EOF

manifest=$campaign_dir/manifest.csv
submissions=$campaign_dir/submissions.csv
printf '%s\n' 'measurement_id,n,domain_id,lx,ly,lz,physical_final_time,time_steps,time_step,cfl_fraction,cfl_squared,requested_threads,repetition,job_group,job_name,round' >"$manifest" ||
    fail 'cannot create the campaign manifest'
printf '%s\n' 'timestamp_utc,event,job_group,job_name,job_script,lsf_job_id,details' >"$submissions" ||
    fail 'cannot create the submission record'

job_files=()
job_groups=()
job_names=()
manifest_rows=0
job_slots=0

generate_job() {
    local n=$1 domain_id=$2 length=$3 dt=$4 final_time=$5 cfl_squared=$6
    local threads=$7 repetitions=$8 group=$9 job_name=${10}
    local job_file log_prefix repetition measurement_id repetition_words
    local quoted_campaign quoted_solver quoted_config quoted_measurements quoted_checksum

    job_file=$jobs_dir/${group}.lsf
    log_prefix=$logs_dir/${group}
    repetition_words=${repetitions//,/ }
    printf -v quoted_campaign '%q' "$campaign_dir"
    printf -v quoted_solver '%q' "$campaign_solver"
    printf -v quoted_config '%q' "$campaign_config"
    printf -v quoted_measurements '%q' "$measurements_dir"
    printf -v quoted_checksum '%q' "$binary_sha256"

    cat >"$job_file" <<EOF
#!/usr/bin/env bash
#BSUB -J $job_name
#BSUB -n $threads
#BSUB -W $POLUS_FULL_V1_WALLTIME
#BSUB -q $POLUS_FULL_V1_QUEUE
#BSUB -o $log_prefix.%J.out
#BSUB -e $log_prefix.%J.err
#BSUB -R "span[hosts=1]"
#BSUB -x
#BSUB -m $POLUS_FULL_V1_HOST

set -u
set -o pipefail

campaign_dir=$quoted_campaign
solver=$quoted_solver
config_file=$quoted_config
measurements_dir=$quoted_measurements
expected_checksum=$quoted_checksum
requested_threads=$threads
job_group=$group

fail() {
    printf 'full V1 job error: %s\n' "\$1" >&2
    exit 2
}

[[ -r "\$config_file" ]] || fail "campaign configuration is missing: \$config_file"
# shellcheck source=/dev/null
source "\$config_file" || fail 'could not read campaign configuration'
conda_setup=\$POLUS_CONDA_BASE/etc/profile.d/conda.sh
[[ -r "\$conda_setup" ]] || fail "Conda initialization is missing: \$conda_setup"
set +u
source "\$conda_setup"
conda_status=\$?
set -u
((conda_status == 0)) || fail 'could not initialize Conda'
set +u
conda activate "\$POLUS_CONDA_ENV"
conda_status=\$?
set -u
((conda_status == 0)) || fail "could not activate Conda environment \$POLUS_CONDA_ENV"
[[ -n "\${CONDA_PREFIX:-}" && -d "\$CONDA_PREFIX/lib" ]] ||
    fail 'activated Conda environment has no library directory'
export LD_LIBRARY_PATH="\$CONDA_PREFIX/lib\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"

[[ -x "\$solver" ]] || fail "campaign solver is missing or not executable: \$solver"
if command -v sha256sum >/dev/null 2>&1; then
    actual_checksum=\$(sha256sum "\$solver" | awk '{ print \$1 }')
elif command -v shasum >/dev/null 2>&1; then
    actual_checksum=\$(shasum -a 256 "\$solver" | awk '{ print \$1 }')
else
    fail 'no SHA-256 utility is available on the compute host'
fi
[[ "\$actual_checksum" == "\$expected_checksum" ]] || fail 'campaign solver checksum mismatch'

job_id=\${LSB_JOBID:-}
[[ "\$job_id" =~ ^[0-9]+$ ]] || fail 'numeric LSB_JOBID is required'
host_name=\$(hostname 2>/dev/null || uname -n)
host_fqdn=\$(hostname -f 2>/dev/null || printf 'unavailable')
printf 'campaign=%s\njob_id=%s\njob_group=%s\nhostname=%s\nhostname_fqdn=%s\nLSB_HOSTS=%s\n' \
    "\$campaign_dir" "\$job_id" "\$job_group" "\$host_name" "\$host_fqdn" "\${LSB_HOSTS:-unavailable}"

export OMP_NUM_THREADS=\$requested_threads
export OMP_DYNAMIC=FALSE
export OMP_PLACES=cores
export OMP_PROC_BIND=close

repetition=$repetition_words
    measurement_id=n${n}_${domain_id}_t${threads}_r\${repetition}
    stem=\$measurements_dir/\${measurement_id}.job\${job_id}
    stdout_file=\${stem}.stdout
    stderr_file=\${stem}.stderr
    metadata_file=\${stem}.meta
    if [[ -e "\$stdout_file" || -e "\$stderr_file" || -e "\$metadata_file" ]]; then
        printf 'measurement files already exist for %s; refusing to overwrite\n' "\$measurement_id" >&2
        exit 1
    fi

    started_at=\$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    (
        set -o noclobber
        LC_ALL=C "\$solver" --n $n --lx $length --ly $length --lz $length \
            --time $final_time --steps $time_steps --threads $threads \
            >"\$stdout_file" 2>"\$stderr_file"
    )
    solver_status=\$?
    completed_at=\$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    if ! (
        set -o noclobber
        {
            printf 'round=%s\nconfiguration_id=n${n}_${domain_id}_t${threads}\n' "\$repetition"
            printf 'measurement_id=%s\n' "\$measurement_id"
            printf 'job_group=%s\njob_id=%s\n' "\$job_group" "\$job_id"
            printf 'hostname=%s\nhostname_fqdn=%s\nLSB_HOSTS=%s\n' \
                "\$host_name" "\$host_fqdn" "\${LSB_HOSTS:-unavailable}"
            printf 'n=%d\ndomain_id=%s\nlx=%s\nly=%s\nlz=%s\n' \
                $n $domain_id $length $length $length
            printf 'physical_final_time=%s\ntime_steps=%d\ntime_step=%s\n' \
                $final_time $time_steps $dt
            printf 'cfl_fraction=%s\ncfl_squared=%s\nrequested_threads=%d\nrepetition=%d\n' \
                $cfl_fraction $cfl_squared $threads "\$repetition"
            printf 'binary_sha256=%s\nstarted_at_utc=%s\ncompleted_at_utc=%s\nsolver_exit_code=%d\n' \
                "\$expected_checksum" "\$started_at" "\$completed_at" "\$solver_status"
        } >"\$metadata_file"
    ); then
        printf 'could not publish metadata for %s\n' "\$measurement_id" >&2
        exit 1
    fi

    printf 'measurement=%s solver_exit_code=%d stdout=%s stderr=%s\n' \
        "\$measurement_id" "\$solver_status" "\$stdout_file" "\$stderr_file"
exit "\$solver_status"
EOF
    chmod 755 "$job_file" || fail "cannot make generated job executable: $job_file"

    IFS=, read -r -a repetition_values <<<"$repetitions"
    for repetition in "${repetition_values[@]}"; do
        measurement_id=n${n}_${domain_id}_t${threads}_r${repetition}
        printf '%s,%d,%s,%s,%s,%s,%s,%d,%s,%s,%s,%d,%d,%s,%s,%d\n' \
            "$measurement_id" "$n" "$domain_id" "$length" "$length" "$length" \
            "$final_time" "$time_steps" "$dt" "$cfl_fraction" "$cfl_squared" \
            "$threads" "$repetition" "$group" "$job_name" "$repetition" >>"$manifest" ||
            fail 'cannot append to the campaign manifest'
        ((manifest_rows += 1))
    done
    job_files+=("$job_file")
    job_groups+=("$group")
    job_names+=("$job_name")
    ((job_slots += threads))
}


campaign_tag=${campaign_id//[-_]/}
while read -r n domain_id threads repetition; do
    length=$(domain_length "$domain_id") || fail 'unknown domain'
    read -r dt final_time cfl_squared <<< "$(time_parameters "$n" "$length" "$length" "$length")"
    group=n${n}_${domain_id}_t${threads}_r${repetition}
    job_name=v1_${campaign_tag}_${group}
    generate_job "$n" "$domain_id" "$length" "$dt" "$final_time" "$cfl_squared" "$threads" "$repetition" "$group" "$job_name"
done <<< "$plan"
((manifest_rows == 360 && ${#job_files[@]} == 360 && job_slots == 3060)) || fail 'internal matrix error'
printf 'campaign_directory=%s\nprepared_jobs=360 measurements=360 total_requested_slots=3060\n' "$campaign_dir"
printf 'No jobs submitted. Next: bash scripts/polus/submit_full_v1.sh --submit-next %q\n' "$campaign_dir"
