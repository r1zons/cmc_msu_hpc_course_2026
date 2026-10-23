#!/usr/bin/env bash

set -eu

fail() { printf 'prepare error: %s\n' "$1" >&2; exit 1; }
[[ -f Makefile && -f SPEC.md ]] || fail 'run from the repository root'

source scripts/polus/config.sh
timestamp=$(date -u +%Y-%m-%d_%H-%M-%S)
campaign=${1:-results/polus/optimization_ab/$timestamp}
[[ ! -e "$campaign" ]] || fail "campaign already exists: $campaign"
mkdir -p "$campaign"/bin "$campaign"/logs "$campaign"/measurements

cxx=${CXX:-g++}
common_flags=${POLUS_AB_CXXFLAGS:--O3 -Wall -Wextra -Wpedantic -mcpu=power8 -mtune=power8}
build_dir=$campaign/build
make BUILD_DIR="$build_dir" CXX="$cxx" CXXFLAGS="$common_flags" all optimized
cp "$build_dir/wave_solver" "$campaign/bin/wave_solver_baseline"
cp "$build_dir/wave_solver_opt" "$campaign/bin/wave_solver_optimized"

checksum() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
    else shasum -a 256 "$1" | awk '{print $1}'
    fi
}

campaign_abs=$(cd "$campaign" && pwd -P)
cat >"$campaign/metadata.txt" <<EOF
created_at_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
repository_root=$(pwd -P)
campaign_path=$campaign_abs
compiler=$cxx
compiler_version=$($cxx --version | sed -n '1p' | tr ',' ';')
cxxflags=$common_flags
project_cxxflags=-std=c++17
openmp_flags=-fopenmp
baseline_sha256=$(checksum "$campaign/bin/wave_solver_baseline")
optimized_sha256=$(checksum "$campaign/bin/wave_solver_optimized")
git_commit=$(git rev-parse HEAD 2>/dev/null || printf unavailable)
git_change_count=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
queue=$POLUS_FULL_V1_QUEUE
walltime=$POLUS_FULL_V1_WALLTIME
required_host=$POLUS_FULL_V1_HOST
time_steps=20
cfl_fraction=0.5
repetitions=5
thread_counts=1,4,8,16,20
grid_sizes=128,256,512
omp_dynamic=FALSE
omp_places=cores
omp_proc_bind=close
EOF

printf '%s\n' 'measurement_id,variant,n,threads,repetition' \
    >"$campaign/manifest.csv"
for n in 128 256 512; do
    for threads in 1 4 8 16 20; do
        for repetition in 1 2 3 4 5; do
            for variant in baseline optimized; do
                id=${variant}_n${n}_t${threads}_r${repetition}
                printf '%s,%s,%s,%s,%s\n' \
                    "$id" "$variant" "$n" "$threads" "$repetition" \
                    >>"$campaign/manifest.csv"
            done
        done
    done
done

printf 'campaign=%s\n' "$campaign_abs"
printf 'measurements=150\n'
printf 'No jobs submitted. Inspect metadata/manifest, then run:\n'
printf '  bash scripts/polus/submit_optimization_ab.sh %q --submit\n' "$campaign_abs"
