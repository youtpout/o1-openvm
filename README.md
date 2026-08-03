# o1-openvm

Universal Mina pickles verifier running in the [OpenVM](https://github.com/openvm-org/openvm)
zkVM. The verifier core is shared with the SP1 port; this repo is the OpenVM
entrypoint, I/O and chip wiring.

```text
stdin  : postcard(UniversalInput { vk_bytes, statement, proof })
reveal : keccak256(abi.encode(bytes32 vkHash, bytes32[] statement))
panic  : if the proof does not verify
```

## Prove on an NVIDIA GPU (vast.ai)

Rent an instance from a CUDA **`-devel`** image (`-runtime` images have the
driver but no `nvcc`, which the CUDA build needs), then:

```bash
git clone git@github.com:youtpout/o1-openvm.git && cd o1-openvm
./scripts/gpu-setup.sh     # rustup + cargo-openvm --features cuda + guest toolchain
make prove                 # keygen if stale, then prove app on the GPU
```

`input.json` is the mainnet fixture and is committed, so a fresh clone proves
without any host-side setup.

The GPU affects only the prover: `--features cuda` swaps each extension's trace
generator for its CUDA one. The guest ELF is identical, so a CPU box runs the
exact same targets — install `cargo-openvm` without `--features cuda` and skip
`gpu-setup.sh`.

## Targets

```bash
make run      # execute, no proof
make meter    # instructions + trace cells
make segment  # segment count (proving shape)
make prove    # app proof
make check    # digest against the recorded golden output
make tamper   # both rejection tests: they must panic, revealing nothing
```

`make help` lists the rest. Implementation notes, measured results and the
failure modes worth knowing are in [CLAUDE.md](CLAUDE.md).
