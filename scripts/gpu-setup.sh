#!/usr/bin/env bash
# Bootstrap a fresh Linux + NVIDIA box for GPU proving.
#
# Tested target: a vast.ai instance started from a CUDA **devel** image
# (`nvidia/cuda:12.9.x-devel-ubuntu24.04` or similar). A *runtime* image ships no
# `nvcc`, and cargo-openvm's `cuda` feature compiles CUDA kernels at install
# time -- so a runtime image fails minutes into the build, not up front.
#
# Idempotent: safe to re-run. The expensive step is the cargo-openvm install
# (CUDA kernel compilation, ~20-40 min on a mid-range box).
#
#   git clone git@github.com:youtpout/o1-openvm.git && cd o1-openvm
#   ./scripts/gpu-setup.sh
#   make prove
set -euo pipefail

OPENVM_TAG=${OPENVM_TAG:-v2.1.0-preview}
RUST_TOOLCHAIN=${RUST_TOOLCHAIN:-1.91.1}
log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
die() { printf '\n\033[1;31merror: %s\033[0m\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- GPU present?
log "Checking the GPU"
command -v nvidia-smi >/dev/null 2>&1 \
  || die "nvidia-smi not found. This script must run ON the GPU machine, not on your laptop."
nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv

# ------------------------------------------------------------- CUDA toolkit?
# The driver gives you nvidia-smi; the *toolkit* gives you nvcc. Only the
# toolkit lets the cuda feature build.
if ! command -v nvcc >/dev/null 2>&1; then
  for d in /usr/local/cuda/bin /usr/local/cuda-13.1/bin /usr/local/cuda-13.0/bin /usr/local/cuda-12.9/bin; do
    [ -x "$d/nvcc" ] && export PATH="$d:$PATH" && break
  done
fi
command -v nvcc >/dev/null 2>&1 || die "nvcc not found. Start the instance from a CUDA *devel* image
(runtime images have the driver but no toolkit), or install cuda-toolkit-12-9.
OpenVM is tested against toolkit 12.9 / 13.0 / 13.1; 12.9 is the most stable."
nvcc --version | tail -2

CUDA_HOME="$(dirname "$(dirname "$(command -v nvcc)")")"
export CUDA_HOME
export LD_LIBRARY_PATH="${CUDA_HOME}/lib64${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
# nvcc is single-threaded per file by default; the backend has a lot of kernels.
export NVCC_THREADS="${NVCC_THREADS:-$(nproc)}"

# ------------------------------------------------------------- system packages
if command -v apt-get >/dev/null 2>&1; then
  log "Installing system packages"
  SUDO=""
  [ "$(id -u)" -ne 0 ] && SUDO="sudo"
  $SUDO apt-get update -qq
  DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y --no-install-recommends \
    build-essential pkg-config libssl-dev cmake clang git curl ca-certificates
fi

# --------------------------------------------------------------------- rust
if ! command -v rustup >/dev/null 2>&1; then
  log "Installing rustup (${RUST_TOOLCHAIN})"
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
    | sh -s -- -y --profile minimal --default-toolchain "${RUST_TOOLCHAIN}"
fi
# shellcheck disable=SC1091
[ -f "${HOME}/.cargo/env" ] && . "${HOME}/.cargo/env"
rustup toolchain install "${RUST_TOOLCHAIN}" --profile minimal
# The OpenVM guest toolchain is a *linked* toolchain: it ships rustc but no
# cargo, and rustup's fallback for that case is nightly's cargo specifically.
# Without nightly installed, `cargo openvm build` dies with
# `'cargo' is not installed for the custom toolchain 'openvm-1.94.1'`.
rustup toolchain install nightly --profile minimal

# ------------------------------------------------------- cargo-openvm (CUDA)
# `--features cuda` is the whole point: it swaps every extension's CPU trace
# generator for its GPU one. All four extensions this guest uses (algebra /
# modular, ecc, keccak256, riscv) have a CUDA backend, so nothing falls back.
log "Installing cargo-openvm ${OPENVM_TAG} with --features cuda (this compiles CUDA kernels, 20-40 min)"
cargo "+${RUST_TOOLCHAIN}" install --locked --force \
  --git https://github.com/openvm-org/openvm.git \
  --tag "${OPENVM_TAG}" \
  --features cuda \
  cargo-openvm

# -------------------------------------------------- guest toolchain (riscv64)
# Prebuilt riscv64im-unknown-openvm-elf from the openvm-org/rust fork. Downloads
# a tarball; it does not build rustc.
log "Installing the OpenVM guest toolchain"
cargo openvm toolchain install
cargo openvm --version

# ------------------------------------------------------------------ shell env
PROFILE="${HOME}/.bashrc"
if ! grep -q 'openvm gpu setup' "${PROFILE}" 2>/dev/null; then
  {
    echo ''
    echo '# openvm gpu setup'
    echo "export PATH=\"${CUDA_HOME}/bin:\$HOME/.cargo/bin:\$PATH\""
    echo "export LD_LIBRARY_PATH=\"${CUDA_HOME}/lib64\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}\""
  } >> "${PROFILE}"
fi

log "Done. Next: make prove"
