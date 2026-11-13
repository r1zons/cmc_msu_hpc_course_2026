# Source after activating wave-cpp17 (source setup.sh mpi does both).
if ! type module >/dev/null 2>&1; then
    source /etc/profile.d/modules.sh || return 1
fi
module load "${POLUS_MPI_MODULE:-OpenMPI/4.0.2}" || return 1
export OMPI_CXX="${CXX:-g++}"
export MPICXX="${MPICXX:-mpicxx}" MPIEXEC="${MPIEXEC:-mpirun}"
export PYTHON="${PYTHON:-${POLUS_CONDA_BASE}/bin/python3}"
export WAVE_REQUIRE_LSF=1
