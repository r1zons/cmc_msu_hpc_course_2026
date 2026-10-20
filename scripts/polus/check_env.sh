#!/usr/bin/env bash

set -u

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
    printf 'cxx=%s\n' "$(command -v "$compiler")"
    printf 'cxx_version:\n'
    "$compiler" --version 2>&1 | sed -n '1,3p'
else
    printf 'cxx=not found\n'
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

if [[ -z "$compiler" ]]; then
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
for candidate in "$compiler" g++ c++ clang++ xlC \
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
