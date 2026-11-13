#!/usr/bin/env bash
set -eo pipefail

usage() {
    printf '%s\n' 'Usage: ./run.sh mpi|hybrid [--ranks P] [--threads T] [--n N] [--length 1|pi]' \
        '               [--dims PxXPyXPz] [--steps K] [--cfl F] [--verify] [--dry-run]' \
        'Defaults: N=128, L=1, K=20, CFL=0.5, P=1, T=1 (mpi) or 4 (hybrid).' \
        'Optional environment: MPIEXEC, MPI_SOLVER, MPI_HOSTFILE; run inside an allocation.'
}

mode=${1:-help}
case $mode in
    help|--help|-h) usage; exit ;;
    mpi) threads=1 ;;
    hybrid) threads=4 ;;
    *) usage >&2; exit 2 ;;
esac
shift
ranks=1 dry=false
length=1
args=()
while (($#)); do
    case $1 in
        --help|-h) usage; exit ;;
        --verify) args+=("$1"); shift ;;
        --dry-run) dry=true; shift ;;
        --ranks|--threads|--length|--n|--dims|--lx|--ly|--lz|--steps|--cfl|--time)
            (($# >= 2)) || { echo "missing value for $1" >&2; exit 2; }
            case $1 in
                --ranks) ranks=$2 ;;
                --threads) threads=$2 ;;
                --length) length=$2 ;;
                *) args+=("$1" "$2") ;;
            esac
            shift 2 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done
[[ $ranks =~ ^[1-9][0-9]{0,6}$ && $threads =~ ^[1-9][0-9]{0,6}$ ]] || {
    echo 'ranks and threads must be positive integers' >&2; exit 2;
}
if [[ $mode == mpi && $threads != 1 ]]; then
    echo 'pure MPI requires one thread per rank' >&2; exit 2
fi
[[ $length != pi ]] || length=3.1415926535897931
export OMP_NUM_THREADS=$threads OMP_DYNAMIC=FALSE
export OMP_PLACES=${OMP_PLACES:-cores} OMP_PROC_BIND=${OMP_PROC_BIND:-close}
map=slot
[[ $threads == 1 ]] || map=slot:PE=$threads
map=${MPI_MAP_BY:-$map}
launcher=("${MPIEXEC:-mpirun}" -np "$ranks" --nooversubscribe --map-by "$map" --bind-to core)
if [[ ${MPI_REPORT_BINDINGS:-0} == 1 ]]; then launcher+=(--report-bindings); fi
if [[ -n ${MPI_HOSTFILE:-} ]]; then launcher+=(--hostfile "$MPI_HOSTFILE"); fi
root=$(cd "$(dirname "$0")" && pwd -P)
command=("${launcher[@]}" "${MPI_SOLVER:-$root/build/wave_solver_mpi}"
    --threads "$threads" --lx "$length" --ly "$length" --lz "$length" "${args[@]}")
if $dry; then printf '%q ' "${command[@]}"; printf '\n'; exit; fi
if [[ -n ${LSB_JOBID:-} ]]; then
    [[ ${LSB_DJOB_NUMPROC:-} =~ ^[1-9][0-9]*$ ]] &&
        (( ranks * threads <= LSB_DJOB_NUMPROC )) || {
        echo 'MPI ranks × threads exceed or cannot verify the LSF allocation' >&2; exit 2;
    }
elif [[ ${WAVE_REQUIRE_LSF:-0} == 1 ]]; then
    echo 'run MPI on a Polus compute node via LSF' >&2; exit 2
fi
exec "${command[@]}"
