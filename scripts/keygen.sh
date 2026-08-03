#!/usr/bin/env bash
# Regenerate openvm/app.pk when it is stale, or when FORCE_KEYGEN=1.
#
# Stale means older than `openvm.toml` (chip config changed) or older than the
# cargo-openvm binary (OpenVM version changed). The second case is the nasty
# one: an rv32-era key against an rv64 ELF fails as
# `Memory access out of bounds: start=144 size=8 memory_size=128` from
# memory/online/memmap.rs, and the CLI is stripped so the backtrace is empty.
set -euo pipefail

cd "$(dirname "$0")/.."

NEED=0
[ -f openvm/app.pk ] || NEED=1
if [ -f openvm/app.pk ]; then
  [ openvm.toml -nt openvm/app.pk ] && NEED=1
  CLI_BIN="$(command -v cargo-openvm || true)"
  [ -n "${CLI_BIN}" ] && [ "${CLI_BIN}" -nt openvm/app.pk ] && NEED=1
fi
[ "${FORCE_KEYGEN:-0}" = "1" ] && NEED=1

if [ "${NEED}" = "1" ]; then
  printf '\n\033[1;36m==> Keygen (app only) -- stale or missing app.pk\033[0m\n'
  rm -f openvm/app.pk openvm/app.vk
  cargo openvm keygen --app-only
fi
