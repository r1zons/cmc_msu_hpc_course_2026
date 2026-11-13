#!/usr/bin/env bash
# Print the full matrix, or submit one explicitly selected single-node row.
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/polus/config.sh
if [[ ${1:-} == --plan && $# == 1 ]]; then
    echo 'mode,n,length,ranks,threads,slots,placement'
    for n in 128 256 512; do
        for length in 1 pi; do
            for r in 1 4 8 16 32; do
                placement=single
                ((r <= 20)) || placement=two_nodes
                echo "mpi,$n,$length,$r,1,$r,$placement"
            done
            for r in 1 2 4 8; do
                placement=single
                ((r*4 <= 20)) || placement=two_nodes
                echo "hybrid,$n,$length,$r,4,$((r*4)),$placement"
            done
        done
    done
    exit
fi
if [[ $# != 7 || $1 != --submit-one ]]; then
    echo 'usage: mpi_benchmark.sh --plan | --submit-one CAMPAIGN mpi|hybrid N 1|pi RANKS REP' >&2
    exit 2
fi
campaign=$2 mode=$3 n=$4 length=$5 ranks=$6 rep=$7
[[ $n =~ ^(128|256|512)$ && $length =~ ^(1|pi)$ && $rep =~ ^[1-9][0-9]*$ ]] || exit 2
case $mode in
    mpi) threads=1; [[ $ranks =~ ^(1|4|8|16|32)$ ]] || exit 2 ;;
    hybrid) threads=4; [[ $ranks =~ ^(1|2|4|8)$ ]] || exit 2 ;;
    *) exit 2 ;;
esac
slots=$((ranks*threads))
placement=(-m "${MPI_HOST:-$POLUS_FULL_V1_HOST}" -R 'span[hosts=1]')
export WAVE_MPI_TWO_NODES=0
if ((slots > 20)); then
    [[ ${MPI_ALLOW_TWO_NODES:-0} == 1 ]] || {
        echo 'Requires explicit MPI_ALLOW_TWO_NODES=1 for a 2x16 allocation' >&2; exit 2;
    }
    placement=(-R 'span[ptile=16]')
    export WAVE_MPI_TWO_NODES=1
fi
campaign=$(cd "$campaign" && pwd -P)
[[ -x $campaign/bin/wave_solver_mpi && -x $campaign/bin/wave_solver_opt &&
   -r $campaign/bin/mpi-build.txt && -d $campaign/logs ]] || exit 2
export WAVE_MPI_ROOT="$(pwd -P)" WAVE_MPI_BIN_DIR="$campaign/bin"
export WAVE_MPI_MODE=$mode WAVE_MPI_N=$n WAVE_MPI_LENGTH=$length
export WAVE_MPI_RANKS=$ranks WAVE_MPI_THREADS=$threads WAVE_MPI_TEST=0
id=${mode}_n${n}_l${length}_r${ranks}_rep${rep}
# Reserve each row before bsub. Reconcile with LSF before retrying an uncertain submission.
mkdir "$campaign/logs/$id" || exit 2
bsub -q "${MPI_QUEUE:-$POLUS_FULL_V1_QUEUE}" -W "${MPI_WALLTIME:-$POLUS_FULL_V1_WALLTIME}" \
    -x -n "$slots" "${placement[@]}" \
    -J "$id" -o "$campaign/logs/$id/%J.out" -e "$campaign/logs/$id/%J.err" \
    < scripts/polus/mpi_job.lsf | tee "$campaign/logs/$id/submission.txt"
