#!/usr/bin/env bash

set -u

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
config_file=$script_dir/config.sh
config_loaded=FALSE
if [[ -r "$config_file" ]] && source "$config_file"; then
    config_loaded=TRUE
    printf 'polus_conda_base=%s\n' "$POLUS_CONDA_BASE"
    printf 'polus_conda_environment=%s\n' "$POLUS_CONDA_ENV"
else
    printf 'polus_config=unavailable (%s)\n' "$config_file"
fi

printf 'hostname=%s\n' "$(hostname 2>/dev/null || uname -n)"
printf 'architecture=%s\n' "$(uname -m 2>/dev/null || printf 'unknown')"

compiler=''
if [[ -n "${CXX:-}" ]] && command -v "$CXX" >/dev/null 2>&1; then
    compiler=$CXX
fi
if [[ -z "$compiler" ]]; then
    for candidate in g++ c++ clang++ xlC; do
        if command -v "$candidate" >/dev/null 2>&1; then
            compiler=$candidate
            break
        fi
    done
fi

if [[ -n "$compiler" ]]; then
    printf 'system_cxx=%s\n' "$(command -v "$compiler")"
    printf 'system_cxx_version:\n'
    "$compiler" --version 2>&1 | sed -n '1,3p'
else
    printf 'system_cxx=not found\n'
fi

if command -v make >/dev/null 2>&1; then
    printf 'make=%s\n' "$(command -v make)"
    printf 'make_version=%s\n' "$(make --version 2>&1 | sed -n '1p')"
else
    printf 'make=not found\n'
fi

for utility in bsub bjobs; do
    if command -v "$utility" >/dev/null 2>&1; then
        printf '%s=%s\n' "$utility" "$(command -v "$utility")"
    else
        printf '%s=not found\n' "$utility"
    fi
done

printf 'OMP_NUM_THREADS=%s\n' "${OMP_NUM_THREADS:-unset}"
printf 'OMP_DYNAMIC=%s\n' "${OMP_DYNAMIC:-unset}"
printf 'OMP_PLACES=%s\n' "${OMP_PLACES:-unset}"
printf 'OMP_PROC_BIND=%s\n' "${OMP_PROC_BIND:-unset}"

conda_compiler=''
if [[ "$config_loaded" == TRUE ]]; then
    conda_setup=$POLUS_CONDA_BASE/etc/profile.d/conda.sh
    if [[ ! -r "$conda_setup" ]]; then
        printf 'conda_activation=unavailable (%s is not readable)\n' "$conda_setup"
    else
        conda_init_status=0
        conda_activate_status=1
        set +u
        source "$conda_setup" || conda_init_status=$?
        if ((conda_init_status == 0)); then
            conda activate "$POLUS_CONDA_ENV"
            conda_activate_status=$?
        fi
        set -u

        if ((conda_init_status != 0)); then
            printf 'conda_activation=failed (could not initialize Conda)\n'
        elif ((conda_activate_status != 0)); then
            printf 'conda_activation=failed (could not activate configured environment)\n'
        elif [[ -z "${CONDA_PREFIX:-}" || ! -d "$CONDA_PREFIX/lib" ]]; then
            printf 'conda_activation=failed (CONDA_PREFIX/lib is unavailable)\n'
        else
            export LD_LIBRARY_PATH="$CONDA_PREFIX/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
            printf 'conda_activation=success\n'
            printf 'conda_prefix=%s\n' "$CONDA_PREFIX"
            activated_cxx=${CXX:-g++}
            if command -v "$activated_cxx" >/dev/null 2>&1; then
                conda_compiler=$(command -v "$activated_cxx")
                printf 'conda_cxx=%s\n' "$conda_compiler"
                printf 'conda_cxx_version:\n'
                "$conda_compiler" --version 2>&1 | sed -n '1,3p'
            else
                printf 'conda_cxx=not found after activation\n'
            fi
        fi
    fi
fi

if [[ -z "$compiler" && -z "$conda_compiler" ]]; then
    printf 'openmp_probe=skipped (no C++ compiler found)\n'
    exit 0
fi

probe_dir=$(mktemp -d "${TMPDIR:-/tmp}/wave-openmp-check.XXXXXX" 2>/dev/null) || {
    printf 'openmp_probe=skipped (could not create a temporary directory)\n'
    exit 0
}
trap 'rm -rf -- "$probe_dir"' EXIT

cat >"$probe_dir/openmp_probe.cpp" <<'EOF'
#include <iostream>
#include <omp.h>

int main() {
    std::cout << "openmp_macro=" << _OPENMP << '\n';
    std::cout << "openmp_max_threads=" << omp_get_max_threads() << '\n';
}
EOF

openmp_compiler=''
for candidate in "$conda_compiler" "$compiler" g++ c++ clang++ xlC \
        /usr/local/opt/llvm/bin/clang++ /opt/homebrew/opt/llvm/bin/clang++; do
    if command -v "$candidate" >/dev/null 2>&1 && \
            "$candidate" -std=c++17 -fopenmp "$probe_dir/openmp_probe.cpp" \
                -o "$probe_dir/openmp_probe" \
                >"$probe_dir/compiler.out" 2>&1; then
        openmp_compiler=$candidate
        break
    fi
done

if [[ -n "$openmp_compiler" ]]; then
    printf 'openmp_cxx=%s\n' "$(command -v "$openmp_compiler")"
    printf 'openmp_cxx_version:\n'
    "$openmp_compiler" --version 2>&1 | sed -n '1,3p'
    printf 'openmp_compile=success\n'
    if "$probe_dir/openmp_probe"; then
        printf 'openmp_run=success\n'
    else
        printf 'openmp_run=failed\n'
    fi
else
    printf 'openmp_compile=failed\n'
    sed -n '1,20p' "$probe_dir/compiler.out"
fi
