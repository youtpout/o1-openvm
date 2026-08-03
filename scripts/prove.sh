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

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
die() { printf '\n\033[1;31merror: %s\033[0m\n' "$*" >&2; exit 1; }

[ -f "${INPUT}" ] || die "input file ${INPUT} not found (regenerate with tools/mkinput)"
command -v cargo-openvm >/dev/null 2>&1 || command -v cargo >/dev/null 2>&1 \
  || die "cargo not on PATH -- run scripts/gpu-setup.sh first"

# ------------------------------------------------------------------ preflight
if grep -qs cuda "${HOME}/.openvm/cli-features"; then
  if command -v nvidia-smi >/dev/null 2>&1; then
    log "GPU"
    nvidia-smi --query-gpu=name,memory.used,memory.total --format=csv
  else
    die "cargo-openvm was built with cuda but no nvidia-smi is present"
  fi
else
  printf '\033[1;33mwarning: no CUDA stamp in ~/.openvm/cli-features -- this cargo-openvm is\n'
  printf 'probably a CPU build. Run scripts/gpu-setup.sh to get the GPU prover.\033[0m\n'
fi

# --------------------------------------------------------------------- keygen
./scripts/keygen.sh

# ---------------------------------------------------------------------- prove
ARGS=(prove app --input "${INPUT}" --proof "${PROOF}")
[ -n "${SEGMENT_MAX_MEMORY}" ] && ARGS+=(--segment-max-memory "${SEGMENT_MAX_MEMORY}")

log "Proving with: cargo openvm ${ARGS[*]}"
START=${SECONDS}
cargo openvm "${ARGS[@]}"
ELAPSED=$((SECONDS - START))

log "Proof written to ${PROOF} ($(du -h "${PROOF}" | cut -f1)) in ${ELAPSED}s"

# GPU memory knobs, if the run OOMs on the device:
#   SEGMENT_MAX_MEMORY=...   smaller segments -> more, smaller proofs
#   VPMM_PAGE_SIZE / VPMM_VA_SIZE / VPMM_PAGES  virtual-memory pool of the CUDA
#     backend (crates/cuda-common/src/memory_manager/vm_pool.rs)
