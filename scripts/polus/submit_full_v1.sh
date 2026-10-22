#!/usr/bin/env bash

set -u
set -o pipefail

thread_counts=(1 2 4 8 16 20)
grid_sizes=(128 256 512)
domain_ids=(l1 lpi)
time_steps=20
cfl_fraction=0.5
dry_run=FALSE

usage() {
    printf 'Usage: %s [--dry-run]\n' "$0" >&2
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

while (($# > 0)); do
    case "$1" in
        --dry-run) dry_run=TRUE ;;
        *) usage; exit 2 ;;
    esac
    shift
done

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

print_plan() {
    local jobs=0 measurements=0 total_slots=0 n domain_id length threads repetition
    local group repetitions job_name dt final_time cfl_squared

    printf 'dry_run=true\n'
    printf 'required_host=%s\nqueue=%s\nwalltime=%s\n' \
        "$POLUS_FULL_V1_HOST" "$POLUS_FULL_V1_QUEUE" "$POLUS_FULL_V1_WALLTIME"
    printf 'campaign_root=%s/results/polus/full_v1\n' "$repo_root"
    printf 'binary_source=%s/build/wave_solver\n' "$repo_root"
    printf 'benchmark_policy=cfl_scaled_fixed_steps_v1\ntime_steps=%d\ncfl_fraction=%s\n' \
        "$time_steps" "$cfl_fraction"

    for n in "${grid_sizes[@]}"; do
        for domain_id in "${domain_ids[@]}"; do
            length=$(domain_length "$domain_id") || exit 1
            read -r dt final_time cfl_squared <<<"$(time_parameters "$n" "$length" "$length" "$length")" ||
                fail "could not calculate time parameters for N=$n, L=$length"
            printf 'configuration: N=%d L=%s K=%d cfl_fraction=%s dt=%s T=%s cfl_squared=%s\n' \
                "$n" "$length" "$time_steps" "$cfl_fraction" "$dt" \
                "$final_time" "$cfl_squared"
            for threads in "${thread_counts[@]}"; do
                if ((n == 512)); then
                    for repetition in 1 2 3; do
                        group=n${n}_${domain_id}_t${threads}_r${repetition}
                        job_name=v1_CAMPAIGN_${group}
                        printf 'job: group=%s name=%s N=%d L=%s K=%d dt=%s T=%s cfl_fraction=%s cfl_squared=%s threads=%d repetitions=%d slots=%d queue=%s walltime=%s host=%s exclusive=yes span_hosts=1\n' \
                            "$group" "$job_name" "$n" "$length" "$time_steps" \
                            "$dt" "$final_time" "$cfl_fraction" "$cfl_squared" "$threads" \
                            "$repetition" "$threads" "$POLUS_FULL_V1_QUEUE" \
                            "$POLUS_FULL_V1_WALLTIME" "$POLUS_FULL_V1_HOST"
                        printf '  submit: bsub < CAMPAIGN_DIRECTORY/jobs/%s.lsf\n' "$group"
                        printf '  measurement: id=%s repetition=%d command=wave_solver --n %d --lx %s --ly %s --lz %s --time %s --steps %d --threads %d\n' \
                            "$group" "$repetition" "$n" "$length" "$length" "$length" \
                            "$final_time" "$time_steps" "$threads"
                        ((jobs += 1))
                        ((measurements += 1))
                        ((total_slots += threads))
                    done
                else
                    group=n${n}_${domain_id}_t${threads}_r123
                    job_name=v1_CAMPAIGN_${group}
                    printf 'job: group=%s name=%s N=%d L=%s K=%d dt=%s T=%s cfl_fraction=%s cfl_squared=%s threads=%d repetitions=1,2,3 slots=%d queue=%s walltime=%s host=%s exclusive=yes span_hosts=1\n' \
                        "$group" "$job_name" "$n" "$length" "$time_steps" \
                        "$dt" "$final_time" "$cfl_fraction" "$cfl_squared" "$threads" \
                        "$threads" "$POLUS_FULL_V1_QUEUE" \
                        "$POLUS_FULL_V1_WALLTIME" "$POLUS_FULL_V1_HOST"
                    printf '  submit: bsub < CAMPAIGN_DIRECTORY/jobs/%s.lsf\n' "$group"
                    for repetition in 1 2 3; do
                        printf '  measurement: id=n%d_%s_t%d_r%d repetition=%d command=wave_solver --n %d --lx %s --ly %s --lz %s --time %s --steps %d --threads %d\n' \
                            "$n" "$domain_id" "$threads" "$repetition" "$repetition" \
                            "$n" "$length" "$length" "$length" "$final_time" \
                            "$time_steps" "$threads"
                        ((measurements += 1))
                    done
                    ((jobs += 1))
                    ((total_slots += threads))
                fi
            done
        done
    done
    printf 'planned_configurations=36\nplanned_jobs=%d\nplanned_measurements=%d\nplanned_total_requested_slots=%d\n' \
        "$jobs" "$measurements" "$total_slots"
    ((jobs == 60 && measurements == 108 && total_slots == 510)) ||
        fail "internal matrix error: planned $jobs jobs, $measurements measurements, and $total_slots slots"
    printf 'note=dry-run did not call bsub or create campaign data\n'
}

if [[ "$dry_run" == TRUE ]]; then
    print_plan
    exit 0
fi

solver_source=$repo_root/build/wave_solver
[[ -x "$solver_source" ]] ||
    fail "$solver_source is missing or not executable; run ./setup.sh first"
command -v bsub >/dev/null 2>&1 || fail 'bsub is unavailable'

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
manifest_schema_version=2
benchmark_policy=cfl_scaled_fixed_steps_v1
time_steps=$time_steps
cfl_fraction=$cfl_fraction
cfl_squared=0.25
expected_configurations=36
expected_jobs=60
expected_measurements=108
EOF

manifest=$campaign_dir/manifest.csv
submissions=$campaign_dir/submissions.csv
printf '%s\n' 'measurement_id,n,domain_id,lx,ly,lz,physical_final_time,time_steps,time_step,cfl_fraction,cfl_squared,requested_threads,repetition,job_group,job_name' >"$manifest" ||
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
if [[ -n "\${LSB_DJOB_NUMPROC:-}" ]]; then
    [[ "\$LSB_DJOB_NUMPROC" =~ ^[0-9]+$ ]] || fail 'invalid LSF slot count'
    ((LSB_DJOB_NUMPROC == requested_threads)) || fail 'LSF slot count does not match requested threads'
fi
host_name=\$(hostname 2>/dev/null || uname -n)
host_fqdn=\$(hostname -f 2>/dev/null || printf 'unavailable')
printf 'campaign=%s\njob_id=%s\njob_group=%s\nhostname=%s\nhostname_fqdn=%s\nLSB_HOSTS=%s\n' \
    "\$campaign_dir" "\$job_id" "\$job_group" "\$host_name" "\$host_fqdn" "\${LSB_HOSTS:-unavailable}"

export OMP_NUM_THREADS=\$requested_threads
export OMP_DYNAMIC=FALSE
export OMP_PLACES=cores
export OMP_PROC_BIND=close

job_status=0
for repetition in $repetition_words; do
    measurement_id=n${n}_${domain_id}_t${threads}_r\${repetition}
    stem=\$measurements_dir/\${measurement_id}.job\${job_id}
    stdout_file=\${stem}.stdout
    stderr_file=\${stem}.stderr
    metadata_file=\${stem}.meta
    if [[ -e "\$stdout_file" || -e "\$stderr_file" || -e "\$metadata_file" ]]; then
        printf 'measurement files already exist for %s; refusing to overwrite\n' "\$measurement_id" >&2
        job_status=1
        continue
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
        job_status=1
        continue
    fi

    printf 'measurement=%s solver_exit_code=%d stdout=%s stderr=%s\n' \
        "\$measurement_id" "\$solver_status" "\$stdout_file" "\$stderr_file"
    ((solver_status == 0)) || job_status=1
done

exit "\$job_status"
EOF
    chmod 755 "$job_file" || fail "cannot make generated job executable: $job_file"

    IFS=, read -r -a repetition_values <<<"$repetitions"
    for repetition in "${repetition_values[@]}"; do
        measurement_id=n${n}_${domain_id}_t${threads}_r${repetition}
        printf '%s,%d,%s,%s,%s,%s,%s,%d,%s,%s,%s,%d,%d,%s,%s\n' \
            "$measurement_id" "$n" "$domain_id" "$length" "$length" "$length" \
            "$final_time" "$time_steps" "$dt" "$cfl_fraction" "$cfl_squared" \
            "$threads" "$repetition" "$group" "$job_name" >>"$manifest" ||
            fail 'cannot append to the campaign manifest'
        ((manifest_rows += 1))
    done
    job_files+=("$job_file")
    job_groups+=("$group")
    job_names+=("$job_name")
    ((job_slots += threads))
}

