#!/usr/bin/env bash

set -eu

fail() { printf 'submit error: %s\n' "$1" >&2; exit 1; }
[[ $# -eq 2 && $2 == --submit ]] || fail \
  'usage: submit_optimization_ab.sh ABSOLUTE_CAMPAIGN --submit'
campaign=$1
[[ $campaign = /* && -f $campaign/manifest.csv ]] || fail \
  'campaign must be an absolute prepared campaign path'
[[ -x $campaign/bin/wave_solver_baseline && \
   -x $campaign/bin/wave_solver_optimized ]] || fail 'frozen binaries are missing'
job_script=$(cd "$(dirname "$0")" && pwd -P)/optimization_ab_job.lsf
[[ -f $job_script ]] || fail 'job script is missing'
command -v bsub >/dev/null 2>&1 || fail 'bsub is unavailable'

tail -n +2 "$campaign/manifest.csv" | while IFS=, read -r id variant n threads repetition; do
    log=$campaign/logs/$id.%J
    bsub -n "$threads" -J "$id" -o "$log.out" -e "$log.err" \
        -env "all,AB_CAMPAIGN=$campaign,AB_ID=$id,AB_VARIANT=$variant,AB_N=$n,AB_THREADS=$threads,AB_REPETITION=$repetition" \
        <"$job_script"
done
