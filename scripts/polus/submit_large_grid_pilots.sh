#!/usr/bin/env bash

set -u

dry_run=FALSE

while (($# > 0)); do
    case "$1" in
        --dry-run)
            dry_run=TRUE
            shift
            ;;
        *)
            printf 'Usage: %s [--dry-run]\n' "$0" >&2
            exit 2
            ;;
    esac
done

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

for n in 256 512; do
    job_file=scripts/polus/large_grid_pilot_n${n}.lsf
    [[ -r "$job_file" ]] || {
        printf 'error: missing job file: %s\n' "$job_file" >&2
        exit 1
    }

    slots=$(awk '$1 == "#BSUB" && $2 == "-n" { print $3 }' "$job_file")
    [[ "$slots" == 16 ]] || {
        printf 'error: %s requests %s slots instead of 16\n' \
            "$job_file" "${slots:-none}" >&2
        exit 1
    }
    grep -Fxq '#BSUB -q normal' "$job_file" || exit 1
    grep -Fxq '#BSUB -W 03:00' "$job_file" || exit 1
    grep -Fxq '#BSUB -R "span[hosts=1]"' "$job_file" || exit 1
    grep -Fxq '#BSUB -x' "$job_file" || exit 1

    if [[ "$n" == 256 ]]; then
        grep -Fxq 'exec bash scripts/polus/large_grid_pilot.sh 256 512' "$job_file" || exit 1
    else
        grep -Fxq 'exec bash scripts/polus/large_grid_pilot.sh 512 1024' "$job_file" || exit 1
    fi

    if [[ "$dry_run" == TRUE ]]; then
        printf 'validated: bsub < %s (slots=16, walltime=03:00)\n' "$job_file"
    else
        printf 'submitting: %s (slots=16, walltime=03:00)\n' "$job_file"
        bsub <"$job_file" || exit 1
    fi
done
