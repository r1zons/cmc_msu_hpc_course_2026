#!/usr/bin/env bash
# Three independent allocations on the same required host; no automatic retries.
set -euo pipefail
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
source "$repo_root/scripts/polus/config.sh"
dry_run=false
case "${1:-}" in
    --dry-run) dry_run=true ;;
    '') ;;
    *) printf 'Usage: %s [--dry-run]\n' "$0" >&2; exit 2 ;;
esac
[[ $# -le 1 ]] || exit 2
if ! $dry_run; then
    [[ -x "$repo_root/build/wave_solver" ]] || { echo 'Build the solver first.' >&2; exit 1; }
    command -v bsub >/dev/null || { echo 'bsub unavailable' >&2; exit 1; }
    root="$repo_root/results/polus/openmp_recheck"
    mkdir -p "$root"
    campaign=$(mktemp -d "$root/$(date -u +%Y-%m-%d_%H-%M-%S).XXXXXX")
    mkdir "$campaign/jobs" "$campaign/logs" "$campaign/measurements" "$campaign/analysis"
    cp "$repo_root/build/wave_solver" "$campaign/wave_solver"
    cp "$repo_root/scripts/polus/config.sh" "$campaign/config.sh"
    if command -v sha256sum >/dev/null; then
        checksum=$(sha256sum "$campaign/wave_solver" | awk '{print $1}')
    else
        checksum=$(shasum -a 256 "$campaign/wave_solver" | awk '{print $1}')
    fi
    printf 'binary_sha256=%s\nsource=%s\ncreated_utc=%s\n' "$checksum" "$repo_root/build/wave_solver" "$(date -u +%FT%TZ)" > "$campaign/metadata.txt"
    printf 'configuration,l,threads,dt,T,K,cfl_fraction,warmups,repetitions\n' > "$campaign/manifest.csv"
    printf 'configuration,job_id\n' > "$campaign/submissions.csv"
fi
for configuration in A B C; do
    length=3.14159265358979323846
    threads=16
    [[ $configuration != B ]] || length=1
    [[ $configuration != C ]] || threads=20
    read -r dt final_time <<< "$(LC_ALL=C awk -v l="$length" 'BEGIN {dt=0.5*l/(sqrt(3)*128); printf "%.17g %.17g\n",dt,20*dt}')"
    printf '%s: N=128 L=%s threads=%s K=20 dt=%s T=%s CFL=0.5 warmups=2 measured=10 queue=short walltime=00:10 host=%s slots=%s exclusive=yes span[hosts=1]\n' "$configuration" "$length" "$threads" "$dt" "$final_time" "$POLUS_FULL_V1_HOST" "$threads"
    $dry_run && continue
    printf '%s,%s,%s,%s,%s,20,0.5,2,10\n' "$configuration" "$length" "$threads" "$dt" "$final_time" >> "$campaign/manifest.csv"
    job="$campaign/jobs/$configuration.lsf"
    # Quoted assignments allow execution from any scheduler working directory.
    {
        printf '#!/usr/bin/env bash\n#BSUB -J recheck_%s\n#BSUB -n %s\n#BSUB -W 00:10\n#BSUB -q short\n#BSUB -x\n#BSUB -R "span[hosts=1]"\n#BSUB -m %s\n#BSUB -o %s/logs/%s.%%J.out\n#BSUB -e %s/logs/%s.%%J.err\n' "$configuration" "$threads" "$POLUS_FULL_V1_HOST" "$campaign" "$configuration" "$campaign" "$configuration"
        printf 'campaign=%q\nconfiguration=%q\nthreads=%q\nlength=%q\nfinal_time=%q\nchecksum=%q\n' "$campaign" "$configuration" "$threads" "$length" "$final_time" "$checksum"
        cat <<'JOB'
set -eo pipefail
source "$campaign/config.sh"
source "$POLUS_CONDA_BASE/etc/profile.d/conda.sh"
conda activate "$POLUS_CONDA_ENV"
[[ -n ${CONDA_PREFIX:-} && -d "$CONDA_PREFIX/lib" ]] || { echo 'Conda runtime unavailable' >&2; exit 2; }
export LD_LIBRARY_PATH="$CONDA_PREFIX/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
if command -v sha256sum >/dev/null; then
    actual=$(sha256sum "$campaign/wave_solver" | awk '{print $1}')
else
    actual=$(shasum -a 256 "$campaign/wave_solver" | awk '{print $1}')
fi
[[ "$actual" == "$checksum" ]] || { echo 'Binary checksum mismatch' >&2; exit 2; }
[[ ${LSB_JOBID:-} =~ ^[0-9]+$ ]] || exit 2
export OMP_NUM_THREADS=$threads OMP_DYNAMIC=FALSE OMP_PLACES=cores OMP_PROC_BIND=close
export OMP_DISPLAY_ENV=VERBOSE OMP_DISPLAY_AFFINITY=TRUE
host_name=$(hostname)
host_fqdn=$(hostname -f 2>/dev/null || printf unavailable)
printf 'hostname=%s\nhostname_fqdn=%s\njob_id=%s\nLSB_HOSTS=%s\nrequested_slots=%s\nLSB_DJOB_NUMPROC=%s\nOMP_NUM_THREADS=%s\nOMP_DYNAMIC=%s\nOMP_PLACES=%s\nOMP_PROC_BIND=%s\n' "$host_name" "$host_fqdn" "$LSB_JOBID" "${LSB_HOSTS:-}" "$threads" "${LSB_DJOB_NUMPROC:-}" "$OMP_NUM_THREADS" "$OMP_DYNAMIC" "$OMP_PLACES" "$OMP_PROC_BIND"
status=0
for phase in warmup measured; do
    count=2
    [[ $phase != measured ]] || count=10
    for ((repetition=1; repetition<=count; repetition++)); do
        stem="$campaign/measurements/${configuration}_${phase}_${repetition}.job${LSB_JOBID}"
        # noclobber retains existing evidence on accidental manual resubmission.
        set +e
        (set -C; "$campaign/wave_solver" --n 128 --lx "$length" --ly "$length" --lz "$length" --time "$final_time" --steps 20 --threads "$threads" > "$stem.stdout" 2> "$stem.stderr")
        code=$?
        set -e
        (set -C; printf 'exit_code=%s\njob_id=%s\nconfiguration=%s\nphase=%s\nrepetition=%s\nhostname=%s\nLSB_HOSTS=%s\n' "$code" "$LSB_JOBID" "$configuration" "$phase" "$repetition" "$(hostname)" "${LSB_HOSTS:-}" > "$stem.meta") || exit 2
        ((code == 0)) || status=1
    done
done
exit "$status"
JOB
    } > "$job"
done
if $dry_run; then
    echo 'planned_jobs=3 warmups=6 measured=30 total_processes=36; no files created or jobs submitted'
else
    echo "campaign_directory=$campaign"
    for configuration in A B C; do
        if output=$(bsub < "$campaign/jobs/$configuration.lsf" 2>&1); then
            printf '%s\n' "$output" | tee "$campaign/logs/${configuration}_submission.txt"
            job_id=$(printf '%s\n' "$output" | awk 'match($0, /<[0-9]+>/) {print substr($0,RSTART+1,RLENGTH-2); exit}')
            [[ $job_id =~ ^[0-9]+$ ]] || { echo 'Uncertain submission: inspect bjobs; do not retry blindly.' >&2; exit 1; }
            printf '%s,%s\n' "$configuration" "$job_id" >> "$campaign/submissions.csv"
        else
            printf '%s\nSubmission failed; partial campaign preserved: %s\n' "$output" "$campaign" >&2
            exit 1
        fi
    done
fi
