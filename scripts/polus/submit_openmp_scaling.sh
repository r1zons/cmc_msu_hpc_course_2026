#!/usr/bin/env bash

set -u

thread_counts=(1 2 4 8 16 20)
dry_run=FALSE

if [[ ${1:-} == --dry-run ]]; then
    dry_run=TRUE
    shift
fi
[[ $# -eq 0 ]] || {
    printf 'Usage: %s [--dry-run]\n' "$0" >&2
    exit 2
}

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/../.." && pwd)
cd "$repo_root" || exit 1
[[ -f Makefile && -f SPEC.md ]] || {
    printf 'error: could not locate the repository root\n' >&2
    exit 1
}

if [[ "$dry_run" == FALSE ]]; then
    command -v bsub >/dev/null 2>&1 || {
        printf 'error: bsub is not available\n' >&2
        exit 1
    }
    mkdir -p logs/polus || exit 1
fi

for threads in "${thread_counts[@]}"; do
    job_file=scripts/polus/openmp_scaling_${threads}t.lsf
    [[ -r "$job_file" ]] || {
        printf 'error: missing job file: %s\n' "$job_file" >&2
        exit 1
    }

    slots=$(awk '$1 == "#BSUB" && $2 == "-n" { print $3 }' "$job_file")
    [[ "$slots" == "$threads" ]] || {
        printf 'error: %s requests %s slots instead of %s\n' \
            "$job_file" "${slots:-none}" "$threads" >&2
        exit 1
    }
    grep -Fxq '#BSUB -q normal' "$job_file" || exit 1
    grep -Fxq '#BSUB -W 00:15' "$job_file" || exit 1
    grep -Fxq '#BSUB -R "span[hosts=1]"' "$job_file" || exit 1
    grep -Fxq '#BSUB -x' "$job_file" || exit 1
    grep -Fxq "exec bash scripts/polus/benchmark_openmp_per_thread.sh $threads" \
        "$job_file" || exit 1

    if [[ "$dry_run" == TRUE ]]; then
        printf 'validated: bsub < %s (slots=%s)\n' "$job_file" "$slots"
    else
        printf 'submitting: %s (slots=%s)\n' "$job_file" "$slots"
        bsub <"$job_file" || exit 1
    fi
done
