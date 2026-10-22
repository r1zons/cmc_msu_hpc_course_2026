#!/usr/bin/env bash
# Prepare the existing Polus Conda environment, build V1, and run tests.
#
# From the repository root:
#   ./setup.sh          # build and test; environment stays inside this script
#   source ./setup.sh   # build and test; environment also stays in your shell

_wave_setup() {
    local repo_root config_file conda_init compiler python_executable python_version

    repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)" || return 1
    config_file="${repo_root}/scripts/polus/config.sh"

    if [[ ! -f "$config_file" ]]; then
        printf 'setup error: missing %s\n' "$config_file" >&2
        return 1
    fi

    # Reuse the single source of truth for the Polus Conda installation.
    # shellcheck source=/dev/null
    source "$config_file" || return 1

    if [[ -z "${POLUS_CONDA_BASE:-}" || -z "${POLUS_CONDA_ENV:-}" ]]; then
        printf 'setup error: POLUS_CONDA_BASE or POLUS_CONDA_ENV is not set in %s\n' "$config_file" >&2
        return 1
    fi

    conda_init="${POLUS_CONDA_BASE}/etc/profile.d/conda.sh"
    if [[ ! -f "$conda_init" ]]; then
        printf 'setup error: Conda initialization script not found: %s\n' "$conda_init" >&2
        return 1
    fi

    # shellcheck source=/dev/null
    source "$conda_init" || return 1
    conda activate "$POLUS_CONDA_ENV" || {
        printf 'setup error: failed to activate Conda environment %s\n' "$POLUS_CONDA_ENV" >&2
        return 1
    }

    if [[ -z "${CONDA_PREFIX:-}" ]]; then
        printf 'setup error: CONDA_PREFIX is empty after activation\n' >&2
        return 1
    fi

    # Avoid duplicating the same path if setup.sh is sourced more than once.
    case ":${LD_LIBRARY_PATH:-}:" in
        *":${CONDA_PREFIX}/lib:"*) ;;
        *) export LD_LIBRARY_PATH="${CONDA_PREFIX}/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}" ;;
    esac

    compiler="${CXX:-g++}"
    if ! command -v "$compiler" >/dev/null 2>&1; then
        printf 'setup error: C++ compiler not found: %s\n' "$compiler" >&2
        return 1
    fi

    # The compiler environment does not necessarily provide a modern Python.
    # Use the Python shipped by the confirmed Anaconda base explicitly; Polus'
    # default python3 is 3.6 and cannot parse the benchmark analysis tests.
    python_executable="${POLUS_CONDA_BASE}/bin/python3"
    if [[ ! -x "$python_executable" ]]; then
        printf 'setup error: Anaconda Python executable not found: %s\n' \
            "$python_executable" >&2
        return 1
    fi
    if ! "$python_executable" -c \
        'import sys; raise SystemExit(0 if sys.version_info >= (3, 7) else 1)'
    then
        python_version=$("$python_executable" --version 2>&1 || printf 'unknown')
        printf 'setup error: Python 3.7 or newer is required; selected %s (%s)\n' \
            "$python_executable" "$python_version" >&2
        return 1
    fi
    python_version=$("$python_executable" --version 2>&1) || {
        printf 'setup error: could not query Python version: %s\n' \
            "$python_executable" >&2
        return 1
    }

    printf 'Repository: %s\nConda environment: %s\nCompiler: %s\nPython: %s (%s)\n' \
        "$repo_root" "$POLUS_CONDA_ENV" "$compiler" \
        "$python_executable" "$python_version"

    # Always rebuild with the selected Conda compiler, not old system GCC.
    make -C "$repo_root" clean || return 1
    make -C "$repo_root" CXX="$compiler" || return 1
    make -C "$repo_root" test \
        CXX="$compiler" \
        PYTHON="$python_executable" || return 1

    printf '\nSetup complete: V1 built and tests passed.\n'
    return 0
}

_wave_setup "$@"
_wave_setup_status=$?
unset -f _wave_setup
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    exit "$_wave_setup_status"
else
    return "$_wave_setup_status"
fi
