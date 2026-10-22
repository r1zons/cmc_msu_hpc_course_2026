#!/usr/bin/env bash

# Shared Polus toolchain configuration. Source this file from build and job
# scripts so the cluster-specific values remain in one place.
POLUS_CONDA_BASE=/polusfs/modules/anaconda/anaconda3-2023.03
POLUS_CONDA_ENV=wave-cpp17

# Exact LSF host restriction for the final V1 benchmark. Compute-side hostname
# spellings are recorded for analysis but do not replace this -m value.
POLUS_FULL_V1_HOST=polus-c4-ib.bmc.hpc.cs.msu.ru

# Full V1 benchmark scheduler defaults. Confirm the short-queue RUNLIMIT with
# `bqueues -l short` before submission and adjust the walltime here if needed.
POLUS_FULL_V1_QUEUE=short
POLUS_FULL_V1_WALLTIME=00:10