campaign_tag=${campaign_id//[-_]/}
for n in "${grid_sizes[@]}"; do
    for domain_id in "${domain_ids[@]}"; do
        length=$(domain_length "$domain_id") || fail "unknown domain: $domain_id"
        read -r dt final_time cfl_squared <<<"$(time_parameters "$n" "$length" "$length" "$length")" ||
            fail "could not calculate time parameters for N=$n, L=$length"
        for threads in "${thread_counts[@]}"; do
            if ((n == 512)); then
                for repetition in 1 2 3; do
                    group=n${n}_${domain_id}_t${threads}_r${repetition}
                    job_name=v1_${campaign_tag}_${group}
                    generate_job "$n" "$domain_id" "$length" "$dt" "$final_time" \
                        "$cfl_squared" "$threads" "$repetition" "$group" "$job_name"
                done
            else
                group=n${n}_${domain_id}_t${threads}_r123
                job_name=v1_${campaign_tag}_${group}
                generate_job "$n" "$domain_id" "$length" "$dt" "$final_time" \
                    "$cfl_squared" "$threads" '1,2,3' "$group" "$job_name"
            fi
        done
    done
done

((manifest_rows == 108)) || fail "manifest contains $manifest_rows measurements instead of 108"
((${#job_files[@]} == 60)) || fail "generated ${#job_files[@]} jobs instead of 60"
((job_slots == 510)) || fail "generated jobs request $job_slots total slots instead of 510"
printf 'submission_plan: jobs=%d measurements=%d total_requested_slots=%d queue=%s walltime=%s\n' \
    "${#job_files[@]}" "$manifest_rows" "$job_slots" \
    "$POLUS_FULL_V1_QUEUE" "$POLUS_FULL_V1_WALLTIME"

current_group=''
current_name=''
current_script=''
submission_in_progress=FALSE
record_submission_event() {
    local event=$1 job_id=$2 details=$3
    if ! printf '%s,%s,%s,%s,%s,%s,%s\n' \
        "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$event" "$current_group" \
        "$current_name" "$(csv_text "$current_script")" "$job_id" \
        "$(csv_text "$details")" \
        >>"$submissions"; then
        printf 'cannot append submission event %s to %s\n' "$event" "$submissions" >&2
        return 1
    fi
}
on_interrupt() {
    if [[ "$submission_in_progress" == TRUE ]]; then
        record_submission_event interrupted '' \
            'submission script interrupted; inspect bjobs before any manual rerun' || true
    fi
    printf 'submission interrupted; campaign preserved at %s\n' "$campaign_dir" >&2
    exit 130
}
trap on_interrupt HUP INT TERM

accepted_jobs=0
for index in "${!job_files[@]}"; do
    current_script=${job_files[$index]}
    current_group=${job_groups[$index]}
    current_name=${job_names[$index]}
    submission_in_progress=TRUE
    record_submission_event submitting '' 'calling bsub' ||
        fail "cannot record submission attempt for $current_group"

    if submission_output=$(bsub <"$current_script" 2>&1); then
        submission_status=0
    else
        submission_status=$?
    fi
    if ((submission_status != 0)); then
        record_submission_event failed '' "bsub exit $submission_status: $submission_output" || true
        submission_in_progress=FALSE
        printf '%s\n' "$submission_output" >&2
        fail "submission failed for $current_group; campaign preserved at $campaign_dir"
    fi

    job_id=$(awk 'match($0, /<[0-9]+>/) { print substr($0, RSTART + 1, RLENGTH - 2); exit }' <<<"$submission_output")
    if [[ ! "$job_id" =~ ^[0-9]+$ ]]; then
        record_submission_event uncertain '' \
            "bsub succeeded but its job ID was not understood: $submission_output" || true
        submission_in_progress=FALSE
        fail "uncertain submission for $current_group; inspect bjobs and $submissions"
    fi
    record_submission_event accepted "$job_id" "$submission_output" ||
        fail "job $job_id was accepted but could not be recorded; inspect bjobs"
    submission_in_progress=FALSE
    ((accepted_jobs += 1))
    printf 'submitted: group=%s job_id=%s script=%s\n' "$current_group" "$job_id" "$current_script"
done

printf 'campaign_directory=%s\n' "$campaign_dir"
printf 'manifest_measurements=%d\nsubmitted_jobs=%d\n' "$manifest_rows" "$accepted_jobs"
printf 'monitor_command=bjobs\n'
