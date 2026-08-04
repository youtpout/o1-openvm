#!/usr/bin/env bash
# Generate an app proof, on GPU if cargo-openvm was installed with `--features cuda`.
#
#   ./scripts/prove.sh [input.json]
#
# The guest ELF is identical CPU or GPU -- `cuda` only swaps the host-side trace
# generator. So this script is the same on both, and the only GPU-specific parts
# are the preflight checks and the memory knobs documented at the bottom.
#
# Keygen is delegated to scripts/keygen.sh, which re-runs it only when app.pk is
# stale.
set -euo pipefail

cd "$(dirname "$0")/.."

INPUT=${1:-input.json}
PROOF=${PROOF:-o1-openvm-verifier.app.proof}
SEGMENT_MAX_MEMORY=${SEGMENT_MAX_MEMORY:-}
# EXE=path/to.vmexe skips the guest build entirely and proves a transpiled
# executable built elsewhere. The prebuilt OpenVM rustc needs GLIBC 2.39 /
# GLIBCXX 3.4.32 (it is built on Ubuntu 24.04, and the fork ships one tarball
# per host triple, no older-glibc variant), so on a 22.04 box the *build* is
# impossible while the *proving* is fine -- it is a plain CPU/GPU binary.
# Build on any 24.04+ or macOS machine, copy the .vmexe over, prove here.
EXE=${EXE:-}

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
die() { printf '\n\033[1;31merror: %s\033[0m\n' "$*" >&2; exit 1; }

# gpu-setup.sh appends this to .bashrc, but the shell that ran it never re-reads
# its own rc file -- so the first `make prove` after a setup finds no cargo.
# shellcheck disable=SC1091
[ -f "${HOME}/.cargo/env" ] && . "${HOME}/.cargo/env"

[ -f "${INPUT}" ] || die "input file ${INPUT} not found (regenerate with tools/mkinput)"
command -v cargo >/dev/null 2>&1 \
  || die "cargo not on PATH -- run scripts/gpu-setup.sh, or . ~/.cargo/env"

# ------------------------------------------------------------------ preflight
# The CLI reports its own features: `cargo-openvm v2.0.0 (538c548) [cuda]`.
if cargo openvm --version 2>/dev/null | grep -q '\[cuda\]'; then
  command -v nvidia-smi >/dev/null 2>&1 \
    || die "cargo-openvm was built with cuda but no nvidia-smi is present"
  log "GPU"
  nvidia-smi --query-gpu=name,memory.used,memory.total --format=csv
else
  printf '\033[1;33mwarning: cargo-openvm reports no [cuda] -- this is a CPU build.\n'
  printf 'Run scripts/gpu-setup.sh to get the GPU prover.\033[0m\n'
fi

# --------------------------------------------------------------------- keygen
./scripts/keygen.sh

# ---------------------------------------------------------------------- prove
ARGS=(prove app --input "${INPUT}" --proof "${PROOF}")
[ -n "${SEGMENT_MAX_MEMORY}" ] && ARGS+=(--segment-max-memory "${SEGMENT_MAX_MEMORY}")
if [ -n "${EXE}" ]; then
  [ -f "${EXE}" ] || die "EXE=${EXE} not found"
  ARGS+=(--exe "${EXE}")
fi

log "Proving with: cargo openvm ${ARGS[*]}"
START=${SECONDS}
cargo openvm "${ARGS[@]}"
ELAPSED=$((SECONDS - START))

log "Proof written to ${PROOF} ($(du -h "${PROOF}" | cut -f1)) in ${ELAPSED}s"

# GPU memory knobs, if the run OOMs on the device:
#   SEGMENT_MAX_MEMORY=...   smaller segments -> more, smaller proofs
#   VPMM_PAGE_SIZE / VPMM_VA_SIZE / VPMM_PAGES  virtual-memory pool of the CUDA
#     backend (crates/cuda-common/src/memory_manager/vm_pool.rs)
